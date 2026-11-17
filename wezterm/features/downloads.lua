-- Right-click a path in an ssh pane: download the file or folder to
-- ~/Downloads/<host>/ in the background over the pane's ControlMaster, then
-- reveal it in Finder. Clicks go through features/paths.lua.
-- Remote Yazi does the same for its selection (g m in yazi/keymap.toml),
-- which shows no path to click: it sets the user var wez_download.
local wezterm = require 'wezterm'
local act = wezterm.action
local core = require 'lib.core'
local ssh_lib = require 'lib.ssh'
local files = require 'lib.files'
local links = require 'lib.links'
local pane_ssh_args = ssh_lib.pane_ssh_args
local LINK_MODE_KEY = links.LINK_MODE_KEY

local M = { needs = { 'paths' } }

-- Most items one wez_download request may fetch (each is its own ssh + tar)
local MAX_ITEMS = 50

-- user var wez_download = "NONCE\n/abs/path\n..." (base64-decoded by
-- WezTerm; the nonce makes a repeat request a change). Honoured only in a
-- local pane running ssh: the paths are on that pane's host.
local function on_download_request(window, pane, value)
  local ssh = pane_ssh_args(pane)
  if not ssh then return end
  local paths, seen, bad = {}, {}, 0
  for line in (value:match '^[^\n]*\n(.*)$' or ''):gmatch '[^\n]+' do
    if line:sub(1, 1) ~= '/' or line:find '[\0\r]' then
      bad = bad + 1
    elseif not seen[line] then
      seen[line] = true
      table.insert(paths, line)
    end
  end
  if bad > 0 then
    wezterm.log_warn('downloads: ignored ' .. bad .. ' invalid path(s) in wez_download')
  end
  if #paths == 0 then
    if bad > 0 then core.toast(window, 'Download: no usable path in the request') end
  elseif #paths > MAX_ITEMS then
    core.toast(window, 'Download: ' .. #paths .. ' items selected, at most ' .. MAX_ITEMS
      .. '; select their folder instead', 6000)
  else
    files.download_remote(window, ssh, paths)
  end
end

function M.apply(config)
  files.enable_polling()
  wezterm.on('user-var-changed', function(window, pane, name, value)
    if name == 'wez_download' then on_download_request(window, pane, value) end
  end)
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
