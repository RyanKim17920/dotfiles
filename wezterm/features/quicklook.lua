-- CMD+OPT+SHIFT+click a path: open the file in macOS Quick Look (a remote one
-- is first copied to ~/Library/Caches/wezterm/peek/<host>/). Clicks go
-- through features/paths.lua.
local links = require 'lib.links'

local M = { needs = { 'paths' } }

function M.apply(config)
  links.bind_click(config, 'CMD|OPT|SHIFT', 'look')
end

return M
