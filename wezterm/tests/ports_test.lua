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

io.stderr:write('RESULT ', passed, ' passed, ', failed, ' failed\n')
return {}
