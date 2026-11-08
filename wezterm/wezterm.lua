-- WezTerm config: pane/split keybindings mirroring Ghostty's macOS defaults.
local wezterm = require 'wezterm'
local act = wezterm.action

local config = wezterm.config_builder()

-- Match Ghostty's `working-directory = ~/Desktop`
config.default_cwd = wezterm.home_dir .. '/Desktop'

-- Make the inactive pane visibly dimmer so the focused split is obvious
config.inactive_pane_hsb = { saturation = 0.8, brightness = 0.7 }

-- Render at the MacBook's 120Hz ProMotion rate instead of the 60fps default
config.max_fps = 120

-- Render via WebGpu (Metal) instead of the OpenGL default: measured ~40% lower
-- memory footprint (~70-118 MB vs ~137-187 MB with 3 panes), same look
config.front_end = 'WebGpu'

local RESIZE_STEP = 5 -- cells per keypress

-- UI palette for the tab bar, prompts and pickers: Catppuccin Mocha, the
-- same flavor as Yazi (~/.config/yazi/theme.toml)
local C = {
  crust = '#11111b', mantle = '#181825', surface0 = '#313244', overlay0 = '#6c7086',
  text = '#cdd6f4', mauve = '#cba6f7', blue = '#89b4fa', peach = '#fab387', red = '#f38ba8',
}

-- Nerd Font glyphs; WezTerm bundles Symbols Nerd Font Mono as a fallback
local ICON = {
  rename = utf8.char(0xF03EB), window = utf8.char(0xF0614),
  server = utf8.char(0xF048B), folder = utf8.char(0xF024B),
  forward = utf8.char(0xF0318), zoom = utf8.char(0xF0293), console = utf8.char(0xF018D),
}

-- Feedback for clicks, prompts and moves; messages read "<Area>: <what
-- happened>". WezTerm's macOS toasts use the deprecated NSUserNotification
-- API, which current macOS no longer displays (WezTerm never even shows up in
-- System Settings > Notifications), so the message also flashes in the tab
-- bar's right status for `ms` and goes to the GUI log.
local function toast(window, msg, ms)
  ms = ms or 3000
  window:toast_notification('WezTerm', msg, nil, ms)
  wezterm.log_info('notice: ' .. msg)
  local seq = (wezterm.GLOBAL.notice_seq or 0) + 1
  wezterm.GLOBAL.notice_seq = seq
  window:set_right_status(wezterm.format {
    { Background = { Color = C.surface0 } }, { Foreground = { Color = C.peach } },
    { Text = ' ' .. msg .. ' ' },
  })
  wezterm.time.call_after(ms / 1000, function()
    if wezterm.GLOBAL.notice_seq == seq then window:set_right_status('') end
  end)
end

-- Pane by id, or nil once it's gone: wezterm.mux.get_pane raises for a
-- missing pane on 20240203 instead of returning nil
local function mux_pane(id)
  local ok, pane = pcall(wezterm.mux.get_pane, id)
  return ok and pane or nil
end

-- Peek state per tab (see replace_peek): 'origin|peek|zoomed' = the pane
-- that was clicked, the Yazi pane (split to its right, or alone in a new tab)
-- and whether to zoom the origin again once it closes. wezterm.GLOBAL
-- survives config reloads.
local PEEK_KEY = 'peek_for_tab_' -- .. tab id

local function peek_record(tab)
  local origin, peek, zoomed = (wezterm.GLOBAL[PEEK_KEY .. tab:tab_id()] or ''):match '^(%d+)|(%d+)|([01])$'
  if not peek then return nil end
  return { origin = tonumber(origin), peek = tonumber(peek), zoomed = zoomed == '1' }
end

local function set_peek_record(tab, rec) -- nil forgets the peek
  wezterm.GLOBAL[PEEK_KEY .. tab:tab_id()] = rec
    and string.format('%d|%d|%d', rec.origin, rec.peek, rec.zoomed and 1 or 0) or nil
end

-- True while a live peek pane is split into `tab`: layout surgery (rebuild,
-- pane moves, the sidebar) would destroy it. A peek in its own tab is not.
local function peek_open(tab)
  local rec = peek_record(tab)
  local peek = rec and mux_pane(rec.peek)
  local peek_tab = peek and peek:tab()
  return peek_tab ~= nil and peek_tab:tab_id() == tab:tab_id()
end

-- WezTerm 20240203 takes a `split-pane --move-pane-id` pane out of its tab
-- before attempting the split, so a refused split ("No space for split!", or
-- a zoomed target tab) loses the pane. Mirror split_and_insert's checks
-- (mux/src/tab.rs) first: true if splitting pane `target_id` along `flag`
-- with `percent` for the new part will succeed.
local function split_fits(target_id, flag, percent)
  local target = mux_pane(target_id)
  local tab = target and target:tab()
  if not tab then return false end
  local size = tab:get_size()
  for _, info in ipairs(tab:panes_with_info()) do
    if info.is_zoomed then return false end
    if info.pane:pane_id() == target_id then
      local span = flag == '--right' and info.width or info.height
      local second = math.max(1, math.floor(span * percent / 100))
      return span - second - 1 >= 1
        and info.left + info.width <= size.cols and info.top + info.height <= size.rows
    end
  end
  return false
end

-- Heading for PromptInputLine: accent icon, bold title, dim hint below
local function prompt_text(icon, title, hint)
  return wezterm.format {
    { Foreground = { Color = C.mauve } }, { Text = ' ' .. icon .. '  ' },
    { Attribute = { Intensity = 'Bold' } }, { Foreground = { Color = C.text } }, { Text = title },
    { Attribute = { Intensity = 'Normal' } }, { Foreground = { Color = C.overlay0 } },
    { Text = '\r\n    ' .. hint .. '\r\n' },
  }
end

-- Pickers in the same palette: PaneSelect labels as mauve tiles, command
-- palette and character selector on the darker mantle
config.pane_select_font_size = 40
config.pane_select_fg_color = C.crust
config.pane_select_bg_color = C.mauve
config.command_palette_fg_color = C.text
config.command_palette_bg_color = C.mantle
config.command_palette_font_size = 15
config.char_select_fg_color = C.text
config.char_select_bg_color = C.mantle
config.char_select_font_size = 15

-- Retro (cell-based) tab bar on crust; each tab is drawn by
-- format-tab-title below
config.use_fancy_tab_bar = false
config.tab_max_width = 32
config.colors = {
  tab_bar = {
    background = C.crust,
    new_tab = { bg_color = C.crust, fg_color = C.overlay0 },
    new_tab_hover = { bg_color = C.surface0, fg_color = C.text },
  },
}

-- File sidebar (VS Code style): CMD+E toggles a narrow Yazi pane on the left
-- of the tab. It uses ~/.config/yazi-sidebar (single column; text files open in
-- micro in a new pane to its right via ~/.local/bin/yazi-open).
local SIDEBAR_CELLS = 32
local YAZI = '/opt/homebrew/bin/yazi'
-- GUI-launched WezTerm has a minimal PATH; yazi needs brew tools
local YAZI_PATH = '/opt/homebrew/bin:' .. wezterm.home_dir .. '/.local/bin:'
  .. (os.getenv 'PATH' or '/usr/bin:/bin:/usr/sbin:/sbin')

-- A Dock-launched GUI has no EDITOR, and Yazi's built-in text opener runs
-- ${EDITOR:-vi}: give every pane (and each peek) micro instead of vim
local EDITOR_ENV = { EDITOR = 'micro', VISUAL = 'micro' }
local function with_editor(env)
  for k, v in pairs(EDITOR_ENV) do env[k] = v end
  return env
end
config.set_environment_variables = with_editor {}

-- Directory of a pane: Url object on 20240203+, string on older builds,
-- falling back to the foreground process's cwd.
local function pane_cwd(pane)
  local url = pane:get_current_working_dir()
  if type(url) == 'userdata' and url.file_path then
    return url.file_path
  elseif type(url) == 'string' then
    return (url:gsub('^file://[^/]*', ''))
  end
  local info = pane:get_foreground_process_info()
  return info and info.cwd or wezterm.home_dir
end

-- Sidebar pane id per tab; wezterm.GLOBAL survives config reloads
local SIDEBAR_KEY = 'sidebar_pane_for_tab_' -- .. tab id

-- Pane geometry of a tab: { id, pane, left, top, width, height } records in
-- cells (the shape merge_tab below consumes), plus the tree's extent and
-- whether a pane is zoomed (zoom hides the real geometry)
local function tab_geometry(tab)
  local panes, cols, rows, zoomed = {}, 0, 0, false
  for _, info in ipairs(tab:panes_with_info()) do
    table.insert(panes, {
      id = info.pane:pane_id(), pane = info.pane, left = info.left, top = info.top,
      width = info.width, height = info.height,
    })
    cols = math.max(cols, info.left + info.width)
    rows = math.max(rows, info.top + info.height)
    zoomed = zoomed or info.is_zoomed
  end
  return panes, cols, rows, zoomed
end

-- Rebuilds a tab from a geometry list (defined with merge_tab below)
local rebuild_tab

-- Multi-pane tab: lay out `geometry` (the panes, extent cols x rows) shifted
-- right of a full-height sidebar column `sidebar_id`, `width` cells wide
local function with_sidebar(geometry, cols, rows, sidebar_id, width)
  local rest = math.max(1, cols - width - 1)
  local function x(v) return width + 1 + math.floor(v * rest / cols) end
  local out = { { id = sidebar_id, left = 0, top = 0, width = width, height = rows } }
  for _, p in ipairs(geometry) do
    local left = x(p.left)
    table.insert(out, {
      id = p.id, left = left, top = p.top, width = x(p.left + p.width) - left, height = p.height,
    })
  end
  return out
end

-- Spawn spec (cwd, args, env) of the sidebar's Yazi; toggle_sidebar and the
-- session restore add direction and size
local function sidebar_spec(cwd)
  return {
    cwd = cwd,
    -- Pass the dir explicitly: yazi trusts an inherited $PWD over the real cwd
    args = { YAZI, cwd },
    set_environment_variables = {
      YAZI_SIDEBAR = '1',
      YAZI_CONFIG_HOME = wezterm.home_dir .. '/.config/yazi-sidebar',
      PATH = YAZI_PATH,
    },
  }
end

local function toggle_sidebar(window, pane)
  local tab = pane:tab()
  if peek_open(tab) then
    toast(window, 'Sidebar: close the peek (q) first', 2000)
    return
  end
  local key = SIDEBAR_KEY .. tab:tab_id()
  local sidebar_id = wezterm.GLOBAL[key]

  -- Sidebar already open in this tab: close it
  for _, p in ipairs(tab:panes()) do
    if p:pane_id() == sidebar_id then
      p:activate()
      window:perform_action(act.CloseCurrentPane { confirm = false }, p)
      wezterm.GLOBAL[key] = nil
      return
    end
  end

  -- Yazi only exists on this Mac; don't try to run it inside ssh/mux domains
  if pane:get_domain_name() ~= 'local' then
    toast(window, 'Sidebar: only works in local tabs')
    return
  end

  local spec = sidebar_spec(pane_cwd(pane))
  spec.direction = 'Left'
  spec.size = SIDEBAR_CELLS
  tab:set_zoomed(false) -- a zoomed tab refuses splits and hides geometry
  local geometry, cols, rows = tab_geometry(tab)
  if #geometry == 1 then
    -- One pane: a plain left split already spans the whole tab
    wezterm.GLOBAL[key] = pane:split(spec):pane_id()
    return
  end

  -- Several panes: WezTerm 20240203's `top_level` split leaves the tab's
  -- recorded size short of its panes (mux/src/tab.rs split_and_insert), so
  -- they later spill past the window edge. Instead spawn yazi as an ordinary
  -- split of the widest pane that fits, then rebuild the tab with it as a
  -- full-height column on the left.
  local size, host = tab:get_size(), nil
  for _, p in ipairs(geometry) do
    if p.left + p.width <= size.cols and p.width >= 3 and (not host or p.width > host.width) then
      host = p
    end
  end
  if not host then
    toast(window, 'Sidebar: no room for a split in this tab')
    return
  end
  spec.size = math.min(SIDEBAR_CELLS, host.width - 2)
  local sidebar = host.pane:split(spec):pane_id()
  local width = math.min(SIDEBAR_CELLS, math.max(1, cols - 2))
  local new_tab = rebuild_tab(window, tab, with_sidebar(geometry, cols, rows, sidebar, width), sidebar)
  wezterm.GLOBAL[SIDEBAR_KEY .. (new_tab or tab):tab_id()] = sidebar
end

-- ssh helpers shared by smart splits, image paste, clickable paths and port
-- forwarding.

-- PATH for spawned ssh/ssh-pane (GUI-launched WezTerm has a minimal PATH),
-- so they run the same ssh as an interactive shell
local SPAWN_PATH = '/opt/homebrew/bin:' .. (os.getenv 'PATH' or '/usr/bin:/bin:/usr/sbin:/sbin')

local function sh_quote(s)
  return "'" .. s:gsub("'", [['\'']]) .. "'"
end

local WEZTERM_CLI = '/opt/homebrew/bin/wezterm'

-- Run `wezterm cli <args...>`; returns success, stderr
local function cli(...)
  local ok, _, err = wezterm.run_child_process { WEZTERM_CLI, 'cli', ... }
  return ok, err
end

-- ssh options that take a value (from `man ssh`)
local SSH_OPTS_WITH_VALUE = {}
for c in ('bcDEeFIiJLlmOopQRSWw'):gmatch '.' do SSH_OPTS_WITH_VALUE[c] = true end
-- Of those, the ones carried over so the new connection matches
local SSH_OPTS_KEPT = { l = true, p = true, F = true, J = true, i = true }

