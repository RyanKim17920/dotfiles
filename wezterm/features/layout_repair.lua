-- Layout repair: CMD+SHIFT+= (and after every window resize, quietly)
-- rebuilds a tab whose panes spill past the window edge, a WezTerm 20240203
-- bug no resize undoes (see repair_layout in lib/layout.lua).
local wezterm = require 'wezterm'
local act = wezterm.action
local layout = require 'lib.layout'
local repair_layout = layout.repair_layout

local M = {}

function M.apply(config)
  -- Manual fix (CMD+SHIFT+=) and automatic checks after window resizes
  wezterm.on('fix-layout', function(window, pane) repair_layout(window, pane:tab(), false) end)
  wezterm.on('window-resized', function(window, pane)
    if pane then repair_layout(window, pane:tab(), true) end
  end)
  for _, key in ipairs {
    -- Fix layout: refit panes that spill past the window edge (see repair_layout);
    -- macOS reports Shift+= as either key
    { key = '=', mods = 'CMD|SHIFT', action = act.EmitEvent 'fix-layout' },
    { key = '+', mods = 'CMD|SHIFT', action = act.EmitEvent 'fix-layout' },
  } do table.insert(config.keys, key) end
end

return M
