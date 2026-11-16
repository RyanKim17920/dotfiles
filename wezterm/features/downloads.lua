-- Right-click a path in an ssh pane: download the file or folder to
-- ~/Downloads/<host>/ in the background over the pane's ControlMaster, then
-- reveal it in Finder. Clicks go through features/paths.lua.
local wezterm = require 'wezterm'
local act = wezterm.action
local ssh_lib = require 'lib.ssh'
local files = require 'lib.files'
local links = require 'lib.links'
local pane_ssh_args = ssh_lib.pane_ssh_args
local LINK_MODE_KEY = links.LINK_MODE_KEY

local M = { needs = { 'paths' } }

function M.apply(config)
  files.enable_polling()
  for _, reporting in ipairs { false, true } do
    -- Right-click on a path in an ssh pane downloads it (see download_remote);
    -- right-click was unbound before, so elsewhere it stays a no-op. Lua can't
    -- hand a mouse event back to the app, so only Up is bound: an app that
    -- grabs the mouse (mouse_reporting) still gets the press, in every pane,
    -- but not the release. A press with no link under it leaves the mode unused:
    -- drop it, or the next plain click on a link within 2s would download.
    table.insert(config.mouse_bindings, {
      event = { Up = { streak = 1, button = 'Right' } },
      mods = 'NONE',
      mouse_reporting = reporting,
      action = wezterm.action_callback(function(window, pane)
        if not pane_ssh_args(pane) then return end
        local stamp = 'download ' .. os.time()
        wezterm.GLOBAL[LINK_MODE_KEY] = stamp
        window:perform_action(act.OpenLinkAtMouseCursor, pane)
        wezterm.time.call_after(0.5, function()
          if wezterm.GLOBAL[LINK_MODE_KEY] == stamp then wezterm.GLOBAL[LINK_MODE_KEY] = nil end
        end)
      end),
    })
  end
end

return M
