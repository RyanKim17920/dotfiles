-- Tests for `ssh -L` tunnel commands on screen (features/port_forward.lua,
-- the CMD+SHIFT+I rows in features/ports.lua). Run tests/run.sh; like
-- paths_test.lua it loads as a WezTerm config under a fake HOME with the fake
-- ssh (tests/shims/ssh) first, so nothing ever connects. Hosts, users and
-- tokens here are placeholders.
local wezterm = require 'wezterm'
local ROOT, SHIMS = os.getenv 'WZT_ROOT', os.getenv 'WZT_SHIMS'
package.path = os.getenv 'WZT_SRC' .. '/?.lua;' .. package.path
assert(ROOT and SHIMS, 'run this through tests/run.sh')
local core = require 'lib.core'
core.SPAWN_PATH = SHIMS .. ':' .. core.SPAWN_PATH
local ssh_lib = require 'lib.ssh'
local pf = require 'features.port_forward'
local ports = require 'features.ports'
local T = pf._test
local SSH_PANE = ssh_lib.SSH_PANE

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
local function split(text)
  local lines = {}
  for line in (text .. '\n'):gmatch '([^\n]*)\n' do table.insert(lines, line) end
  return lines
end
local function write(path, text)
  local f = assert(io.open(path, 'w'))
  f:write(text)
  f:close()
end
local function specs(forwards)
  local out = {}
  for _, f in ipairs(forwards or {}) do table.insert(out, f.lport .. ':' .. f.host .. ':' .. f.rport) end
  return table.concat(out, ' ')
end

-- The line a remote web UI printed (placeholders for user, host, token)
local URL = 'http://localhost:8766/#otc=TOKEN_x-9'
local LINE = "ssh -fN -L 8766:localhost:8766 USER@login-1.HOST.example && (open '" .. URL
  .. "' 2>/dev/null || xdg-open '" .. URL .. "')"

