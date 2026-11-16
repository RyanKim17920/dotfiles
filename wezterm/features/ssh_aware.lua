-- ssh-aware splits, tabs and windows: from a local pane running ssh,
-- CMD+D / CMD+SHIFT+D / CMD+T / CMD+N open ssh-pane to the same host
-- (instant over its ControlMaster); elsewhere they split or spawn as usual.
-- CMD+SHIFT+T / CMD+SHIFT+N always open a local tab / window.
local wezterm = require 'wezterm'
local act = wezterm.action
local core = require 'lib.core'
local ssh_lib = require 'lib.ssh'
local pane_cwd, SPAWN_PATH = core.pane_cwd, core.SPAWN_PATH
local pane_ssh_args = ssh_lib.pane_ssh_args

-- SSH-aware splits (VS Code style): splitting a local pane whose foreground
-- process is plain `ssh` opens a fresh shell on the same host. Relies on
-- ControlMaster in ~/.ssh/config, so the new connection is instant. The new
-- pane runs ssh through ssh-pane: it closes when that session exits normally,
-- but a dropped connection leaves it open with Enter to reconnect.
local function smart_split(direction)
  return wezterm.action_callback(function(window, pane)
    local args = pane_ssh_args(pane)
    if args then
      pane:split {
        direction = direction,
        args = args,
        cwd = pane_cwd(pane),
        set_environment_variables = { PATH = SPAWN_PATH },
      }
    elseif direction == 'Right' then
      window:perform_action(act.SplitHorizontal { domain = 'CurrentPaneDomain' }, pane)
    else
      window:perform_action(act.SplitVertical { domain = 'CurrentPaneDomain' }, pane)
    end
  end)
end

-- SSH-aware new tab/window: from a local pane running ssh, open a fresh
-- ssh-pane to the same host (instant via ControlMaster); otherwise the default
-- spawn.
local function smart_spawn(new_window)
  return wezterm.action_callback(function(window, pane)
    local args = pane_ssh_args(pane)
    if args then
      local spec = {
        args = args,
        cwd = pane_cwd(pane),
        set_environment_variables = { PATH = SPAWN_PATH },
      }
      window:perform_action(new_window and act.SpawnCommandInNewWindow(spec)
        or act.SpawnCommandInNewTab(spec), pane)
    else
      window:perform_action(new_window and act.SpawnWindow or act.SpawnTab 'CurrentPaneDomain', pane)
    end
  end)
end

local M = {}

function M.apply(config)
  for _, key in ipairs {
    -- Splits (Ghostty: cmd+d = right, cmd+shift+d = down); ssh-aware
    { key = 'd', mods = 'CMD', action = smart_split 'Right' },
    { key = 'd', mods = 'CMD|SHIFT', action = smart_split 'Bottom' },

    -- New tab/window, ssh-aware (see smart_spawn); CMD+SHIFT variants are always local
    { key = 't', mods = 'CMD', action = smart_spawn(false) },
    { key = 'n', mods = 'CMD', action = smart_spawn(true) },
    { key = 't', mods = 'CMD|SHIFT', action = act.SpawnTab 'DefaultDomain' },
    { key = 'n', mods = 'CMD|SHIFT', action = act.SpawnWindow },
  } do table.insert(config.keys, key) end
end

return M
