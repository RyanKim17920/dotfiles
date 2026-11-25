-- Tests for WezTerm's background ssh master (lib/ssh.lua bg_*): routing,
-- the Duo guard, the start command, its rate limit and the fallback to the
-- pane's own master. Run tests/run.sh: like paths_test.lua it runs under a
-- fake HOME with the fake ssh (tests/shims/ssh) first in PATH.
local wezterm = require 'wezterm'
local ROOT, SHIMS = os.getenv 'WZT_ROOT', os.getenv 'WZT_SHIMS'
package.path = os.getenv 'WZT_SRC' .. '/?.lua;' .. package.path
assert(ROOT and SHIMS, 'run this through tests/run.sh')
assert(wezterm.home_dir:match '^/tmp/wz', 'HOME must be a fake /tmp/wz* one')
local core = require 'lib.core'
core.SPAWN_PATH = SHIMS .. ':' .. core.SPAWN_PATH
local ssh_lib = require 'lib.ssh'
local paths = require 'lib.paths'

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
local function write(path, text)
  local f = assert(io.open(path, 'w'))
  f:write(text)
  f:close()
end
local function mode(m) write(ROOT .. '/ssh-mode', m) end
local function exists(path)
  local f = io.open(path)
  if f then f:close() end
  return f ~= nil
end
local function sleep() wezterm.run_child_process { '/bin/sleep', '0.2' } end
-- Waits up to 4 s for `path` to exist
local function wait_for(path)
  for _ = 1, 20 do
    if exists(path) then return true end
    sleep()
  end
  return false
end
local function starts(lines)
  local n = 0
  for _, l in ipairs(lines) do
    if l:find('ControlMaster=yes', 1, true) then n = n + 1 end
  end
  return n
end
local function joined(t) return table.concat(t, ' ') end

local HOST = 'fakehost'
local SSH = { 'ssh-pane', '-p', '2222', 'user@' .. HOST }
local BG = wezterm.home_dir .. '/.ssh/cm-wezbg-C' -- the shim expands %C to C
local STATE = wezterm.home_dir .. '/.local/state/wezterm/ssh-bg/' .. HOST
local LAST_KEY = 'ssh_bg_last_' .. HOST
wezterm.run_child_process { '/bin/mkdir', '-p', ROOT .. '/ssh-G', wezterm.home_dir .. '/.ssh' }
write(ROOT .. '/cm', '') -- the pane's own master is live (sockets mode)

-- 1. The start command: key auth only, its own socket, everything as -o
do
  local cmd = joined(ssh_lib._test.bg_start_cmd(SSH))
  check('start: BatchMode=yes', cmd:find('-o BatchMode=yes', 1, true) ~= nil, cmd)
  check('start: its own ControlPath', cmd:find('-o ControlPath=' .. ssh_lib.BG_CP, 1, true) ~= nil, cmd)
  check('start: ControlMaster=yes, backgrounded', cmd:find('-o ControlMaster=yes', 1, true) ~= nil
    and cmd:find('-fN', 1, true) ~= nil, cmd)
  check('start: ControlPersist=4h', cmd:find('-o ControlPersist=4h', 1, true) ~= nil, cmd)
  check('start: never askpass', cmd:find('SSH_ASKPASS_REQUIRE=never', 1, true) ~= nil, cmd)
  check('start: the pane\'s destination last', cmd:match '(%S+)$' == 'user@' .. HOST, cmd)
end

