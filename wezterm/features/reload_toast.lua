-- "config reloaded" on the tab bar after a reload.
local wezterm = require 'wezterm'
local core = require 'lib.core'
local toast = core.toast

local M = {}

function M.apply()
  -- A reload is otherwise silent on macOS, so confirm it on the tab bar. The
  -- counter tells a real reload apart from the same event at first launch.
  wezterm.GLOBAL.config_gen = (wezterm.GLOBAL.config_gen or 0) + 1
  wezterm.on('window-config-reloaded', function(window)
    local gen, shown = wezterm.GLOBAL.config_gen, wezterm.GLOBAL.config_gen_shown
    if gen == shown then return end
    wezterm.GLOBAL.config_gen_shown = gen
    if shown then toast(window, 'config reloaded', 4000) end
  end)
end

return M
