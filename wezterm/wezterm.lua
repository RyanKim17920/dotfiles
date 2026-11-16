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
do
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

M.apply(config, ctx)
end
do
-- Fullscreen refit after a monitor change. WezTerm's own (non-native)
-- fullscreen sets the window frame to the screen it was entered on and never
-- refits it (toggle_simple_fullscreen in window/src/os/macos/window.rs, same
-- on nightly). Unplug the external monitor and the window lands on the
-- laptop still at the monitor's size, so the panes run off the screen. On a
-- resize that leaves a fullscreen window bigger than every screen, wait for
-- the display change to settle, then leave and re-enter fullscreen, which
-- sizes it to the current screen. One try per oversize episode, so a wrong
-- guess can't loop toggling fullscreen.
local wezterm = require 'wezterm'
local act = wezterm.action

local SETTLE_SECONDS = 1
local refit = {} -- window id -> 'pending' or 'tried', until it fits again

-- True if the window (dims from get_dimensions) fits on some screen.
-- Compared in points: macOS dpi is 72 per backing scale unit
local function fits_a_screen(dims)
  local w = dims.pixel_width * 72 / dims.dpi
  local h = dims.pixel_height * 72 / dims.dpi
  for _, s in pairs(wezterm.gui.screens().by_name) do
    if w <= s.width / s.scale + 1 and h <= s.height / s.scale + 1 then return true end
  end
  return false
end

local function oversized_fullscreen(window)
  local dims = window:get_dimensions()
  return dims.is_full_screen and not fits_a_screen(dims), dims
end

local M = {}

function M.apply()
  wezterm.on('window-resized', function(window)
    local id = window:window_id()
    if not oversized_fullscreen(window) then
      refit[id] = nil
      return
    end
    if refit[id] then return end
    refit[id] = 'pending'
    wezterm.time.call_after(SETTLE_SECONDS, function()
      local ok, oversized, dims = pcall(oversized_fullscreen, window)
      if not ok or not oversized then
        refit[id] = nil
        return
      end
      refit[id] = 'tried'
      wezterm.log_info(string.format('Fullscreen: %dx%d px at %d dpi is bigger than every screen; refitting',
        dims.pixel_width, dims.pixel_height, dims.dpi))
      window:perform_action(act.ToggleFullScreen, window:active_pane())
      window:perform_action(act.ToggleFullScreen, window:active_pane())
    end)
  end)
end

M.apply(config, ctx)
end
do
-- Moving panes between tabs and windows: CMD+OPT+T / CMD+OPT+N to a new tab /
-- window, CMD+OPT+1..9 (SHIFT: below) into tab N as a split, CMD+SHIFT+M
-- merges every other window into this one with split layouts kept.
local wezterm = require 'wezterm'
local act = wezterm.action
local core = require 'lib.core'
local layout = require 'lib.layout'
local toast, peek_open, cli = core.toast, core.peek_open, core.cli
local merge_tab, repair_layout, split_fits = layout.merge_tab, layout.repair_layout, layout.split_fits

-- Merge every other window into this one, one new tab per source tab with its
-- split layout kept, in window order then tab order. Emptied windows close on
-- their own once their last pane leaves.
local merge_windows = wezterm.action_callback(function(window, pane)
  local cur = window:mux_window():window_id()
  -- Capture all geometry before anything moves
  local tabs = {}
  for _, w in ipairs(wezterm.mux.all_windows()) do
    if w:window_id() ~= cur then
      for _, t in ipairs(w:tabs()) do
        t:set_zoomed(false) -- zoom hides the other panes' real geometry
        local panes = {}
        for _, info in ipairs(t:panes_with_info()) do
          table.insert(panes, {
            id = info.pane:pane_id(), left = info.left, top = info.top,
            width = info.width, height = info.height,
          })
        end
        if #panes > 0 then table.insert(tabs, panes) end
      end
    end
  end
  local total, moved, lost = 0, 0, 0
  for _, panes in ipairs(tabs) do
    local n, exact = merge_tab(panes, cur)
    total, moved = total + #panes, moved + n
    if not exact and #panes > 1 then lost = lost + 1 end
  end
  local msg = string.format('Merge: %d tab%s (%d pane%s)', #tabs, #tabs == 1 and '' or 's',
    moved, moved == 1 and '' or 's')
  if lost > 0 then msg = msg .. '; layout lost in ' .. lost .. ' (split into tabs)' end
  if moved < total then msg = msg .. '; ' .. (total - moved) .. ' failed' end
  toast(window, msg, 4000)
  repair_layout(window, window:mux_window():active_tab(), true)
end)

-- Move this pane into tab N of this window (1-based, tab bar order) as a
-- split to the right of (flag '--right') or below ('--bottom') that tab's
-- active pane, then switch to tab N and focus it. A single-pane source tab
-- closes once its last pane leaves.
local function move_to_tab(n, flag)
  return wezterm.action_callback(function(window, pane)
    local tabs = window:mux_window():tabs()
    local target = tabs[n]
    if not target then
      toast(window, 'Move: no tab ' .. n, 2000)
      return
    end
    if target:tab_id() == pane:tab():tab_id() then
      toast(window, 'Move: already in tab ' .. n, 2000)
      return
    end
    if peek_open(target) then
      toast(window, 'Move: close the peek in tab ' .. n .. ' first', 2000)
      return
    end
    -- An overflowing or zoomed target refuses the split, and a refused
    -- --move-pane-id split loses the pane (see split_fits): fix those first
    target:set_zoomed(false)
    target = repair_layout(window, target, true)
    local id = tostring(pane:pane_id())
    local anchor = target:active_pane():pane_id()
    if not split_fits(anchor, flag, 50) then
      toast(window, 'Move: no room to split in tab ' .. n .. '; pane left where it was', 4000)
      return
    end
    local ok, err = cli('split-pane', '--pane-id', tostring(anchor),
      flag, '--percent', '50', '--move-pane-id', id)
    if not ok then
      toast(window, 'Move: failed: ' .. (err or '?'), 4000)
      return
    end
    -- Activate the tab object, not index N-1: indices shift if the source tab closed
    target:activate()
    cli('activate-pane', '--pane-id', id)
  end)
end

local M = {}

function M.apply(config)
  for _, key in ipairs {
    -- Move the focused pane out into a new tab / new window
    { key = 't', mods = 'CMD|OPT', action = wezterm.action_callback(function(_, pane)
      pane:move_to_new_tab()
    end) },
    { key = 'n', mods = 'CMD|OPT', action = wezterm.action_callback(function(_, pane)
      pane:move_to_new_window()
    end) },
    -- Pull every other window's tabs into this window, keeping split layouts
    { key = 'm', mods = 'CMD|SHIFT', action = merge_windows },
  } do table.insert(config.keys, key) end

  -- Move the focused pane into tab N (1-9) as a split: CMD+OPT+N = right of
  -- that tab's active pane, CMD+OPT+SHIFT+N = below it. phys: keys so Option/
  -- Shift symbols (¡, !, ...) don't stop the digits from matching.
  for n = 1, 9 do
    table.insert(config.keys, { key = 'phys:' .. n, mods = 'CMD|OPT', action = move_to_tab(n, '--right') })
    table.insert(config.keys, { key = 'phys:' .. n, mods = 'CMD|OPT|SHIFT', action = move_to_tab(n, '--bottom') })
  end
end

