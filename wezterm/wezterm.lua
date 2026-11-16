-- WezTerm config (WezTerm 20240203, macOS). Features live in features/, shared
-- code in lib/.
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

local features = setmetatable({}, { __index = function() return true end })

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

local function never() return false end
local ctx = { features = features, is_media = never, is_pdf = never }

require('features.tab_bar').apply(config, ctx)
require('features.ghostty_keys').apply(config, ctx)
require('features.ssh_aware').apply(config, ctx)
require('features.copy_paste').apply(config, ctx)
require('features.sidebar').apply(config, ctx)
require('features.rename').apply(config, ctx)
require('features.paths').apply(config, ctx)
require('features.finder_reveal').apply(config, ctx)
require('features.quicklook').apply(config, ctx)
require('features.media_reveal').apply(config, ctx)
require('features.pdf_preview').apply(config, ctx)
require('features.downloads').apply(config, ctx)
require('features.port_forward').apply(config, ctx)
require('features.layout_repair').apply(config, ctx)
require('features.fullscreen_refit').apply(config, ctx)
require('features.pane_moves').apply(config, ctx)
require('features.md_preview').apply(config, ctx)
require('features.session_restore').apply(config, ctx)
require('features.hibernation').apply(config, ctx)
require('features.reload_toast').apply(config, ctx)

-- WezTerm reloads when a module it loaded changes; also watch this file by
-- its real path
for _, pattern in ipairs { '/wezterm.lua' } do
  for _, path in ipairs(wezterm.glob(DIR .. pattern)) do wezterm.add_to_config_reload_watch_list(path) end
end

return config