-- 1. Parsing the exact line
do
  local tunnels, _, urls = T.hints_from_lines { 'some output', LINE, '' }
  eq('line: one tunnel', #tunnels, 1)
  local t = tunnels[1] or {}
  eq('line: destination', t.ssh and t.ssh[#t.ssh], 'USER@login-1.HOST.example')
  eq('line: only the destination is kept', t.ssh and #t.ssh, 2)
  eq('line: forward', specs(t.forwards), '8766:localhost:8766')
  eq('line: its own URL, fragment whole', t.url and t.url.rest, '/#otc=TOKEN_x-9')
  eq('line: URL port', t.url and t.url.rport, 8766)
  eq('line: both URLs seen, no quote or paren taken', #urls == 2 and urls[2].rest, '/#otc=TOKEN_x-9')
  -- The same with a prompt and indent in front (an agent's answer)
  tunnels = T.hints_from_lines { '  ' .. LINE }
  eq('line: indented', tunnels[1] and specs(tunnels[1].forwards), '8766:localhost:8766')
end

-- 2. Flag shapes
for _, c in ipairs {
  { 'ssh -fN -L 8766:localhost:8766 me@h', '8766:localhost:8766', 'me@h' },
  { 'ssh -NfL 8766:localhost:8766 me@h', '8766:localhost:8766', 'me@h' },
  { 'ssh -NfL8766:localhost:8766 me@h', '8766:localhost:8766', 'me@h' },
  { 'ssh -N -L 8766:localhost:8766 -L 6006:node-1:6006 me@h', '8766:localhost:8766 6006:node-1:6006', 'me@h' },
  { 'ssh -L 127.0.0.1:8766:localhost:8766 -fN me@h', '8766:localhost:8766', 'me@h' },
  { 'ssh -L [::1]:8766:127.0.0.1:8766 me@h', '8766:127.0.0.1:8766', 'me@h' },
  { 'ssh -fN -p 2222 -L 8766:localhost:8766 me@h', '8766:localhost:8766', 'me@h' },
  { 'ssh me@h -N -L 8766:localhost:8766', '8766:localhost:8766', 'me@h' },
} do
  local ssh, forwards = T.parse_ssh_text(c[1])
  eq('flags: ' .. c[1], specs(forwards), c[2])
  eq('flags dest: ' .. c[1], ssh and ssh[#ssh], c[3])
end
check('flags: -fN keeps -p', table.concat(T.parse_ssh_text 'ssh -fN -p 2222 -L 1:a:1 me@h', ' '):find('-p 2222', 1, true))
check('flags: -L without a spec is no tunnel', T.parse_ssh_text 'the ssh -fN -L … part opens a tunnel' == nil)
check('flags: no -L is no tunnel', T.parse_ssh_text 'ssh -fN me@h' == nil)

-- 3. Clicked URLs: a link rule may take in the closing quote and paren
for _, u in ipairs { URL, URL .. "'", URL .. "')", URL .. '")', URL .. ')' } do
  eq('url: ' .. u:sub(#URL + 1), (T.parse_loopback_url(u) or {}).rest, '/#otc=TOKEN_x-9')
end
eq('url: balanced parens stay', T.parse_loopback_url('http://localhost:80/a_(b)').rest, '/a_(b)')
eq('url: 127.0.0.1', T.parse_loopback_url('http://127.0.0.1:8766/?token=abc').rest, '/?token=abc')

-- 4. Wrapped variants. Soft wraps reach us as one logical line; hard wraps
-- (an agent's TUI breaking lines itself, continuation indented) are joined.
do
  local soft = T.hints_from_lines { LINE }
  eq('soft wrap: one logical line', soft[1] and soft[1].url and soft[1].url.rest, '/#otc=TOKEN_x-9')
  -- Break before the destination
  local t = T.hints_from_lines(split("  ssh -fN -L 8766:localhost:8766\n  USER@login-1.HOST.example && (open\n  '"
    .. URL .. "' 2>/dev/null || xdg-open\n  '" .. URL .. "')"))
  eq('hard wrap: destination on the next line', t[1] and t[1].ssh[2], 'USER@login-1.HOST.example')
  eq('hard wrap: URL still found', t[1] and t[1].url and t[1].url.rest, '/#otc=TOKEN_x-9')
  -- The token split mid-word inside its quotes
  t = T.hints_from_lines(split("  ssh -fN -L 8766:localhost:8766 USER@login-1.HOST.example && (open 'http://localhost:8766/#otc=TOK\n"
    .. "  EN_x-9' 2>/dev/null || xdg-open 'http://localhost:8766/#otc=TOKEN_x-9')"))
  eq('hard wrap: token split mid-word is rejoined', t[1] and t[1].url and t[1].url.rest, '/#otc=TOKEN_x-9')
  -- -L at a line end, its spec on the next
  t = T.hints_from_lines(split '  ssh -fN -L\n  8766:localhost:8766 me@h')
  eq('hard wrap: -L spec on the next line', t[1] and specs(t[1].forwards), '8766:localhost:8766')
  -- Prose after a finished command is not joined in
  local _, _, urls = T.hints_from_lines(split '  ssh -N -L 8766:localhost:8766 me@h\n  then open http://localhost:8766/x')
  eq('hard wrap: whole command left alone', #urls, 1)
  -- A blank line ends a command
  t = T.hints_from_lines(split '  ssh -fN -L 8766:localhost:8766\n\n  me@h')
  eq('hard wrap: stops at a blank line', #t, 0)
end

-- Fake ssh config: an alias whose HostName is the FQDN the line names, one
-- with the same host but another user, and the hint's own resolution. Only
-- the alias's ControlPath (cm-alias) has a live master.
local HOME = os.getenv 'HOME'
os.execute('mkdir -p ' .. HOME .. '/.ssh ' .. ROOT .. '/ssh-G')
write(HOME .. '/.ssh/config', 'Host other\n  HostName login-1.HOST.example\n  User someone\n'
  .. 'Host labhost\n  HostName login-1.HOST.example\n  User USER\nHost *\n  ControlPath ~/.ssh/cm-%C\n')
local function g(host, user, cp)
  return 'host ' .. host .. '\nhostname ' .. host .. '\nuser ' .. user .. '\nport 22\ncontrolpath ' .. cp .. '\n'
end
write(ROOT .. '/ssh-G/USER@login-1.HOST.example', g('login-1.HOST.example', 'USER', ROOT .. '/cm-hint'))
write(ROOT .. '/ssh-G/login-1.HOST.example', g('login-1.HOST.example', 'me', ROOT .. '/cm-hint2'))
write(ROOT .. '/ssh-G/labhost', g('login-1.HOST.example', 'USER', ROOT .. '/cm-alias'))
write(ROOT .. '/ssh-G/other', g('login-1.HOST.example', 'someone', ROOT .. '/cm-other'))
write(ROOT .. '/ssh-mode', 'sockets refuse') -- live masters, but sshd refuses new sessions
write(ROOT .. '/cm-alias', '')
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
local GATE = '-o BatchMode=yes -o ControlMaster=no -o ProxyCommand=false -S '

-- 5. user@FQDN maps to the alias by ssh -G hostname and user
do
  log_lines()
  local master, pid = T.find_master { SSH_PANE, 'USER@login-1.HOST.example' }
  eq('master: alias with the same hostname and user', master and master[#master], 'labhost')
  eq('master: pid from -O check', pid, '4242')
  check('master: gated on the alias socket', master and table.concat(master, ' '):find(GATE .. ROOT .. '/cm-alias', 1, true),
    master and table.concat(master, ' '))
  for _, l in ipairs(log_lines()) do
    check('master: only -G and gated -O check', l:find(' -G ', 1, true)
      or (l:find('-O check', 1, true) and l:find('BatchMode=yes', 1, true) and l:find(' -S ', 1, true)), l)
  end
  -- A named user never borrows another user's master
  write(ROOT .. '/cm-other', '')
  os.remove(ROOT .. '/cm-alias')
  eq('master: other user not used for user@host', T.find_master { SSH_PANE, 'USER@login-1.HOST.example' }, nil)
  -- No user named: an alias for that host stands in
  local m2 = T.find_master { SSH_PANE, 'login-1.HOST.example' }
  check('master: no user named, any alias for the host', m2 ~= nil)
  os.remove(ROOT .. '/cm-other')
  write(ROOT .. '/cm-alias', '')
  log_lines()
end

-- Fake window and pane
local function fake_window()
  local w = { toasts = {} }
  function w:toast_notification(_, msg) table.insert(self.toasts, msg) end
  function w:set_right_status() end
  function w:mux_window() error 'no mux window in tests' end
  return w
end
local function fake_pane(text, id)
  return {
    get_logical_lines_as_text = function() return text end,
    pane_id = function() return id or 1 end,
  }
end
local opened = {}
wezterm.open_with = function(u) table.insert(opened, u) end

-- 6. Picking the line: forward over the alias's master, open the URL as
-- printed; no login, no session (sshd refuses them), the printed ssh -fN
-- never run
do
  local w, pane = fake_window(), fake_pane('$ claude\n' .. LINE .. '\n')
  local list = pf.screen_tunnels(w, pane)
  eq('screen: tunnel listed', #list, 1)
  eq('screen: label', list[1] and ports._test.tunnel_label(list[1]), '⇄ :8766 (from screen: open with token)')
  local choices = ports._test.picker_choices(nil, {}, {}, list)
  eq('picker: first row is the tunnel', choices[1] and choices[1].label, '⇄ :8766 (from screen: open with token)')
  eq('picker: its id', choices[1] and choices[1].id, 's1')
  log_lines()
  opened = {}
  local t = list[1]
  pf.forward_tunnel(w, t.pane, t.ssh, t.forwards, t.url)
  local fwd, lport
  for _, l in ipairs(log_lines()) do
    check('pick: master operations only, never a session or -fN',
      (l:find(' -G ', 1, true) or l:find(' -O ', 1, true)) and not l:find('-fN', 1, true), l)
    if l:find('-O forward', 1, true) then
      fwd = l
      lport = l:match '%-L (%d+):localhost:8766 '
    end
    if l:find(' -O ', 1, true) then check('pick: -O gated', l:find(GATE, 1, true), l) end
    if l:find(' -O forward ', 1, true) then
      check('pick: -O forward on the live socket', l:find(GATE .. ROOT .. '/cm-alias', 1, true), l)
    end
  end
  check('pick: -O forward on the alias master', fwd and fwd:find(' labhost ', 1, true), fwd)
  eq('pick: opened the URL as printed', opened[1], lport and ('http://localhost:' .. lport .. '/#otc=TOKEN_x-9'))
  eq('pick: one open', #opened, 1)
  check('pick: toast names the forward', (w.toasts[1] or ''):find('Forward: localhost:' .. tostring(lport), 1, true), w.toasts[1])
  check('pick: toast never shows the token', not (w.toasts[1] or ''):find('TOKEN', 1, true), w.toasts[1])
end

-- 7. CMD+click on the first line of a hard-wrapped command
do
  local w = fake_window()
  local pane = fake_pane('  ssh -fN -L 8766:localhost:8766\n  USER@login-1.HOST.example && (open\n  \'' .. URL .. "')\n")
  opened = {}
  T.forward_command(w, pane, 'ssh -fN -L 8766:localhost:8766')
  check('click: wrapped command forwarded', (w.toasts[1] or ''):find('Forward: localhost:', 1, true), w.toasts[1])
  check('click: wrapped command opens its URL', (opened[1] or ''):find('/#otc=TOKEN_x-9', 1, true), opened[1])
  log_lines()
end

-- 8. No live master: a toast, nothing else
do
  os.remove(ROOT .. '/cm-alias')
  local w = fake_window()
  opened = {}
  log_lines()
  local list = pf.screen_tunnels(w, fake_pane(LINE))
  pf.forward_tunnel(w, list[1].pane, list[1].ssh, list[1].forwards, list[1].url)
  check('no master: toast says so', (w.toasts[1] or ''):find('no live ssh connection', 1, true), w.toasts[1])
  eq('no master: nothing opened', #opened, 0)
  for _, l in ipairs(log_lines()) do
    check('no master: no forward, no session', l:find(' -G ', 1, true) or l:find('-O check', 1, true), l)
  end
end

-- 9. Labels and helpers
do
  local function label(text)
    local list = pf.screen_tunnels(fake_window(), fake_pane(text))
    return list[1] and ports._test.tunnel_label(list[1])
  end
  eq('label: no URL', label 'ssh -N -L 8888:localhost:8888 me@h', '⇄ :8888 (from screen: forward and open)')
  eq('label: URL without token', label 'ssh -N -L 8888:localhost:8888 me@h && open http://localhost:8888/lab',
    '⇄ :8888 (from screen: open /lab)')
  eq('label: two forwards', label 'ssh -N -L 8888:localhost:8888 -L 6006:localhost:6006 me@h',
    '⇄ :8888, :6006 (from screen: forward and open)')
  eq('screen: same command twice is one row', #pf.screen_tunnels(fake_window(), fake_pane(LINE .. '\n' .. LINE)), 1)
  check('target: localhost is 127.0.0.1', T.same_target('localhost', '127.0.0.1'))
  check('target: node differs', not T.same_target('localhost', 'node-1'))
  local gated = table.concat(ssh_lib.gated_args({ SSH_PANE, '-J', 'jump', '-p', '22', 'h' }, '/cm'), ' ')
  check('gated: -J dropped, -S first', not gated:find('-J', 1, true) and gated:find(GATE .. '/cm -p 22 h', 1, true), gated)
end

io.stderr:write(string.format('RESULT %d passed, %d failed\n', passed, failed))
return {}
