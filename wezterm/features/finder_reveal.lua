-- CMD+OPT+click a path: reveal it in Finder (a remote file is first copied to
-- ~/Downloads/<host>/ over the ssh pane's ControlMaster), so it can be
-- dragged into a browser upload, Slack, ... Clicks go through features/paths.lua.
local links = require 'lib.links'

local M = { needs = { 'paths' } }

function M.apply(config)
  links.bind_click(config, 'CMD|OPT', 'reveal')
end

return M