-- ssh wrapper that offers Enter-to-reconnect when the connection drops
local SSH_PANE = wezterm.home_dir .. '/.local/bin/ssh-pane'
-- $0 of the sh -c script that waits before running ssh-pane when a session
-- is restored (see SSH_RESTORE_SCRIPT)
local RESTORE_TAG = 'wez-restore'

-- argv of an ssh process -> args for a fresh ssh-pane to the same destination
-- (remote command dropped), or nil if no destination is found.
local function ssh_split_args(argv, first)
  local kept, i = {}, (first or 1) + 1
  while i <= #argv do
    local a = argv[i]
    if a == '--' then
      i = i + 1
      break
    elseif a:sub(1, 1) ~= '-' or a == '-' then
      break
    end
    -- Walk bundled flags like -tt or -4p2222
    for j = 2, #a do
      local c = a:sub(j, j)
      if SSH_OPTS_WITH_VALUE[c] then
        local value = a:sub(j + 1)
        if value == '' then
          i = i + 1
          value = argv[i]
        end
        if value and SSH_OPTS_KEPT[c] then
          table.insert(kept, '-' .. c)
          table.insert(kept, value)
        end
        break
      end
    end
    i = i + 1
  end
  local dest = argv[i]
  if not dest then return nil end
  local args = { SSH_PANE }
  for _, v in ipairs(kept) do table.insert(args, v) end
  table.insert(args, dest)
  return args
end

-- { SSH_PANE, <kept opts...>, dest } when the pane is a local pane whose
-- foreground process is ssh or ssh-pane, else nil. Shared by smart splits,
-- image paste, clickable paths and port forwarding. ssh-pane is a #!/bin/sh
-- script, so its argv is { '/bin/sh', '.../ssh-pane', <ssh args...> }: parse
-- from the ssh-pane entry.
local function info_ssh_args(info)
  local argv = info.argv or {}
  local function base(k) return (argv[k] or ''):match '[^/]*$' end
  if (info.executable or ''):match '[^/]*$' == 'ssh' or base(1) == 'ssh' or base(1) == 'ssh-pane' then
    return ssh_split_args(argv, 1)
  elseif base(2) == 'ssh-pane' then
    return ssh_split_args(argv, 2)
  elseif base(1) == 'sh' and argv[4] == RESTORE_TAG then
    return ssh_split_args(argv, 5)
  end
  return nil
end

local function pane_ssh_args(pane)
  local info = pane:get_domain_name() == 'local' and pane:get_foreground_process_info()
  return info and info_ssh_args(info) or nil
end

-- `ssh <opts...> <kept opts...> dest` for a pane_ssh_args result, run with
-- SPAWN_PATH so it is the same ssh as the pane's and computes the same
-- ControlPath (%C)
local function ssh_cmd(ssh, ...)
  local cmd = { '/usr/bin/env', 'PATH=' .. SPAWN_PATH, 'ssh', ... }
  for k = 2, #ssh do table.insert(cmd, ssh[k]) end
  return cmd
end

-- ssh_cmd that can only ride an existing ControlMaster: never prompts, never
-- logs in on its own
local function ssh_batch_cmd(ssh)
  return ssh_cmd(ssh, '-o', 'BatchMode=yes', '-o', 'ControlMaster=no')
end

-- pid (string) of the live ControlMaster for the pane's host, or nil. Only
-- asks the master socket (-O check), so it never connects or prompts.
local function ssh_master_pid(ssh)
  local ok, _, err = wezterm.run_child_process(ssh_cmd(ssh, '-O', 'check'))
  return ok and ((err or ''):match 'pid=(%d+)' or '?') or nil
end

