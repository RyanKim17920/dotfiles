-- Tests for the CMD+SHIFT+I list (features/ports.lua): its rows grouped by
-- source, their order, empty and error states, the filter text, the badge,
-- listing errors, and that listings ride the background master. Run
-- tests/run.sh: it loads as a WezTerm config under a fake HOME with the fake
-- ssh (tests/shims/ssh) first, so nothing ever connects. Hosts are
-- placeholders.
local wezterm = require 'wezterm'
local ROOT, SHIMS = os.getenv 'WZT_ROOT', os.getenv 'WZT_SHIMS'
package.path = os.getenv 'WZT_SRC' .. '/?.lua;' .. package.path
assert(ROOT and SHIMS, 'run this through tests/run.sh')
assert(wezterm.home_dir:match '^/tmp/wz', 'HOME must be a fake /tmp/wz* one')
local core = require 'lib.core'
core.SPAWN_PATH = SHIMS .. ':' .. core.SPAWN_PATH
local ssh_lib = require 'lib.ssh'
local ports = require 'features.ports'
local T = ports._test
local port_names = require 'lib.port_names'
local function names_row(p) return port_names.row_text(p) end

local failed, passed = 0, 0
local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    io.stderr:write('PASS ', name, '\n')
  else
    failed = failed + 1
    io.stderr:write('FAIL ', name, detail and (': ' .. tostring(detail)) or '', '\n')
  end
end
local function eq(name, got, want) check(name, got == want, 'got ' .. tostring(got) .. ', want ' .. tostring(want)) end
local function write(path, text)
  local f = assert(io.open(path, 'w'))
  f:write(text)
  f:close()
end
-- A label as it shows on screen: escapes dropped
local function plain(label) return (label:gsub('\27%[[%d;:]*m', ''):gsub('\27%(B', '')) end
local function find(rows, pattern)
  for i, r in ipairs(rows) do
    if plain(r.label):find(pattern) then return i, r end
  end
end

-- Fixture: this Mac, gpubox (focused, listed), delta (refused: MaxSessions),
-- gpu (listed, nothing there), and a forward through a master no pane uses
local GATE = { 'ssh-pane', '-o', 'BatchMode=yes', '-o', 'ControlMaster=no', '-o', 'ProxyCommand=false', '-S' }
local function gated(path, dest)
  local t = {}
  for _, v in ipairs(GATE) do table.insert(t, v) end
  table.insert(t, path)
  table.insert(t, dest)
  return t
end
local LOCALS = {
  { port = 3000, name = 'node' }, { port = 5000, name = 'ControlCe' }, { port = 5173, name = 'vite' },
  { port = 8890, name = 'ssh' }, { port = 9000, name = 'ssh' },
}
local function hosts()
  return {
    { key = '/cm/gpubox', host = 'gpubox', ports = {
      { port = 22, owned = true, name = 'sshd' }, { port = 6006, name = 'tensorboard', owned = true },
      { port = 8888, name = 'jupyter-lab', owned = true }, { port = 9999, owned = false },
    } },
    { key = '/cm/delta', host = 'delta', err = 'maxsessions' },
    { key = '/cm/gpu', host = 'gpu', ports = {} },
  }
end
local FORWARDS = {
  { ssh = gated('/cm/gpubox', 'gpubox'), lport = 8890, host = '127.0.0.1', rport = 8888 },
  { ssh = gated('/cm/old', 'oldbox'), lport = 9000, host = '127.0.0.1', rport = 9000 },
  { ssh = gated('/cm/gpubox', 'gpubox'), lport = 7000, host = '127.0.0.1', rport = 7000 }, -- gone: port not held
}
local TUNNELS = {
  { key = '/cm/gpubox', ssh = { 'ssh-pane', 'USER@login-1.HOST.example' },
    forwards = { { lport = 8766, host = 'localhost', rport = 8766 } }, url = { rest = '/#otc=TOKEN', rport = 8766 } },
}

