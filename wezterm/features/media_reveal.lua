-- Clicked video and audio files go to Finder (features/paths.lua asks ctx.is_media).
-- Video and audio can't play in a terminal: a plain click reveals them too
local MEDIA_EXT = {}
for e in ([[mp4 mov m4v mkv webm avi wmv flv mpg mpeg 3gp mp3 wav m4a flac aac ogg opus aiff]]):gmatch '%S+' do
  MEDIA_EXT[e] = true
end

local function is_media(path)
  local ext = path:match '%.([^./]+)$'
  return ext ~= nil and MEDIA_EXT[ext:lower()] == true
end

local M = { needs = { 'paths' } }

function M.apply(_, ctx)
  ctx.is_media = is_media
end

return M
