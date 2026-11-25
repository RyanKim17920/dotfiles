-- WezTerm config (WezTerm 20240203, macOS): Ghostty-style splits that follow
-- you into ssh, Yazi peeks on clicked paths, session restore and more.
--
-- Features: each one lives in features/<name>.lua with its own keys, mouse
-- bindings, link rules and event handlers (shared code is in lib/). Set one
-- to false to leave it out. To do that without editing this tracked file,
-- put the overrides in local.lua next to it (gitignored), e.g.
--   return { hibernation = false, sidebar = false }
local features = {
  tab_bar = true,          -- Catppuccin retro tab bar (number, icon, ssh host or cwd) and pickers
  ghostty_keys = true,     -- Ghostty-style pane keys: splits, close, focus, resize, zoom, swap, rotate, tab order
  ssh_aware = true,        -- CMD+D/T/N from an ssh pane open ssh-pane to the same host
  copy_paste = true,       -- CMD/CTRL+C/V copy-or-interrupt, image paste into ssh panes
  sidebar = true,          -- CMD+E toggles a Yazi file sidebar
  rename = true,           -- CMD+SHIFT+R / CMD+CTRL+R rename the tab / window
  paths = true,            -- CMD+click a path opens it in a Yazi peek (local and over ssh)
  finder_reveal = true,    -- CMD+OPT+click a path reveals it in Finder (needs paths)
  quicklook = true,        -- CMD+OPT+SHIFT+click a path opens Quick Look (needs paths)
  media_reveal = true,     -- CMD+click a video/audio file reveals it in Finder (needs paths)
  pdf_preview = true,      -- CMD+click a PDF opens it in Preview (needs paths)
  downloads = true,        -- right-click a path in an ssh pane (or g m in remote Yazi) downloads it (needs paths)
  drag = true,             -- Finder drag and drop: g o / g i in Yazi, CMD+SHIFT+U drop zone (wez-drag helper)
  port_forward = true,     -- CMD+click localhost URLs / ssh -L commands forwards the port; CMD+SHIFT+L
  ports = true,            -- CMD+SHIFT+I lists remote/local ports to forward or open; toasts new remote ports
  layout_repair = true,    -- CMD+SHIFT+= and window resizes refit panes that spill off the window
  fullscreen_refit = true, -- refit a fullscreen window after a monitor is unplugged
  pane_moves = true,       -- CMD+OPT+T/N/1..9 move panes, CMD+SHIFT+M merges windows
  md_preview = true,       -- side-by-side Markdown preview for mdedit over ssh
  session_restore = true,  -- reopen windows, tabs, splits and their commands at launch
  hibernation = true,      -- stop agent CLI panes idle for an hour, resume on a key
  reload_toast = true,     -- "config reloaded" toast on the tab bar
}

-- Settings, overridden in local.lua the same way (same type as here), e.g.
--   return { ssh_bg_hosts = { 'myhost' } }
local settings = {
  -- ssh destinations (as typed, no user@) whose WezTerm remote commands
  -- (path checks, downloads, drag, previews) ride WezTerm's own key-only
  -- background ControlMaster, so they never compete with your ssh tabs for
  -- the server's MaxSessions (lib/ssh.lua). Duo/2FA hosts are always refused.
  ssh_bg_hosts = {},
  -- The CMD+SHIFT+I list asks each listening port of yours for its page
  -- <title> (one quick request each, at most 2 s per host, then cached until
  -- the process changes). false skips it, e.g. on a slow HPC login node.
  port_titles = true,
}

local wezterm = require 'wezterm'

-- require() and the reload watcher need this file's real directory: WezTerm
-- loads ~/.wezterm.lua, a symlink to it, and only searches ~/.config/wezterm
-- and ~/.wezterm itself
local function real_dir()
  local file = wezterm.config_file or ''
  local ok, success, out = pcall(wezterm.run_child_process, { '/usr/bin/readlink', '-f', file })
  local real = ok and success and out:match '^(/[^\n]*)' or file
  return real:match '^(.*)/[^/]*$' or '.'
