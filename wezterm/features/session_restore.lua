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

return M