-- Destination without user@, for messages and file names
local function ssh_host(ssh)
  return (ssh[#ssh]:gsub('^.*@', ''))
end

-- Clickable file paths: CMD+click on a path such as ~/.ssh/config,
-- /Users/me/x.md, ./foo.py, tasks/todo.md, README.md or src/app.py:42 opens a
-- Yazi "peek" on the right half of the clicked pane (or in a new tab when it
-- is narrow), with the file hovered and the preview maximized (YAZI_PEEK, see
-- ~/.config/yazi/init.lua), or the directory opened. Images too (Yazi
-- previews them); PDFs open in Preview instead (see preview_file). q quits Yazi and you are back in the pane you
-- clicked (see replace_peek). CMD+OPT+SHIFT+click Quick Looks a file instead,
-- and in an ssh pane right-click downloads the file or folder (see
-- download_remote).
-- OSC 8 file:// links (ls --hyperlink) are handled the same way; web URLs are
-- untouched.
local PEEK_SCHEME = 'yazi-open-path:'
local SSH_FORWARD_SCHEME = 'ssh-forward:' -- see forward_command

local function is_dir(path)
  local ok = pcall(wezterm.read_dir, path)
  return ok
end

local function exists(path)
  if is_dir(path) then return true end
  local f = io.open(path, 'r')
  if f then f:close() return true end
  return false
end

-- Collapse `.`/`..`/empty segments of an absolute path
local function normalize(path)
  local parts = {}
  for seg in path:gmatch '[^/]+' do
    if seg == '..' then
      table.remove(parts)
    elseif seg ~= '.' then
      table.insert(parts, seg)
    end
  end
  return '/' .. table.concat(parts, '/')
end

local function percent_decode(s)
  return (s:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end))
end

local function is_local_host(host)
  local here = wezterm.hostname()
  return host == '' or host == 'localhost' or host == here or host == (here:gsub('%..*$', ''))
end

-- uri -> path text (may carry :line[:col]) plus, for file://otherhost/...
-- (e.g. ls --hyperlink inside ssh), that host; nil if not ours
local function uri_to_path(uri)
  if uri:sub(1, #PEEK_SCHEME) == PEEK_SCHEME then
    return uri:sub(#PEEK_SCHEME + 1)
  end
  local host, path = uri:match '^file://([^/]*)(/.*)$'
  if not path then return nil end
  path = percent_decode((path:gsub('[?#].*$', '')))
  if is_local_host(host) then return path end
  return path, host
end

-- Spellings of a clicked path to try in order: as is, without a trailing
-- :line, :line:col or :first-last, then each %-decoded (My%20File.md)
local function path_variants(text)
  local out = { text }
  local stripped = text:match '^(.-):%d+[:-]%d+$' or text:match '^(.-):%d+$'
  if stripped and stripped ~= '' then table.insert(out, stripped) end
  for i = 1, #out do
    local decoded = percent_decode(out[i])
    if decoded ~= out[i] then table.insert(out, decoded) end
  end
  return out
end

-- Existing absolute path for `text` (see path_variants), resolving ~ and
-- relative paths against `cwd`; nil if nothing exists.
local function resolve_path(text, cwd)
  for _, c in ipairs(path_variants(text)) do
    if c == '~' or c:sub(1, 2) == '~/' then
      c = wezterm.home_dir .. c:sub(2)
    elseif c:sub(1, 1) ~= '/' then
      c = cwd .. '/' .. c
    end
    c = normalize(c)
    if exists(c) then return c end
  end
  return nil
end

-- Narrowest clicked pane (columns) whose right half is still a useful peek;
-- a narrower one gets the peek in a new tab instead
local PEEK_MIN_COLS = 80

-- Back to the pane the peek was opened from (and its tab), zoomed again if
-- it was before
local function show_origin(tab, origin, zoomed)
  origin:activate()
  if zoomed then tab:set_zoomed(true) end
end

-- Open a peek (`spec`: cwd, args, env) for the clicked `pane`: the right half
-- of that pane (a split of the pane itself, never top_level, see
-- repair_layout), focused. A pane under PEEK_MIN_COLS, or one that can't take
-- the split (split_fits), gets the peek in a new tab right after its own
-- instead. When Yazi quits the pane (or tab) closes and restore_peeks
-- re-activates `pane`. One peek per tab: a click while one is open opens the
-- new one in its place.
local function replace_peek(window, pane, spec)
  local tab = pane:tab()
  local origin, zoomed = pane, select(4, tab_geometry(tab))
  local rec = peek_record(tab)
  local old = rec and mux_pane(rec.peek)
  if rec then
    zoomed = rec.zoomed
    if old and old:pane_id() == pane:pane_id() then origin = mux_pane(rec.origin) or pane end
    set_peek_record(tab, nil)
  end
  spec.domain = 'DefaultDomain' -- local Yazi, even when the clicked pane is in a mux domain
  -- An open peek is split and then closed, so the new one takes over its
  -- cells: closing it first would not help, as 20240203 hands its cells back
  -- only after this handler returns
  local target = old
  if not old then
    tab:set_zoomed(false) -- a zoomed tab refuses splits and hides geometry
    if origin:get_dimensions().cols >= PEEK_MIN_COLS and split_fits(origin:pane_id(), '--right', 50) then
      target = origin
    end
  end
  local ok, peek = false, nil
  if target then
    target:tab():set_zoomed(false)
    spec.direction, spec.size = 'Right', 0.5
    ok, peek = pcall(target.split, target, spec)
    spec.direction, spec.size = nil, nil
  end
  if old then cli('kill-pane', '--pane-id', tostring(old:pane_id())) end
  if ok then
    peek:activate()
  else
    show_origin(tab, origin, zoomed)
    zoomed = false -- the origin tab keeps its zoom while the peek tab is open
    local mux_window = window:mux_window()
    local index = 0 -- 0-based position of the origin tab
    for i, t in ipairs(mux_window:tabs()) do
      if t:tab_id() == tab:tab_id() then index = i - 1 end
    end
    local peek_tab
    ok, peek_tab, peek = pcall(mux_window.spawn_tab, mux_window, spec)
    if not ok then
      toast(window, 'Peek: could not open a tab: ' .. tostring(peek_tab))
      return
    end
    peek_tab:activate()
    if index + 1 < #mux_window:tabs() - 1 then
      -- MoveTab moves the active tab; perform_action waits for it to finish
      window:perform_action(act.MoveTab(index + 1), peek)
    end
  end
  set_peek_record(tab, { origin = origin:pane_id(), peek = peek:pane_id(), zoomed = zoomed })
end

-- A peek pane has closed (Yazi quit): activate the pane (and tab) it came
-- from again and re-zoom it if the tab was zoomed there. WezTerm has no
-- pane-exit event, so update-status (every status_update_interval) notices.
local function restore_peeks(mux_window)
  for _, tab in ipairs(mux_window:tabs()) do
    local rec = peek_record(tab)
    if rec and not mux_pane(rec.peek) then
      set_peek_record(tab, nil)
      local origin = mux_pane(rec.origin)
      if origin then show_origin(tab, origin, rec.zoomed) end
    end
  end
end

wezterm.on('update-status', function(window) restore_peeks(window:mux_window()) end)
config.status_update_interval = 200

-- Closing a pane that only runs an idle shell needs no confirmation
-- (the default list, minus tmux: closing it kills the sessions inside)
config.skip_close_confirmation_for_processes_named = { 'bash', 'sh', 'zsh', 'fish', 'nu' }

-- "29:15", "29" or nil: the :line[:col] (or :first-last) a clicked path
-- carried, unless `path` really ends with it (a file named a:5)
local function click_line(text, path)
  local spec = text:match ':(%d+:%d+)$' or text:match ':(%d+)[:-]%d+$' or text:match ':(%d+)$'
  if spec and path:sub(-#spec - 1) ~= ':' .. spec then return spec end
end

local function open_peek(window, pane, path, line)
  local dir = is_dir(path)
  local env = with_editor { PATH = YAZI_PATH }
  if not dir then
    env.YAZI_PEEK = path
    env.YAZI_PEEK_LINE = line
  end
  replace_peek(window, pane, {
    cwd = dir and path or (path:match '^(.+)/' or '/'),
    args = { YAZI, path },
    set_environment_variables = env,
  })
end

-- Paths clicked in a local pane running ssh live on the remote host. They
-- are resolved there over the existing ControlMaster and opened in remote
-- Yazi (installed by ssh-setup, whose synced init.lua handles YAZI_PEEK)
-- through ssh-pane. Relative paths resolve against the remote shell's cwd
-- when it reports one with OSC 7 (ssh-setup's ~/.bashrc block does), else
-- against the cwds of the user's processes there (Claude Code inside tmux
-- reports nothing) and the remote home; see REMOTE_RESOLVE.

-- The remote shell's cwd from OSC 7 (file://<remote host>/dir), or nil.
-- The local shell's last report is still there while ssh runs, and its
-- host is whatever name DHCP gave this Mac at the time (it changes between
-- networks), so a dir that exists here is taken as that stale local one.
local function remote_cwd(pane)
  local url = pane:get_current_working_dir()
  if type(url) == 'userdata' and url.host and not is_local_host(url.host)
      and not exists(url.file_path) then
    return url.file_path
  end
  return nil
end

-- Shell word for path text on the remote: ~ becomes "$HOME", relative
-- paths are under it
local function remote_word(text)
  if text == '~' then return '"$HOME"' end
  if text:sub(1, 2) == '~/' then return '"$HOME"' .. sh_quote(text:sub(2)) end
  if text:sub(1, 1) == '/' then return sh_quote(text) end
  return '"$HOME"/' .. sh_quote(text)
end

-- Remote side of a path click, one round trip. Prints "d <dir>" or "f
-- <file>" (absolute, ./.. collapsed) for the first argument that exists, exit
-- 1 if none does. Arguments are A:<absolute path> or R:<relative path>. A
-- relative path is tried against $RCWD (the shell's OSC 7 cwd) first, then
-- against the cwds of the user's own processes (Linux /proc; those on a tty
-- named claude/node/python/bash first, other tty ones next, the rest last)
-- and $HOME; of several matches the newest (mtime) wins, the earlier one in
-- that order on a tie. `/` is never a base.
local REMOTE_RESOLVE = [[
emit() {
  if [ -d "$1" ]; then
    cd -- "$1" && printf 'd %s\n' "$(pwd)" && exit 0
  else
    d=$(cd -- "$(dirname -- "$1")" && pwd) && printf 'f %s\n' "${d%/}/$(basename -- "$1")" && exit 0
  fi
}
mtime() { stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1" 2>/dev/null || echo 0; }
bases() {
  ps -u "$(id -u)" -o pid=,tty=,comm= 2>/dev/null | while read -r pid tty comm; do
    c=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
    case $c in ''|/) continue ;; esac
    r=2
    case $tty in
      '?'|'') ;;
      *) r=1; case $comm in claude|node|python*|bash) r=0 ;; esac ;;
    esac
    printf '%s %s\n' "$r" "$c"
  done | sort -n -k1,1 | awk '!seen[substr($0, 3)]++ { print substr($0, 3) }'
  printf '%s\n' "$HOME"
}
B=
for w in "$@"; do
  case $w in
    A:*) p=${w#A:}; [ -e "$p" ] && emit "$p" ;;
    R:*)
      r=${w#R:}
      [ -n "$RCWD" ] && [ -e "$RCWD/$r" ] && emit "$RCWD/$r"
      [ -n "$B" ] || B=$(bases)
      best= bt=-1
      while IFS= read -r b; do
        [ -n "$b" ] && [ -e "$b/$r" ] || continue
        t=$(mtime "$b/$r")
        [ "$t" -gt "$bt" ] 2>/dev/null && best=$b/$r bt=$t
      done <<EOF
$B
EOF
      [ -n "$best" ] && emit "$best" ;;
  esac
done
exit 1]]

-- REMOTE_RESOLVE argument(s) for clicked path text (see path_variants)
local function resolve_words(text)
  local words = {}
  for _, v in ipairs(path_variants(text)) do
    if v == '~' then
      table.insert(words, '"A:$HOME"')
    elseif v:sub(1, 2) == '~/' then
      table.insert(words, '"A:$HOME"' .. sh_quote(v:sub(2)))
    elseif v:sub(1, 1) == '/' then
      table.insert(words, sh_quote('A:' .. v))
    else
      table.insert(words, sh_quote('R:' .. v))
    end
  end
  return words
end

-- kind ('f' or 'd') and absolute path on the pane's host of the first of
-- `texts` that exists there, or nil and a message
local function resolve_remote(ssh, texts, rcwd)
  if not ssh_master_pid(ssh) then
    return nil, 'ssh: no live connection to ' .. ssh_host(ssh) .. ' (ControlMaster)'
  end
  local words = {}
  for _, text in ipairs(texts) do
    for _, w in ipairs(resolve_words(text)) do table.insert(words, w) end
  end
  local script = 'RCWD=' .. sh_quote(rcwd or '') .. '\nset -- ' .. table.concat(words, ' ')
    .. '\n' .. REMOTE_RESOLVE
  local cmd = ssh_batch_cmd(ssh)
  table.insert(cmd, 'sh -c ' .. sh_quote(script))
  local ok, out = wezterm.run_child_process(cmd)
  local kind, path
  if ok then kind, path = out:match '^([fd]) (/[^\n]*)' end
  if not kind then return nil, 'Path: not found on ' .. ssh_host(ssh) .. ': ' .. texts[1] end
  return kind, path
end

-- Hard-wrapped paths: TUIs like Claude Code break long lines themselves
-- (newline + indentation, often behind a gutter such as │ or ⎿), so a click
-- sees only one piece of a long path. wrapped_candidates rebuilds it from
-- the pane's recent text: the clicked piece plus the path characters that
-- continue it at the start of the next lines and/or end the previous ones,
-- longest first. `wrapped` is true when the piece ends its line and a
-- continuation follows, i.e. on its own it is likely a cut-off prefix.
local WRAP_LINES = 3 -- lines joined at most in each direction
local WRAP_SCAN_LINES = 500
local WRAP_GUTTERS = { '│', '┃', '⎿', '●', '⏺', '▎', '▏', '•', '>', '*', '`', '|' }
local PATH_CHARS = '[%w%._~/@+%%:-]'

-- `s` without leading (or, with at_end, trailing) whitespace and gutter marks
local function strip_gutter(s, at_end)
  repeat
    local before = s
    s = at_end and (s:gsub('%s+$', '')) or (s:gsub('^%s+', ''))
    for _, g in ipairs(WRAP_GUTTERS) do
      if at_end and s:sub(-#g) == g then
        s = s:sub(1, -#g - 1)
      elseif not at_end and s:sub(1, #g) == g then
        s = s:sub(#g + 1)
      end
    end
  until s == before
  return s
end

local function wrapped_candidates(pane, text)
  local ok, all = pcall(pane.get_lines_as_text, pane, WRAP_SCAN_LINES)
  local lines = {}
  for line in ((ok and all or '') .. '\n'):gmatch '([^\n]*)\n' do table.insert(lines, line) end
  for i = #lines, 1, -1 do
    local first, last = lines[i]:find(text, 1, true)
    if first then
      local prefixes, suffixes = { '' }, { '' }
      if strip_gutter(lines[i]:sub(last + 1), true) == '' then
        local acc = ''
        for k = i + 1, math.min(i + WRAP_LINES, #lines) do
          local rest = strip_gutter(lines[k], false)
          local frag = rest:match('^' .. PATH_CHARS .. '+')
          if not frag then break end
          acc = acc .. frag
          table.insert(suffixes, acc)
          if frag ~= (rest:gsub('%s+$', '')) then break end -- the path ends on this line
        end
      end
      if strip_gutter(lines[i]:sub(1, first - 1), false) == '' then
        local acc = ''
        for k = i - 1, math.max(i - WRAP_LINES, 1), -1 do
          local rest = strip_gutter(lines[k], true)
          local frag = rest:match(PATH_CHARS .. '+$')
          if not frag then break end
          acc = frag .. acc
          table.insert(prefixes, acc)
          if frag ~= strip_gutter(rest, false) then break end -- the path starts on this line
        end
      end
      local cands = {}
      for _, pre in ipairs(prefixes) do
        for _, suf in ipairs(suffixes) do
          if pre ~= '' or suf ~= '' then table.insert(cands, pre .. text .. suf) end
        end
      end
      table.sort(cands, function(a, b) return #a > #b end)
      return cands, #suffixes > 1
    end
  end
  return {}, false
end

local function open_remote_peek(window, pane, ssh, kind, path, line)
  -- $HOME/.local/bin first: ssh-setup's yazi and its previewers, else any yazi.
  -- This sh is non-interactive (no ~/.bashrc), so set the editor here too
  local script = 'export PATH="$HOME/.local/bin:$PATH" EDITOR=micro VISUAL=micro; '
    .. (kind == 'f' and ('export YAZI_PEEK=' .. sh_quote(path) .. '; ') or '')
    .. (kind == 'f' and line and ('export YAZI_PEEK_LINE=' .. sh_quote(line) .. '; ') or '')
    .. 'exec yazi ' .. sh_quote(path)
  local args = { SSH_PANE, '-t' }
  for k = 2, #ssh do table.insert(args, ssh[k]) end
  table.insert(args, 'sh -c ' .. sh_quote(script))
  replace_peek(window, pane, {
    cwd = wezterm.home_dir,
    args = args,
    set_environment_variables = { PATH = SPAWN_PATH },
  })
end

-- CMD+OPT+click reveals the path in Finder instead (drag it from there into
-- a browser upload, Slack, ...): `open -R` for files, `open` for directories.
-- A remote file is first copied to ~/Downloads/<host>/ over the existing
-- ControlMaster. CMD+OPT+SHIFT+click opens a file in macOS Quick Look
-- instead (a remote one is copied to ~/Library/Caches/wezterm/peek/<host>/
-- first). The mouse binding sets 'reveal <time>' or 'look <time>' right
-- before opening the link; it is consumed by the next open-uri and ignored
-- once stale.
local LINK_MODE_KEY = 'link_mode_next_link'

-- Video and audio can't play in a terminal: a plain click reveals them too
local MEDIA_EXT = {}
for e in ([[mp4 mov m4v mkv webm avi wmv flv mpg mpeg 3gp mp3 wav m4a flac aac ogg opus aiff]]):gmatch '%S+' do
  MEDIA_EXT[e] = true
end

local function is_media(path)
  local ext = path:match '%.([^./]+)$'
  return ext ~= nil and MEDIA_EXT[ext:lower()] == true
end

-- A plain click opens PDFs in Preview, which zooms and scrolls them properly
local function is_pdf(path)
  return path:lower():match '%.pdf$' ~= nil
end

local reveal_local -- defined below, after file_cmd

-- Quick Look (CMD+OPT+SHIFT+click), see LINK_MODE_KEY
local QUICKLOOK_PID = wezterm.home_dir .. '/.local/state/wezterm/quicklook.pid'
local PEEK_CACHE = wezterm.home_dir .. '/Library/Caches/wezterm/peek/'

-- sh -c script: pidfile mode args...
--   reveal <file>      select it in Finder (AppleScript, since `open -R` skips
--                      files under hidden paths like /private/tmp; falls back
--                      to `open -R` if osascript fails, e.g. Automation denied)
--   look <file>        Quick Look it; one panel at a time (the qlmanage
--                      started last time is closed first)
--   reveal-copy|look-copy <dir> <name> <cmd...>
--                      run cmd (cat of a remote file) into dir/name via a
--                      .part file, then reveal it in Finder or Quick Look
--                      it; notify on failure
--   download <dir> <status> <cmd...>
--                      unpack the tar stream of one file or folder that cmd
--                      writes into dir, under a numbered name if a different
--                      item already has that name, write the outcome to the
--                      status file (three lines: kind, path, size or error;
--                      see DOWNLOAD_NOTES) and reveal it in Finder. Exit 1-2
--                      are tar's "some files changed or were unreadable";
--                      higher is ssh or the remote shell failing.
--   preview <status> <file>
--                      open it in Preview; status as for download (kind
--                      `opened` or `failed`)
--   preview-copy <dir> <name> <status> <stat cmd> <cat cmd> <ssh...>
--                      copy a remote file into dir/name (ssh... + cat cmd)
--                      unless dir/.stamp still matches its size and mtime
--                      (ssh... + stat cmd), then preview it
local FILE_SCRIPT = [[
pf=$1 mode=$2; shift 2
reveal() {
  osascript -e 'on run argv' -e 'tell application "Finder"' \
    -e 'reveal POSIX file (item 1 of argv)' -e 'activate' -e 'end tell' \
    -e 'end run' "$1" >/dev/null 2>&1 || open -R -- "$1"
}
look() {
  old=$(cat "$pf" 2>/dev/null)
  case $(ps -o comm= -p "${old:-0}" 2>/dev/null) in *qlmanage) kill "$old" ;; esac
  mkdir -p "$(dirname "$pf")"
  qlmanage -p "$1" >/dev/null 2>&1 &
  echo $! > "$pf"
  wait $!
  # qlmanage aborts on video (AVKit: highlightedTimeRanges unsupported) and
  # shows nothing; reveal it in Finder instead (Space there previews it).
  # 143 = SIGTERM from the next Quick Look replacing this panel
  st=$?
  if [ "$st" -gt 128 ] && [ "$st" -ne 143 ]; then reveal "$1"; fi
}
report() { printf '%s\n' "$1" "$2" "$3" > "$st.tmp" && mv -f "$st.tmp" "$st"; }
download() {
  dir=$1 st=$2; shift 2
  mkdir -p "$dir" "$(dirname "$st")"
  tmp=$(mktemp -d "$dir/.download.XXXXXX") || { report failed "$dir" 'cannot write there'; return; }
  mkdir "$tmp/x"
  { "$@" 2> "$tmp/err"; echo $? > "$tmp/rc"; } | tar -xf - -C "$tmp/x" 2> "$tmp/xerr"
  xrc=$? rc=$(cat "$tmp/rc")
  # read-only remote folders could neither be renamed nor deleted here
  chmod -R u+rwX "$tmp/x"
  item=$(find "$tmp/x" -mindepth 1 -maxdepth 1 -print -quit)
  if [ "$xrc" -ne 0 ] || [ "$rc" -gt 2 ] || [ -z "$item" ]; then
    msg=$(tail -n 1 "$tmp/err")
    report failed '' "${msg:-$(tail -n 1 "$tmp/xerr")}"
    rm -rf "$tmp"
    return
  fi
  base=${item##*/} stem=${item##*/} ext=
  if [ -f "$item" ]; then
    case $base in ?*.*) stem=${base%.*} ext=.${base##*.} ;; esac
  fi
  dest=$dir/$base n=0 kind=done
  [ "$rc" -eq 0 ] || kind=partial
  while [ -e "$dest" ] || [ -L "$dest" ]; do
    if diff -rq "$dest" "$item" > /dev/null 2>&1; then kind=same; break; fi
    n=$((n + 1)) dest="$dir/$stem ($n)$ext"
  done
  [ "$kind" = same ] || mv -n "$item" "$dest"
  rm -rf "$tmp"
  report "$kind" "$dest" "$(du -sh "$dest" | awk '{ print $1 }')"
  reveal "$dest"
}
fail() { report failed '' "$(tail -n 1 "$st.err" 2>/dev/null)"; rm -f "$st.err"; }
preview() {
  st=$1
  mkdir -p "$(dirname "$st")"
  if open -a Preview -- "$2" 2> "$st.err"; then report opened "$2" ''; rm -f "$st.err"; else fail; fi
}
preview_copy() {
  dir=$1 name=$2 st=$3 statcmd=$4 catcmd=$5; shift 5
  f=$dir/$name
  mkdir -p "$dir" "$(dirname "$st")" || { report failed '' 'cannot write the cache'; return; }
  stamp=$("$@" "$statcmd" 2> "$st.err") && [ -n "$stamp" ] || { fail; return; }
  if [ ! -f "$f" ] || [ "$(cat "$dir/.stamp" 2>/dev/null)" != "$stamp" ]; then
    rm -f "$dir/.stamp"
    "$@" "$catcmd" > "$f.part" 2> "$st.err" && mv -f "$f.part" "$f" \
      || { rm -f "$f.part"; fail; return; }
    printf '%s\n' "$stamp" > "$dir/.stamp"
  fi
  rm -f "$st.err"
  preview "$st" "$f"
}
if [ "$mode" = preview ]; then preview "$@"; exit; fi
if [ "$mode" = preview-copy ]; then preview_copy "$@"; exit; fi
if [ "$mode" = look ]; then look "$1"; exit; fi
if [ "$mode" = reveal ]; then reveal "$1"; exit; fi
if [ "$mode" = download ]; then download "$@"; exit; fi
dir=$1 name=$2; shift 2
if mkdir -p "$dir" && "$@" > "$dir/$name.part" && mv -f "$dir/$name.part" "$dir/$name"; then
  if [ "$mode" = look-copy ]; then look "$dir/$name"; else reveal "$dir/$name"; fi
  exit
fi
rm -f "$dir/$name.part"
osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "wezterm"' -e 'end run' "Copy failed: $name"]]

local function file_cmd(mode, ...)
  return { '/bin/sh', '-c', FILE_SCRIPT, 'sh', QUICKLOOK_PID, mode, ... }
end

reveal_local = function(path)
  wezterm.background_child_process(is_dir(path) and { '/usr/bin/open', path }
    or file_cmd('reveal', path))
end

local function quicklook_local(window, path)
  wezterm.background_child_process(file_cmd('look', path))
  toast(window, 'Quick Look: ' .. (path:match '[^/]+$' or path), 2000)
end

-- Copies from the pane's host over the master.
-- (A do-block: the main chunk is near Lua's limit of 200 local variables.)
local reveal_remote, quicklook_remote, download_remote, preview_file
do
-- Copy remote file `path` into local `dir` over the master, then reveal or
-- Quick Look it (mode 'reveal-copy' / 'look-copy')
local function fetch_remote(ssh, path, mode, dir)
  local cmd = file_cmd(mode, dir, path:match '[^/]+$')
  for _, a in ipairs(ssh_batch_cmd(ssh)) do table.insert(cmd, a) end
  table.insert(cmd, 'cat -- ' .. sh_quote(path))
  wezterm.background_child_process(cmd)
end

-- Host as a safe local directory name
local function host_dir(ssh)
  return (ssh_host(ssh):gsub('[^%w.-]', '_'))
end

function reveal_remote(window, ssh, kind, path)
  local host = ssh_host(ssh)
  if kind == 'd' then
    toast(window, 'Finder: ' .. host .. ':' .. path .. ' is a remote directory; not copied')
    return
  end
  local sub = host_dir(ssh)
  fetch_remote(ssh, path, 'reveal-copy', wezterm.home_dir .. '/Downloads/' .. sub)
  toast(window, 'Finder: copying ' .. host .. ':' .. path .. ' to ~/Downloads/' .. sub .. '/')
end

function quicklook_remote(window, ssh, path)
  fetch_remote(ssh, path, 'look-copy', PEEK_CACHE .. host_dir(ssh))
  toast(window, 'Quick Look: copying ' .. ssh_host(ssh) .. ':' .. path, 2000)
end

-- Right-click on a path in an ssh pane: download the file or folder to
-- ~/Downloads/<host>/ in the background. tar works for both, keeps names with
-- spaces and needs nothing but ssh and tar on the host (rsync may be missing
-- there, and this Mac's is openrsync). The transfer outlives this config
-- (reloads, ...), so it is not waited for here: `download` in FILE_SCRIPT
-- leaves a status file, which update-status picks up. wezterm.time.call_after
-- would be dropped by a reload. preview_file tracks its copies the same way.
local DOWNLOADS_KEY = 'downloads' -- JSON list of { status, window, what, area? }
local DOWNLOAD_STATUS_DIR = wezterm.home_dir .. '/.local/state/wezterm/downloads/'
local DOWNLOAD_NOTES = {
  done = 'Download: %s (%s) in %s',
  partial = 'Download: %s (%s) in %s, INCOMPLETE: some files changed or were unreadable',
  same = 'Download: %s (%s) was already in %s',
}

-- $1: remote path. A symlink gets its target, not a dangling link.
local REMOTE_TAR = [[
p=$(readlink -f -- "$1" 2>/dev/null) || p=$1
[ "$p" != / ] || { echo 'refusing to download /' >&2; exit 3; }
cd -- "$(dirname -- "$p")" && exec tar -cf - -- "./$(basename -- "$p")"]]

local function set_downloads(list)
  wezterm.GLOBAL[DOWNLOADS_KEY] = #list > 0 and wezterm.json_encode(list) or nil
end

local function downloads()
  return wezterm.json_parse(wezterm.GLOBAL[DOWNLOADS_KEY] or '[]')
end

-- New status file path for a background copy
local function new_status()
  local seq = (wezterm.GLOBAL.download_seq or 0) + 1
  wezterm.GLOBAL.download_seq = seq
  return DOWNLOAD_STATUS_DIR .. os.time() .. '-' .. seq
end

-- Have update-status toast the outcome written to `status`
local function track(window, status, what, area)
  local list = downloads()
  table.insert(list, { status = status, window = window:window_id(), what = what, area = area })
  set_downloads(list)
end

function download_remote(window, ssh, path)
  local sub = host_dir(ssh)
  local status = new_status()
  local cmd = file_cmd('download', wezterm.home_dir .. '/Downloads/' .. sub, status)
  for _, a in ipairs(ssh_batch_cmd(ssh)) do table.insert(cmd, a) end
  table.insert(cmd, 'sh -c ' .. sh_quote(REMOTE_TAR) .. ' sh ' .. sh_quote(path))
  wezterm.background_child_process(cmd)
  local what = ssh_host(ssh) .. ':' .. path
  track(window, status, what)
  toast(window, 'Download: ' .. what .. ' to ~/Downloads/' .. sub .. '/', 4000)
end

-- 8 hex digits (FNV-1a) naming the cache folder of one remote path, so files
-- with the same name in different remote folders don't overwrite each other
local function short_hash(s)
  local h = 2166136261
  for k = 1, #s do h = ((h ~ s:byte(k)) * 16777619) & 0xffffffff end
  return string.format('%08x', h)
end

-- Open a PDF in Preview without blocking the GUI. A local one opens in
-- place; a remote one (ssh given) is copied over the master to
-- PEEK_CACHE/<host>/<hash of path>/<name> first, or reused from there when
-- its size and mtime are unchanged. Failures toast via update-status.
function preview_file(window, path, ssh)
  local name = path:match '[^/]+$' or path
  local status = new_status()
  local cmd, what = file_cmd('preview', status, path), name
  if ssh then
    local q = sh_quote(path)
    cmd = file_cmd('preview-copy', PEEK_CACHE .. host_dir(ssh) .. '/' .. short_hash(path), name,
      status, 'sh -c ' .. sh_quote('{ stat -L -c "%s %Y" -- ' .. q .. ' || stat -L -f "%z %m" -- '
        .. q .. '; } 2>/dev/null || { echo "cannot read the file" >&2; exit 1; }'),
      'cat -- ' .. q)
    for _, a in ipairs(ssh_batch_cmd(ssh)) do table.insert(cmd, a) end
    what = ssh_host(ssh) .. ':' .. path
  end
  wezterm.background_child_process(cmd)
  track(window, status, what, 'Preview')
  toast(window, 'Preview: opening ' .. name .. (ssh and (' from ' .. ssh_host(ssh)) or '') .. '…', 2000)
end

local function download_note(d, kind, dest, info)
  if kind == 'opened' then return nil end -- preview_file: Preview shows it
  if not DOWNLOAD_NOTES[kind] then
    return (d.area or 'Download') .. ' failed: ' .. d.what .. ((info or '') ~= '' and (': ' .. info) or '')
  end
  local dir, name = dest:match '^(.*)/([^/]*)$'
  if dir:sub(1, #wezterm.home_dir + 1) == wezterm.home_dir .. '/' then
    dir = '~' .. dir:sub(#wezterm.home_dir + 1)
  end
  return string.format(DOWNLOAD_NOTES[kind], name, info, dir .. '/')
end

-- Every status file is taken and the list saved before the first toast:
-- finding the window yields, and other windows poll in the meantime
local function poll_downloads(window)
  local left, finished = {}, {}
  for _, d in ipairs(downloads()) do
    local f = io.open(d.status)
    if f then
      local kind, dest, info = f:read('a'):match '^([^\n]*)\n([^\n]*)\n([^\n]*)'
      f:close()
      os.remove(d.status)
      local note = download_note(d, kind, dest, info)
      if note then table.insert(finished, { d = d, note = note }) end
    else
      table.insert(left, d)
    end
  end
  set_downloads(left)
  for _, r in ipairs(finished) do
    -- It raises for a window closed since the click
    local ok, target = pcall(wezterm.gui.gui_window_for_mux_window, r.d.window)
    toast(ok and target or window, r.note, 8000)
  end
end

wezterm.on('update-status', function(window)
  if wezterm.GLOBAL[DOWNLOADS_KEY] then poll_downloads(window) end
end)
end -- copies from the pane's host

-- Localhost links and ssh -L tunnel commands. A server on a remote host
-- (Jupyter, TensorBoard, vite, ...) prints http://localhost:PORT/..., often
-- with a tunnel hint like `ssh -N -L 8790:node-1:8765 me@login.example.org`
-- when it runs on a compute node behind a login host. Forwards are added to
-- the existing ControlMaster for that host (`ssh -O forward`), never a new
-- login:
--  * CMD+click an `ssh ... -L ...` command: add its forwards instead of
--    running it.
--  * CMD+click http://localhost:PORT/...: the most recent `ssh ... -L
--    PORT:...` command in the pane's scrollback gives the host and target
--    (this works from a local pane too); otherwise, in an ssh pane, the same
--    port on that host's localhost is forwarded. Then the URL opens locally,
--    path and query kept. A placeholder like ?token=<token> is filled from
--    a token file read over the same master: the most recent `cat .../token`
--    in this pane's scrollback, else in the window's other panes (newest
--    first), else the file that last worked for that host and remote port
--    (see TOKEN_PATHS_FILE). The token is never logged, shown or written to
--    disk; only the file's path is remembered.
-- Local port conflicts: a forward of ours for another target is cancelled
-- and replaced; one added through the master some other way is cancelled if
-- its -L spec shows up in the scrollback or a running ssh command line; a
-- standalone ssh tunnel (an old `ssh -N -L`) is left alone and named by pid;
-- otherwise the next free port is used and the URL rewritten. Ports below
-- 1024 map to 8000+port. Forwards are remembered in wezterm.GLOBAL and reused
-- while the master still listens on them.

-- Remote target per URL host, also the host used in the rewritten URL
local LOOPBACK = {
  localhost = 'localhost', ['127.0.0.1'] = '127.0.0.1', ['0.0.0.0'] = 'localhost', ['[::1]'] = '[::1]',
}
local FORWARD_KEY = 'ssh_forward_' -- .. master args .. '|' .. target:rport -> local port
local FORWARD_PORT_KEY = 'ssh_forward_port_' -- .. local port -> "args\ttarget\trport" (ours)
local SCROLLBACK_LINES = 2000

-- { scheme, host, rport, rest } for a loopback http(s) URL, else nil
local function parse_loopback_url(uri)
  local scheme, host, port, rest = uri:match '^(https?)://(%[::1%])(:?%d*)(.*)$'
  if not scheme then
    scheme, host, port, rest = uri:match '^(https?)://([^/:?#]+)(:?%d*)(.*)$'
  end
  if not scheme or not LOOPBACK[host:lower()] or not (rest == '' or rest:match '^[/?#]') then
    return nil
  end
  local rport = tonumber(port:sub(2)) or (scheme == 'https' and 443 or 80)
  return { scheme = scheme, host = host:lower(), rport = rport, rest = rest }
end

-- "[bind:]lport:host:rport" (host may be [v6]) -> { lport, host, rport }
local function parse_forward_spec(spec)
  local rest, rport = spec:match '^(.*):(%d+)$'
  if not rest then return nil end
  local head, host = rest:match '^(.*):(%[[^%]]+%])$'
  if not head then head, host = rest:match '^(.*):([^:]+)$' end
  local lport = head and (head:match '^(%d+)$' or head:match ':(%d+)$')
  if not lport then return nil end
  return { lport = tonumber(lport), host = host, rport = tonumber(rport) }
end

-- -L forwards anywhere after argv[first] (OpenSSH also takes options after
-- the destination); flags are walked like ssh_split_args does
local function collect_forwards(argv, first)
  local forwards, k = {}, first + 1
  while k <= #argv do
    local a = argv[k]
    if a:match '^%-%w' then
      for j = 2, #a do
        local c = a:sub(j, j)
        if SSH_OPTS_WITH_VALUE[c] then
          local value = a:sub(j + 1)
          if value == '' then
            k = k + 1
            value = argv[k]
          end
          local f = c == 'L' and value and parse_forward_spec(value)
          if f then table.insert(forwards, f) end
          break
        end
      end
    end
    k = k + 1
  end
  return forwards
end

-- Text holding `ssh ... -L ... dest` -> pane_ssh_args-style args and its
-- forwards, or nil. Quotes/backticks around words and trailing prose
-- punctuation are dropped.
local function parse_ssh_text(text)
  local argv, first = {}, nil
  for w in text:gmatch '%S+' do
    w = w:gsub('^[`\'"(]+', ''):gsub('[`\'".,;)]+$', '')
    if w ~= '' then
      table.insert(argv, w)
      if not first and w:match '[^/]*$' == 'ssh' then first = #argv end
    end
  end
  if not first then return nil end
  local ssh, forwards = ssh_split_args(argv, first), collect_forwards(argv, first)
  if not ssh or #forwards == 0 then return nil end
  return ssh, forwards
end

-- Tunnel commands ({ ssh, forwards }, oldest first), the last `cat <path
-- with "token">` and loopback URLs (parsed, oldest first) in the pane's
-- recent scrollback. Logical lines, so text soft-wrapped by the terminal
-- stays whole.
local function scrollback_hints(pane)
  local tunnels, token_path, urls = {}, nil, {}
  local ok, text = pcall(pane.get_logical_lines_as_text, pane, SCROLLBACK_LINES)
  for line in (ok and text or ''):gmatch '[^\n]+' do
    local cmd = line:match '%f[%w]ssh%s.*'
    if cmd and cmd:find('-', 1, true) then
      local ssh, forwards = parse_ssh_text(cmd)
      if ssh then table.insert(tunnels, { ssh = ssh, forwards = forwards }) end
    end
    for path in line:gmatch '%f[%w]cat%s+([^%s`\'"]+)' do
      if path:lower():find('token', 1, true) then token_path = (path:gsub('[.,;:)]+$', '')) end
    end
    for u in line:gmatch 'https?://[^%s`\'"]+' do
      local url = parse_loopback_url((u:gsub('[.,;:)]+$', '')))
      if url then table.insert(urls, url) end
    end
  end
  return tunnels, token_path, urls
end

-- Most recent tunnel forwarding local `port`: its args and forward
local function find_tunnel(tunnels, port)
  for i = #tunnels, 1, -1 do
    for _, f in ipairs(tunnels[i].forwards) do
      if f.lport == port then return tunnels[i].ssh, f end
    end
  end
  return nil
end

-- "hostname user port" as ssh resolves them from the config (ssh -G never
-- connects)
local function ssh_identity(ssh)
  local ok, out = wezterm.run_child_process(ssh_cmd(ssh, '-G'))
  if not ok then return nil end
  local f = {}
  for line in out:gmatch '[^\n]+' do
    local k, v = line:match '^(%S+) (.*)$'
    if k and not f[k] then f[k] = v end
  end
  return f.hostname, f.user, f.port
end

-- Concrete Host aliases in ~/.ssh/config (no wildcards; Includes not read)
local function ssh_config_aliases()
  local f = io.open(wezterm.home_dir .. '/.ssh/config')
  if not f then return {} end
  local text = f:read 'a'
  f:close()
  local aliases = {}
  for line in text:gmatch '[^\n]+' do
    for alias in (line:match '^%s*[Hh][Oo][Ss][Tt]%s+(.-)%s*$' or ''):gmatch '%S+' do
      if not alias:find '[*?!]' then table.insert(aliases, alias) end
    end
  end
  return aliases
end

-- Args whose ControlMaster is live for the destination of `ssh`, and the
-- master's pid; nil if none. A hint may spell the host differently from the
-- alias that started the master (me@login.example.org vs myserver): with
-- ControlPath %C that is the same socket, but a per-alias ControlPath (e.g.
-- %r@%h:%p set only under `Host myserver`) is not, so config aliases
-- resolving to the same hostname/port (user too, if any alias matches it)
-- are tried as well.
local function find_master(ssh)
  local pid = ssh_master_pid(ssh)
  if pid then return ssh, pid end
  local host, user, port = ssh_identity(ssh)
  if not host then return nil end
  local loose = {}
  for _, alias in ipairs(ssh_config_aliases()) do
    local cand = { SSH_PANE, alias }
    local h, u, p = ssh_identity(cand)
    if h == host and p == port then
      if u == user then
        pid = ssh_master_pid(cand)
        if pid then return cand, pid end
      else
        table.insert(loose, cand)
      end
    end
  end
  for _, cand in ipairs(loose) do
    pid = ssh_master_pid(cand)
    if pid then return cand, pid end
  end
  return nil
end

-- pid (string) and command name of the process listening on local TCP
-- `port`, or nil
local function listener(port)
  local ok, out = wezterm.run_child_process {
    '/usr/sbin/lsof', '-nP', '-iTCP:' .. port, '-sTCP:LISTEN', '-Fpc',
  }
  if not ok then return nil end
  return out:match '^p(%d+)', out:match '\nc([^\n]*)'
end

-- -L forwards for local `port` from running ssh command lines (`pid` only,
-- if given)
local function running_forwards(port, pid)
  local ok, out = wezterm.run_child_process(pid and { '/bin/ps', '-o', 'args=', '-p', pid }
    or { '/bin/ps', '-axo', 'args=' })
  local found = {}
  for line in (ok and out or ''):gmatch '[^\n]+' do
    if line:find('-', 1, true) and line:match '%f[%w]ssh%s' then
      local _, forwards = parse_ssh_text(line)
      for _, f in ipairs(forwards or {}) do
        if f.lport == port then table.insert(found, f) end
      end
    end
  end
  return found
end

local function forward_key(ssh, target, rport)
  return FORWARD_KEY .. table.concat(ssh, ' ', 2) .. '|' .. target .. ':' .. rport
end

-- -O forward / -O cancel of lport:target:rport on master `ssh`, keeping the
-- GLOBAL records in step
local function add_forward(ssh, lport, target, rport)
  local spec = lport .. ':' .. target .. ':' .. rport
  if not wezterm.run_child_process(ssh_cmd(ssh, '-O', 'forward', '-L', spec)) then return false end
  wezterm.GLOBAL[forward_key(ssh, target, rport)] = lport
  wezterm.GLOBAL[FORWARD_PORT_KEY .. lport] = table.concat(ssh, '\t') .. '\n' .. target .. '\n' .. rport
  return true
end

local function cancel_forward(ssh, lport, target, rport)
  wezterm.run_child_process(ssh_cmd(ssh, '-O', 'cancel', '-L', lport .. ':' .. target .. ':' .. rport))
  if listener(lport) then return false end
  wezterm.GLOBAL[FORWARD_PORT_KEY .. lport] = nil
  wezterm.GLOBAL[forward_key(ssh, target, rport)] = nil
  return true
end

-- Master args and forward recorded as ours for local `port`, or nil
local function recorded_forward(port)
  local rec = wezterm.GLOBAL[FORWARD_PORT_KEY .. port]
  local args, target, rport = (rec or ''):match '^(.-)\n(.-)\n(%d+)$'
  if not args then return nil end
  local ssh = {}
  for v in args:gmatch '[^\t]+' do table.insert(ssh, v) end
  return ssh, { lport = port, host = target, rport = tonumber(rport) }
end

-- Forward local `want` (or a free port near it) to target:rport through
-- master `ssh` (pid `pid`). `seen` are -L forwards from the scrollback: what
-- a busy port may have been forwarded to, for cancelling. Returns the local
-- port, how ('new', 'reused' or 'tunnel') and an optional note; or nil and a
-- message.
local function ssh_forward(ssh, pid, target, rport, want, seen)
  want = want >= 1024 and want or 8000 + want
  local function same(f) return f.host == target and f.rport == rport end
  local note
  local lpid, lcmd = listener(want)
  if lpid then
    -- Which master holds `want` (one we forwarded through, or this one) and
    -- what it is known to forward there (our record, running ssh -L clients)
    local rec_ssh, rec = recorded_forward(want)
    local holder, held = nil, {}
    if rec_ssh and ssh_master_pid(rec_ssh) == lpid then
      holder, held = rec_ssh, { rec }
    elseif lpid == pid then
      holder = ssh
    end
    if holder then
      for _, f in ipairs(running_forwards(want)) do table.insert(held, f) end
      for _, f in ipairs(held) do
        if lpid == pid and same(f) then
          wezterm.GLOBAL[forward_key(ssh, target, rport)] = want
          return want, 'reused'
        end
      end
      local candidates = held
      for _, f in ipairs(seen or {}) do
        if f.lport == want and not same(f) then table.insert(candidates, f) end
      end
      for _, f in ipairs(candidates) do
        if cancel_forward(holder, want, f.host, f.rport) then
          note = 'replaced ' .. want .. ' → ' .. f.host .. ':' .. f.rport
          break
        end
      end
      if not note then note = want .. ' is held by ssh pid ' .. lpid .. ' for another target' end
    elseif lcmd == 'ssh' then
      for _, f in ipairs(running_forwards(want, lpid)) do
        if same(f) then return want, 'tunnel', 'ssh pid ' .. lpid end
      end
      note = want .. ' is held by an older ssh tunnel (pid ' .. lpid .. ', left running)'
    else
      note = want .. ' is used by ' .. (lcmd or '?') .. ' (pid ' .. lpid .. ')'
    end
    -- Still busy: an earlier forward of ours to the same target will do
    local known = wezterm.GLOBAL[forward_key(ssh, target, rport)]
    if listener(want) and known and known ~= want and listener(known) == pid then
      return known, 'reused', note
    end
  end
  local last = math.min(want + 20, 65535)
  for lport = want, last do
    -- lsof can't see other users' listeners; a failed bind just moves on
    if not listener(lport) and add_forward(ssh, lport, target, rport) then
      return lport, 'new', note
    end
  end
  return nil, 'Forward: no free local port in ' .. want .. '-' .. last .. (note and ('; ' .. note) or '')
end

local function is_loopback_target(target)
  return target == 'localhost' or target == '127.0.0.1' or target == '[::1]'
end

-- "localhost:8790 → node-1:8765 via myserver" (+ how/note)
local function describe_forward(master, lport, target, rport, how, note)
  local to = is_loopback_target(target) and (ssh_host(master) .. ':' .. rport)
    or (target .. ':' .. rport .. ' via ' .. ssh_host(master))
  local msg = 'localhost:' .. lport .. ' → ' .. to
  if how == 'reused' then msg = msg .. ' (existing)' end
  if how == 'tunnel' then msg = msg .. ' (existing tunnel, ' .. note .. ')' end
  if note and how ~= 'tunnel' then msg = msg .. '; ' .. note end
  return msg
end

local function all_forwards(tunnels)
  local seen = {}
  for _, t in ipairs(tunnels) do
    for _, f in ipairs(t.forwards) do table.insert(seen, f) end
  end
  return seen
end

local function no_master_msg(ssh)
  return 'Forward: no live ssh connection to ' .. ssh_host(ssh)
    .. ' (ControlMaster); open an ssh pane to it first'
end

-- Query value that is a placeholder: <token>, %3Ctoken%3E, {token}, TOKEN,
-- YOUR_TOKEN (a link rule may have cut a trailing >)
local function is_placeholder(v)
  return v:match '^<' or v:match '^%%3[Cc]' or v:match '^{' or v:match '^[A-Z_]*TOKEN[A-Z_]*$'
end

-- `rest` (path?query#frag) with placeholder values set to `value` (already
-- URL-encoded) or, if nil, their params dropped; plus whether any was found
local function fill_placeholder(rest, value)
  local path, query, frag = rest:match '^([^?#]*)%??([^#]*)(.*)$'
  local parts, found = {}, false
  for kv in query:gmatch '[^&]+' do
    local k, v = kv:match '^([^=]*)=(.*)$'
    if k and is_placeholder(v) then
      found = true
      if value then table.insert(parts, k .. '=' .. value) end
    else
      table.insert(parts, kv)
    end
  end
  if not found then return rest, false end
  return path .. (#parts > 0 and ('?' .. table.concat(parts, '&')) or '') .. frag, true
end

local function url_encode(s)
  return (s:gsub('[^%w%-._~]', function(c) return string.format('%%%02X', c:byte()) end))
end

-- One whitespace-free token from a remote file (first 4 KiB), or nil
local function read_remote_token(ssh, path)
  local cmd = ssh_batch_cmd(ssh)
  table.insert(cmd, 'head -c 4096 -- ' .. remote_word(path))
  local ok, out = wezterm.run_child_process(cmd)
  return ok and out:match '^%s*(%S+)%s*$' or nil
end

-- Token-file paths that worked, per "<ssh hostname> <remote port>", so a
-- later click finds the token without a `cat` hint even when the server
-- moved to another node. One "host port path" line each; paths only, never
-- tokens. Cached in wezterm.GLOBAL (TOKEN_PATH_KEY .. key).
local TOKEN_PATHS_FILE = wezterm.home_dir .. '/.local/state/wezterm/token-paths'
local TOKEN_PATH_KEY = 'token_path_'

local function read_token_paths()
  local paths = {}
  local f = io.open(TOKEN_PATHS_FILE)
  if not f then return paths end
  for line in f:lines() do
    local host, port, path = line:match '^(%S+) (%d+) (.+)$'
    if host then paths[host .. ' ' .. port] = path end
  end
  f:close()
  return paths
end

local function remembered_token_path(key)
  if not wezterm.GLOBAL.token_paths_loaded then
    for k, path in pairs(read_token_paths()) do wezterm.GLOBAL[TOKEN_PATH_KEY .. k] = path end
    wezterm.GLOBAL.token_paths_loaded = true
  end
  return wezterm.GLOBAL[TOKEN_PATH_KEY .. key]
end

local function remember_token_path(key, path)
  if remembered_token_path(key) == path then return end
  wezterm.GLOBAL[TOKEN_PATH_KEY .. key] = path
  local paths = read_token_paths()
  paths[key] = path
  -- Private file (mode 600) in a private dir, created before anything is written
  local dir = TOKEN_PATHS_FILE:match '^(.*)/'
  wezterm.run_child_process { '/bin/sh', '-c',
    'umask 077 && mkdir -p "$1" && touch "$2" && chmod 600 "$2"', 'sh', dir, TOKEN_PATHS_FILE }
  local lines = {}
  for k, v in pairs(paths) do table.insert(lines, k .. ' ' .. v) end
  table.sort(lines)
  local f = io.open(TOKEN_PATHS_FILE, 'w')
  if f then
    f:write(table.concat(lines, '\n') .. '\n')
    f:close()
  end
end

-- Memoized finder for the token of the server on remote port `rport` behind
-- master `ssh`, trying in order: `hint` (this pane's `cat` path), `cat`
-- paths in the window's other panes (newest first), the remembered path for
-- that host and port. A path that yields a token is remembered.
local function token_finder(window, pane, ssh, rport, hint)
  local done, token
  return function()
    if done then return token end
    done = true
    local host = ssh_identity(ssh)
    local key = host and rport and (host .. ' ' .. rport)
    local tried = {}
    local function try(path)
      if token or not path or tried[path] then return end
      tried[path] = true
      token = read_remote_token(ssh, path)
      if token and key then remember_token_path(key, path) end
    end
    try(hint)
    if not token then
      local others = {}
      local ok, tabs = pcall(function() return window:mux_window():tabs() end)
      for _, tab in ipairs(ok and tabs or {}) do
        for _, p in ipairs(tab:panes()) do
          if p:pane_id() ~= pane:pane_id() then table.insert(others, p) end
        end
      end
      table.sort(others, function(a, b) return a:pane_id() > b:pane_id() end)
      for _, p in ipairs(others) do
        local _, path = scrollback_hints(p)
        try(path)
      end
    end
    if key then try(remembered_token_path(key)) end
    return token
  end
end

-- Open loopback `url` in the browser on local port `lport`, its token
-- placeholder (if any) filled from `get_token()` (a token_finder);
-- `notify` gets a note about the token. Returns "host:port" opened.
local function open_local(url, lport, get_token, notify)
  local rest, has_placeholder = fill_placeholder(url.rest, nil)
  if has_placeholder then
    local token = get_token()
    if token then
      rest = fill_placeholder(url.rest, url_encode(token))
      notify 'token filled in'
    else
      notify 'token not found, opened without it'
    end
  end
  local host = LOOPBACK[url.host]
  wezterm.open_with(url.scheme .. '://' .. host .. ':' .. lport .. rest)
  return host .. ':' .. lport
end

-- Most recent scrollback URL for local `port`, or nil
local function latest_url(urls, port)
  for i = #urls, 1, -1 do
    if urls[i].rport == port then return urls[i] end
  end
  return nil
end

-- CMD+click on an `ssh ... -L ...` command: add its forwards
local function forward_command(window, pane, text)
  local ssh, forwards = parse_ssh_text(text)
  if not ssh then
    toast(window, 'Forward: no -L forward in that ssh command')
    return
  end
  local master, pid = find_master(ssh)
  if not master then
    toast(window, no_master_msg(ssh), 5000)
    return
  end
  local tunnels, token_path, urls = scrollback_hints(pane)
  local seen = all_forwards(tunnels)
  local done, open_url, open_port, open_rport = {}, nil, nil, nil
  for _, f in ipairs(forwards) do
    local lport, how, note = ssh_forward(master, pid, f.host, f.rport, f.lport, seen)
    table.insert(done, lport and describe_forward(master, lport, f.host, f.rport, how, note) or how)
    -- Open one: the first forward with a URL in the scrollback, else the first
    local url = lport and latest_url(urls, f.lport)
    if lport and (not open_port or (url and not open_url)) then
      open_url, open_port, open_rport = url, lport, f.rport
    end
  end
  local msg = 'Forward: ' .. table.concat(done, ' · ')
  if open_port then
    -- No URL printed: a findable token still gets in (Jupyter-style ?token=)
    local get_token = token_finder(window, pane, master, open_rport, token_path)
    local url = open_url or parse_loopback_url('http://localhost:' .. open_port
      .. (get_token() and '/?token=<token>' or '/'))
    local token_note
    local opened = open_local(url, open_port, get_token, function(n) token_note = n end)
    msg = msg .. ' → opened ' .. opened .. (token_note and ('; ' .. token_note) or '')
  end
  toast(window, msg, 5000)
end

-- Forward for a loopback URL clicked in `pane` and open it; false when
-- neither a tunnel hint nor an ssh pane says where it lives
local function open_forwarded(window, pane, url)
  local tunnels, token_path = scrollback_hints(pane)
  local ssh, f = find_tunnel(tunnels, url.rport)
  local target, rport = f and f.host, f and f.rport
  if not ssh then
    ssh = pane_ssh_args(pane)
    if not ssh then return false end
    target, rport = LOOPBACK[url.host], url.rport
  end
  local master, pid = find_master(ssh)
  if not master then
    toast(window, no_master_msg(ssh), 5000)
    return true
  end
  local lport, how, note = ssh_forward(master, pid, target, rport, url.rport, all_forwards(tunnels))
  if not lport then
    toast(window, how, 5000)
    return true
  end
  local msg = 'Forward: ' .. describe_forward(master, lport, target, rport, how, note)
  open_local(url, lport, token_finder(window, pane, master, rport, token_path),
    function(n) msg = msg .. '; ' .. n end)
  toast(window, msg, 5000)
  return true
end

-- CMD+SHIFT+L: forward without a click: a port, a localhost URL or a whole
-- `ssh -L` command
local forward_prompt = act.PromptInputLine {
  description = prompt_text(ICON.forward, 'Forward a remote port to this Mac',
    'Port (8888), localhost URL or an ssh -L command · Enter forwards and opens · Esc cancels'),
  action = wezterm.action_callback(function(window, pane, line)
    line = (line or ''):match '^%s*(.-)%s*$'
    if line == '' then return end
    if line:match '%f[%w]ssh%s' then
      forward_command(window, pane, line)
      return
    end
    local url = parse_loopback_url(line:match '^%d+$' and ('http://localhost:' .. line .. '/') or line)
    if not url then
      toast(window, 'Forward: expected a port, a localhost URL or an ssh -L command')
    elseif not open_forwarded(window, pane, url) then
      toast(window, 'Forward: not an ssh pane and no ssh -L hint for port ' .. url.rport)
    end
  end),
}

wezterm.on('open-uri', function(window, pane, uri)
  -- One GUI log line per click (~/.local/share/wezterm/wezterm-gui-log-*.txt);
  -- web URLs only up to host:port so tokens stay out of the log
  wezterm.log_info('open-uri: ' .. (uri:match '^%a[%w+.-]*://[^/?#]*' or uri))
  local mode, clicked = (wezterm.GLOBAL[LINK_MODE_KEY] or ''):match '^(%a+) (%d+)$'
  wezterm.GLOBAL[LINK_MODE_KEY] = nil
  if not clicked or os.time() - tonumber(clicked) > 2 then mode = nil end
  local reveal, look, download = mode == 'reveal', mode == 'look', mode == 'download'
  -- Right-click is for paths in ssh panes only: nothing happens on web links
  -- and `ssh -L` commands, like before it was bound
  if download and not (pane_ssh_args(pane) and uri_to_path(uri)) then return false end
  if uri:sub(1, #SSH_FORWARD_SCHEME) == SSH_FORWARD_SCHEME then
    forward_command(window, pane, uri:sub(#SSH_FORWARD_SCHEME + 1))
    return false
  end
  local url = parse_loopback_url(uri)
  if url and open_forwarded(window, pane, url) then return false end
  local ssh = pane_ssh_args(pane)

  local text, host = uri_to_path(uri)
  if not text then return end -- web URL etc.: default opener
  local custom = uri:sub(1, #PEEK_SCHEME) == PEEK_SCHEME

  if ssh then
    local rcwd = remote_cwd(pane)
    local kind, path = resolve_remote(ssh, { text }, rcwd)
    if custom and kind ~= 'f' then
      local cands, wrapped = wrapped_candidates(pane, text)
      local full_kind, full = nil, nil
      if #cands > 0 then full_kind, full = resolve_remote(ssh, cands, rcwd) end
      if full_kind then
        kind, path = full_kind, full
      elseif kind == 'd' and wrapped then
        toast(window, "Path: couldn't resolve wrapped path: " .. text)
        return false
      end
    end
    if not kind then
      toast(window, path)
      return false
    end
    if download then
      download_remote(window, ssh, path)
    elseif reveal or (kind == 'f' and is_media(path)) then
      reveal_remote(window, ssh, kind, path)
    elseif kind == 'f' and look then
      quicklook_remote(window, ssh, path)
    elseif kind == 'f' and is_pdf(path) then
      preview_file(window, path, ssh)
    else
      open_remote_peek(window, pane, ssh, kind, path, click_line(text, path))
    end
    return false
  end
  -- Outside ssh a file:// host is this Mac under some name (OSC 7 / ls
  -- --hyperlink use the DHCP name, which changes): use the path if it exists
  local cwd = pane_cwd(pane)
  local path = pane:get_domain_name() == 'local' and resolve_path(text, cwd)
  if custom and path ~= false and not (path and not is_dir(path)) then
    -- Missing, or a directory that may be the cut-off start of a wrapped path
    local cands, wrapped = wrapped_candidates(pane, text)
    local full
    for _, c in ipairs(cands) do
      full = resolve_path(c, cwd)
      if full then break end
    end
    if full then
      path = full
    elseif path and wrapped then
      toast(window, "Path: couldn't resolve wrapped path: " .. text)
      return false
    end
  end
  if not path then
    if custom then
      toast(window, 'Path: not found: ' .. text, 2000)
      return false
    end
    return -- file:// we can't resolve: let the default opener try
  end
  if reveal or (not look and not is_dir(path) and is_media(path)) then
    reveal_local(path)
    if not reveal then toast(window, 'Finder: ' .. (path:match '[^/]+$' or path), 2000) end
  elseif look and not is_dir(path) then
    quicklook_local(window, path)
  elseif not is_dir(path) and is_pdf(path) then
    preview_file(window, path)
  else
    open_peek(window, pane, path, click_line(text, path))
  end
  return false
end)

-- Paths are recognized at the start of a line or after whitespace, a quote,
-- backtick, bracket, = or * (markdown **bold**), so the /a/b inside URLs
-- never matches. Group 1 is the path (with any :line[:col] or :first-last).
-- WezTerm compiles these with fancy-regex, so lookarounds work.
config.hyperlink_rules = wezterm.default_hyperlink_rules()

-- Anchored paths: ~/, ./, ../ or /. They stop at whitespace, quotes,
-- backticks, brackets and * and never end in . , : ; ! ? so prose
-- punctuation stays out.
table.insert(config.hyperlink_rules, {
  regex = [=[(?:^|[\s"'`(\[{<=*])((?:~|\.\.?)?/[^\s"'`()\[\]{}<>*]*[^\s"'`()\[\]{}<>*.,:;!?])]=],
  format = PEEK_SCHEME .. '$1',
  highlight = 1,
})

-- Bare relative paths as Claude Code prints them (tasks/todo.md,
-- src/app.py:42, README.md). To keep prose like and/or, 1/2, 10/16/2026,
-- e.g., 1.2.3 and example.com out, one must be
--  * dir/.../file.ext (extension starts with a letter),
--  * three or more segments starting with a letter (bin/tools/ssh-pane),
--  * dir/ followed by whitespace or punctuation,
--  * name.ext with a known source/doc extension, a common dotfile, or a
--    Makefile/Dockerfile/Justfile.
-- Segments never end in a dot, so a sentence's final period is left out.
-- Unknown paths only toast when clicked.
local REL_START = [=[(?<![^\s"'`(\[{<=*])]=] -- like the boundary above, not consumed
local REL_FIRST = [=[\.?[\w@+](?:[\w.@+~-]*[\w@+~-])?]=]
local REL_FIRST_ALPHA = [=[\.?[A-Za-z_](?:[\w.@+~-]*[\w@+~-])?]=]
local REL_SEG = [=[\.?[\w@+~-](?:[\w.@+~-]*[\w@+~-])?]=]
local REL_EXTS = 'md|markdown|txt|rst|py|pyi|ipynb|js|mjs|cjs|jsx|ts|tsx|vue|svelte|lua|sh|bash'
  .. '|zsh|fish|json|jsonl|toml|ya?ml|ini|cfg|conf|env|lock|rs|go|c|h|cc|cpp|hpp|cu|java|kt'
  .. '|swift|rb|php|sql|css|scss|html?|xml|csv|tsv|log|tex|bib|pdf|png|jpe?g|gif|svg|webp'
  .. '|mp4|mov|zip|gz|tgz|tar|patch|diff|proto|tf|nix|vim'
local REL_DOTFILES = [=[[\w-]*rc|env|gitignore|gitconfig|gitattributes|profile|zprofile|editorconfig|dockerignore]=]
table.insert(config.hyperlink_rules, {
  regex = REL_START .. '((?:'
    .. REL_FIRST_ALPHA .. '(?:/' .. REL_SEG .. '){2,}/?'
    .. '|' .. REL_FIRST .. '(?:/' .. REL_SEG .. [=[)*/[\w@+~.-]*\.[A-Za-z]\w*]=]
    .. '|' .. REL_FIRST .. '(?:/' .. REL_SEG .. [=[)*/(?=$|[\s"'`)\]}>*,;:!?])]=]
    .. '|' .. REL_FIRST .. [=[\.(?i:]=] .. REL_EXTS .. [=[)\b]=]
    .. [=[|\.(?:]=] .. REL_DOTFILES .. [=[)\b(?:\.[\w-]+)*]=]
    .. [=[|(?:Makefile|Dockerfile|Justfile)\b]=]
    .. [=[)(?::\d+(?:[:-]\d+)?)?)]=],
  format = PEEK_SCHEME .. '$1',
  highlight = 1,
})

-- `ssh ... -L ... dest` commands (tunnel hints printed by servers and
-- agents): CMD+click adds the forwards on the existing ControlMaster instead
-- of running anything (see forward_command). The command runs to the end of
-- the line or to a quote, backtick, ; | or &; the longer match wins over
-- path rules inside it.
table.insert(config.hyperlink_rules, {
  regex = [=[(?<![\w.-])(ssh\s+(?:[^\s`'";|&]+\s+)*?-\w*L\s*[^\s`'";|&]+(?:\s+[^\s`'";|&]+)*)]=],
  format = SSH_FORWARD_SCHEME .. '$1',
  highlight = 1,
})

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

-- Layout-preserving merge. A WezTerm tab is a binary split tree, so its panes
-- can always be divided by one full-height (vertical) or full-width
-- (horizontal) cut into two groups. Recursing on that rebuilds the tree: the
-- top-left pane of the tab moves over as a new tab, then each cut becomes a
-- `split-pane --move-pane-id` of the first group's top-left pane, pulling in
-- the second group's top-left pane at a proportional --percent.
-- Pane records: { id, left, top, width, height } in cells (the shape of
-- tab:panes_with_info() and `wezterm cli list --format json` geometry).

-- Top-left pane of a group
local function anchor_of(group)
  local a = group[1]
  for _, p in ipairs(group) do
    if p.top < a.top or (p.top == a.top and p.left < a.left) then a = p end
  end
  return a
end

local CUT_AXES = {
  { pos = 'left', size = 'width', flag = '--right' },
  { pos = 'top', size = 'height', flag = '--bottom' },
}

-- First full-length cut through `group`: returns first, second, flag, percent
-- (second group's share of the span), or nil if no clean cut exists.
local function find_cut(group)
  for _, axis in ipairs(CUT_AXES) do
    local lo, hi = math.huge, -math.huge
    for _, p in ipairs(group) do
      lo = math.min(lo, p[axis.pos])
      hi = math.max(hi, p[axis.pos] + p[axis.size])
    end
    for _, cand in ipairs(group) do
      local edge = cand[axis.pos] + cand[axis.size]
      local first, second, clean = {}, {}, true
      for _, p in ipairs(group) do
        if p[axis.pos] + p[axis.size] <= edge then
          table.insert(first, p)
        elseif p[axis.pos] >= edge then
          table.insert(second, p)
        else
          clean = false
          break
        end
      end
      if clean and #first > 0 and #second > 0 then
        local start2 = math.huge
        for _, p in ipairs(second) do start2 = math.min(start2, p[axis.pos]) end
        -- WezTerm floors span * percent / 100, so round the percent up
        local pct = math.ceil(100 * (hi - start2) / (hi - lo) - 1e-9)
        return first, second, axis.flag, math.max(1, math.min(99, pct))
      end
    end
  end
  return nil
end

-- Split steps { target, flag, percent, move } that rebuild `group` from its
-- anchor, appended to `steps`; false if some sub-group has no clean cut.
local function plan_splits(group, steps)
  if #group <= 1 then return true end
  local first, second, flag, pct = find_cut(group)
  if not first then return false end
  table.insert(steps, {
    target = anchor_of(first).id, flag = flag, percent = pct, move = anchor_of(second).id,
  })
  return plan_splits(first, steps) and plan_splits(second, steps)
end

-- Move one tab's panes into window `target_window` as a single new tab with the
-- same layout. Panes that can't be placed (no clean cut, no room, or a cli
-- call failed) become separate tabs. Returns panes moved, whether layout was
-- kept.
local function merge_tab(panes, target_window)
  local moved, pending = 0, {}
  for _, p in ipairs(panes) do pending[p.id] = true end
  local function to_new_tab(id)
    pending[id] = nil
    if cli('move-pane-to-new-tab', '--pane-id', tostring(id),
        '--window-id', tostring(target_window)) then
      moved = moved + 1
      return true
    end
    return false
  end

  local steps = {}
  local exact = plan_splits(panes, steps)
  if not exact then steps = {} end
  if to_new_tab(anchor_of(panes).id) then
    for _, s in ipairs(steps) do
      if not split_fits(s.target, s.flag, s.percent) then
        exact = false
        break
      end
      pending[s.move] = nil
      if cli('split-pane', '--pane-id', tostring(s.target), s.flag,
          '--percent', tostring(s.percent), '--move-pane-id', tostring(s.move)) then
        moved = moved + 1
      else
        exact = false
        break
      end
    end
  else
    exact = false
  end
  for _, p in ipairs(panes) do
    if pending[p.id] then to_new_tab(p.id) end
  end
  return moved, exact
end

-- Layout repair. WezTerm 20240203's `top_level` split on a tab with 2+ panes
-- shrinks the tab's recorded size without restoring it, and later resizes
-- apply only the difference from that size, so the panes end up wider (or
-- taller) than the window and no resize brings them back. The only cure is a
-- fresh tab: rebuild_tab moves the panes, layout kept, into a new tab
-- (sized like the window's active tab, so internally consistent) that takes
-- over the old tab's slot, title, active pane and sidebar. Processes keep
-- running; only their panes move.

-- Rebuild `tab` from `geometry` (records as tab_geometry returns, ids only
-- needed); `active_id` defaults to the tab's active pane. Returns the new
-- tab, or nil if nothing was rebuilt.
rebuild_tab = function(window, tab, geometry, active_id)
  if wezterm.GLOBAL.layout_repairing or not plan_splits(geometry, {}) then return nil end
  local mux_window = tab:window()
  local old_id, title = tab:tab_id(), tab:get_title()
  active_id = active_id or tab:active_pane():pane_id()
  local before = {} -- tabs left of the old one, to put the new one after them
  for _, t in ipairs(mux_window:tabs()) do
    if t:tab_id() == old_id then break end
    before[t:tab_id()] = true
  end

  wezterm.GLOBAL.layout_repairing = true
  local ok, err, exact = pcall(merge_tab, geometry, mux_window:window_id())
  wezterm.GLOBAL.layout_repairing = nil
  if not ok then
    toast(window, 'Layout: rebuild failed: ' .. tostring(err), 5000)
    return nil
  end
  if not exact then
    toast(window, 'Layout: no room to keep the split layout; some panes went to their own tabs', 5000)
  end

  local anchor = mux_pane(anchor_of(geometry).id)
  local new_tab = anchor and anchor:tab()
  if not new_tab or new_tab:tab_id() == old_id then return nil end
  if title ~= '' then new_tab:set_title(title) end
  local index, current = 0, nil
  for i, t in ipairs(mux_window:tabs()) do
    if before[t:tab_id()] then index = index + 1 end
    if t:tab_id() == new_tab:tab_id() then current = i - 1 end
  end
  new_tab:activate()
  if current and current ~= index then
    -- MoveTab moves the active tab; perform_action waits for it to finish
    window:perform_action(act.MoveTab(index), new_tab:active_pane())
  end
  local active = mux_pane(active_id)
  if active then active:activate() end
  local sidebar = wezterm.GLOBAL[SIDEBAR_KEY .. old_id]
  wezterm.GLOBAL[SIDEBAR_KEY .. old_id] = nil
  if sidebar then wezterm.GLOBAL[SIDEBAR_KEY .. new_tab:tab_id()] = sidebar end
  return new_tab
end

-- True if some pane of `tab` reaches past the tab's recorded size (zoomed
-- tabs hide their real geometry and are skipped)
local function layout_overflows(tab)
  local geometry, cols, rows, zoomed = tab_geometry(tab)
  local size = tab:get_size()
  return not zoomed and #geometry > 1 and (cols > size.cols or rows > size.rows)
end

-- Rebuild `tab` if its panes overflow; `quiet` skips the "nothing to fix"
-- notice. Returns the tab now holding those panes.
local function repair_layout(window, tab, quiet)
  if not tab or wezterm.GLOBAL.layout_repairing then return tab end
  if peek_open(tab) then
    if not quiet then toast(window, 'Layout: close the peek (q) first', 2000) end
    return tab
  end
  if not layout_overflows(tab) then
    if not quiet then toast(window, 'Layout: panes already fit the window', 2000) end
    return tab
  end
  local geometry = tab_geometry(tab)
  local new_tab = rebuild_tab(window, tab, geometry)
  if not new_tab then
    toast(window, 'Layout: could not rebuild this tab', 4000)
    return tab
  end
  toast(window, string.format('Layout: refit %d panes to the window', #geometry), 3000)
  return new_tab
end

-- Manual fix (CMD+SHIFT+=) and automatic checks after window resizes
wezterm.on('fix-layout', function(window, pane) repair_layout(window, pane:tab(), false) end)
wezterm.on('window-resized', function(window, pane)
  if pane then repair_layout(window, pane:tab(), true) end
end)

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

-- Tab / window renaming: a prompt sets an explicit title; empty input goes
-- back to the automatic one. Tab titles already win over pane titles in the
-- default tab bar; window titles need the format-window-title handler below.
local function rename_prompt(what)
  return act.PromptInputLine {
    description = prompt_text(what == 'tab' and ICON.rename or ICON.window, 'Rename ' .. what,
      'Enter applies · empty restores the automatic title · Esc cancels'),
    action = wezterm.action_callback(function(window, _, line)
      if line == nil then return end -- Esc
      if what == 'tab' then
        window:active_tab():set_title(line)
      else
        window:mux_window():set_title(line)
      end
    end),
  }
end

-- Tab bar entry: " 1 <icon> <title> " where the title is the explicit one
-- (CMD+SHIFT+R), else the ssh host for ssh panes (server icon, peach), else
-- the pane title, or the cwd's name when the title is just the process name.
-- The active tab is lifted onto surface0 with a mauve index.
local function tab_label(tab)
  local p = tab.active_pane
  local proc = (p.foreground_process_name or ''):match '[^/]*$'
  local ssh
  if proc == 'ssh' or proc == 'sh' then -- ssh-pane runs under /bin/sh
    local pane = mux_pane(p.pane_id)
    ssh = pane and pane_ssh_args(pane)
  end
  local icon, text = ICON.console, p.title
  if ssh then
    icon, text = ICON.server, ssh_host(ssh)
  elseif text == '' or text == proc then
    local cwd = p.current_working_dir
    local dir = type(cwd) == 'userdata' and cwd.file_path or tostring(cwd or '')
    icon, text = ICON.folder, dir:match '([^/]+)/?$' or proc
  end
  if (tab.tab_title or '') ~= '' then text = tab.tab_title end
  return icon, text, ssh ~= nil
end

wezterm.on('format-tab-title', function(tab, _, _, _, hover, max_width)
  local icon, text, remote = tab_label(tab)
  local index = tostring(tab.tab_index + 1)
  local zoom = tab.active_pane.is_zoomed and (' ' .. ICON.zoom) or ''
  -- cells: " N " + icon + " " + text + zoom + " "
  text = wezterm.truncate_right(text, math.max(1, max_width - #index - 5 - (zoom ~= '' and 2 or 0)))
  local bg = tab.is_active and C.surface0 or (hover and C.mantle or C.crust)
  return {
    { Background = { Color = bg } },
    { Foreground = { Color = tab.is_active and C.mauve or C.overlay0 } },
    { Attribute = { Intensity = 'Bold' } }, { Text = ' ' .. index .. ' ' },
    { Attribute = { Intensity = tab.is_active and 'Bold' or 'Normal' } },
    { Foreground = { Color = remote and C.peach or (tab.is_active and C.blue or C.overlay0) } },
    { Text = icon .. ' ' },
    { Foreground = { Color = tab.is_active and C.text or C.overlay0 } },
    { Text = text .. zoom .. ' ' },
  }
end)

-- WezTerm's default window title ([Z] zoomed, [i/N] tab index, pane title)
-- unless the window was renamed
wezterm.on('format-window-title', function(tab, _, tabs)
  if (tab.window_title or '') ~= '' then return tab.window_title end
  local zoomed = tab.active_pane.is_zoomed and '[Z] ' or ''
  local index = #tabs > 1 and string.format('[%d/%d] ', tab.tab_index + 1, #tabs) or ''
  return zoomed .. index .. tab.active_pane.title
end)

-- Session restore, browser style: windows, tabs (order, titles), split
-- layouts with proportions, zoom, the active tab/pane, the sidebar and what
-- each pane was running come back after quitting WezTerm, a reboot or a
-- crash. No process is kept alive: panes are re-created and their commands
-- re-run (see restore_spec). The snapshot is saved to session.json by the
-- poller below whenever it changed; WezTerm 20240203 has no quit event, so
-- the last settled state before quitting is what comes back.
-- (A do-block: the main chunk is at Lua's limit of 200 local variables.)
local restore_previous, toggle_auto_restore
do
local STATE_DIR = wezterm.home_dir .. '/.local/state/wezterm'
local SESSION_FILE = STATE_DIR .. '/session.json'
local SESSION_PREV = STATE_DIR .. '/session.prev.json' -- the session before this launch
local NO_RESTORE_FILE = STATE_DIR .. '/no-restore' -- exists = no auto-restore at launch
local SKIP_HOSTS_FILE = STATE_DIR .. '/restore-skip-hosts' -- ssh hosts never reconnected
-- Claude Code session id per pane, written by bin/wez-claude-session (a
-- SessionStart hook) as <WEZTERM_PANE>: line 1 id, line 2 cwd
local CLAUDE_DIR = STATE_DIR .. '/claude'
local SNAPSHOT_VERSION = 1
local SETTLE_MAX = 10 -- seconds a changing state may delay the save

local function read_file(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local text = f:read '*a'
  f:close()
  return text
end

-- tmp + rename, so a crash never leaves a half-written file; a failed write
-- (disk full) leaves the old file in place
local function write_atomic(path, text)
  wezterm.run_child_process { '/bin/mkdir', '-p', path:match '^(.*)/' }
  local tmp = path .. '.tmp'
  local f, err = io.open(tmp, 'w')
  if not f then return false, err end
  local wrote, werr = f:write(text)
  local closed, cerr = f:close()
  if not (wrote and closed) then
    os.remove(tmp)
    return false, werr or cerr
  end
  return os.rename(tmp, path)
end

-- `path` with glob metacharacters matched literally
local function glob_quote(path) return (path:gsub('[%[%]%*%?{}]', '[%0]')) end

-- Does the absolute path exist? A stat (wezterm.glob), not a listing: macOS
-- privacy protection can deny WezTerm reading folders such as ~/Desktop,
-- where is_dir (read_dir) fails although the shells there work fine
local function present(path)
  if type(path) ~= 'string' or path:sub(1, 1) ~= '/' then return false end
  local ok, found = pcall(wezterm.glob, glob_quote(path))
  return ok and #found > 0
end

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

local function base(path) return (path or ''):match '[^/]*$' end

local function set_of(words)
  local set = {}
  for w in words:gmatch '%S+' do set[w] = true end
  return set
end

-- What a pane was running ---------------------------------------------------

local SHELLS = set_of 'bash sh zsh fish nu dash ksh'

-- A shell waiting at its prompt: no script, no -c command
local function is_idle_shell(argv)
  if not SHELLS[(base(argv[1]):gsub('^%-', ''))] then return false end
  for i = 2, #argv do
    local a = argv[i]
    if a:sub(1, 1) ~= '-' or (a:match '^%-%a+$' and a:find 'c') then return false end
  end
  return true
end

local function is_claude(info)
  local argv = info.argv or {}
  if base(argv[1]) == 'claude' or base(info.executable) == 'claude' then return true end
  return base(argv[1]) == 'node' and (argv[2] or ''):find('/claude', 1, true) ~= nil
end

local claude_session
do
-- Session id on a claude command line: --resume/-r <id>, --session-id <id>
-- (a uuid; --resume <search words> opens a picker). --fork-session runs
-- under a new id, so its command line says nothing.
local UUID = '^%x+%-%x+%-%x+%-%x+%-%x+$'
local function argv_claude_id(argv)
  local id
  for i, a in ipairs(argv) do
    if a == '--fork-session' then return nil end
    local flag, value = a:match '^(%-%-[%w-]+)=(.*)$'
    if not flag then flag, value = a, argv[i + 1] end
    if (flag == '--resume' or flag == '-r' or flag == '--session-id') and (value or ''):match(UUID) then
      id = value
    end
  end
  return id
end

-- Session id (and cwd) a running claude process published: Claude Code keeps
-- <config dir>/sessions/<pid>.json ({ pid, sessionId, cwd, startedAt }) for
-- each live interactive process, under ~/.claude or another config dir
-- named ~/.claude-* (CLAUDE_CONFIG_DIR). Trusted only if written by this
-- very process, i.e. not before it started (pids get reused).
local function pid_claude_session(info)
  if type(info.pid) ~= 'number' then return nil end
  local ok, files = pcall(wezterm.glob, glob_quote(wezterm.home_dir) .. '/.claude*/sessions/' .. info.pid .. '.json')
  for _, path in ipairs(ok and files or {}) do
    local parsed, s = pcall(wezterm.json_parse, read_file(path) or '')
    if parsed and type(s) == 'table' and s.pid == info.pid and type(s.sessionId) == 'string'
        and s.sessionId:match '^[%w_-]+$' and type(s.startedAt) == 'number'
        and (type(info.start_time) ~= 'number' or s.startedAt / 1000 >= info.start_time - 5) then
      return s.sessionId, type(s.cwd) == 'string' and s.cwd or nil
    end
  end
end

-- Session id (and its cwd) of the claude process in a pane. The pane's file
-- holds line 1 id, line 2 cwd: written by the SessionStart hook, or here,
-- with `pid <n>` on line 3, for a process the hook never saw (started before
-- it was installed): then the id comes from the process's own sessions file
-- or its command line, and the file keeps it known for that process.
function claude_session(pane_id, info)
  local path = CLAUDE_DIR .. '/' .. pane_id
  local text = read_file(path) or ''
  local id, cwd, owner = text:match '^([^\n]*)\n?([^\n]*)\n?([^\n]*)'
  if not id:match '^[%w_-]+$' then id = nil end
  cwd = cwd ~= '' and cwd or nil
  if id and owner == '' then return id, cwd end -- the hook's
  local found, found_cwd = pid_claude_session(info)
  if not found and id and owner == 'pid ' .. tostring(info.pid) then return id, cwd end
  found = found or argv_claude_id(info.argv or {})
  if not found then return nil end
  found_cwd = found_cwd or info.cwd
  local record = string.format('%s\n%s\npid %d\n', found, found_cwd or '', info.pid or 0)
  if type(info.pid) == 'number' and record ~= text then write_atomic(path, record) end
  return found, found_cwd
end
end

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
  if is_sidebar then
    rec.kind = 'sidebar'
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

wezterm.on('update-status', function()
  local now = os.time()
  if wezterm.GLOBAL.session_tick ~= now then
    wezterm.GLOBAL.session_tick = now
    save_session()
  end
end)

-- Restore ---------------------------------------------------------------------

local RESTORE_SHELL = os.getenv 'SHELL' or '/bin/zsh'

-- Run `cmd` in the login shell (right PATH and env) from `cwd`, and stay in
-- that shell when it exits. cd here rather than via the spawn's cwd: on
-- 20240203 a split or new tab with `args` ignores `cwd`.
local function shell_args(cmd, cwd)
  local cd = cwd and ('cd ' .. sh_quote(cwd) .. ' && ') or ''
  return { RESTORE_SHELL, '-lic', cd .. cmd .. '; exec ' .. sh_quote(RESTORE_SHELL) .. ' -l' }
end

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
wezterm.on('gui-startup', startup)

restore_previous = wezterm.action_callback(function(window)
  local snap = load_snapshot(SESSION_PREV)
  if not snap then
    toast(window, 'Session: no previous session saved', 2000)
    return
  end
  local n = restore_session(snap)
  toast(window, string.format('Session: restored %d window%s', n, n == 1 and '' or 's'), 3000)
end)

toggle_auto_restore = wezterm.action_callback(function(window)
  if exists(NO_RESTORE_FILE) then
    os.remove(NO_RESTORE_FILE)
    toast(window, 'Session: auto-restore on', 2000)
  elseif write_atomic(NO_RESTORE_FILE, 'delete this file to restore the last session at launch\n') then
    toast(window, 'Session: auto-restore off', 2000)
  end
end)
end -- session restore

-- Home-row labels for PaneSelect (swap / jump)
local PANE_ALPHABET = 'asdfghjkl'

config.keys = {
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

  -- Toggle the Yazi file sidebar for this tab
  { key = 'e', mods = 'CMD', action = wezterm.action_callback(toggle_sidebar) },

  -- Splits (Ghostty: cmd+d = right, cmd+shift+d = down); ssh-aware
  { key = 'd', mods = 'CMD', action = smart_split 'Right' },
  { key = 'd', mods = 'CMD|SHIFT', action = smart_split 'Bottom' },

  -- Close the focused pane instead of the whole tab (Ghostty: cmd+w). The
  -- built-in confirm is a pane-scoped overlay (y = close, n / Esc = cancel)
  -- and is skipped for an idle shell (skip_close_confirmation_for_processes_named)
  { key = 'w', mods = 'CMD', action = act.CloseCurrentPane { confirm = true } },
  { key = 'w', mods = 'CTRL|SHIFT', action = act.CloseCurrentPane { confirm = true } },

  -- Cycle panes (Ghostty: cmd+[ / cmd+])
  { key = '[', mods = 'CMD', action = act.ActivatePaneDirection 'Prev' },
  { key = ']', mods = 'CMD', action = act.ActivatePaneDirection 'Next' },

  -- Move focus directionally (Ghostty: cmd+opt+arrows)
  { key = 'LeftArrow', mods = 'CMD|OPT', action = act.ActivatePaneDirection 'Left' },
  { key = 'RightArrow', mods = 'CMD|OPT', action = act.ActivatePaneDirection 'Right' },
  { key = 'UpArrow', mods = 'CMD|OPT', action = act.ActivatePaneDirection 'Up' },
  { key = 'DownArrow', mods = 'CMD|OPT', action = act.ActivatePaneDirection 'Down' },

  -- Resize focused pane (Ghostty: cmd+ctrl+arrows)
  { key = 'LeftArrow', mods = 'CMD|CTRL', action = act.AdjustPaneSize { 'Left', RESIZE_STEP } },
  { key = 'RightArrow', mods = 'CMD|CTRL', action = act.AdjustPaneSize { 'Right', RESIZE_STEP } },
  { key = 'UpArrow', mods = 'CMD|CTRL', action = act.AdjustPaneSize { 'Up', RESIZE_STEP } },
  { key = 'DownArrow', mods = 'CMD|CTRL', action = act.AdjustPaneSize { 'Down', RESIZE_STEP } },

  -- Zoom/unzoom focused pane to fill the tab (Ghostty: cmd+shift+enter)
  { key = 'Enter', mods = 'CMD|SHIFT', action = act.TogglePaneZoomState },

  -- Reshape: swap the focused pane with one you pick (shows letter labels)
  { key = 's', mods = 'CMD|SHIFT', action = act.PaneSelect { mode = 'SwapWithActive', alphabet = PANE_ALPHABET } },
  -- Reshape: rotate pane positions within the tab
  { key = 'r', mods = 'CMD|OPT', action = act.RotatePanes 'Clockwise' },
  { key = 'r', mods = 'CMD|SHIFT|OPT', action = act.RotatePanes 'CounterClockwise' },
  -- Rename the tab / window (see rename_prompt)
  { key = 'r', mods = 'CMD|SHIFT', action = rename_prompt 'tab' },
  { key = 'r', mods = 'CMD|CTRL', action = rename_prompt 'window' },
  -- Jump to any pane by label
  { key = 'p', mods = 'CMD|SHIFT', action = act.PaneSelect { mode = 'Activate', alphabet = PANE_ALPHABET } },

  -- Reorder tabs: move the current tab one slot left/right
  { key = 'LeftArrow', mods = 'CMD|SHIFT', action = act.MoveTabRelative(-1) },
  { key = 'RightArrow', mods = 'CMD|SHIFT', action = act.MoveTabRelative(1) },

  -- New tab/window, ssh-aware (see smart_spawn); CMD+SHIFT variants are always local
  { key = 't', mods = 'CMD', action = smart_spawn(false) },
  { key = 'n', mods = 'CMD', action = smart_spawn(true) },
  { key = 't', mods = 'CMD|SHIFT', action = act.SpawnTab 'DefaultDomain' },
  { key = 'n', mods = 'CMD|SHIFT', action = act.SpawnWindow },

  -- Move the focused pane out into a new tab / new window
  { key = 't', mods = 'CMD|OPT', action = wezterm.action_callback(function(_, pane)
    pane:move_to_new_tab()
  end) },
  { key = 'n', mods = 'CMD|OPT', action = wezterm.action_callback(function(_, pane)
    pane:move_to_new_window()
  end) },
  -- Pull every other window's tabs into this window, keeping split layouts
  { key = 'm', mods = 'CMD|SHIFT', action = merge_windows },
  -- Fix layout: refit panes that spill past the window edge (see repair_layout);
  -- macOS reports Shift+= as either key
  { key = '=', mods = 'CMD|SHIFT', action = act.EmitEvent 'fix-layout' },
  { key = '+', mods = 'CMD|SHIFT', action = act.EmitEvent 'fix-layout' },
  -- Session restore: reopen the session from before this launch; toggle
  -- whether launching restores the last session on its own
  { key = 'o', mods = 'CMD|SHIFT', action = restore_previous },
  { key = 'o', mods = 'CMD|SHIFT|OPT', action = toggle_auto_restore },
  -- ssh pane: forward a remote port to this Mac and open it (see open_forwarded)
  { key = 'l', mods = 'CMD|SHIFT', action = forward_prompt },
}

-- Move the focused pane into tab N (1-9) as a split: CMD+OPT+N = right of
-- that tab's active pane, CMD+OPT+SHIFT+N = below it. phys: keys so Option/
-- Shift symbols (¡, !, ...) don't stop the digits from matching.
for n = 1, 9 do
  table.insert(config.keys, { key = 'phys:' .. n, mods = 'CMD|OPT', action = move_to_tab(n, '--right') })
  table.insert(config.keys, { key = 'phys:' .. n, mods = 'CMD|OPT|SHIFT', action = move_to_tab(n, '--bottom') })
end

-- CMD+click opens links/paths even inside apps that capture the mouse
-- (Claude Code, less, micro); CMD+OPT+click reveals a path in Finder and
-- CMD+OPT+SHIFT+click Quick Looks it (see LINK_MODE_KEY). mouse_reporting=true
-- covers those apps; the plain entries cover normal shells. The Down events
-- are swallowed so the click isn't also sent to the app or start a selection.
local function open_link(mode)
  return wezterm.action_callback(function(window, pane)
    wezterm.GLOBAL[LINK_MODE_KEY] = mode and (mode .. ' ' .. os.time()) or nil
    window:perform_action(act.OpenLinkAtMouseCursor, pane)
  end)
end

-- Bindings are built in a fixed order (ipairs, not pairs): each
-- action_callback is named by a per-evaluation counter, and the GUI may bind
-- the names from one config evaluation to the callbacks of another, so a
-- random pairs order sent plain CMD+click to the Quick Look callback.
config.mouse_bindings = {}
for _, reporting in ipairs { false, true } do
  for _, b in ipairs { { 'CMD', false }, { 'CMD|OPT', 'reveal' }, { 'CMD|OPT|SHIFT', 'look' } } do
    local mods, mode = b[1], b[2]
    table.insert(config.mouse_bindings, {
      event = { Down = { streak = 1, button = 'Left' } },
      mods = mods,
      mouse_reporting = reporting,
      action = act.Nop,
    })
    table.insert(config.mouse_bindings, {
      event = { Up = { streak = 1, button = 'Left' } },
      mods = mods,
      mouse_reporting = reporting,
      action = open_link(mode),
    })
  end
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

-- A reload is otherwise silent on macOS, so confirm it on the tab bar. The
-- counter tells a real reload apart from the same event at first launch.
do
  wezterm.GLOBAL.config_gen = (wezterm.GLOBAL.config_gen or 0) + 1
  wezterm.on('window-config-reloaded', function(window)
    local gen, shown = wezterm.GLOBAL.config_gen, wezterm.GLOBAL.config_gen_shown
    if gen == shown then return end
    wezterm.GLOBAL.config_gen_shown = gen
    if shown then toast(window, 'config reloaded', 4000) end
  end)
end

return config
