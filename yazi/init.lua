-- Peek mode: WezTerm's clickable file paths launch yazi with
-- YAZI_PEEK=<absolute file path> (see ~/.wezterm.lua). Show hidden files (so
-- a clicked dotfile like ~/.wezterm.lua can be hovered), hover the file, and
-- start with the preview maximized exactly as if T (toggle-pane max-preview)
-- had been pressed, so T still restores the normal layout.
-- Normal yazi and the CMD+E sidebar never set YAZI_PEEK.
local peek = os.getenv("YAZI_PEEK")
if peek and peek ~= "" then
	ya.emit("hidden", { "show" })
	ya.emit("plugin", { "toggle-pane", "max-preview" })
	-- Re-hover once the directory has loaded (with hidden entries); earlier
	-- reveals are lost when the listing arrives.
	local parent = peek:match("^(.*)/[^/]*$")
	parent = parent == "" and "/" or parent
	ps.sub("load", function(body)
		if tostring(body.url) == parent then
			ps.unsub("load")
			ya.emit("reveal", { peek })
		end
	end)
end