M.apply(config, ctx)
end
do
-- Side-by-side Markdown over ssh: remote mdedit asks (by user var) for its
-- preview pane next to the ssh pane.
local wezterm = require 'wezterm'
local core = require 'lib.core'
local ssh_lib = require 'lib.ssh'
local cli, sh_quote, pane_cwd, YAZI_PATH = core.cli, core.sh_quote, core.pane_cwd, core.YAZI_PATH
local pane_ssh_args = ssh_lib.pane_ssh_args

-- Side-by-side Markdown over ssh. Locally ~/.local/bin/mdedit splits the pane
-- itself with `wezterm cli`; on a remote host it can't, so it sets user vars
-- (OSC 1337 SetUserVar, base64-decoded by WezTerm before this handler runs):
--  * mdedit_preview = "NONCE|/abs/path": if this is a local pane running ssh,
--    open `ssh -t HOST mdpreview PATH` to its right (instant via
--    ControlMaster) and keep focus on the editor.
--  * mdedit_close = NONCE: micro exited; kill that preview pane.
--  * mdpreview_reload: sent by mdpreview's watcher after a re-render; press
--    R in that pane so less reloads in place. send_text is raw input, not a
--    bracketed paste.
-- Local panes not running ssh ignore mdedit_*: local mdedit handles itself.
local MD_PREVIEW_KEY = 'md_preview_for_pane_' -- .. editor pane id -> "NONCE|PREVIEW_ID"

-- Kill the preview recorded for editor pane `editor_id` (only if its nonce
-- matches `nonce`, when given) and forget it.
local function close_md_preview(editor_id, nonce)
  local key = MD_PREVIEW_KEY .. editor_id
  local entry = wezterm.GLOBAL[key]
  if not entry then return end
  local n, preview = entry:match '^(.*)|(%d+)$'
  if nonce and n ~= nonce then return end
  wezterm.GLOBAL[key] = nil
  if preview then cli('kill-pane', '--pane-id', preview) end
end

local M = {}

function M.apply()
  wezterm.on('user-var-changed', function(_, pane, name, value)
    if name == 'mdpreview_reload' then
      pane:send_text 'R'
    elseif name == 'mdedit_close' then
      close_md_preview(pane:pane_id(), value)
    elseif name == 'mdedit_preview' then
      local nonce, path = value:match '^([^|]*)|(/.*)$'
      local ssh = nonce and pane_ssh_args(pane)
      if not ssh then return end
      close_md_preview(pane:pane_id()) -- stale preview from an mdedit that died
      local args = { 'ssh', '-t' }
      for k = 2, #ssh do table.insert(args, ssh[k]) end
      -- One remote command string; the remote shell expands $HOME
      table.insert(args, '"$HOME/.local/bin/mdpreview" ' .. sh_quote(path))
      local preview = pane:split {
        direction = 'Right',
        size = 0.5,
        args = args,
        cwd = pane_cwd(pane),
        set_environment_variables = { PATH = YAZI_PATH },
      }
      pane:activate()
      wezterm.GLOBAL[MD_PREVIEW_KEY .. pane:pane_id()] = nonce .. '|' .. preview:pane_id()
    end
  end)
end

M.apply(config, ctx)
end
do
-- Session restore, browser style: windows, tabs (order, titles), split
-- layouts with proportions, zoom, the active tab/pane, the sidebar and what
-- each pane was running come back after quitting WezTerm, a reboot or a
-- crash. No process is kept alive: panes are re-created and their commands
-- re-run (see restore_spec). The snapshot is saved to session.json by the
-- poller below whenever it changed; WezTerm 20240203 has no quit event, so
-- the last settled state before quitting is what comes back.
local wezterm = require 'wezterm'
local core = require 'lib.core'
local ssh_lib = require 'lib.ssh'
local layout = require 'lib.layout'
local agent = require 'lib.agent'
local toast, mux_pane, peek_open, peek_record = core.toast, core.mux_pane, core.peek_open, core.peek_record
local pane_cwd, sh_quote, SPAWN_PATH, is_dir, exists = core.pane_cwd, core.sh_quote, core.SPAWN_PATH, core.is_dir, core.exists
local SIDEBAR_KEY, sidebar_spec = core.SIDEBAR_KEY, core.sidebar_spec
local info_ssh_args, ssh_host, SSH_PANE, RESTORE_TAG = ssh_lib.info_ssh_args, ssh_lib.ssh_host, ssh_lib.SSH_PANE, ssh_lib.RESTORE_TAG
local find_cut, anchor_of = layout.find_cut, layout.anchor_of
local STATE_DIR, CLAUDE_DIR, read_file, write_atomic = agent.STATE_DIR, agent.CLAUDE_DIR, agent.read_file, agent.write_atomic
local present, base, set_of, SHELLS = agent.present, agent.base, agent.set_of, agent.SHELLS
local is_idle_shell, is_claude, claude_session = agent.is_idle_shell, agent.is_claude, agent.claude_session
local RESTORE_SHELL, shell_args, hibernated_session = agent.RESTORE_SHELL, agent.shell_args, agent.hibernated_session

local SESSION_FILE = STATE_DIR .. '/session.json'
local SESSION_PREV = STATE_DIR .. '/session.prev.json' -- the session before this launch
local NO_RESTORE_FILE = STATE_DIR .. '/no-restore' -- exists = no auto-restore at launch
local SKIP_HOSTS_FILE = STATE_DIR .. '/restore-skip-hosts' -- ssh hosts never reconnected
local SNAPSHOT_VERSION = 1
local SETTLE_MAX = 10 -- seconds a changing state may delay the save

-- Compact JSON with sorted keys, so equal states compare equal as strings
local function canon(v)
  if type(v) ~= 'table' then return wezterm.json_encode(v) end
  local out = {}
  if #v > 0 or next(v) == nil then
    for i, x in ipairs(v) do out[i] = canon(x) end
    return '[' .. table.concat(out, ',') .. ']'
  end
  local keys = {}
  for k in pairs(v) do table.insert(keys, k) end
  table.sort(keys)
  for _, k in ipairs(keys) do table.insert(out, wezterm.json_encode(k) .. ':' .. canon(v[k])) end
  return '{' .. table.concat(out, ',') .. '}'
end

-- What a pane was running ---------------------------------------------------

-- Commands that are never re-run on their own: re-running could damage or
-- duplicate work, so they are only typed at the prompt (see type_when_ready)
local DENY_BARE = set_of [[rm rmdir mv cp dd sudo doas su kill pkill killall shutdown reboot halt
  ssh-setup mkfs diskutil truncate shred srm unlink tee scp rsync]]
local DENY_ARGS = {
  git = set_of [[push commit reset rebase merge clean checkout switch pull cherry-pick revert stash
    tag am apply rm mv restore add]],
  docker = set_of 'rm rmi prune kill stop down push system volume',
  kubectl = set_of 'delete apply patch scale replace drain cordon',
  terraform = set_of 'apply destroy import',
  gh = set_of 'merge create delete close edit',
}
local PKG_WRITE = set_of [[install i add remove uninstall rm un update upgrade up publish link unlink
  cleanup autoremove sync init create ci dedupe prune]]
for _, pm in ipairs { 'npm', 'pnpm', 'yarn', 'bun', 'pip', 'pip3', 'uv', 'brew', 'cargo', 'gem',
    'conda', 'mamba', 'apt', 'apt-get' } do
  DENY_ARGS[pm] = PKG_WRITE
