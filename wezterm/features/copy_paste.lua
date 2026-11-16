-- Smart copy/paste: CMD+C / CMD+V and their SHIFT / CTRL variants copy the
-- selection or paste; CTRL+C with no selection still sends ^C; pasting an
-- image in an ssh pane uploads it (clipimg-push) and types the remote path.
local wezterm = require 'wezterm'
local act = wezterm.action
local core = require 'lib.core'
local ssh_lib = require 'lib.ssh'
local YAZI_PATH = core.YAZI_PATH
local pane_ssh_args = ssh_lib.pane_ssh_args

-- Unified copy/paste (VS Code terminal style): CMD+C, CMD+SHIFT+C,
-- CTRL+SHIFT+C and CTRL+C all run smart_copy; the V variants run smart_paste,
-- except that CTRL+V only does in ssh panes (see the key table).
local CLIPIMG = wezterm.home_dir .. '/.local/bin/clipimg-push'

-- Copy the selection (and clear it) if there is one. Otherwise CTRL+C passes
-- through as a raw ^C so interrupt still works; CMD+C does nothing.
local function smart_copy(passthrough)
  return wezterm.action_callback(function(window, pane)
    if window:get_selection_text_for_pane(pane) ~= '' then
      window:perform_action(act.CopyTo 'ClipboardAndPrimarySelection', pane)
      window:perform_action(act.ClearSelection, pane)
    elseif passthrough then
      window:perform_action(act.SendKey { key = 'c', mods = 'CTRL' }, pane)
    end
  end)
end

-- Paste, image-aware. `clipimg-push --check` (~0.1s, synchronous) decides:
--  * image + local pane running ssh: Claude Code on the remote host can't read
--    this Mac's clipboard but accepts a path, so clipimg-push uploads the image
--    to ~/.cache/clipimg/ on that host (via the ControlMaster) in the
--    background and types the remote path into the pane.
--  * image + any other pane: send a raw Ctrl+V; local Claude Code reads the
--    image from the macOS clipboard itself on that keypress.
--  * no image: normal bracketed paste of the clipboard text.
local smart_paste = wezterm.action_callback(function(window, pane)
  if not wezterm.run_child_process { CLIPIMG, '--check' } then
    window:perform_action(act.PasteFrom 'Clipboard', pane)
    return
  end
  local args = pane_ssh_args(pane)
  if args then
    local cmd = { '/usr/bin/env', 'PATH=' .. YAZI_PATH, CLIPIMG, tostring(pane:pane_id()) }
    for k = 2, #args do table.insert(cmd, args[k]) end -- drop leading ssh-pane
    wezterm.background_child_process(cmd)
  else
    window:perform_action(act.SendKey { key = 'v', mods = 'CTRL' }, pane)
  end
end)

local M = {}

function M.apply(config)
  for _, key in ipairs {
    -- Unified copy/paste (see smart_copy / smart_paste above)
    { key = 'c', mods = 'CMD', action = smart_copy(false) },
    { key = 'c', mods = 'CMD|SHIFT', action = smart_copy(false) },
    { key = 'c', mods = 'CTRL|SHIFT', action = smart_copy(false) },
    { key = 'c', mods = 'CTRL', action = smart_copy(true) },
    { key = 'v', mods = 'CMD', action = smart_paste },
    { key = 'v', mods = 'CMD|SHIFT', action = smart_paste },
    { key = 'v', mods = 'CTRL|SHIFT', action = smart_paste },
    -- Local panes keep the raw key: local Claude Code pastes images on it
    { key = 'v', mods = 'CTRL', action = wezterm.action_callback(function(window, pane)
      window:perform_action(pane_ssh_args(pane) and smart_paste or act.SendKey { key = 'v', mods = 'CTRL' }, pane)
    end) },
  } do table.insert(config.keys, key) end
end

return M