-- 1. Groups and their order
local rows = T.picker_rows(LOCALS, hosts(), FORWARDS, TUNNELS)
local mock = {}
for _, r in ipairs(rows) do table.insert(mock, plain(r.label)) end
io.stderr:write('MOCK ', table.concat(mock, '\nMOCK '), '\n')
do
  local mac = find(rows, '^── This Mac ──$')
  local so = find(rows, '^── gpubox %(ssh%) ──$')
  local de = find(rows, '^── delta %(ssh%) ──$')
  local gp = find(rows, '^── gpu %(ssh%) ──$')
  local ot = find(rows, '^── Other forwards ──$')
  eq('order: This Mac first', mac, 1)
  check('order: hosts in the given order (focused first)', so and de and gp and mac < so and so < de and de < gp,
    table.concat({ tostring(so), tostring(de), tostring(gp) }, ' '))
  check('order: Other forwards last', ot and gp and ot > gp, ot)
  eq('headers reopen the list', rows[so].id, 'h')
  -- This Mac: node and vite; ssh (our forwards) and macOS noise left out
  local node, vite = find(rows, ':3000 +node'), find(rows, ':5173 +vite')
  check('mac: node and vite, in port order', node and vite and mac < node and node < vite and vite < so)
  eq('mac: id', node and rows[node].id, 'l3000')
  check('mac: no ssh or noise rows', not find(rows, 'ControlCe') and not find(rows, '^  ⌂  :8890'))
  -- gpubox: (a) listening, (b) on screen, (c) forwards, in that order
  local tb, jl = find(rows, ':6006 +tensorboard'), find(rows, ':8888 +jupyter%-lab')
  local sc, st = find(rows, ':8766 +on screen'), find(rows, ':8890 +forward')
  check('gpubox: a then b then c', tb and jl and sc and st and so < tb and tb < jl and jl < sc and sc < st and st < de,
    table.concat({ tostring(tb), tostring(jl), tostring(sc), tostring(st) }, ' '))
  check('gpubox: system and others\' ports left out', not find(rows, ':22 ') and not find(rows, ':9999'))
  eq('gpubox: remote id names the host', jl and rows[jl].id, 'r1:8888')
  check('gpubox: forwarded port shows its local port', jl and plain(rows[jl].label):find('forwarded at localhost:8890', 1, true),
    jl and plain(rows[jl].label))
  check('gpubox: unforwarded port offers to forward', tb and plain(rows[tb].label):find('forward and open', 1, true))
  eq('gpubox: tunnel id', sc and rows[sc].id, 's1')
  check('gpubox: tunnel action', sc and plain(rows[sc].label):find('open with token', 1, true))
  check('gpubox: tunnel never shows the token', not plain(table.concat(mock, '\n')):find('TOKEN', 1, true))
  eq('gpubox: stop id', st and rows[st].id, 'x8890')
  check('gpubox: stop row names the target', st and plain(rows[st].label):find('stop · → gpubox:8888', 1, true))
  check('forwards: one whose port ssh no longer holds is left out', not find(rows, ':7000'))
  -- delta: the reason, dim, as a no-op line; nothing else
  local why = find(rows, "can't list: server session limit %(MaxSessions%)")
  eq('delta: status line right under its header', why, de and de + 1)
  eq('delta: status reopens the list', why and rows[why].id, 'h')
  check('delta: status line is dim', why and rows[why].label:find('\27[90m', 1, true))
  eq('delta: nothing else in it', gp, de and de + 2)
  -- gpu: listed, empty
  local empty = find(rows, 'no listening ports  · gpu')
  eq('gpu: empty state under its header', empty, gp and gp + 1)
  -- Other forwards: oldbox
  local old = find(rows, ':9000 +forward')
  check('other: forward through an unlisted master', old and ot and old > ot, old)
  check('other: names its host', old and plain(rows[old].label):find('oldbox', 1, true))
end

