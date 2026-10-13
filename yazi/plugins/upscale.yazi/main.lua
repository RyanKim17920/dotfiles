--- Image previewer that enlarges small raster images.
--
-- Yazi never upscales: an icon or a small screenshot is drawn at its native
-- pixel size, which on a Retina display is tiny. For images whose BOTH sides
-- are small next to the preview area, this writes an enlarged PNG copy into
-- Yazi's cache (keyed by file + target size) and shows that instead. Anything
-- else, and every failure path, falls through to the built-in `image`
-- previewer, so the worst case is the stock behaviour.
--
-- Resizer: `sips` on macOS (built in), ImageMagick `magick`/`convert`
-- elsewhere; with neither, small images are shown at native size.

local FILL = 0.8 -- fraction of the preview area the enlarged image should fill
local MAX_SCALE = 8 -- never enlarge more than this
local MIN_SCALE = 1.5 -- below this the gain is not worth a resize
local SKIP_SALT = 0x75707363 -- separates our cache keys from the built-in image cache

local M = {}

-- Pixel size of the preview area, capped like Yazi's own downscaler caps it
-- (anything larger would just be shrunk again by `ya.image_show`).
local function area_pixels(area)
	local cw, ch = rt.term.cell_size()
	if not cw or not ch or cw <= 0 or ch <= 0 then
		return nil
	end
	return math.min(area.w * cw, rt.preview.max_width), math.min(area.h * ch, rt.preview.max_height)
end

-- Largest side of the enlarged image, or nil when the image should not be enlarged.
local function target_side(info, area)
	local aw, ah = area_pixels(area)
	if not aw or info.w <= 0 or info.h <= 0 then
		return nil
	end

	-- EXIF orientations 5-8 swap width and height on screen
	local w, h = info.w, info.h
	if info.ori and info.ori >= 5 then
		w, h = h, w
	end

	local scale = math.min(aw * FILL / w, ah * FILL / h, MAX_SCALE)
	if scale < MIN_SCALE then
		return nil
	end
	return math.floor(math.max(info.w, info.h) * scale)
end

-- Resize `src` so its larger side is `side` pixels, writing a PNG to `dst`.
local function resize(src, dst, side)
	local cmds
	if ya.target_os() == "macos" then
		cmds = {
			Command("sips"):arg { "-s", "format", "png", "-Z", tostring(side), tostring(src), "--out", tostring(dst) },
		}
	else
		-- `[0]`: first frame of animated GIF/WebP; magick is IM7, convert is IM6
		local args = { tostring(src) .. "[0]", "-resize", string.format("%dx%d", side, side), "PNG32:" .. tostring(dst) }
		cmds = { Command("magick"):arg(args), Command("convert"):arg(args) }
	end

	for _, cmd in ipairs(cmds) do
		local status = cmd:stdout(Command.NULL):stderr(Command.NULL):status()
		if status then -- the tool exists; do not try the next one
			return status.success
		end
	end
	return false
end

-- Path of an enlarged copy of the hovered image, creating it when needed; nil to fall back.
local function enlarged(job)
	local src = Url(job.file.path)
	local info = ya.image_info(src)
	if not info then
		return nil
	end

	local side = target_side(info, job.area)
	if not side then
		return nil
	end

	local cache = ya.file_cache { file = job.file, skip = SKIP_SALT + side }
	if not cache then
		return nil
	end
	if fs.cha(cache) then
		return cache
	end

	-- write next to the final name, then rename, so a cancelled peek never
	-- leaves a half-written file that later looks like a valid cache entry
	local tmp = Url(tostring(cache) .. ".part.png")
	if resize(src, tmp, side) and fs.rename(tmp, cache) then
		return cache
	end
	fs.remove("file", tmp)
	return nil
end

function M:peek(job)
	local start = os.clock()
	local url = enlarged(job)
	if not url then
		return require("image"):peek(job)
	end

	ya.sleep(math.max(0, rt.preview.image_delay / 1000 + start - os.clock()))

	local _, err = ya.image_show(url, job.area)
	ya.preview_widget(job, err)
end

function M:seek(job) require("image"):seek(job) end

-- The enlarged copy depends on the preview area, which preloaders do not get,
-- so it is made on first peek; preload keeps the built-in downscaled cache for
-- large images.
function M:preload(job) return require("image"):preload(job) end

function M:spot(job) return require("image"):spot(job) end

return M