end
DENY_ARGS.podman = DENY_ARGS.docker
DENY_ARGS.tofu = DENY_ARGS.terraform
-- Commands that run other commands: every argument may be the real one
local WRAPPERS = set_of 'env nice nohup time caffeinate command builtin exec xargs watch timeout'

local function is_denied(argv)
  local from = 1
  if SHELLS[base(argv[1])] then
    if (argv[2] or '-'):sub(1, 1) == '-' then -- sh -c '...': scan the script's words and redirects
      for i = 2, #argv do
        if argv[i]:find '>' then return true end
        for w in argv[i]:gmatch '[%w_-]+' do
          if DENY_BARE[w] then return true end
        end
      end
      return false
    end
    from = 2 -- sh script.sh args: the script is the command
  end
  local cmd = base(argv[from])
  if DENY_BARE[cmd] then return true end
  local deny = DENY_ARGS[cmd]
  for i = from + 1, #argv do
    if (deny and deny[argv[i]]) or (WRAPPERS[cmd] and DENY_BARE[base(argv[i])]) then return true end
  end
  return false
end

local command_argv, names_temp
do
-- The command a user would type for argv:
-- * an interpreter running a script that is a command on PATH (uv, pipx and
--   npm install CLIs as `#!/abs/python` or `#!/usr/bin/env node` scripts):
--   `.../bin/python ~/.local/bin/tool` -> `tool` (so shell functions of that
--   name apply again)
-- * yazi without --cwd-file/--chooser-file: temp files of the wrapper that
--   started it, gone after it exits (restore_spec runs it via `y` again)
local INTERPRETERS = set_of 'python python3 node ruby perl bun deno'
local CMD_DIRS = set_of(table.concat({ SPAWN_PATH:gsub(':', ' '), wezterm.home_dir .. '/.local/bin',
  wezterm.home_dir .. '/bin', wezterm.home_dir .. '/.cargo/bin', wezterm.home_dir .. '/.bun/bin',
  '/usr/local/bin', '/opt/homebrew/bin' }, ' '))
local YAZI_TEMP_OPTS = set_of '--cwd-file --chooser-file'
function command_argv(argv)
  local script, interp = argv[2] or '', base(argv[1]):gsub('[%d.]+$', '')
  if INTERPRETERS[interp] and CMD_DIRS[script:match '^(.*)/' or ''] then
    local f = io.open(script, 'r')
    local line = f and f:read '*l' or ''
    if f then f:close() end
    local direct, via_env = line:match '^#!%s*(%S+)', line:match '^#!%s*%S*/env%s+(%S+)%s*$'
    if direct == argv[1] or via_env == base(argv[1]) then
      return { base(script), table.unpack(argv, 3) }
    end
  end
  if base(argv[1]) == 'yazi' then
    local out, i = { 'yazi' }, 2
    while i <= #argv do
      local a = argv[i]
      if YAZI_TEMP_OPTS[a] then
        i = i + 1 -- and its value
      elseif not YAZI_TEMP_OPTS[a:match '^(%-%-[%w-]+)=' or ''] then
        table.insert(out, a)
      end
      i = i + 1
    end
    return out
  end
  return argv
end