-- 2. Filter text: every row of a group carries its host
do
  local group
  for _, r in ipairs(rows) do
    local text = plain(r.label)
    local h = text:match '^── (%S+) %(ssh%) ──$'
    if h then
      group = h
    elseif text:match '^── ' then
      group = nil
    elseif group then
      check('search: row has its host (' .. group .. ')', text:find(group, 1, true), text)
    end
  end
  for _, r in ipairs(rows) do
    if r.id:match '^l' then check('search: mac row says This Mac', plain(r.label):find('This Mac', 1, true)) end
  end
end

-- 3. Columns line up: the port and process start at the same column
do
  local col
  for _, r in ipairs(rows) do
    local text = plain(r.label)
    local at = text:find(':%d')
    if r.id ~= 'h' and at then
      local name_at = utf8.len(text:sub(1, at - 1)) + 9 -- past :port (PORT_W) and a space
      col = col or name_at
      eq('columns: process column (' .. r.id .. ')', name_at, col)
      check('columns: process starts there (' .. r.id .. ')', text:sub(utf8.offset(text, name_at)):match '^%S', text)
    end
  end
end

-- 4. Empty and error states
do
  local r = T.picker_rows({}, {}, {}, {})
  eq('empty: header and a note', #r, 2)
  eq('empty: This Mac says so', r[2] and plain(r[2].label), '     no listening ports  · This Mac')
  check('empty: no Other forwards group', not find(r, 'Other'))
  r = T.picker_rows({}, {
    { key = 'a', host = 'a', err = 'nomaster' }, { key = 'b', host = 'b', err = 'nopane' },
    { key = 'c', host = 'c', err = 'timeout' }, { key = 'd', host = 'd', err = 'weird' },
  }, {}, {})
  check('error: no live connection', find(r, "can't list: no live connection  · a"))
  check('error: no pane', find(r, 'ports not listed: no ssh pane open to it  · b'))
  check('error: timed out', find(r, "can't list: listing timed out  · c"))
  check('error: unknown reason still shown', find(r, "can't list: weird  · d"))
  -- A tunnel whose host has no group lands in Other forwards
  r = T.picker_rows({}, {}, {}, { { key = 'nowhere', ssh = { 'ssh-pane', 'me@h' }, forwards = { { lport = 1234 } } } })
  local ot, tun = find(r, '^── Other forwards ──$'), find(r, ':1234 +on screen')
  check('other: stray tunnel', ot and tun and tun > ot)
end

-- 5. Badge
do
  local P = { { port = 8888, owned = true }, { port = 22, owned = true }, { port = 6006, owned = true } }
  eq('badge: local and remote', T.badge_text('gpubox', P, 2), '⇄ 2 local · 2 gpubox · ⌘⇧I')
  eq('badge: remote only', T.badge_text('gpubox', P, 0), '⇄ 2 gpubox · ⌘⇧I')
  eq('badge: local only (listing failed)', T.badge_text('gpubox', nil, 1), '⇄ 1 local · ⌘⇧I')
  eq('badge: nothing', T.badge_text('gpubox', {}, 0), '')
end

-- 6. Listing errors
do
  local _, err = T.parse_remote '#exit 255\n#err mux_client_request_session: session request failed: Session open refused by peer\n'
  eq('parse: MaxSessions', err, 'maxsessions')
  _, err = T.parse_remote '#exit 255\n#err channel 1: open failed: administratively prohibited: open failed\n'
  eq('parse: administratively prohibited', err, 'maxsessions')
  _, err = T.parse_remote '#exit 142\n'
  eq('parse: alarm is a timeout', err, 'timeout')
  _, err = T.parse_remote '#exit 255\n#err Connection closed\n'
  eq('parse: other failure', err, 'failed')
  _, err = T.parse_remote '#nomaster\n'
  eq('parse: no master', err, 'nomaster')
  local p = T.parse_remote '#ss\nLISTEN 0 128 127.0.0.1:8888 0.0.0.0:* users:(("jupyter",pid=1,fd=3))\n#exit 0\n'
  eq('parse: ss with trailers', p and p[1] and p[1].port, 8888)
end

-- 7. Group tunnels: same socket joins the pane's host; another host gets
-- its config alias, never the FQDN
do
  wezterm.run_child_process { '/bin/mkdir', '-p', ROOT .. '/ssh-G', wezterm.home_dir .. '/.ssh' }
  local function g(host, user, cp)
    return 'host ' .. host .. '\nhostname ' .. host .. '\nuser ' .. user .. '\nport 22\ncontrolpath ' .. cp .. '\n'
  end
  write(ROOT .. '/ssh-G/gpubox', g('gpubox.example.org', 'me', ROOT .. '/cm-gpubox'))
  write(ROOT .. '/ssh-G/me@gpubox.example.org', g('gpubox.example.org', 'me', ROOT .. '/cm-gpubox'))
  write(ROOT .. '/ssh-G/USER@login-1.HOST.example', g('login-1.HOST.example', 'USER', ROOT .. '/cm-hint'))
  write(ROOT .. '/ssh-G/labhost', g('login-1.HOST.example', 'USER', ROOT .. '/cm-alias'))
  write(wezterm.home_dir .. '/.ssh/config', 'Host labhost\n  HostName login-1.HOST.example\n')
  local hs = { { key = ROOT .. '/cm-gpubox', host = 'gpubox', ssh = { 'ssh-pane', 'gpubox' }, ports = {} } }
  local ts = {
    { ssh = { 'ssh-pane', 'me@gpubox.example.org' }, forwards = { { lport = 1 } } },
    { ssh = { 'ssh-pane', 'USER@login-1.HOST.example' }, forwards = { { lport = 2 } } },
  }
  T.group_tunnels(hs, ts)
  eq('tunnels: FQDN of an open host joins it', ts[1].key, ROOT .. '/cm-gpubox')
  eq('tunnels: other host gets a group', #hs, 2)
  eq('tunnels: named by its alias', hs[2] and hs[2].host, 'labhost')
  eq('tunnels: unlisted', hs[2] and hs[2].err, 'nopane')
  eq('tunnels: keyed to it', ts[2].key, hs[2] and hs[2].key)
end

-- 8. Listings ride the background master when it is live, even while the
-- pane's master refuses sessions (MaxSessions); without it they fail with
-- 'maxsessions'
local LOG = os.getenv 'FAKE_SSH_LOG'
local function log_lines()
  local f = io.open(LOG)
  if not f then return {} end
  local out = {}
  for l in f:lines() do table.insert(out, l) end
  f:close()
  os.remove(LOG)
  return out
end
local function run_job(ssh, path)
  T.start_job(ssh, path)
  local job = T.read_jobs()[path]
  if not job then return nil end
  for _ = 1, 50 do
    local f = io.open(job.out)
    if f then
      local text = f:read 'a'
      f:close()
      os.remove(job.out)
      return text
    end
    wezterm.run_child_process { '/bin/sleep', '0.2' }
  end
end
do
  local SSH = { 'ssh-pane', 'bghost' }
  local BG = wezterm.home_dir .. '/.ssh/cm-wezbg-C' -- the shim expands %C to C
  local PANE_CP = ROOT .. '/cm'
  write(ROOT .. '/ssh-mode', 'sockets refuse')
  write(PANE_CP, '')
  write(BG, '')
  ssh_lib.bg_hosts = { 'bghost' }
  log_lines()
  local text = run_job(SSH, PANE_CP)
  local listing
  for _, l in ipairs(log_lines()) do
    if l:find('sh -s', 1, true) then listing = l end
    check('bg: every call gated', not l:find('ControlMaster=yes', 1, true) and (l:find(' -G ', 1, true)
      or l:find('BatchMode=yes', 1, true)), l)
  end
  check('bg: listing rides the background socket', listing and listing:find('-S ' .. BG .. ' ', 1, true), listing)
  check('bg: gated', listing and listing:find('ControlMaster=no', 1, true) and listing:find('ProxyCommand=false', 1, true))
  local _, err = T.parse_remote(text and text:match '^(.-)#local\n' or text)
  check('bg: not refused', text and err ~= 'maxsessions', tostring(err))
  check('bg: this Mac listed after #local', text and text:find('\n#local\n', 1, true))

  ssh_lib.bg_hosts = {}
  os.remove(BG)
  text = run_job(SSH, PANE_CP)
  for _, l in ipairs(log_lines()) do
    if l:find('sh -s', 1, true) then listing = l end
  end
  check('pane master: listing rides it', listing and listing:find('-S ' .. PANE_CP .. ' ', 1, true), listing)
  _, err = T.parse_remote(text and text:match '^(.-)#local\n' or text)
  eq('pane master: refusal named', err, 'maxsessions')

  -- No live master at all: no job, the reason recorded
  os.remove(PANE_CP)
  log_lines()
  wezterm.GLOBAL.ports_jobs = nil
  T.start_job(SSH, PANE_CP)
  eq('no master: no job', T.read_jobs()[PANE_CP], nil)
  local cache = wezterm.json_parse(wezterm.GLOBAL['ports_cache_' .. PANE_CP] or '{}')
  eq('no master: reason recorded', cache.err, 'nomaster')
  for _, l in ipairs(log_lines()) do
    check('no master: only -G and -O check', l:find(' -G ', 1, true) or l:find('-O check', 1, true), l)
  end
end

-- 9. Naming lines: parsed, and titles cached per port until its pid changes
do
  local info = T.parse_info(table.concat({
    '#home /home/u', '#lp 8888 101', '#cmd 101 python\31-m\31jupyter\31lab\31', '#cwd 101 /home/u/my proj',
    '#lp 6006 202', '#cmd 202 tensorboard\31--logdir\31runs\31', '#cwd 202 /home/u', '#lp 7000 303', '#cwd 303 ',
    '#titles', '#title 8888 101 Swap &amp; Explorer', '#title 6006 202 TensorBoard',
  }, '\n'))
  eq('info: home', info.home, '/home/u')
  eq('info: pid of a port', info.pid[8888], '101')
  eq('info: cmdline kept whole', info.cmd['101'], 'python\31-m\31jupyter\31lab\31')
  eq('info: cwd with spaces', info.cwd['101'], '/home/u/my proj')
  eq('info: empty cwd dropped', info.cwd['303'], nil)
  eq('info: title', info.titles[8888] and info.titles[8888].text, 'Swap &amp; Explorer')
  eq('info: titles asked', info.titled, true)
  local ports = { { port = 6006, name = 'tensorboard', owned = true }, { port = 7000, name = 'node', owned = true },
    { port = 8888, name = 'python', owned = true }, { port = 9000, name = 'other', owned = true } }
  local cache = T.name_ports(ports, info, nil, {})
  eq('name: title and project', ports[3].what .. ' | ' .. ports[3].project, 'Swap & Explorer | my proj')
  eq('name: generic title, home cwd', ports[1].what .. ' | ' .. tostring(ports[1].project), 'TensorBoard · runs | nil')
  eq('name: no cmdline, the process name', ports[2].what, 'node')
  eq('name: no pid, untouched', ports[4].what, nil)
  eq('name: pid recorded', ports[3].pid, 101)
  eq('cache: title kept', cache['8888'] and cache['8888'].title, 'Swap &amp; Explorer')
  eq('cache: no answer kept as empty', cache['7000'] and cache['7000'].title, '')
  eq('cache: no pid, nothing', cache['9000'], nil)
  -- Next poll: titles skipped for known pids (no #title lines), cache used
  local vars = T.title_vars(cache)
  check('vars: known has port:pid', vars:find(' 8888:101 ', 1, true) and vars:find(' 7000:303 ', 1, true), vars)
  check('vars: titles on', vars:find('\ntitles=1\n', 1, true), vars)
  local again = T.parse_info '#home /home/u\n#lp 8888 101\n#cmd 101 python\31-m\31jupyter\31lab\31\n#lp 7000 404\n#titles\n'
  ports = { { port = 8888, name = 'python', owned = true }, { port = 7000, name = 'node', owned = true } }
  cache = T.name_ports(ports, again, nil, cache)
  eq('cache: same pid, title from cache', ports[1].what, 'Swap & Explorer')
  eq('cache: new pid asked again, no answer', cache['7000'] and cache['7000'].pid, '404')
  eq('cache: ports gone dropped', cache['6006'], nil)
  -- Titles off: nothing asked, nothing cached, names still there
  ports[1].what = nil
  local off = T.parse_info '#lp 8888 101\n#cmd 101 python\31-m\31jupyter\31lab\31\n'
  cache = T.name_ports(ports, off, nil, {})
  eq('off: name without a title', ports[1].what, 'Jupyter Lab')
  eq('off: nothing cached', next(cache), nil)
  require('features.ports').fetch_titles = false
  check('off: titles=0', T.title_vars({}):find('\ntitles=0\n', 1, true))
  require('features.ports').fetch_titles = true
end

-- 10. Rows say what a port is; the process name stays in the text, dimmed
do
  local hs = { { key = '/cm/gpubox', host = 'gpubox', ports = {
    { port = 8888, name = 'python', owned = true, what = 'Jupyter Lab', project = 'cswap' },
    { port = 6006, name = 'tensorboard', owned = true, what = 'tensorboard' },
  } } }
  local locs = { { port = 5173, name = 'node', what = 'vite', project = 'web' } }
  local r = T.picker_rows(locs, hs, {}, {})
  local i, jl = find(r, ':8888 +Jupyter Lab · cswap ')
  check('row: name · project', jl, plain(r[3] and r[3].label or ''))
  check('row: process name searchable', jl and plain(jl.label):find('python · forward and open', 1, true))
  check('row: process name dimmed', jl and jl.label:find('\27[90m' .. 'python', 1, true) or
    (jl and jl.label:find('python', jl.label:find('\27[', 1, true), true)), jl and jl.label)
  local _, tb = find(r, ':6006 +tensorboard ')
  check('row: name same as process, said once', tb and not plain(tb.label):find('tensorboard · forward', 1, true),
    tb and plain(tb.label))
  local _, vite = find(r, ':5173 +vite · web ')
  check('row: mac row named too', vite and plain(vite.label):find('node · open', 1, true), vite and plain(vite.label))
  eq('row: ids unchanged', i and r[i].id, 'r1:8888')
end

-- 11. New-port toast
eq('toast: name (project)', T.toast_message('gpubox', { { port = 8888, what = 'Jupyter Lab', project = 'cswap' } }),
  '⇄ gpubox:8888 Jupyter Lab (cswap) started · CMD+SHIFT+I to open')
eq('toast: several, plain name', T.toast_message('gpubox', { { port = 8888, what = 'Jupyter Lab' },
  { port = 9000, name = 'node' }, { port = 9001 } }), '⇄ gpubox:8888 Jupyter Lab, :9000 node, :9001 started · CMD+SHIFT+I to open')

-- 12. REMOTE_SCRIPT itself, in sh and dash, over a fake ss (or /proc/net/tcp
-- and fd links), a fake /proc with real NUL cmdlines and a fake curl
local function sh(script)
  local ok, out, err = wezterm.run_child_process { '/bin/sh', '-c', script }
  return ok, out, err
end
local FAKE = ROOT .. '/fake'
do
  local setup = [=[
set -e
F=$1; rm -rf "$F"; mkdir -p "$F/bin" "$F/proc/net" "$F/proc/101/fd" "$F/proc/202/fd" "$F/proc/303" "$F/home/u/my proj"
cat >"$F/bin/ss" <<'X'
#!/bin/sh
cat "$WZ_PROC/ss.txt"
X
cat >"$F/proc/ss.txt" <<'X'
LISTEN 0 128 127.0.0.1:8888 0.0.0.0:* users:(("python",pid=101,fd=3))
LISTEN 0 128 [::1]:8888 [::]:* users:(("python",pid=101,fd=4))
LISTEN 0 128 0.0.0.0:6006 0.0.0.0:* users:(("tensorboard",pid=202,fd=5))
LISTEN 0 128 0.0.0.0:7000 0.0.0.0:* users:(("node",pid=303,fd=5))
LISTEN 0 128 0.0.0.0:5432 0.0.0.0:* users:(("postgres",pid=303,fd=6))
LISTEN 0 128 0.0.0.0:9999 0.0.0.0:*
X
cat >"$F/bin/curl" <<'X'
#!/bin/sh
for a; do u=$a; done
echo "$u" >>"$WZ_PROC/curl.log"
case $u in
  *:8888/) printf '<html><head>\n<TITLE>Swap &amp; Explorer</TITLE></head><svg><title>x</title></svg>' ;;
  *:6006/) printf '<title>TensorBoard</title>' ;;
  *:7000/) sleep 4 ;;
esac
X
cat >"$F/bin/find" <<'X'
#!/bin/sh
for l in "$WZ_PROC"/[0-9]*/fd/*; do printf '%s %s\n' "${l%/*}" "$(readlink "$l")"; done
X
chmod +x "$F/bin/ss" "$F/bin/curl" "$F/bin/find"
printf 'python3\0-m\0jupyter\0lab\0--no-browser\0' >"$F/proc/101/cmdline"
printf '/env/bin/python\0/env/bin/tensorboard\0--logdir\0runs/exp 1/\0' >"$F/proc/202/cmdline"
printf 'node\0server.js\0' >"$F/proc/303/cmdline"
ln -s "$F/home/u/my proj" "$F/proc/101/cwd"
ln -s "$F/home/u" "$F/proc/202/cwd"
echo python >"$F/proc/101/comm"; echo tensorboard >"$F/proc/202/comm"
me=$(id -u)
printf '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n' >"$F/proc/net/tcp"
printf '   0: 0100007F:22B8 00000000:0000 0A 00000000:00000000 00:00000000 00000000 %s 0 55501 1 0 100 0 0 10 0\n' "$me" >>"$F/proc/net/tcp"
printf '   1: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000 %s 0 66601 1 0 100 0 0 10 0\n' 99999 >>"$F/proc/net/tcp"
printf '   0: 00000000000000000000000000000000:178E 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000 %s 0 55502 1 0 100 0 0 10 0\n' "$me" >"$F/proc/net/tcp6"
ln -s 'socket:[55501]' "$F/proc/101/fd/3"
ln -s 'socket:[55502]' "$F/proc/202/fd/5"
]=]
  local f = assert(io.open(ROOT .. '/setup.sh', 'w'))
  f:write(setup)
  f:close()
  local ok, _, err = sh('/bin/sh ' .. ROOT .. '/setup.sh ' .. FAKE)
  check('fake: set up', ok, err)
end
local function run_remote(shell, vars, no_ss)
  write(ROOT .. '/remote.sh', vars .. T.REMOTE_SCRIPT)
  os.remove(FAKE .. '/proc/curl.log')
  local bin = FAKE .. '/bin'
  if no_ss then
    sh('mkdir -p ' .. FAKE .. '/bin2 && cp ' .. bin .. '/curl ' .. bin .. '/find ' .. FAKE .. '/bin2/')
    bin = FAKE .. '/bin2'
  end
  local t0 = os.time()
  local _, out = sh('cd / && HOME=' .. FAKE .. '/home/u WZ_PROC=' .. FAKE .. '/proc PATH=' .. bin
    .. ':/usr/bin:/bin ' .. shell .. ' -s <' .. ROOT .. '/remote.sh')
  local f = io.open(FAKE .. '/proc/curl.log')
  local log = f and f:read 'a' or ''
  if f then f:close() end
  return out, log, os.time() - t0
end
for _, shell in ipairs { '/bin/sh', '/bin/dash' } do
  local out, log, secs = run_remote(shell, T.title_vars {})
  local ports = T.parse_remote(out)
  check(shell .. ': listed', ports and #ports == 5, out)
  local cache = T.name_ports(ports or {}, T.parse_info(out), nil, {})
  local by = {}
  for _, p in ipairs(ports or {}) do by[p.port] = p end
  eq(shell .. ': title and project', by[8888] and names_row(by[8888]), 'Swap & Explorer · my proj')
  eq(shell .. ': NUL argv, spaces, home cwd', by[6006] and names_row(by[6006]), 'TensorBoard · exp 1')
  eq(shell .. ': slow page, script name', by[7000] and names_row(by[7000]), 'server.js')
  eq(shell .. ': other user\'s port unnamed', by[9999] and by[9999].what, nil)
  check(shell .. ': postgres port never asked', not log:find(':5432/', 1, true), log)
  check(shell .. ': capped near 2 s', secs <= 4, secs)
  eq(shell .. ': slow page cached as none', cache['7000'] and cache['7000'].title, '')
  -- Next poll: nothing asked again
  out, log = run_remote(shell, T.title_vars(cache))
  eq(shell .. ': known pids not asked again', log, '')
  ports = T.parse_remote(out)
  T.name_ports(ports, T.parse_info(out), nil, cache)
  eq(shell .. ': title from cache', ports[4] and ports[4].port == 8888 and ports[4].what, 'Swap & Explorer')
  -- Titles off: no curl at all
  out, log = run_remote(shell, 'known=\ntitles=0\n')
  eq(shell .. ': titles off, no requests', log, '')
  check(shell .. ': titles off, no marker', not out:find('#titles', 1, true), out)
  -- /proc/net/tcp fallback: ports from tcp and tcp6, pids from fd links
  out = run_remote(shell, 'known=\ntitles=0\n', true)
  ports = T.parse_remote(out)
  check(shell .. ': proc listing', ports and #ports == 3, out)
  if ports then T.name_ports(ports, T.parse_info(out), nil, {}) end
  by = {}
  for _, p in ipairs(ports or {}) do by[p.port] = p end
  eq(shell .. ': proc names 8888', by[8888] and names_row(by[8888]), 'Jupyter Lab · my proj')
  eq(shell .. ': proc names 6030 (tcp6)', by[6030] and names_row(by[6030]), 'TensorBoard · exp 1')
  eq(shell .. ': proc, another uid unnamed', by[8080] and tostring(by[8080].what) .. ' ' .. tostring(by[8080].owned),
    'nil false')
end

-- 13. LOCAL_SCRIPT on this Mac: a real process's args and cwd
do
  wezterm.run_child_process { '/bin/mkdir', '-p', ROOT .. '/my web' }
  write(ROOT .. '/local.sh', 'known=\ntitles=0\n' .. T.LOCAL_SCRIPT)
  local ok, out = sh('cd ' .. core.sh_quote(ROOT .. '/my web') .. ' && { /bin/sleep 7 & p=$!; } && pairs="5173 $p" pids=$p '
    .. '/bin/sh ' .. ROOT .. '/local.sh; kill $p; echo "#pid $p"')
  local pid = out and out:match '#pid (%d+)'
  local info = T.parse_info(out)
  check('local: ran', ok and pid, out)
  check('local: args', pid and info.cmd[pid] and info.cmd[pid]:find('^/bin/sleep 7'), out)
  eq('local: cwd', pid and info.cwd[pid] and info.cwd[pid]:gsub('^/private', ''), (ROOT .. '/my web'):gsub('^/private', ''))
end

io.stderr:write('RESULT ', passed, ' passed, ', failed, ' failed\n')
return {}
