-- VS Code-style Ports. CMD+SHIFT+I lists ports in groups, one per source:
--  * This Mac: ports your own processes listen on; pick one to open it;
--  * one group per ssh host with an open pane (the focused pane's first),
--    named as you typed it (gpubox, not its FQDN), each with
--    (a) the TCP ports listening there, each named for what it is
--        ("Jupyter Lab · cswap", see REMOTE_SCRIPT and lib/port_names.lua;
--        listed only over a live master, see start_job; never a new
--        login): pick one to
--        forward it here (`ssh -O forward`, see features/port_forward.lua
--        for busy local ports; ports below 1024 map to 8000+port) and open
--        it; one already forwarded shows its local port,
--    (b) `ssh -L` tunnel commands on screen for that host (this pane's
--        scrollback, then the window's other panes): pick one to add its
--        forwards on the live master for its host (never running it or
--        logging in) and open the URL printed with it, token and all (see
--        port_forward.forward_tunnel),
--    (c) forwards of ours through it that are up: pick one to stop it
--        (`ssh -O cancel`),
--    or a dim line saying why its ports could not be listed;
--  * Other forwards: ours through a host no group above names.
-- Group headers and status lines reopen the list (a refresh). Every row
-- ends in its group's name, so `/` then "gpubox" filters to that host.
-- While an ssh pane whose master is live has focus, its host is polled every
-- POLL_SECONDS in the background, a port of yours that starts listening
-- there toasts once, and the right status shows "⇄ 2 local · 3 gpubox ·
-- ⌘⇧I" (status text can't be clicked on 20240203; the key opens the list).
-- Every remote call first asks the master (-O check) and carries gated_args
-- (lib/ssh.lua), so nothing here can prompt or authenticate.
local wezterm = require 'wezterm'
local act = wezterm.action
local core = require 'lib.core'
local ssh_lib = require 'lib.ssh'
local port_forward = require 'features.port_forward'
local names = require 'lib.port_names'
local toast, mux_pane, sh_quote = core.toast, core.mux_pane, core.sh_quote
local pane_ssh_args, ssh_cmd, ssh_host = ssh_lib.pane_ssh_args, ssh_lib.ssh_cmd, ssh_lib.ssh_host
local ssh_master_pid, command_master = ssh_lib.ssh_master_pid, ssh_lib.command_master
local control_path, gated_args = ssh_lib.control_path, ssh_lib.gated_args

local KEY, KEY_MODS, KEY_TEXT, KEY_SHORT = 'i', 'CMD|SHIFT', 'CMD+SHIFT+I', '⌘⇧I'
local POLL_SECONDS = 10
local CACHE_SECONDS = 15 -- the picker opens at once on a poll this recent
local JOB_SECONDS = 20 -- a listing (or a picker waiting on one) older than this is dropped
local CHECK_TIMEOUT, RUN_TIMEOUT = 3, 8 -- seconds for -O check and for the listing
local STATE_DIR = wezterm.home_dir .. '/.local/state/wezterm/ports/'

-- wezterm.GLOBAL keys (they survive config reloads, timers don't)
local JOBS_KEY = 'ports_jobs' -- JSON control path -> { out, path, host, started } of listings in flight
local PICKER_KEY = 'ports_picker' -- JSON { window, pane, paths, started } waiting on listings
local CACHE_KEY = 'ports_cache_' -- .. control path -> JSON { t, ports | err, locals }
local LAST_KEY = 'ports_last_' -- .. control path -> " port port ... " of the last poll
local NOTIFIED_KEY = 'ports_notified_' -- .. control path -> " port ... " already toasted
local TITLES_KEY = 'ports_titles_' -- .. control path or 'local' -> JSON { [port] = { pid, title } }

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
-- Rows the This Mac group shows (and the badge counts): not ssh, whose
-- listeners are our forwards
local function is_local_listed(l)
  return l.name ~= 'ssh' and not MAC_NOISE[l.name or '']
end

-- Page titles of the ports in $pairs ("port pid" lines), all at once, each
-- request at most 1 s and all of them killed at 2 s: "#titles", then
-- "#title port pid text" per port asked (text empty when there is none).
-- Skips ports in $known (" port:pid ... ", titles we have) and ones that
-- never speak HTTP. Only when $titles is 1 and curl is there.
local TITLE_SCRIPT = [=[
if [ "$titles" = 1 ] && command -v curl >/dev/null 2>&1; then
  echo '#titles'
  set --
  while read -r port pid; do
    [ -n "$pid" ] || continue
    case $known in *" $port:$pid "*) continue ;; esac
    case $port in 22|25|53|111|631|2049|3306|5432|5353|5355|6379|11211|27017) continue ;; esac
    { t=$(curl -s -m 1 --max-filesize 65536 "http://127.0.0.1:$port/" | head -c 65536 | tr '\r\n\t' '   ' |
        sed 's,</[Tt][Ii][Tt][Ll][Ee][[:space:]]*>.*,,' | sed -n 's,.*<[Tt][Ii][Tt][Ll][Ee][^>]*>,,p' | cut -c1-200)
      printf '#title %s %s %s\n' "$port" "$pid" "$t"; } 2>/dev/null &
    set -- "$@" $!
  done <<EOF
$pairs
EOF
  if [ $# -gt 0 ]; then
    ( sleep 2; kill "$@" ) >/dev/null 2>&1 &
    w=$!
    wait "$@" 2>/dev/null
    kill "$w" 2>/dev/null
  fi
fi
exit 0
]=]

-- Remote listing in one round trip (POSIX sh, sent on stdin to `sh -s`).
-- `ss` shows the process only for your own sockets; without ss,
-- /proc/net/tcp{,6} with your uid, and which of your processes holds each
-- socket from your own /proc/<pid>/fd links. Then, to name them: "#home",
-- and per port of yours "#lp port pid", with "#cmd pid argv" (its
-- /proc/<pid>/cmdline, NULs as \31) and "#cwd pid dir" once per pid; then
-- TITLE_SCRIPT. Anything missing (awk, readlink) only leaves names out.
-- WZ_PROC is for tests.
local REMOTE_SCRIPT = [=[
P=${WZ_PROC:-/proc}
pairs=
if command -v ss >/dev/null 2>&1 && { out=$(ss -tlnpH 2>/dev/null) || out=$(ss -tlnp 2>/dev/null | sed 1d); }; then
  printf '#ss\n%s\n' "$out"
  pairs=$(printf '%s\n' "$out" | awk '$1 == "LISTEN" && match($0, /pid=[0-9]+/) {
    n = split($4, a, ":"); print a[n], substr($0, RSTART + 4, RLENGTH - 4) }' 2>/dev/null)
elif [ -r "$P/net/tcp" ]; then
  me=$(id -u)
  printf '#proc %s\n' "$me"
  tcp=$(for f in "$P/net/tcp" "$P/net/tcp6"; do [ -r "$f" ] && cat "$f"; done)
  socks=$(find "$P"/[0-9]*/fd -maxdepth 1 -lname 'socket:*' -printf '%h %l\n' 2>/dev/null |
  while read -r h l; do
    p=${h#"$P"/}; p=${p%/fd}; i=${l#"socket:["}; i=${i%]}
    printf '#sock %s %s %s\n' "$i" "$p" "$(cat "$P/$p/comm" 2>/dev/null)"
  done)
  printf '%s\n%s\n' "$tcp" "$socks"
  pairs=$(printf '%s\n#\n%s\n' "$tcp" "$socks" | awk -v me="$me" '$1 == "#" { s = 1; next }
    !s && $4 == "0A" && $8 == me { n = split($2, a, ":"); L[$10] = a[n] }
    s && ($2 in L) { print L[$2], $3 }' 2>/dev/null |
  while read -r h p; do printf '%d %s\n' "0x$h" "$p"; done)
else
  echo '#unsupported'; exit 0
fi
pairs=$(printf '%s\n' "$pairs" | sort -u -k1,1n 2>/dev/null)
printf '#home %s\n' "$HOME"
seen=' '
while read -r port pid; do
  [ -n "$pid" ] || continue
  printf '#lp %s %s\n' "$port" "$pid"
  case $seen in *" $pid "*) continue ;; esac
  seen="$seen$pid "
  printf '#cmd %s %s\n' "$pid" "$({ tr '\000\n' '\037 ' <"$P/$pid/cmdline"; } 2>/dev/null)"
  printf '#cwd %s %s\n' "$pid" "$(readlink "$P/$pid/cwd" 2>/dev/null)"
done <<EOF
$pairs
EOF
]=] .. TITLE_SCRIPT

-- This Mac's half of REMOTE_SCRIPT's naming, for $pids (comma-separated)
-- of $pairs: "#cmd pid args" (ps joins argv with spaces) and "#cwd pid dir"
local LOCAL_SCRIPT = [=[
/bin/ps -ww -o pid=,args= -p "$pids" 2>/dev/null | sed 's/^ *\([0-9][0-9]*\) /#cmd \1 /'
/usr/sbin/lsof -a -p "$pids" -d cwd -Fpn 2>/dev/null |
  awk '/^p/ { p = substr($0, 2) } /^n/ { print "#cwd", p, substr($0, 2) }'
]=] .. TITLE_SCRIPT

-- Shell lines that set what TITLE_SCRIPT reads: $known from `cache` (port
-- -> { pid, title }) and $titles from M.fetch_titles
local M = { fetch_titles = true }
local function title_vars(cache)
  local known = ' '
  for port, c in pairs(cache or {}) do known = known .. port .. ':' .. tostring(c.pid) .. ' ' end
  return 'known=' .. sh_quote(known) .. '\ntitles=' .. (M.fetch_titles and '1' or '0') .. '\n'
end

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
-- 'maxsessions' (sshd refused the session: too many on that connection) /
-- 'timeout' / 'failed'. ssh's stderr comes as "#err" lines.
local function parse_remote(text)
  local lines = {}
  for line in (text or ''):gmatch '[^\n]+' do table.insert(lines, line) end
  local head = lines[1] or ''
  if head == '#nomaster' then return nil, 'nomaster' end
  if head == '#unsupported' then return nil, 'unsupported' end
  if head == '#ss' then return merge(parse_ss(lines)) end
  local uid = tonumber(head:match '^#proc (%d+)$')
  if uid then return merge(parse_proc(lines, uid)) end
  for _, line in ipairs(lines) do
    if line:match '^#err .*refused by peer' or line:match '^#err .*administratively prohibited' then
      return nil, 'maxsessions'
    end
  end
  for _, line in ipairs(lines) do
    if line == '#exit 142' then return nil, 'timeout' end -- killed by the alarm (128 + SIGALRM)
  end
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

-- REMOTE_SCRIPT's and LOCAL_SCRIPT's naming lines -> { home, pid = { [port]
-- = pid }, cmd = { [pid] = cmdline }, cwd = { [pid] = dir }, titles = {
-- [port] = { pid, text } }, titled (titles were asked for) }
local function parse_info(text)
  local info = { pid = {}, cmd = {}, cwd = {}, titles = {} }
  for line in (text or ''):gmatch '[^\n]+' do
    local tag, rest = line:match '^#(%a+) ?(.*)$'
    if tag == 'home' then
      info.home = rest ~= '' and rest or nil
    elseif tag == 'titles' then
      info.titled = true
    elseif tag == 'lp' then
      local port, pid = rest:match '^(%d+) (%d+)$'
      if port then info.pid[tonumber(port)] = pid end
    elseif tag == 'cmd' or tag == 'cwd' then
      local pid, value = rest:match '^(%d+) ?(.*)$'
      if pid and value ~= '' then info[tag][pid] = value end
    elseif tag == 'title' then
      local port, pid, t = rest:match '^(%d+) (%d+) ?(.*)$'
      if port then info.titles[tonumber(port)] = { pid = pid, text = t } end
    end
  end
  return info
end

-- Name each of `ports` from `info` (parse_info): p.what ("Jupyter Lab") and
-- p.project ("cswap"); `home` is the fallback home folder, `exists` checks
-- a path (to rejoin a ps line's paths with spaces). `cache` (port -> {
-- pid, title }) holds titles fetched before; a title is fetched again only
-- when its port's pid changes. Returns the cache for the ports there now.
local function name_ports(ports, info, home, cache, exists)
  local kept = {}
  cache = cache or {}
  for _, p in ipairs(ports) do
    local pid = info.pid[p.port]
    if pid then
      local key, t, c = tostring(p.port), info.titles[p.port], cache[tostring(p.port)]
      local title
      if t then
        title, kept[key] = t.text, { pid = t.pid, title = t.text }
      elseif c and tostring(c.pid) == pid then
        title, kept[key] = c.title, c
      elseif info.titled then
        kept[key] = { pid = pid, title = '' } -- asked, no answer: not again for this pid
      end
      p.pid = tonumber(pid)
      p.what, p.project = names.label {
        argv = info.cmd[pid] and names.split_cmdline(info.cmd[pid], exists),
        cwd = info.cwd[pid], home = info.home or home, title = title, name = p.name,
      }
    end
  end
  return kept
end

-- "⇄ gpubox:8888 Jupyter Lab (cswap), :6006 TensorBoard started · ⌘⇧I to open"
local function toast_message(host, fresh)
  local parts = {}
  for _, p in ipairs(fresh) do
    local text = names.toast_text(p)
    table.insert(parts, ':' .. p.port .. (text and (' ' .. text) or ''))
  end
  return '⇄ ' .. host .. table.concat(parts, ', ') .. ' started · ' .. KEY_TEXT .. ' to open'
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

-- Right-status badge for the focused ssh pane's host: "⇄ 2 local · 3
-- gpubox · ⌘⇧I" (only the counts above 0), or '' when both are 0
local function badge_text(host, ports, locals)
  local n = 0
  for _, p in ipairs(ports or {}) do
    if is_listed(p) then n = n + 1 end
  end
  local parts = {}
  if (locals or 0) > 0 then table.insert(parts, locals .. ' local') end
  if n > 0 then table.insert(parts, n .. ' ' .. host) end
  if #parts == 0 then return '' end
  return '⇄ ' .. table.concat(parts, ' · ') .. ' · ' .. KEY_SHORT
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

local LSOF = { '/usr/sbin/lsof', '-nP', '-iTCP', '-sTCP:LISTEN', '-Fpcn' }

-- sh script that runs `check` and, only if it succeeds, `run` with
-- `script` (REMOTE_SCRIPT and its variables) on stdin (its exit status and stderr as "#exit" and "#err"
-- lines after), else writes "#nomaster"; then this Mac's listeners after a
-- "#local" line (for the badge). It moves the output to `out` in one step,
-- so a reader never sees half of it.
local function job_script(check, run, out, script)
  return table.concat({
    'umask 077',
    'mkdir -p ' .. sh_quote(out:match '^(.*)/') .. ' || exit 1',
    'tmp=' .. sh_quote(out .. '.tmp'),
    'if ' .. timed(CHECK_TIMEOUT, check) .. ' >/dev/null 2>&1; then',
    '  printf %s ' .. sh_quote(script) .. ' | ' .. timed(RUN_TIMEOUT, run) .. ' >"$tmp" 2>"$tmp.err"',
    '  echo "#exit $?" >>"$tmp"',
    '  sed "s/^/#err /" "$tmp.err" >>"$tmp"',
    '  rm -f "$tmp.err"',
    'else',
    '  echo "#nomaster" >"$tmp"',
    'fi',
    'echo "#local" >>"$tmp"',
    sh_words(LSOF) .. ' >>"$tmp" 2>/dev/null',
    'mv -f "$tmp" ' .. sh_quote(out),
  }, '\n')
end

local function read_json(key)
  local v = wezterm.GLOBAL[key]
  return v and wezterm.json_parse(v) or nil
end

-- Listings in flight, by control path
local function read_jobs() return read_json(JOBS_KEY) or {} end
local function save_jobs(jobs)
  wezterm.GLOBAL[JOBS_KEY] = next(jobs) and wezterm.json_encode(jobs) or nil
end

local function save_result(path, ports, err, locals)
  wezterm.GLOBAL[CACHE_KEY .. path] = wezterm.json_encode { t = os.time(), ports = ports, err = err, locals = locals }
end

-- Start listing the ports of the host of `ssh` (its pane master's control
-- path `path` names the result), without waiting: tick picks the result up
-- (see finish_job). It rides command_master: the host's background master
-- when that is live (lib/ssh.lua; sshd's MaxSessions often refuses one more
-- session on the pane's own), else the pane's master; with neither live,
-- no job starts and the result is 'nomaster'.
local function start_job(ssh, path)
  local gated = command_master(ssh)
  if not gated then return save_result(path, nil, 'nomaster') end
  local run = ssh_cmd(gated, '-T', '-o', 'ClearAllForwardings=yes')
  table.insert(run, 'sh -s')
  local seq = (wezterm.GLOBAL.ports_seq or 0) + 1
  wezterm.GLOBAL.ports_seq = seq
  local out = STATE_DIR .. os.time() .. '-' .. seq
  local jobs = read_jobs()
  jobs[path] = { out = out, path = path, host = ssh_host(ssh), started = os.time() }
  save_jobs(jobs)
  local script = title_vars(read_json(TITLES_KEY .. path)) .. REMOTE_SCRIPT
  wezterm.background_child_process { '/bin/sh', '-c', job_script(ssh_cmd(gated, '-O', 'check'), run, out, script) }
end

-- Whether the master's socket file exists: no need to even ask otherwise
local function socket_exists(path)
  local ok, found = pcall(wezterm.glob, path)
  return ok and #found > 0
end

-- Picker rows ----------------------------------------------------------------

-- One icon per kind of row
local ICON = { mac = '⌂', remote = '⇄', screen = '↗', stop = '✕' }
local PORT_W, NAME_W = 7, 24 -- column widths of ":port" and what listens

-- Why a host group has no listening ports to show
local NO_LIST = {
  nomaster = "can't list: no live connection",
  maxsessions = "can't list: server session limit (MaxSessions)",
  unsupported = "can't list: neither ss nor /proc/net/tcp there",
  timeout = "can't list: listing timed out",
  failed = "can't list: listing failed",
  nocontrol = "can't list: no ControlMaster configured",
  nopane = 'ports not listed: no ssh pane open to it',
}

local function pad(text, width)
  return text .. string.rep(' ', width - (utf8.len(text) or #text))
end

local function dim(text)
  return wezterm.format { { Foreground = { AnsiColor = 'Grey' } }, { Text = text } }
end

-- "── gpubox (ssh) ──" in bold; picking it reopens the list
local function header(title, color)
  return { id = 'h', label = wezterm.format {
    { Attribute = { Intensity = 'Bold' } }, { Foreground = { AnsiColor = color } },
    { Text = '── ' .. title .. ' ──' },
  } }
end

-- A dim status line in a group ("no listening ports"); picking it reopens
-- the list
local function note(text, group)
  return { id = 'h', label = '     ' .. dim(text .. '  · ' .. group) }
end

-- icon, :port and process in aligned columns, then the action and the group
-- dimmed. The dim escape (whose digits a filter can match too) comes after
-- the port and process, the text people type.
local function row(id, icon, port, name, action, group)
  return { id = id, label = '  ' .. icon .. '  ' .. pad(port, PORT_W) .. ' ' .. pad(name or '?', NAME_W) .. ' '
    .. dim(action .. '  · ' .. group) }
end

-- A listening port's row: what it is (and its project), then dimmed its
-- process name (so "/python" still finds it), the action and the group
local function listener_row(id, icon, p, action, group)
  local text = names.row_text(p)
  if p.name and text and text ~= p.name then action = p.name .. ' · ' .. action end
  return row(id, icon, ':' .. p.port, text, action, group)
end

-- "open with token" for a tunnel command on screen
local function tunnel_action(t)
  if not t.url then return 'forward and open' end
  return t.url.rest:match '[?#].-=.' and 'open with token' or ('open ' .. (t.url.rest ~= '' and t.url.rest or '/'))
end

-- ":8766, :6006": the local ports a tunnel command forwards
local function tunnel_ports(t)
  local ports = {}
  for _, f in ipairs(t.forwards) do table.insert(ports, ':' .. f.lport) end
  return table.concat(ports, ', ')
end

-- Group key of a forward: the -S socket of the master it went through
-- (gated_args), else its host
local function forward_key(f)
  for k = 2, #f.ssh - 1 do
    if f.ssh[k] == '-S' then return f.ssh[k + 1] end
  end
  return 'host:' .. ssh_host(f.ssh)
end

-- The picker's rows, grouped by source. `locals` is parse_lsof output;
-- `hosts` an ordered list of { key, host, ports | err } (key: the pane
-- master's control path); `forwards` port_forward.recorded_forwards;
-- `tunnels` port_forward.screen_tunnels, each with .key set to its host's.
-- Row ids: h (header or status: reopen), l<port>, r<host index>:<port>,
-- s<tunnel index>, x<local port>.
local function picker_rows(locals, hosts, forwards, tunnels)
  local rows, listening, up, shown = {}, {}, {}, {}
  for _, l in ipairs(locals) do listening[l.port] = l end
  -- A record outlives its master: only forwards whose port ssh still holds
  for _, f in ipairs(forwards) do
    local l = listening[f.lport]
    if l and l.name == 'ssh' then table.insert(up, f) end
  end

  table.insert(rows, header('This Mac', 'Lime'))
  local before = #rows
  for _, l in ipairs(locals) do
    if is_local_listed(l) then
      table.insert(rows, listener_row('l' .. l.port, ICON.mac, l, 'open', 'This Mac'))
    end
  end
  if #rows == before then table.insert(rows, note('no listening ports', 'This Mac')) end

  local known = {}
  for _, h in ipairs(hosts) do known[h.key] = true end
  for i, h in ipairs(hosts) do
    table.insert(rows, header(h.host .. ' (ssh)', 'Blue'))
    local mine = {}
    for _, f in ipairs(up) do
      if forward_key(f) == h.key then table.insert(mine, f) end
    end
    if h.ports then
      before = #rows
      for _, p in ipairs(h.ports) do
        if is_listed(p) then
          local lport
          for _, f in ipairs(mine) do
            if f.rport == p.port then lport = f.lport end
          end
          table.insert(rows, listener_row('r' .. i .. ':' .. p.port, ICON.remote, p,
            (lport and ('forwarded at localhost:' .. lport .. ' · open') or 'forward and open')
              .. (p.owned == nil and ' (owner unknown)' or ''), h.host))
        end
      end
      if #rows == before then table.insert(rows, note('no listening ports', h.host)) end
    else
      table.insert(rows, note(NO_LIST[h.err] or ("can't list: " .. tostring(h.err)), h.host))
    end
    for ti, t in ipairs(tunnels) do
      if t.key == h.key then
        table.insert(rows, row('s' .. ti, ICON.screen, tunnel_ports(t), 'on screen', tunnel_action(t), h.host))
      end
    end
    for _, f in ipairs(mine) do
      shown[f] = true
      table.insert(rows, row('x' .. f.lport, ICON.stop, ':' .. f.lport, 'forward',
        'stop · → ' .. h.host .. ':' .. f.rport, h.host))
    end
  end

  local other = {}
  for ti, t in ipairs(tunnels) do
    if not known[t.key] then
      local host = ssh_host(t.ssh)
      table.insert(other, row('s' .. ti, ICON.screen, tunnel_ports(t), 'on screen', tunnel_action(t) .. ' · ' .. host, host))
    end
  end
  for _, f in ipairs(up) do
    if not shown[f] then
      local host = ssh_host(f.ssh)
      table.insert(other, row('x' .. f.lport, ICON.stop, ':' .. f.lport, 'forward',
        'stop · → ' .. host .. ':' .. f.rport, host))
    end
  end
  if #other > 0 then
    table.insert(rows, header('Other forwards', 'Yellow'))
    for _, r in ipairs(other) do table.insert(rows, r) end
  end
  return rows
end

-- Gathering ------------------------------------------------------------------

-- ssh hosts with a pane open, one per pane master: the focused pane's first,
-- then its window's, then other windows'. Each is { key, path, ssh, host }.
local function open_hosts(window, pane)
  local hosts, seen = {}, {}
  local function add(p)
    local ssh = pane_ssh_args(p)
    if not ssh then return end
    local path = control_path(ssh)
    local key = path or ('host:' .. ssh_host(ssh))
    if seen[key] then return end
    seen[key] = true
    table.insert(hosts, { key = key, path = path, ssh = ssh, host = ssh_host(ssh) })
  end
  add(pane)
  local windows = {}
  local ok, mw = pcall(function() return window:mux_window() end)
  if ok and mw then table.insert(windows, mw) end
  for _, w in ipairs(wezterm.mux.all_windows()) do table.insert(windows, w) end
  for _, w in ipairs(windows) do
    for _, tab in ipairs(w:tabs()) do
      for _, p in ipairs(tab:panes()) do add(p) end
    end
  end
  return hosts
end

-- The latest listing of host `h`: ports, or nil and why not
local function host_state(h)
  if not h.path then return nil, 'nocontrol' end
  if not socket_exists(h.path) then return nil, 'nomaster' end
  local cache = read_json(CACHE_KEY .. h.path)
  if not cache then return nil, 'timeout' end
  return cache.ports, cache.err
end

-- Set each tunnel's .key to its host's group: the same master socket, else
-- the same hostname and port (ssh -G), else a new group (appended to
-- `hosts`, unlisted) named by its ~/.ssh/config alias. Only asks ssh -G.
local function group_tunnels(hosts, tunnels)
  local by, idents = {}, {}
  for _, h in ipairs(hosts) do by[h.key] = h end
  local function ident(ssh)
    local name, _, port = port_forward.ssh_identity(ssh)
    return name and (name .. ':' .. (port or '22')) or ''
  end
  for _, t in ipairs(tunnels) do
    local path = control_path(t.ssh)
    local key = path and by[path] and path
    if not key then
      local id = ident(t.ssh)
      for _, h in ipairs(hosts) do
        if h.ssh and id ~= '' then
          idents[h.key] = idents[h.key] or ident(h.ssh)
          if idents[h.key] == id then
            key = h.key
            break
          end
        end
      end
    end
    if not key then
      key = path or ('host:' .. ssh_host(t.ssh))
      if not by[key] then
        by[key] = { key = key, host = port_forward.host_alias(t.ssh) or ssh_host(t.ssh), err = 'nopane' }
        table.insert(hosts, by[key])
      end
    end
    t.key = key
  end
end

-- Picker ------------------------------------------------------------------

local function forward_remote(window, remote, rport)
  local gated = gated_args(remote.ssh, remote.path)
  local pid = ssh_master_pid(gated)
  if not pid then
    toast(window, 'Ports: no live ssh connection to ' .. remote.host .. ' (ControlMaster)', 5000)
    return
  end
  local lport, how, note_text = port_forward.ssh_forward(gated, pid, '127.0.0.1', rport, rport)
  if not lport then
    toast(window, how, 5000)
    return
  end
  wezterm.open_with('http://localhost:' .. lport)
  toast(window, 'Ports: ' .. port_forward.describe_forward(gated, lport, '127.0.0.1', rport, how, note_text)
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

-- Name this Mac's listeners the way REMOTE_SCRIPT names a host's (ps for
-- the command line, lsof for the cwd, titles cached the same way)
local function name_local(list)
  local shown, lines, pids, seen = {}, {}, {}, {}
  local info = parse_info ''
  for _, l in ipairs(list) do
    if is_local_listed(l) and l.pid then
      table.insert(shown, l)
      table.insert(lines, l.port .. ' ' .. l.pid)
      info.pid[l.port] = l.pid
      if not seen[l.pid] then
        seen[l.pid] = true
        table.insert(pids, l.pid)
      end
    end
  end
  if #shown == 0 then return end
  local cache = read_json(TITLES_KEY .. 'local')
  local script = title_vars(cache) .. 'pairs=' .. sh_quote(table.concat(lines, '\n')) .. '\npids='
    .. table.concat(pids, ',') .. '\n' .. LOCAL_SCRIPT
  local ok, out = wezterm.run_child_process { '/bin/sh', '-c', script }
  local got = parse_info(ok and out or '')
  got.pid = info.pid
  wezterm.GLOBAL[TITLES_KEY .. 'local'] = wezterm.json_encode(name_ports(shown, got, wezterm.home_dir, cache, core.exists))
end

local function local_listeners()
  local ok, out = wezterm.run_child_process(LSOF)
  local list = ok and parse_lsof(out) or {}
  name_local(list)
  return list
end

local show_ports -- the key's action; picking a header calls it again

local function open_picker(window, pane)
  local hosts = open_hosts(window, pane)
  for _, h in ipairs(hosts) do h.ports, h.err = host_state(h) end
  local tunnels = port_forward.screen_tunnels(window, pane)
  group_tunnels(hosts, tunnels)
  window:perform_action(act.InputSelector {
    title = 'Ports · Enter opens / forwards / stops · / filters (host or port)',
    choices = picker_rows(local_listeners(), hosts, port_forward.recorded_forwards(), tunnels),
    action = wezterm.action_callback(function(win, p, id)
      if not id then return end
      local kind, rest = id:sub(1, 1), id:sub(2)
      if kind == 'h' then
        show_ports(win, p)
      elseif kind == 's' then
        local t = tunnels[tonumber(rest)]
        port_forward.forward_tunnel(win, t.pane, t.ssh, t.forwards, t.url)
      elseif kind == 'r' then
        local i, port = rest:match '^(%d+):(%d+)$'
        forward_remote(win, hosts[tonumber(i)], tonumber(port))
      elseif kind == 'l' then
        wezterm.open_with('http://localhost:' .. rest)
        toast(win, 'Ports: opened localhost:' .. rest)
      elseif kind == 'x' then
        stop_forward(win, tonumber(rest))
      end
    end),
  }, pane)
end

-- A listing finished: cache it (and this Mac's count for the badge), toast
-- new ports
local function finish_job(window, job, text)
  local remote, here = text:match '^(.-\n)#local\n(.*)$'
  local ports, err = parse_remote(remote or text)
  if ports then
    local cache = read_json(TITLES_KEY .. job.path)
    wezterm.GLOBAL[TITLES_KEY .. job.path] = wezterm.json_encode(
      name_ports(ports, parse_info(remote or text), nil, cache))
  end
  local locals = 0
  for _, l in ipairs(parse_lsof(here)) do
    if is_local_listed(l) then locals = locals + 1 end
  end
  save_result(job.path, ports, err, locals)
  if not ports then return end
  local fresh, last, notified = new_ports(ports, wezterm.GLOBAL[LAST_KEY .. job.path],
    wezterm.GLOBAL[NOTIFIED_KEY .. job.path])
  wezterm.GLOBAL[LAST_KEY .. job.path], wezterm.GLOBAL[NOTIFIED_KEY .. job.path] = last, notified
  if #fresh > 0 then toast(window, toast_message(job.host, fresh), 8000) end
end

-- update-status, in the focused window: the badge for the focused ssh pane
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
  local text = cache and now - cache.t <= 3 * POLL_SECONDS and badge_text(ssh_host(ssh), cache.ports, cache.locals) or ''
  if wezterm.GLOBAL[key] == text then return end
  wezterm.GLOBAL[key] = text
  window:set_right_status(text == '' and '' or wezterm.format {
    { Background = { Color = core.C.surface0 } }, { Foreground = { Color = core.C.blue } },
    { Text = ' ' .. text .. ' ' },
  })
end

-- update-status, in the focused window: collect finished listings, open a
-- picker once the ones it waits on are in, then poll the focused pane's
-- host every POLL_SECONDS if its master's socket exists
local function tick(window, pane)
  local now = os.time()
  if wezterm.GLOBAL.ports_badge_tick ~= now then
    wezterm.GLOBAL.ports_badge_tick = now
    update_badge(window, pane, now)
  end
  local jobs, changed = read_jobs(), false
  for path, job in pairs(jobs) do
    local f = io.open(job.out)
    if f then
      local text = f:read 'a'
      f:close()
      os.remove(job.out)
      jobs[path], changed = nil, true
      finish_job(window, job, text)
    elseif now - job.started > JOB_SECONDS then
      jobs[path], changed = nil, true
      save_result(path, nil, 'timeout')
    end
  end
  if changed then save_jobs(jobs) end
  local picker = read_json(PICKER_KEY)
  if picker then
    local waiting = false
    for _, path in ipairs(picker.paths) do waiting = waiting or jobs[path] ~= nil end
    if waiting and now - picker.started <= JOB_SECONDS then return end
    wezterm.GLOBAL[PICKER_KEY] = nil
    local ok, gui = pcall(wezterm.gui.gui_window_for_mux_window, picker.window)
    local p = mux_pane(picker.pane)
    if ok and gui and p then open_picker(gui, p) end
    return
  end
  if now - (wezterm.GLOBAL.ports_tick or 0) < POLL_SECONDS then return end
  wezterm.GLOBAL.ports_tick = now
  local ssh = pane_ssh_args(pane)
  local path = ssh and control_path(ssh)
  if path and not jobs[path] and socket_exists(path) then start_job(ssh, path) end
end

-- CMD+SHIFT+I: the picker, at once when every open host has a recent
-- listing, else once the listings it starts come back
show_ports = function(window, pane)
  local jobs, waiting, names = read_jobs(), {}, {}
  for _, h in ipairs(open_hosts(window, pane)) do
    local cache = h.path and read_json(CACHE_KEY .. h.path)
    if h.path and socket_exists(h.path) and not (cache and os.time() - cache.t <= CACHE_SECONDS) then
      if not jobs[h.path] then start_job(h.ssh, h.path) end
      if read_jobs()[h.path] then
        table.insert(waiting, h.path)
        table.insert(names, h.host)
      end
    end
  end
  if #waiting == 0 then return open_picker(window, pane) end
  wezterm.GLOBAL[PICKER_KEY] = wezterm.json_encode {
    window = window:window_id(), pane = pane:pane_id(), paths = waiting, started = os.time(),
  }
  toast(window, 'Ports: listing ' .. table.concat(names, ', ') .. '…', 2000)
end

-- For tests
M._test = {
  control_path = control_path, gated_args = gated_args, parse_remote = parse_remote, parse_lsof = parse_lsof,
  new_ports = new_ports, job_script = job_script, start_job = start_job, read_jobs = read_jobs,
  picker_rows = picker_rows, group_tunnels = group_tunnels, open_hosts = open_hosts, tunnel_action = tunnel_action, tunnel_ports = tunnel_ports, badge_text = badge_text,
  REMOTE_SCRIPT = REMOTE_SCRIPT, LOCAL_SCRIPT = LOCAL_SCRIPT, title_vars = title_vars, parse_info = parse_info,
  name_ports = name_ports, toast_message = toast_message, name_local = name_local,
}

function M.apply(config)
  wezterm.on('update-status', function(window, pane)
    if window:is_focused() then tick(window, pane) end
  end)
  table.insert(config.keys, { key = KEY, mods = KEY_MODS, action = wezterm.action_callback(show_ports) })
end

return M