end
local DIR = real_dir()
package.path = DIR .. '/?.lua;' .. DIR .. '/?/init.lua;' .. package.path

local LOCAL_FILE = DIR .. '/local.lua'
local f = io.open(LOCAL_FILE)
if f then
  f:close()
  local ok, overrides = pcall(dofile, LOCAL_FILE)
  if not ok or type(overrides) ~= 'table' then
    wezterm.log_error('features: local.lua must return a table of flags: ' .. tostring(overrides))
  else
    for name, on in pairs(overrides) do
      if settings[name] ~= nil and type(on) == type(settings[name]) then
        settings[name] = on
      elseif features[name] == nil or type(on) ~= 'boolean' then
        wezterm.log_warn('features: local.lua: ignoring ' .. tostring(name) .. ' = ' .. tostring(on))
      else
        features[name] = on
      end
    end
  end
end

require('lib.ssh').bg_hosts = settings.ssh_bg_hosts
require('features.ports').fetch_titles = settings.port_titles

local config = wezterm.config_builder()
local with_editor = require('lib.core').with_editor

-- Base settings, always on ------------------------------------------------

-- Match Ghostty's `working-directory = ~/Desktop`
config.default_cwd = wezterm.home_dir .. '/Desktop'

-- Make the inactive pane visibly dimmer so the focused split is obvious
config.inactive_pane_hsb = { saturation = 0.8, brightness = 0.7 }

-- Render at the MacBook's 120Hz ProMotion rate instead of the 60fps default
config.max_fps = 120

-- Render via WebGpu (Metal) instead of the OpenGL default: measured ~40% lower
-- memory footprint (~70-118 MB vs ~137-187 MB with 3 panes), same look
config.front_end = 'WebGpu'

-- A Dock-launched GUI has no EDITOR, and Yazi's built-in text opener runs
-- ${EDITOR:-vi}: give every pane (and each peek) micro instead of vim
config.set_environment_variables = with_editor {}

-- Closing a pane that only runs an idle shell needs no confirmation
-- (the default list, minus tmux: closing it kills the sessions inside)
config.skip_close_confirmation_for_processes_named = { 'bash', 'sh', 'zsh', 'fish', 'nu' }

-- Polling features (peek return, background copies, session save,
-- hibernation) run on update-status
config.status_update_interval = 200

-- Paths and ssh -L commands are added after WezTerm's own URL rules
config.hyperlink_rules = wezterm.default_hyperlink_rules()

config.keys = {}
config.mouse_bindings = {}

-- Features, in this order (link rules and update-status handlers keep it) --

local ORDER = {
  'tab_bar',
  'ghostty_keys',
  'ssh_aware',
  'copy_paste',
  'sidebar',
  'rename',
  'paths',
  'finder_reveal',
  'quicklook',
  'media_reveal',
  'pdf_preview',
  'downloads',
  'drag',
  'port_forward',
  'ports',
  'layout_repair',
  'fullscreen_refit',
  'pane_moves',
  'md_preview',
  'session_restore',
  'hibernation',
  'reload_toast',
}

-- Handed to every feature: the flags, and the click predicates that
-- media_reveal and pdf_preview replace
local function never() return false end
local ctx = { features = features, is_media = never, is_pdf = never }
for _, name in ipairs(ORDER) do
  if features[name] then
    local feature = require('features.' .. name)
    local missing
    for _, need in ipairs(feature.needs or {}) do
      if not features[need] then missing = need end
    end
    if missing then
      features[name] = false
      wezterm.log_warn('features: ' .. name .. ' needs ' .. missing .. ', which is off; skipped')
    else
      feature.apply(config, ctx)
    end
  end
end

-- WezTerm reloads when a module it loaded changes; also watch this file by
-- its real path and local.lua
for _, pattern in ipairs { '/wezterm.lua', '/local.lua' } do
  for _, path in ipairs(wezterm.glob(DIR .. pattern)) do wezterm.add_to_config_reload_watch_list(path) end
end

return config