-- 2. A host not in the list: nothing changes, nothing starts
do
  mode 'sockets bgstart'
  ssh_lib.bg_hosts = {}
  local cmd = joined(ssh_lib.ssh_batch_cmd(SSH))
  check('unlisted: no background socket', not cmd:find('wezbg', 1, true), cmd)
  local lines = log_lines()
  check('unlisted: no start, no check', #lines == 0, joined(lines))
end

-- 3. Listed, not live yet: fall back to the pane's master, start once,
-- record the failure, rate-limit the next start
do
  mode 'sockets'
  ssh_lib.bg_hosts = { HOST }
  local cmd = joined(ssh_lib.ssh_batch_cmd(SSH))
  check('fallback: rides the pane\'s master', not cmd:find('wezbg', 1, true)
    and cmd:find('ProxyCommand=false', 1, true) ~= nil, cmd)
  check('fallback: failure recorded', wait_for(STATE))
  local f = io.open(STATE)
  local count = f and f:read '*l'
  if f then f:close() end
  check('fallback: failure count 1', count == '1', count)
  local lines = log_lines()
  check('fallback: one start', starts(lines) == 1, joined(lines))
  for _, l in ipairs(lines) do
    if l:find('ControlMaster=yes', 1, true) then
      check('fallback: start has BatchMode=yes', l:find('-o BatchMode=yes', 1, true) ~= nil, l)
    end
  end
  ssh_lib.ssh_batch_cmd(SSH)
  ssh_lib.ssh_batch_cmd(SSH)
  check('rate limit: no second start within 60 s', starts(log_lines()) == 0)
  -- One failure doubles the wait to 120 s
  wezterm.GLOBAL[LAST_KEY] = os.time() - 90
  ssh_lib.ssh_batch_cmd(SSH)
  check('rate limit: backs off after a failure', starts(log_lines()) == 0)
  wezterm.GLOBAL[LAST_KEY] = os.time() - 130
  mode 'sockets bgstart'
  ssh_lib.ssh_batch_cmd(SSH)
  check('rate limit: retries after the back-off', wait_for(BG))
  check('rate limit: success clears the failure', (function()
    for _ = 1, 20 do
      if not exists(STATE) then return true end
      sleep()
    end
  end)())
  check('rate limit: exactly one retry', starts(log_lines()) == 1)
end

-- 4. Live: remote commands ride it, even while the pane's master refuses
-- sessions (MaxSessions); every call stays gated
do
  mode 'sockets refuse'
  local cmd = joined(ssh_lib.ssh_batch_cmd(SSH))
  check('routing: batch rides -S background socket', cmd:find('-S ' .. BG, 1, true) ~= nil, cmd)
  check('routing: batch stays gated', cmd:find('-o BatchMode=yes -o ControlMaster=no -o ProxyCommand=false', 1, true)
    ~= nil, cmd)
  log_lines()
  local kind, path = paths.resolve_remote(SSH, { '/etc' }, nil, {})
  check('routing: path check works while the pane\'s master is full', kind == 'd'
    and path:gsub('^/private', '') == '/etc', tostring(path))
  local runs = 0
  for _, l in ipairs(log_lines()) do
    if not l:find(' -G ', 1, true) and not l:find('-O check', 1, true) then
      runs = runs + 1
      check('routing: path run gated on the background socket',
        l:find('-o BatchMode=yes -o ControlMaster=no -o ProxyCommand=false -S ' .. BG, 1, true) ~= nil, l)
    end
    check('routing: no new master', not l:find('ControlMaster=yes', 1, true), l)
  end
  check('routing: one path run', runs == 1, runs)
  local gated, pid = ssh_lib.command_master(SSH)
  check('routing: command_master picks the background master', gated and joined(gated):find('-S ' .. BG, 1, true)
    ~= nil and pid == '4242', gated and joined(gated))
  log_lines()
end

-- 5. Background master gone, pane's master full: the refusal is named
do
  os.remove(BG)
  wezterm.GLOBAL[LAST_KEY] = os.time() -- no start during this check
  mode 'sockets refuse'
  local _, msg = paths.resolve_remote(SSH, { '/etc' }, nil, {})
  check('fallback: refusal names MaxSessions', (msg or ''):find('MaxSessions', 1, true) ~= nil, msg)
  check('fallback: refusal says the own connection is coming', (msg or ''):find('starting', 1, true) ~= nil, msg)
  check('refusal note: generic without a host', (ssh_lib.refusal_note(
    'mux_client_request_session: session request failed: Session open refused by peer') or ''):find(
    'MaxSessions', 1, true) ~= nil)
  check('refusal note: other errors untouched', ssh_lib.refusal_note 'Connection refused' == nil)
  log_lines()
end

-- 6. The Duo guard: listed or not, these never get a start or a socket
do
  mode 'sockets bgstart'
  write(ROOT .. '/ssh-G/delta', 'hostname login.example.org\nuser me\n')
  write(ROOT .. '/ssh-G/hpc', 'hostname login03.delta.example.org\nuser me\n')
  write(ROOT .. '/ssh-G/kbd', 'hostname kbd.example.org\npreferredauthentications keyboard-interactive,password\n')
  ssh_lib.bg_hosts = { 'delta', 'hpc', 'kbd' }
  for _, h in ipairs { 'delta', 'hpc', 'kbd' } do
    local cmd = joined(ssh_lib.ssh_batch_cmd { 'ssh-pane', h })
    check('guard: ' .. h .. ' rides only the pane\'s master', not cmd:find('wezbg', 1, true), cmd)
    local _, msg = paths.resolve_remote({ 'ssh-pane', h }, { '/etc' }, nil, {})
    check('guard: ' .. h .. ' gated run', msg == nil or msg:find('starting', 1, true) == nil, msg)
  end
  sleep()
  local lines = log_lines()
  check('guard: no start for any of them', starts(lines) == 0, joined(lines))
  for _, l in ipairs(lines) do
    check('guard: never touches a background socket', not l:find('-S ' .. wezterm.home_dir .. '/.ssh/cm-wezbg', 1, true), l)
  end
end

io.stderr:write(string.format('RESULT %d passed, %d failed\n', passed, failed))
return {}