-- Does a command name a file in the per-user temp dir (mktemp: an editor on
-- a shell's edit-command-line buffer, ...)? It is gone after a reboot: only
-- typed, never re-run.
local TEMP_DIRS = { '/var/folders/', '/private/var/folders/', os.getenv 'TMPDIR' or '' }
function names_temp(argv)
  for i = 2, #argv do
    for _, dir in ipairs(TEMP_DIRS) do
      if dir ~= '' and argv[i]:find(dir, 1, true) then return true end
    end
  end
  return false
end
end

-- Pane record: where it sits (cells; set by capture_tab) and what it ran.
-- kind: shell (idle), run (argv, re-run), typed (argv, only typed at the
-- prompt), claude (id), ssh (ssh-pane args), sidebar
local function capture_pane(pane, is_sidebar)
  local rec = { kind = 'shell' }
  local cwd = pane_cwd(pane)
  local info = pane:get_domain_name() == 'local' and pane:get_foreground_process_info()
  local ssh = info and info_ssh_args(info)
  local argv = info and info.argv or {}
  local hib_id, hib_cwd = hibernated_session(pane:pane_id(), info)
  if is_sidebar then
    rec.kind = 'sidebar'
  elseif hib_id then -- saved as the claude pane it was, never as its wake screen
    rec.kind, rec.claude = 'claude', hib_id
    cwd = present(hib_cwd) and hib_cwd or cwd
  elseif ssh then
    rec.kind, rec.ssh = 'ssh', { table.unpack(ssh, 2) }
    cwd = nil -- the local shell's cwd means nothing on the host
  elseif info and is_claude(info) then
    local id, id_cwd = claude_session(pane:pane_id(), info)
    if id then
      rec.kind, rec.claude = 'claude', id
      cwd = present(id_cwd) and id_cwd or cwd
    else
      rec.kind, rec.argv = 'typed', command_argv(argv)
    end
  elseif #argv > 0 and not is_idle_shell(argv)
      and not (#argv == 1 and argv[1]:find ' ') then -- a program that rewrote its own title
    argv = command_argv(argv)
    rec.kind, rec.argv = (is_denied(argv) or names_temp(argv)) and 'typed' or 'run', argv
    cwd = present(info.cwd) and info.cwd or cwd
  end
  if present(cwd) then rec.cwd = cwd end
  return rec
end

-- Capture ---------------------------------------------------------------------

-- Pane geometry is hidden while a tab is zoomed and skewed while a peek is
-- split in, so the last clean layout is remembered per tab (one JSON string in
-- wezterm.GLOBAL, rebuilt each capture so closed tabs drop out).
local function capture_tab(tab, geoms_in, geoms_out)
  local tab_id = tostring(tab:tab_id())
  local sidebar_id = wezterm.GLOBAL[SIDEBAR_KEY .. tab:tab_id()]
  local peek = peek_open(tab) and peek_record(tab) or nil
  local infos, recs, ids, fresh, frozen = tab:panes_with_info(), {}, {}, {}, peek ~= nil
  local zoomed_rec, active_rec
  for _, info in ipairs(infos) do
    local pid = info.pane:pane_id()
    frozen = frozen or info.is_zoomed
    if not (peek and pid == peek.peek) then
      local rec = capture_pane(info.pane, pid == sidebar_id)
      table.insert(recs, rec)
      ids[rec] = tostring(pid)
      fresh[tostring(pid)] = { left = info.left, top = info.top, width = info.width, height = info.height }
      if info.is_zoomed and not peek then zoomed_rec = rec end
      if (peek and pid == peek.origin) or (not peek and info.is_active) then active_rec = rec end
      if peek and pid == peek.origin and peek.zoomed then zoomed_rec = rec end
    end
  end
  local geom = fresh
  if frozen then
    geom = geoms_in[tab_id]
    for _, rec in ipairs(recs) do
      if not (geom and geom[ids[rec]]) then geom = nil break end
    end
    if not geom then -- never saw it unzoomed: lay the panes out side by side
      geom = {}
      local size = tab:get_size()
      local w = math.max(1, math.floor(size.cols / #recs))
      for i, rec in ipairs(recs) do
        geom[ids[rec]] = { left = (i - 1) * w, top = 0, width = w, height = size.rows }
      end
    end
  end
  geoms_out[tab_id] = geom
  for _, rec in ipairs(recs) do
    local g = geom[ids[rec]]
    rec.left, rec.top, rec.width, rec.height = g.left, g.top, g.width, g.height
  end
  active_rec = active_rec or recs[1]
  if active_rec then active_rec.active = true end
  if zoomed_rec then zoomed_rec.zoomed = true end
  return { title = tab:get_title(), panes = recs }
end

-- The whole GUI state as plain data
local function capture_session()
  local geoms_in = wezterm.json_parse(wezterm.GLOBAL.tab_geoms or '{}')
  local geoms_out, windows, focused = {}, {}, {}
  if wezterm.gui then
    for _, gw in ipairs(wezterm.gui.gui_windows()) do
      if gw:is_focused() then focused[gw:window_id()] = true end
    end
  end
  local all = wezterm.mux.all_windows()
  table.sort(all, function(a, b) return a:window_id() < b:window_id() end)
  -- Peeks in a tab of their own (see replace_peek) are not saved; peek tab id
  -- -> the tab it was opened from
  local peek_tabs = {}
  for _, mw in ipairs(all) do
    for _, tab in ipairs(mw:tabs()) do
      local rec = not peek_open(tab) and peek_record(tab)
      local peek = rec and mux_pane(rec.peek)
      local peek_tab = peek and peek:tab()
      if peek_tab and #peek_tab:panes() == 1 then peek_tabs[peek_tab:tab_id()] = tab end
    end
  end
  for _, mw in ipairs(all) do
    local tabs, active = {}, mw:active_tab()
    if active and peek_tabs[active:tab_id()] then active = peek_tabs[active:tab_id()] end
    local wrec = { title = mw:get_title(), workspace = mw:get_workspace(), focused = focused[mw:window_id()] }
    for _, tab in ipairs(mw:tabs()) do
      if not peek_tabs[tab:tab_id()] then table.insert(tabs, capture_tab(tab, geoms_in, geoms_out)) end
      if active and tab:tab_id() == active:tab_id() then
        wrec.active_tab = #tabs
        local size = tab:get_size()
        wrec.cols, wrec.rows = size.cols, size.rows
      end
    end
    wrec.tabs = tabs
    -- A pane's own title can end up as the window title; only a title that
    -- is not one of them was set by the user
    for _, tab in ipairs(mw:tabs()) do
      for _, p in ipairs(tab:panes()) do
        if p:get_title() == wrec.title then wrec.title = '' end
      end
    end
    if #tabs > 0 then table.insert(windows, wrec) end
  end
  wezterm.GLOBAL.tab_geoms = wezterm.json_encode(geoms_out)
  return { version = SNAPSHOT_VERSION, workspace = wezterm.mux.get_active_workspace(), windows = windows }
end

-- Claude session files of panes that no longer exist
local function prune_claude_files(live)
  local ok, files = pcall(wezterm.read_dir, CLAUDE_DIR)
  for _, path in ipairs(ok and files or {}) do
    if not live[base(path)] then os.remove(path) end
  end
end

-- Save the state once it has stopped changing (so a half-closed set of
-- windows during quit is never written), or has kept changing for SETTLE_MAX
-- seconds. Called about once a second.
local function save_session()
  local G = wezterm.GLOBAL
  if G.session_restoring then return end
  local ok, snap = pcall(capture_session)
  if not ok then
    wezterm.log_error('session: capture failed: ' .. tostring(snap))
    return
  end
  if #snap.windows == 0 then return end
  local text, now = canon(snap), os.time()
  if text == G.session_saved then
    G.session_pending, G.session_dirty_since = nil, nil
    return
  end
  G.session_dirty_since = G.session_dirty_since or now
  local settled = text == G.session_pending
  G.session_pending = text
  if not settled and now - G.session_dirty_since < SETTLE_MAX then return end
  local live, windows, kept = {}, ',', false
  for _, mw in ipairs(wezterm.mux.all_windows()) do
    windows = windows .. mw:window_id() .. ','
    kept = kept or (G.session_windows or ''):find(',' .. mw:window_id() .. ',', 1, true) ~= nil
    for _, tab in ipairs(mw:tabs()) do
      for _, p in ipairs(tab:panes()) do live[tostring(p:pane_id())] = true end
    end
  end
  -- None of the saved windows is left (the last window was closed, not quit,
  -- and a new one opened; nothing is saved while there are none): keep that
  -- session as session.prev.json (Cmd+Shift+O) before replacing it
  if G.session_windows and not kept then
    local last = read_file(SESSION_FILE)
    if last then write_atomic(SESSION_PREV, last) end
  end
  local wrote, err = write_atomic(SESSION_FILE, text .. '\n')
  if not wrote then
    wezterm.log_error('session: save failed: ' .. tostring(err))
    return
  end
  G.session_saved, G.session_dirty_since, G.session_windows = text, nil, windows
  prune_claude_files(live)
end

-- Restore ---------------------------------------------------------------------

local function join_argv(argv)
  local words = {}
  for _, a in ipairs(argv) do table.insert(words, sh_quote(tostring(a))) end
  return table.concat(words, ' ')
end

-- Hosts (user@ ignored) never reconnected on restore: WEZTERM_RESTORE_SKIP_HOSTS
-- (comma or space separated) and one per line in restore-skip-hosts
local function skip_hosts()
  local set = {}
  for h in (os.getenv 'WEZTERM_RESTORE_SKIP_HOSTS' or ''):gmatch '[^,%s]+' do set[h] = true end
  for line in (read_file(SKIP_HOSTS_FILE) or ''):gmatch '[^\n]+' do
    local h = line:gsub('#.*', ''):match '^%s*(.-)%s*$'
    if h ~= '' then set[h] = true end
  end
  return set
end

-- Runs under /bin/sh with the ssh-pane command line as arguments: an
-- optional pause, then (for further panes of a host) wait until the first
-- one's ControlMaster is up so they ride it instead of logging in again
local SSH_RESTORE_SCRIPT = [[
sleep "${WEZ_RESTORE_DELAY:-0}"
i=0
if [ -n "$WEZ_RESTORE_WAIT" ]; then
  p=$1; shift
  while [ "$i" -lt 90 ] && ! ssh -O check "$@" >/dev/null 2>&1; do sleep 1; i=$((i + 1)); done
  set -- "$p" "$@"
fi
unset WEZ_RESTORE_DELAY WEZ_RESTORE_WAIT
exec "$@"]]

-- Spawn spec for a pane record, plus the text to type at its prompt (or nil)
local function restore_spec(rec, ctx)
  local spec = {}
  -- The shell cds there itself: WezTerm drops a spawn cwd it cannot list
  local cwd = present(rec.cwd) and rec.cwd or nil
  if cwd and is_dir(cwd) then spec.cwd = cwd end
  local kind = rec.kind
  if kind == 'sidebar' then
    return sidebar_spec(cwd or wezterm.home_dir)
  elseif kind == 'ssh' and type(rec.ssh) == 'table' and #rec.ssh > 0 then
    local full = { SSH_PANE, table.unpack(rec.ssh) }
    local host, dest = ssh_host(full), rec.ssh[#rec.ssh]
    if ctx.skip[host] or ctx.skip[dest] then
      spec.args = shell_args('printf "%s\\n" ' .. sh_quote('restore: not reconnecting to ' .. host), cwd)
      return spec
    end
    local first = not ctx.hosts[host]
    if first then ctx.hosts[host], ctx.nhosts = true, ctx.nhosts + 1 end
    spec.args = { '/bin/sh', '-c', SSH_RESTORE_SCRIPT, RESTORE_TAG, table.unpack(full) }
    spec.set_environment_variables = {
      PATH = SPAWN_PATH,
      WEZ_RESTORE_DELAY = tostring(first and 2 * (ctx.nhosts - 1) or 1),
      WEZ_RESTORE_WAIT = first and '' or '1',
    }
  elseif kind == 'claude' and type(rec.claude) == 'string' and rec.claude:match '^[%w_-]+$' then
    spec.args = shell_args('claude --resume ' .. rec.claude, cwd)
  elseif kind == 'run' and type(rec.argv) == 'table' and #rec.argv > 0 then
    local cmd = join_argv(rec.argv)
    if rec.argv[1] == 'yazi' then -- via the shell's `y` wrapper (cd to where yazi was left), if it has one
      cmd = 'if typeset -f y >/dev/null 2>&1; then y ' .. join_argv { table.unpack(rec.argv, 2) }
        .. '; else ' .. cmd .. '; fi'
    end
    spec.args = shell_args(cmd, cwd)
  else
    if cwd then spec.args = { '/bin/sh', '-c', 'cd "$1" 2>/dev/null; exec "$2" -l', 'sh', cwd, RESTORE_SHELL } end
    if kind == 'typed' and type(rec.argv) == 'table' and #rec.argv > 0 then return spec, join_argv(rec.argv) end
  end
  return spec
end

-- Put `text` on the pane's command line without running it, once the shell
-- has drawn its prompt (typed earlier it would echo twice)
local function type_when_ready(pane, text, tries)
  wezterm.time.call_after(0.25, function()
    local ok, shown = pcall(pane.get_lines_as_text, pane)
    if ok and shown:match '%S' then
      pcall(pane.send_text, pane, text)
    elseif tries > 0 then
      type_when_ready(pane, text, tries - 1)
    end
  end)
end

local function finish_pane(pane, typed)
  if typed then type_when_ready(pane, typed, 40) end
end

-- Split `pane` (holding the top-left record of `group`) into the rest of the
-- group, following the same clean cuts merge_tab uses
local function build_group(group, pane, ctx, live)
  if #group <= 1 then return end
  local first, second, flag, pct = find_cut(group)
  if not first then -- not a split tree (hand-edited file): stack the rest to the right
    for i = 2, #group do
      local spec, typed = restore_spec(group[i], ctx)
      spec.direction = 'Right'
      live[group[i]] = pane:split(spec)
      finish_pane(live[group[i]], typed)
    end
    return
  end
  local anchor = anchor_of(second)
  local spec, typed = restore_spec(anchor, ctx)
  spec.direction = flag == '--right' and 'Right' or 'Bottom'
  spec.size = pct / 100
  local created = pane:split(spec)
  live[anchor] = created
  finish_pane(created, typed)
  build_group(first, pane, ctx, live)
  build_group(second, created, ctx, live)
end

local function restore_tab(tab, pane, trec, ctx, typed)
  local anchor = anchor_of(trec.panes)
  local live = { [anchor] = pane }
  finish_pane(pane, typed)
  build_group(trec.panes, pane, ctx, live)
  if (trec.title or '') ~= '' then tab:set_title(trec.title) end
  local active, zoomed
  for _, rec in ipairs(trec.panes) do
    if rec.kind == 'sidebar' then wezterm.GLOBAL[SIDEBAR_KEY .. tab:tab_id()] = live[rec]:pane_id() end
    if rec.active then active = live[rec] end
    if rec.zoomed then zoomed = live[rec] end
  end
  if zoomed then
    zoomed:activate()
    tab:set_zoomed(true)
  elseif active then
    active:activate()
  end
end

local function restore_window(wrec, ctx)
  local mw, tabs = nil, {}
  for _, trec in ipairs(wrec.tabs) do
    if type(trec.panes) == 'table' and #trec.panes > 0 then
      local spec, typed = restore_spec(anchor_of(trec.panes), ctx)
      local tab, pane
      if mw then
        tab, pane = mw:spawn_tab(spec)
      else
        if type(wrec.cols) == 'number' and type(wrec.rows) == 'number' then
          spec.width, spec.height = math.floor(wrec.cols), math.floor(wrec.rows)
        end
        spec.workspace = wrec.workspace
        tab, pane, mw = wezterm.mux.spawn_window(spec)
      end
      restore_tab(tab, pane, trec, ctx, typed)
      tabs[#tabs + 1] = tab
    end
  end
  if tabs[wrec.active_tab] then tabs[wrec.active_tab]:activate() end
  -- last: programs starting in the tabs above retitle the window
  if mw and (wrec.title or '') ~= '' then mw:set_title(wrec.title) end
  return mw ~= nil
end

-- Re-create the windows of `snap`; the focused window last so it ends on top.
-- Returns how many windows came back.
local function restore_session(snap)
  local ctx = { skip = skip_hosts(), hosts = {}, nhosts = 0 }
  local order = {}
  for _, w in ipairs(snap.windows) do
    if type(w.tabs) == 'table' then table.insert(order, w) end
  end
  -- Stable, focused window last (table.sort is not stable)
  local rank = {}
  for i, w in ipairs(order) do rank[w] = (w.focused and 1e6 or 0) + i end
  table.sort(order, function(a, b) return rank[a] < rank[b] end)
  wezterm.GLOBAL.session_restoring = true
  local n = 0
  for _, w in ipairs(order) do
    local ok, made = pcall(restore_window, w, ctx)
    if ok and made then
      n = n + 1
    else
      wezterm.log_error('session: window restore failed: ' .. tostring(made))
    end
  end
  if snap.workspace and n > 0 then pcall(wezterm.mux.set_active_workspace, snap.workspace) end
  wezterm.GLOBAL.session_restoring = nil
  return n
end

local function load_snapshot(path)
  local ok, snap = pcall(function() return wezterm.json_parse(read_file(path) or '') end)
  if ok and type(snap) == 'table' and snap.version == SNAPSHOT_VERSION and type(snap.windows) == 'table'
      and #snap.windows > 0 then
    return snap
  end
  return nil
end

local function restore_disabled()
  return os.getenv 'WEZTERM_NO_RESTORE' == '1' or exists(NO_RESTORE_FILE)
end

-- Fresh launch: keep the last session as session.prev.json (unless it is just
-- one empty-looking window and a better one is already kept), forget stale
-- Claude ids (pane ids restart from 0), then restore or open the default window
local function startup(cmd)
  local current = load_snapshot(SESSION_FILE)
  if current then
    local trivial = #current.windows == 1 and #current.windows[1].tabs == 1
      and #current.windows[1].tabs[1].panes == 1 and current.windows[1].tabs[1].panes[1].kind == 'shell'
    if not trivial or not load_snapshot(SESSION_PREV) then
      write_atomic(SESSION_PREV, read_file(SESSION_FILE))
    end
  end
  prune_claude_files {}
  local n = 0
  if current and not cmd and not restore_disabled() then
    local ok, made = pcall(restore_session, current)
    n = ok and made or 0
    if not ok then wezterm.log_error('session: restore failed: ' .. tostring(made)) end
  end
  if n == 0 and #wezterm.mux.all_windows() == 0 then wezterm.mux.spawn_window(cmd or {}) end
end
local restore_previous = wezterm.action_callback(function(window)
  local snap = load_snapshot(SESSION_PREV)
  if not snap then
    toast(window, 'Session: no previous session saved', 2000)
    return
  end
  local n = restore_session(snap)
  toast(window, string.format('Session: restored %d window%s', n, n == 1 and '' or 's'), 3000)
end)

local toggle_auto_restore = wezterm.action_callback(function(window)
  if exists(NO_RESTORE_FILE) then
    os.remove(NO_RESTORE_FILE)
    toast(window, 'Session: auto-restore on', 2000)
  elseif write_atomic(NO_RESTORE_FILE, 'delete this file to restore the last session at launch\n') then
    toast(window, 'Session: auto-restore off', 2000)
  end
end)

local M = {}

function M.apply(config)
  wezterm.on('update-status', function()
    local now = os.time()
    if wezterm.GLOBAL.session_tick ~= now then
      wezterm.GLOBAL.session_tick = now
      save_session()
    end
  end)
  wezterm.on('gui-startup', startup)
  for _, key in ipairs {
    -- Session restore: reopen the session from before this launch; toggle
    -- whether launching restores the last session on its own
    { key = 'o', mods = 'CMD|SHIFT', action = restore_previous },
    { key = 'o', mods = 'CMD|SHIFT|OPT', action = toggle_auto_restore },
  } do table.insert(config.keys, key) end
end

M.apply(config, ctx)
end
do
-- Hibernation -----------------------------------------------------------------

-- An agent CLI (claude) left idle in a pane for HIB_IDLE seconds is stopped
-- (SIGTERM, so it exits normally) to free its memory; the pane then shows its
-- last screen, dimmed under a banner (bin/wez-hibernate), until a key or a
-- click resumes the same session with `claude --resume <id>`, typed into the
-- same shell so its `claude` function and environment apply. Idle means, at
-- every check for the whole time: the screen above its input box unchanged,
-- its process tree the same and at about no CPU, and not the active pane of
-- the focused window. Right before the stop every gate is checked again, and
-- any doubt keeps it running:
-- * nothing runs under it but its MCP servers (children started within
--   HIB_MCP_WINDOW of it, none of them a shell or in HIB_NOT_MCP): a tool or
--   background command, a build, a sleep, caffeinate (claude holds it while
--   it works) means work in progress
-- * its screen shows an empty input box and no sign of work: spinner, "esc
--   to interrupt", background agents/shells/monitors, queued messages, a
--   permission prompt or other dialog, a draft in the input box
-- * a session id whose transcript exists, and a directory to resume it in
-- * the pane outlives claude: started from a shell that stays when it exits
--   (typed at a prompt, or restore_spec's `...; exec $SHELL -l`), where the
--   wake command is typed once claude is gone; or the pane's own process,
--   whose pane would close with it, so the wake screen is split in first and
--   takes the pane's place
-- Off while ~/.local/state/wezterm/hibernate-off exists or WEZTERM_HIBERNATE=0.
-- For tests, WEZTERM_HIBERNATE_IDLE / _CHECK (or wezterm.GLOBAL.hibernate_idle
-- / hibernate_check) set the idle time and check interval in seconds.
local wezterm = require 'wezterm'
local core = require 'lib.core'
local agent = require 'lib.agent'
local toast, mux_pane, sh_quote = core.toast, core.mux_pane, core.sh_quote
local STATE_DIR, write_atomic, glob_quote, present = agent.STATE_DIR, agent.write_atomic, agent.glob_quote, agent.present
local base, set_of, SHELLS, is_idle_shell = agent.base, agent.set_of, agent.SHELLS, agent.is_idle_shell
local is_claude, claude_session, RESTORE_SHELL, shell_args = agent.is_claude, agent.claude_session, agent.RESTORE_SHELL, agent.shell_args
local hib_json, hib_store = agent.hib_json, agent.hib_store

local HIB_IDLE = 3600 -- seconds idle before hibernating
local HIB_CHECK = 30 -- seconds between idle checks
local HIB_MCP_WINDOW = 90 -- children started this soon after claude are its MCP servers
local HIB_CPU = 0.03 -- CPU share at or below which the process tree is idle (~1% at rest)
local HIB_TERM_WAIT = 20 -- seconds for claude to exit after SIGTERM before SIGKILL
local HIB_GIVE_UP = 60 -- seconds after which a stop that has not finished is dropped
local HIB_SHELL_READY = 2 -- seconds the shell is back before the wake command is typed
local HIB_DIR = STATE_DIR .. '/hibernate' -- <pane id>.screen: the screen at the stop
local HIB_OFF_FILE = STATE_DIR .. '/hibernate-off'
local HIB_SCRIPTS = { wezterm.home_dir .. '/.local/bin/wez-hibernate', wezterm.home_dir .. '/dotfiles/bin/wez-hibernate' }
-- Children never taken for an MCP server, however early they started
local HIB_NOT_MCP = set_of 'tcsh csh caffeinate sleep tmux screen ssh mosh script expect make watch'
-- Signs of work below the input box (footer counters, the agent panel)
local HIB_BUSY_BELOW = { 'background', 'queued', 'waiting', 'running', 'interrupt', '⏺ main', '◯ ' }
local HIB_BUSY_BELOW_PATTERNS = { '·%s*%d+%s+%a', '%d+%s+agents?', '↓%s*%d', '↑%s*%d' }
-- ... and on the lines just above it: the spinner line ...
local HIB_SPINNERS = { '✢', '✳', '✶', '✻', '✽', '*', '·' }
local HIB_BUSY_SPIN = { '…', 'waiting', 'running', 'queued', 'interrupt' }
-- ... and a tool still running ("… +12 lines" is a finished one's output)
local HIB_MARKS = { '⏺', '⎿' }
local HIB_BUSY_MARK = { 'waiting', 'running', 'queued', 'interrupt' }
-- Title prefixes of a working claude (it spins ◐◓◑◒ there; braille spinners too)
local HIB_TITLE_SPINNERS = { '◐', '◓', '◑', '◒' }

-- [[dd-]hh:]mm:ss[.cc] (ps etime and time) in seconds
local function hib_seconds(t)
  local days, rest = t:match '^(%d+)%-(.*)$'
  local total = 0
  for part in (rest or t):gmatch '[^:]+' do total = total * 60 + (tonumber(part) or 0) end
  return total + (tonumber(days) or 0) * 86400
end

-- Every process: pid -> { ppid, age (s), cpu (s), comm, kids = { pid... } }, or nil
local function hib_processes()
  local ok, success, out = pcall(wezterm.run_child_process, { '/bin/ps', '-axo', 'pid=,ppid=,etime=,time=,comm=' })
  if not (ok and success) then return nil end
  local procs = {}
  for line in out:gmatch '[^\n]+' do
    local pid, ppid, etime, cpu, comm = line:match '^%s*(%d+)%s+(%d+)%s+(%S+)%s+(%S+)%s+(.-)%s*$'
    if pid then
      procs[tonumber(pid)] = { ppid = tonumber(ppid), age = hib_seconds(etime), cpu = hib_seconds(cpu), comm = comm, kids = {} }
    end
  end
  for pid, p in pairs(procs) do
    if procs[p.ppid] and p.ppid ~= pid then table.insert(procs[p.ppid].kids, pid) end
  end
  return procs
end

-- `pid` and all its descendants
local function hib_tree(procs, pid)
  local out, seen, i = { pid }, { [pid] = true }, 1
  while out[i] do
    for _, kid in ipairs(procs[out[i]] and procs[out[i]].kids or {}) do
      if not seen[kid] then seen[kid], out[#out + 1] = true, kid end
    end
    i = i + 1
  end
  return out
end

-- CPU seconds of the tree, and its pids as one string (a new or ended
-- process under claude is activity)
local function hib_tree_usage(procs, pid)
  local tree, total = hib_tree(procs, pid), 0
  for _, p in ipairs(tree) do total = total + (procs[p] and procs[p].cpu or 0) end
  table.sort(tree)
  return total, table.concat(tree, ',')
end

-- Why claude's children rule hibernation out (nil: only its MCP servers).
-- MCP servers start with claude and stay; anything started later (a tool
-- or background command, a reconnected server) or any shell is taken for work.
local function hib_busy_child(procs, pid)
  local me = procs and procs[pid]
  if not me then return 'process not found' end
  for _, kid in ipairs(me.kids) do
    local c = procs[kid]
    local name = base(c.comm):gsub('^%-', '')
    if SHELLS[name] or HIB_NOT_MCP[name] then return 'runs ' .. name end
    if me.age - c.age > HIB_MCP_WINDOW then return 'runs ' .. name .. ', started after it' end
  end
end

local function hib_hash(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) & 0xffffffff end
  return h
end

local function hib_is_rule(line)
  local rest, n = line:gsub('─', '')
  return n >= 3 and not rest:find '%S'
end

local function hib_has(line, words)
  local lower = line:lower()
  for _, w in ipairs(words) do
    if lower:find(w, 1, true) then return w end
  end
end

-- Does `line` start with one of `glyphs` and name one of `words`?
local function hib_marked(line, glyphs, words)
  line = line:gsub('^%s+', '')
  for _, glyph in ipairs(glyphs) do
    if line:sub(1, #glyph) == glyph then return hib_has(line, words) end
  end
end

-- The screen of an idle claude: hash of what is above its input box, or
-- nil and why not. The input box is the last `❯` line between two rules.
local function hib_read_screen(text, title)
  title = title or ''
  if title:find '^\226[\160-\163]' then return nil, 'title shows work' end -- U+2800-28FF
  for _, glyph in ipairs(HIB_TITLE_SPINNERS) do
    if title:sub(1, #glyph) == glyph then return nil, 'title shows work' end
  end
  local lines = {}
  for line in (text .. '\n'):gmatch '([^\n]*)\n' do lines[#lines + 1] = (line:gsub('\194\160', ' ')) end
  local box
  for i = #lines - 1, 2, -1 do
    if lines[i]:find '^%s*❯' and hib_is_rule(lines[i - 1]) and hib_is_rule(lines[i + 1]) then
      box = i
      break
    end
  end
  if not box then return nil, 'no input box' end
  if lines[box]:gsub('^%s*❯', ''):find '%S' then return nil, 'draft in the input box' end
  for _, line in ipairs(lines) do
    if line:lower():find('esc to interrupt', 1, true) then return nil, 'shows esc to interrupt' end
  end
  for i = math.max(1, box - 6), box - 2 do
    local w = hib_marked(lines[i], HIB_SPINNERS, HIB_BUSY_SPIN) or hib_marked(lines[i], HIB_MARKS, HIB_BUSY_MARK)
    if w then return nil, 'shows ' .. w end
  end
  for i = box + 2, #lines do
    local w = hib_has(lines[i], HIB_BUSY_BELOW)
    if w then return nil, 'shows ' .. w end
    for _, p in ipairs(HIB_BUSY_BELOW_PATTERNS) do
      if lines[i]:find(p) then return nil, 'shows ' .. lines[i]:match '^%s*(.-)%s*$' end
    end
  end
  return hib_hash(table.concat(lines, '\n', 1, box - 2))
end

local function hib_screen(pane)
  local ok, text = pcall(pane.get_lines_as_text, pane, pane:get_dimensions().viewport_rows)
  return hib_read_screen(ok and text or '', pane:get_title())
end

-- The wake script, if it runs (its interpreter is there)
local function hib_script()
  for _, path in ipairs(HIB_SCRIPTS) do
    if present(path) then
      local ok, success = pcall(wezterm.run_child_process, { path, '--check' })
      return ok and success and path or nil
    end
  end
end

local function hib_transcript(id)
  local ok, found = pcall(wezterm.glob, glob_quote(wezterm.home_dir) .. '/.claude*/projects/*/' .. id .. '.jsonl')
  return ok and #found > 0
end

-- How the pane outlives claude: 'shell' (its parent is a shell that stays:
-- one at its prompt, or restore_spec's `<shell> -lic '... claude --resume
-- <id>; exec <shell> -l'`), 'top' (the pane's own process), or nil
local function hib_shape(info)
  local ok, parent = pcall(wezterm.procinfo.get_info_for_pid, info.ppid)
  if not (ok and parent) then return nil end
  local argv = parent.argv or {}
  if is_idle_shell(argv) then return 'shell' end
  local tail = '; exec ' .. sh_quote(RESTORE_SHELL) .. ' -l'
  if #argv == 3 and argv[1] == RESTORE_SHELL and argv[2] == '-lic' and argv[3]:sub(-#tail) == tail then
    return 'shell'
  end
  if base(parent.executable):match '^wezterm' then return 'top' end
end

-- Stop the idle claude in `pane` (state `s`) after the last gates; true,
-- or nil and why not
local function hib_stop(pane, info, s, now)
  local key = tostring(pane:pane_id())
  local id, id_cwd = claude_session(pane:pane_id(), info)
  if not (id and id:match '^[%w_-]+$') then return nil, 'no session id' end
  if not hib_transcript(id) then return nil, 'no transcript for ' .. id end
  local cwd = present(id_cwd) and id_cwd or (present(info.cwd) and info.cwd or nil)
  if not cwd then return nil, 'no directory to resume in' end
  local shape = hib_shape(info)
  if not shape then return nil, 'not started from a shell that stays' end
  local script = hib_script()
  if not script then return nil, 'wez-hibernate missing or not working' end
  local procs = hib_processes()
  local busy = hib_busy_child(procs, info.pid)
  if busy then return nil, busy end
  local cpu, kids = hib_tree_usage(procs, info.pid)
  if kids ~= s.kids or cpu - s.cpu > HIB_CPU * math.max(1, now - s.at) then return nil, 'became busy' end
  local hash, why = hib_screen(pane)
  if hash ~= s.hash then return nil, why or 'screen changed' end
  local ok, shown = pcall(pane.get_lines_as_escapes, pane, pane:get_dimensions().viewport_rows)
  local screen = HIB_DIR .. '/' .. key .. '.screen'
  if not (ok and write_atomic(screen, shown)) then return nil, 'could not save the screen' end
  local wake = sh_quote(script) .. ' --id ' .. id .. ' --cwd ' .. sh_quote(cwd)
  local job = { pid = info.pid, ppid = info.ppid, start = info.start_time, id = id, cwd = cwd, at = now, shape = shape }
  if shape == 'shell' then
    -- leading space: kept out of the shell's history (HIST_IGNORE_SPACE)
    job.cmd = ' cd ' .. sh_quote(cwd) .. ' && ' .. wake .. ' ' .. sh_quote(screen) .. ' && claude --resume ' .. id .. '\r'
  else -- split the wake screen in now: the pane closes with claude
    local tab = pane:tab()
    local active = tab and tab:active_pane()
    local split_ok = pcall(pane.split, pane, {
      direction = 'Bottom',
      args = shell_args(wake .. ' --after ' .. info.pid .. ' ' .. sh_quote(screen) .. ' && claude --resume ' .. id, cwd),
    })
    if not split_ok then
      os.remove(screen)
      return nil, 'could not split in the wake screen'
    end
    if active and active:pane_id() ~= pane:pane_id() then pcall(active.activate, active) end
  end
  local jobs = hib_json 'hib_jobs'
  jobs[key] = job
  hib_store('hib_jobs', jobs)
  wezterm.run_child_process { '/bin/kill', '-TERM', tostring(info.pid) }
  wezterm.log_info(string.format('hibernate: pane %s: stopping claude %d (session %s)', key, info.pid, id))
  return true
end

-- Is the process of a stop still the one that was stopped (pids get reused)?
local function hib_alive(job)
  local ok, p = pcall(wezterm.procinfo.get_info_for_pid, job.pid)
  return ok and p ~= nil and (type(job.start) ~= 'number' or p.start_time == job.start)
end

-- Follow the stops in progress: SIGKILL a claude that ignores SIGTERM (its
-- own tree only); once it is gone and its shell has been back at the prompt
-- for HIB_SHELL_READY, type the wake command
local function hib_follow(now)
  local jobs = hib_json 'hib_jobs'
  if not next(jobs) then return end
  for key, job in pairs(jobs) do
    local pane = mux_pane(tonumber(key))
    if now - job.at > HIB_GIVE_UP or not (pane or job.shape == 'top') then
      jobs[key] = nil
      wezterm.log_warn('hibernate: pane ' .. key .. ': gave up waiting for the stop')
    elseif hib_alive(job) then
      if now - job.at >= HIB_TERM_WAIT and not job.killed then
        local procs = hib_processes()
        if procs and procs[job.pid] then
          local kill = { '/bin/kill', '-KILL' }
          for _, p in ipairs(hib_tree(procs, job.pid)) do kill[#kill + 1] = tostring(p) end
          wezterm.run_child_process(kill)
          wezterm.log_warn('hibernate: pane ' .. key .. ': claude ignored SIGTERM, killed')
        end
        job.killed = true
      end
    elseif job.shape == 'top' then
      jobs[key] = nil -- its pane closed with it; the wake screen has its place
    else
      local fg = pane:get_foreground_process_info()
      if not (fg and fg.pid == job.ppid and is_idle_shell(fg.argv or {})) then
        job.shell_at = nil
      elseif not job.shell_at then
        job.shell_at = now
      elseif now - job.shell_at >= HIB_SHELL_READY then
        pane:send_text(job.cmd)
        jobs[key] = nil
      end
    end
  end
  hib_store('hib_jobs', jobs)
end

-- One pane's idle check (state in `c`); hibernates it once idle long enough
local function hib_check_pane(pane, c, now)
  local key = tostring(pane:pane_id())
  local info = pane:get_domain_name() == 'local' and not c.focused[pane:pane_id()] and not c.jobs[key]
    and pane:get_foreground_process_info()
  if not (info and is_claude(info)) then return end
  local hash = hib_screen(pane)
  if not hash then return end
  c.procs = c.procs or hib_processes()
  if not (c.procs and c.procs[info.pid]) then return end
  local cpu, kids = hib_tree_usage(c.procs, info.pid)
  local s = c.state[key]
  if not (s and s.pid == info.pid and s.hash == hash and s.kids == kids
      and cpu - s.cpu <= HIB_CPU * math.max(1, now - s.at)) then
    c.fresh[key] = { pid = info.pid, hash = hash, cpu = cpu, kids = kids, at = now, since = now }
    return
  end
  s.cpu, s.at = cpu, now
  c.fresh[key] = s
  if now - s.since < c.idle then return end
  local stopped, reason = hib_stop(pane, info, s, now)
  if stopped then
    c.fresh[key], c.n = nil, c.n + 1
  elseif reason ~= s.blocked then
    s.blocked = reason
    wezterm.log_info('hibernate: pane ' .. key .. ' stays awake: ' .. reason)
  end
end

-- One idle check of every claude pane; hibernates the ones idle long enough
local function hib_check(window, now)
  local G = wezterm.GLOBAL
  local idle = tonumber(G.hibernate_idle) or tonumber(os.getenv 'WEZTERM_HIBERNATE_IDLE') or HIB_IDLE
  local every = tonumber(G.hibernate_check) or tonumber(os.getenv 'WEZTERM_HIBERNATE_CHECK')
    or math.min(HIB_CHECK, math.max(1, idle // 4))
  if now - (tonumber(G.hib_checked) or 0) < every then return end
  G.hib_checked = now
  if os.getenv 'WEZTERM_HIBERNATE' == '0' or present(HIB_OFF_FILE) then
    G.hib_state = nil
    return
  end
  local focused = {}
  for _, gw in ipairs(wezterm.gui and wezterm.gui.gui_windows() or {}) do
    local ok, p = pcall(function() return gw:is_focused() and gw:active_pane() end)
    if ok and p then focused[p:pane_id()] = true end
  end
  local c = { state = hib_json 'hib_state', fresh = {}, jobs = hib_json 'hib_jobs', focused = focused, idle = idle, n = 0 }
  for _, mw in ipairs(wezterm.mux.all_windows()) do
    for _, tab in ipairs(mw:tabs()) do
      for _, pane in ipairs(tab:panes()) do
        local ok, err = pcall(hib_check_pane, pane, c, now) -- a pane gone mid-check raises
        if not ok then wezterm.log_warn('hibernate: ' .. tostring(err)) end
      end
    end
  end
  hib_store('hib_state', c.fresh)
  -- A wake screen reads its file at once: any left after 10 minutes is stale
  local ok, files = pcall(wezterm.read_dir, HIB_DIR)
  if ok and #files > 0 then
    pcall(wezterm.run_child_process, { '/usr/bin/find', HIB_DIR, '-name', '*.screen', '-mmin', '+10', '-delete' })
  end
  if c.n > 0 then
    toast(window, string.format('Hibernate: %d idle pane%s put to sleep 💤', c.n, c.n == 1 and '' or 's'), 3000)
  end
end

local M = {}

function M.apply()
  wezterm.on('update-status', function(window)
    local now = os.time()
    if wezterm.GLOBAL.hib_tick == now then return end
    wezterm.GLOBAL.hib_tick = now
    local ok, err = pcall(hib_follow, now)
    if not ok then wezterm.log_error('hibernate: ' .. tostring(err)) end
    ok, err = pcall(hib_check, window, now)
    if not ok then wezterm.log_error('hibernate: ' .. tostring(err)) end
  end)
end

M.apply(config, ctx)
end
do
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

M.apply(config, ctx)
end

-- WezTerm reloads when a module it loaded changes; also watch this file by
-- its real path
for _, pattern in ipairs { '/wezterm.lua' } do
  for _, path in ipairs(wezterm.glob(DIR .. pattern)) do wezterm.add_to_config_reload_watch_list(path) end
end

return config
