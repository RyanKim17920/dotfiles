-- VS Code-style Ports. CMD+SHIFT+I lists, in one picker:
--  * TCP ports listening on the focused ssh pane's host, with their process
--    (only over that host's live ControlMaster; never a new login): pick one
--    to forward it here (`ssh -O forward`, see features/port_forward.lua for
--    busy local ports; ports below 1024 map to 8000+port) and open it;
--  * ports your own processes listen on, on this Mac: pick one to open it;
--  * forwards of ours that are up: pick one to stop it (`ssh -O cancel`).
-- While an ssh pane whose master is live has focus, its host is polled every
-- POLL_SECONDS in the background, a port of yours that starts listening
-- there toasts once, and the right status shows "⇄ N ports · CMD+SHIFT+I"
-- (status text can't be clicked on 20240203; the key opens the list). Every remote call first asks the master (-O check) and
-- carries gated_args (lib/ssh.lua), so nothing here can prompt or authenticate.
local wezterm = require 'wezterm'
local act = wezterm.action
local core = require 'lib.core'
local ssh_lib = require 'lib.ssh'
local port_forward = require 'features.port_forward'
local toast, mux_pane, sh_quote = core.toast, core.mux_pane, core.sh_quote
local pane_ssh_args, ssh_cmd, ssh_host = ssh_lib.pane_ssh_args, ssh_lib.ssh_cmd, ssh_lib.ssh_host
local ssh_master_pid = ssh_lib.ssh_master_pid
local control_path, gated_args = ssh_lib.control_path, ssh_lib.gated_args

local KEY, KEY_MODS, KEY_TEXT = 'i', 'CMD|SHIFT', 'CMD+SHIFT+I'
local POLL_SECONDS = 10
local CACHE_SECONDS = 15 -- the picker opens at once on a poll this recent
local JOB_SECONDS = 20 -- a listing (or a picker waiting on one) older than this is dropped
local CHECK_TIMEOUT, RUN_TIMEOUT = 3, 8 -- seconds for -O check and for the listing
local STATE_DIR = wezterm.home_dir .. '/.local/state/wezterm/ports/'

-- wezterm.GLOBAL keys (they survive config reloads, timers don't)
local JOB_KEY = 'ports_job' -- JSON { out, path, host, started } of the listing in flight
local PICKER_KEY = 'ports_picker' -- JSON { window, pane, path, started } waiting on a listing
local CACHE_KEY = 'ports_cache_' -- .. control path -> JSON { t, ports }
local LAST_KEY = 'ports_last_' -- .. control path -> " port port ... " of the last poll
local NOTIFIED_KEY = 'ports_notified_' -- .. control path -> " port ... " already toasted

-- Never worth a toast, a picker row or the badge: ssh, smtp, dns, rpcbind,
-- cups, nfs, mDNS, LLMNR, and sshd's X11 forwarding displays (6010 up;
-- TensorBoard's 6006 stays)
local SYSTEM_PORTS = { [22] = true, [25] = true, [53] = true, [111] = true, [631] = true,
  [2049] = true, [5353] = true, [5355] = true }
local function is_system_port(port)
  return SYSTEM_PORTS[port] or (port >= 6010 and port <= 6063)
end

-- Rows the picker shows for a remote port (and the badge counts)
local function is_listed(p)
  return p.owned ~= false and not is_system_port(p.port)
end
-- macOS daemons of yours that always listen (lsof cuts names to 9 chars)
local MAC_NOISE = { rapportd = true, ControlCe = true, sharingd = true }

-- Remote listing in one round trip (POSIX sh, sent on stdin to `sh -s`).
-- `ss` shows the process only for your own sockets; without ss,
-- /proc/net/tcp{,6} with your uid, and which of your processes holds each
-- socket from your own /proc/<pid>/fd links.
local REMOTE_SCRIPT = [[
if command -v ss >/dev/null 2>&1 && { out=$(ss -tlnpH 2>/dev/null) || out=$(ss -tlnp 2>/dev/null | sed 1d); }; then
  printf '#ss\n%s\n' "$out"; exit 0
fi
[ -r /proc/net/tcp ] || { echo '#unsupported'; exit 0; }
printf '#proc %s\n' "$(id -u)"
for f in /proc/net/tcp /proc/net/tcp6; do [ -r "$f" ] && cat "$f"; done
find /proc/[0-9]*/fd -maxdepth 1 -lname 'socket:*' -printf '%h %l\n' 2>/dev/null |
while read -r h l; do
  p=${h#/proc/}; p=${p%/fd}; i=${l#socket:[}; i=${i%]}
  printf '#sock %s %s %s\n' "$i" "$p" "$(cat "/proc/$p/comm" 2>/dev/null)"
done
exit 0
]]

-- Parsing ------------------------------------------------------------------

-- One entry per port, sorted: { port, name?, owned? } where owned is true
-- (yours), false (someone else's) or nil (the host would not say)
local function merge(list)
  local by, order = {}, {}
  for _, p in ipairs(list) do
    local m = by[p.port]
    if not m then
      m = { port = p.port }
      by[p.port] = m
      table.insert(order, m)
    end
    m.name = m.name or p.name
    if p.owned == true or m.owned == nil then m.owned = p.owned end
  end
  table.sort(order, function(a, b) return a.port < b.port end)
  return order
end

-- `ss -tlnp` lines: State Recv-Q Send-Q Local:Port Peer:Port [users:(("name",pid=N,fd=N))]
local function parse_ss(lines)
  local list = {}
  for _, line in ipairs(lines) do
    local state, addr = line:match '^(%S+)%s+%S+%s+%S+%s+(%S+)'
    local port = state == 'LISTEN' and tonumber(addr:match ':(%d+)$')
    if port then
      local name = line:match 'users:%(%("([^"]+)"'
      -- ss names the process of every socket of yours, so none means
      -- another user's (a login node has hundreds)
      table.insert(list, { port = port, name = name, owned = name ~= nil })
    end
  end
  return list
end

-- /proc/net/tcp{,6} rows (sl local rem st tx:rx tr:when retrnsmt uid timeout
-- inode; state 0A is LISTEN) and "#sock inode pid name" lines
local function parse_proc(lines, uid)
  local owners = {}
  for _, line in ipairs(lines) do
    local inode, name = line:match '^#sock (%d+) %d+ ?(.*)$'
    if inode and not owners[inode] then owners[inode] = name end
  end
  local list = {}
  for _, line in ipairs(lines) do
    local f = {}
    for w in line:gmatch '%S+' do table.insert(f, w) end
    if #f >= 10 and f[1]:match '^%d+:$' and f[4] == '0A' then
      local port = tonumber(f[2]:match ':(%x+)$', 16)
      local name = owners[f[10]]
      if port and port > 0 then
        table.insert(list, { port = port, name = (name ~= '' and name) or nil, owned = tonumber(f[8]) == uid })
      end
    end
  end
  return list
end

-- Output of a listing job -> ports, or nil and 'nomaster' / 'unsupported' /
-- 'failed'
local function parse_remote(text)
  local lines = {}
  for line in (text or ''):gmatch '[^\n]+' do table.insert(lines, line) end
  local head = lines[1] or ''
  if head == '#nomaster' then return nil, 'nomaster' end
  if head == '#unsupported' then return nil, 'unsupported' end
  if head == '#ss' then return merge(parse_ss(lines)) end
  local uid = tonumber(head:match '^#proc (%d+)$')
  if uid then return merge(parse_proc(lines, uid)) end
  return nil, 'failed'
end

-- `lsof -nP -iTCP -sTCP:LISTEN -Fpcn` -> { port, name, pid } per port
local function parse_lsof(text)
  local list, seen, pid, name = {}, {}, nil, nil
  for line in (text or ''):gmatch '[^\n]+' do
    local tag, value = line:sub(1, 1), line:sub(2)
    if tag == 'p' then
      pid, name = value, nil
    elseif tag == 'c' then
      name = value
    elseif tag == 'n' then
      local port = tonumber(value:match ':(%d+)$')
      if port and not seen[port] then
        seen[port] = true
        table.insert(list, { port = port, name = name, pid = pid })
      end
    end
  end
  table.sort(list, function(a, b) return a.port < b.port end)
  return list
end

-- Ports of yours that started listening since the last poll and were never
-- toasted. `last` and `notified` are " port ... " strings; `last` is nil on
-- a host's first poll, which only records what is there. Returns the fresh
-- ports and the new `last` and `notified`.
local function new_ports(ports, last, notified)
  local fresh, now = {}, ' '
  notified = notified or ' '
  for _, p in ipairs(ports) do
    local word = ' ' .. p.port .. ' '
    now = now .. p.port .. ' '
    if last and p.owned == true and not is_system_port(p.port)
      and not last:find(word, 1, true) and not notified:find(word, 1, true) then
      table.insert(fresh, p)
      notified = notified .. p.port .. ' '
    end
  end
  return fresh, now, notified
end

local function with_name(p)
  return p.port .. (p.name and (' (' .. p.name .. ')') or '')
end

-- Right-status badge for the focused ssh pane's host: "⇄ 3 ports ·
-- CMD+SHIFT+I", or '' when its last poll found none
local function badge_text(ports)
  local n = 0
  for _, p in ipairs(ports or {}) do
    if is_listed(p) then n = n + 1 end
  end
  if n == 0 then return '' end
  return '⇄ ' .. n .. (n == 1 and ' port' or ' ports') .. ' · ' .. KEY_TEXT
end

-- Background listing --------------------------------------------------------

local function sh_words(argv)
  local q = {}
  for _, w in ipairs(argv) do table.insert(q, sh_quote(w)) end
  return table.concat(q, ' ')
end

-- `argv` killed after `seconds` (macOS has no timeout(1); the alarm
-- survives exec)
local function timed(seconds, argv)
  return "/usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' " .. seconds .. ' ' .. sh_words(argv)
end

-- sh script that runs `check` and, only if it succeeds, `run` with
-- REMOTE_SCRIPT on stdin, then moves the output (or "#nomaster") to `out`
-- in one step, so a reader never sees half of it
local function job_script(check, run, out)
  return table.concat({
    'umask 077',
    'mkdir -p ' .. sh_quote(out:match '^(.*)/') .. ' || exit 1',
    'tmp=' .. sh_quote(out .. '.tmp'),
    'if ' .. timed(CHECK_TIMEOUT, check) .. ' >/dev/null 2>&1; then',
    '  printf %s ' .. sh_quote(REMOTE_SCRIPT) .. ' | ' .. timed(RUN_TIMEOUT, run) .. ' >"$tmp" 2>/dev/null',
    '  echo "#exit $?" >>"$tmp"',
    'else',
    '  echo "#nomaster" >"$tmp"',
    'fi',
    'mv -f "$tmp" ' .. sh_quote(out),
  }, '\n')
end

local function read_json(key)
  local v = wezterm.GLOBAL[key]
  return v and wezterm.json_parse(v) or nil
end

-- Start listing the ports of the host behind control path `path`, without
-- waiting: update-status picks the result up (see finish_job)
local function start_job(ssh, path)
  local gated = gated_args(ssh, path)
  local run = ssh_cmd(gated, '-T', '-o', 'ClearAllForwardings=yes')
  table.insert(run, 'sh -s')
  local seq = (wezterm.GLOBAL.ports_seq or 0) + 1
  wezterm.GLOBAL.ports_seq = seq
  local out = STATE_DIR .. os.time() .. '-' .. seq
  wezterm.GLOBAL[JOB_KEY] = wezterm.json_encode { out = out, path = path, host = ssh_host(ssh), started = os.time() }
  wezterm.background_child_process { '/bin/sh', '-c', job_script(ssh_cmd(gated, '-O', 'check'), run, out) }
end

-- Whether the master's socket file exists: no need to even ask otherwise
local function socket_exists(path)
  local ok, found = pcall(wezterm.glob, path)
  return ok and #found > 0
end

-- Picker ------------------------------------------------------------------

local function forward_remote(window, remote, rport)
  local gated = gated_args(remote.ssh, remote.path)
  local pid = ssh_master_pid(gated)
  if not pid then
    toast(window, 'Ports: no live ssh connection to ' .. remote.host .. ' (ControlMaster)', 5000)
    return
  end
  local lport, how, note = port_forward.ssh_forward(gated, pid, '127.0.0.1', rport, rport)
  if not lport then
    toast(window, how, 5000)
    return
  end
  wezterm.open_with('http://localhost:' .. lport)
  toast(window, 'Ports: ' .. port_forward.describe_forward(gated, lport, '127.0.0.1', rport, how, note)
    .. ', opened', 5000)
end

local function stop_forward(window, lport)
  for _, f in ipairs(port_forward.recorded_forwards()) do
    if f.lport == lport then
      local what = 'localhost:' .. lport .. ' → ' .. ssh_host(f.ssh) .. ':' .. f.rport
      if not ssh_master_pid(f.ssh) then
        toast(window, 'Ports: ' .. ssh_host(f.ssh) .. ' has no live master; ' .. what .. ' went with it', 5000)
      elseif port_forward.cancel_forward(f.ssh, lport, f.host, f.rport) then
        toast(window, 'Ports: stopped ' .. what, 4000)
      else
        toast(window, 'Ports: could not stop ' .. what, 5000)
      end
      return
    end
  end
  toast(window, 'Ports: no forward of ours on localhost:' .. lport)
end

-- Picker rows: `remote` is { ssh, path, host, ports } or nil
local function picker_choices(remote, listeners, forwards)
  local choices, listening = {}, {}
  for _, l in ipairs(listeners) do listening[l.port] = l end
  local up = {}
  for _, f in ipairs(forwards) do
    local l = listening[f.lport]
    if l and l.name == 'ssh' then table.insert(up, f) end
  end
  for _, p in ipairs(remote and remote.ports or {}) do
    if is_listed(p) then
      local fwd
      for _, f in ipairs(up) do
        if f.rport == p.port and ssh_host(f.ssh) == remote.host then fwd = f.lport end
      end
      table.insert(choices, {
        id = 'r' .. p.port,
        label = '⇄  ' .. remote.host .. ':' .. with_name(p)
          .. (p.owned == nil and '  [owner unknown]' or '')
          .. (fwd and ('  · open localhost:' .. fwd) or '  · forward and open'),
      })
    end
  end
  for _, l in ipairs(listeners) do
    if l.name ~= 'ssh' and not MAC_NOISE[l.name or ''] then
      table.insert(choices, { id = 'l' .. l.port, label = '⌂  localhost:' .. with_name(l) .. '  · open' })
    end
  end
  for _, f in ipairs(up) do
    table.insert(choices, {
      id = 'x' .. f.lport,
      label = '✕  stop localhost:' .. f.lport .. ' → ' .. ssh_host(f.ssh) .. ':' .. f.rport,
    })
  end
  return choices
end

local function local_listeners()
  local ok, out = wezterm.run_child_process { '/usr/sbin/lsof', '-nP', '-iTCP', '-sTCP:LISTEN', '-Fpcn' }
  return ok and parse_lsof(out) or {}
end

local function open_picker(window, pane, remote)
  local choices = picker_choices(remote, local_listeners(), port_forward.recorded_forwards())
  if #choices == 0 then
    toast(window, 'Ports: nothing listening' .. (remote and (' on ' .. remote.host .. ' or') or '') .. ' on this Mac')
    return
  end
  window:perform_action(act.InputSelector {
    title = 'Ports' .. (remote and (' · ' .. remote.host) or '') .. ' · Enter forwards / opens / stops',
    choices = choices,
    action = wezterm.action_callback(function(win, _, id)
      if not id then return end
      local kind, port = id:sub(1, 1), tonumber(id:sub(2))
      if kind == 'r' then
        forward_remote(win, remote, port)
      elseif kind == 'l' then
        wezterm.open_with('http://localhost:' .. port)
        toast(win, 'Ports: opened localhost:' .. port)
      else
        stop_forward(win, port)
      end
    end),
  }, pane)
end

-- The remote part of the picker for an ssh pane from a listing's result
local function remote_for(ssh, path, ports)
  return ports and { ssh = ssh, path = path, host = ssh_host(ssh), ports = ports } or nil
end

local NO_REMOTE = {
  nomaster = 'no live ssh connection (ControlMaster)',
  unsupported = 'neither ss nor /proc/net/tcp there',
  failed = 'listing failed',
}

-- A listing finished: cache it, toast new ports, open a waiting picker
local function finish_job(window, job, text)
  local ports, err = parse_remote(text)
  if ports then
    wezterm.GLOBAL[CACHE_KEY .. job.path] = wezterm.json_encode { t = os.time(), ports = ports }
    local fresh, last, notified = new_ports(ports, wezterm.GLOBAL[LAST_KEY .. job.path],
      wezterm.GLOBAL[NOTIFIED_KEY .. job.path])
    wezterm.GLOBAL[LAST_KEY .. job.path], wezterm.GLOBAL[NOTIFIED_KEY .. job.path] = last, notified
    if #fresh > 0 then
      local names = {}
      for _, p in ipairs(fresh) do table.insert(names, ':' .. p.port .. (p.name and (' ' .. p.name) or '')) end
      toast(window, '⇄ ' .. job.host .. table.concat(names, ',') .. ' started · '
        .. KEY_TEXT .. ' to open', 8000)
    end
  else
    wezterm.GLOBAL[CACHE_KEY .. job.path] = nil
  end
  local picker = read_json(PICKER_KEY)
  if not picker or picker.path ~= job.path then return end
  wezterm.GLOBAL[PICKER_KEY] = nil
  local ok, gui = pcall(wezterm.gui.gui_window_for_mux_window, picker.window)
  local pane = mux_pane(picker.pane)
  local ssh = pane and pane_ssh_args(pane)
  if not ok or not gui or not ssh then return end
  if not ports then
    toast(gui, 'Ports: ' .. job.host .. ': ' .. (NO_REMOTE[err] or err) .. '; showing this Mac only', 5000)
  end
  open_picker(gui, pane, remote_for(ssh, job.path, ports))
end

-- update-status, in the focused window: collect a finished listing, then
-- start the next one (for a waiting picker at once, else every POLL_SECONDS
-- for the focused pane's host if its master's socket exists)
local function update_badge(window, pane, now)
  local key = 'ports_badge_' .. window:window_id() -- what this window's right status shows
  if now < (wezterm.GLOBAL.notice_until or 0) then
    wezterm.GLOBAL[key] = nil -- a toast owns the right status; set the badge again after it
    return
  end
  local ssh = pane_ssh_args(pane)
  local path = ssh and control_path(ssh)
  local cache = path and read_json(CACHE_KEY .. path)
  -- No poll for 3 rounds (master gone, pane left ssh): no badge
  local text = cache and now - cache.t <= 3 * POLL_SECONDS and badge_text(cache.ports) or ''
  if wezterm.GLOBAL[key] == text then return end
  wezterm.GLOBAL[key] = text
  window:set_right_status(text == '' and '' or wezterm.format {
    { Background = { Color = core.C.surface0 } }, { Foreground = { Color = core.C.blue } },
    { Text = ' ' .. text .. ' ' },
  })
end

local function tick(window, pane)
  local now = os.time()
  if wezterm.GLOBAL.ports_badge_tick ~= now then
    wezterm.GLOBAL.ports_badge_tick = now
    update_badge(window, pane, now)
  end
  local job = read_json(JOB_KEY)
  if job then
    local f = io.open(job.out)
    if f then
      local text = f:read 'a'
      f:close()
      os.remove(job.out)
      wezterm.GLOBAL[JOB_KEY] = nil
      finish_job(window, job, text)
    elseif now - job.started > JOB_SECONDS then
      wezterm.GLOBAL[JOB_KEY] = nil
    end
    return
  end
  local picker = read_json(PICKER_KEY)
  if picker and now - picker.started > JOB_SECONDS then
    wezterm.GLOBAL[PICKER_KEY], picker = nil, nil
  end
  if picker then
    local p = mux_pane(picker.pane)
    local ssh = p and pane_ssh_args(p)
    if ssh then
      start_job(ssh, picker.path)
    else
      wezterm.GLOBAL[PICKER_KEY] = nil
    end
    return
  end
  if now - (wezterm.GLOBAL.ports_tick or 0) < POLL_SECONDS then return end
  wezterm.GLOBAL.ports_tick = now
  local ssh = pane_ssh_args(pane)
  local path = ssh and control_path(ssh)
  if path and socket_exists(path) then start_job(ssh, path) end
end

-- CMD+SHIFT+I: the picker, at once from a recent poll, else once the
-- listing it starts comes back
local function show_ports(window, pane)
  local ssh = pane_ssh_args(pane)
  local path = ssh and control_path(ssh)
  if not ssh then return open_picker(window, pane, nil) end
  if not path or not socket_exists(path) then
    toast(window, 'Ports: no live ssh connection to ' .. ssh_host(ssh) .. ' (ControlMaster); showing this Mac only', 5000)
    return open_picker(window, pane, nil)
  end
  local cache = read_json(CACHE_KEY .. path)
  if cache and os.time() - cache.t <= CACHE_SECONDS then
    return open_picker(window, pane, remote_for(ssh, path, cache.ports))
  end
  wezterm.GLOBAL[PICKER_KEY] = wezterm.json_encode {
    window = window:window_id(), pane = pane:pane_id(), path = path, started = os.time(),
  }
  toast(window, 'Ports: listing ' .. ssh_host(ssh) .. '…', 2000)
end

local M = {
  -- for tests
  _test = { control_path = control_path, gated_args = gated_args, parse_remote = parse_remote, parse_lsof = parse_lsof, new_ports = new_ports,
    job_script = job_script, picker_choices = picker_choices, badge_text = badge_text, REMOTE_SCRIPT = REMOTE_SCRIPT },
}

function M.apply(config)
  wezterm.on('update-status', function(window, pane)
    if window:is_focused() then tick(window, pane) end
  end)
  table.insert(config.keys, { key = KEY, mods = KEY_MODS, action = wezterm.action_callback(show_ports) })
end

return M
