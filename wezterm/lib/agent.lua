-- Agent CLI panes and the state dir, shared by session restore and
-- hibernation: small file helpers, what a pane's process is (an idle shell,
-- claude), its session id, the login-shell wrapper restored panes run in, and
-- the session of a hibernated pane.
local wezterm = require 'wezterm'
local core = require 'lib.core'
local sh_quote = core.sh_quote

local STATE_DIR = wezterm.home_dir .. '/.local/state/wezterm'
-- Claude Code session id per pane, written by bin/wez-claude-session (a
-- SessionStart hook) as <WEZTERM_PANE>: line 1 id, line 2 cwd
local CLAUDE_DIR = STATE_DIR .. '/claude'

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

local function base(path) return (path or ''):match '[^/]*$' end

local function set_of(words)
  local set = {}
  for w in words:gmatch '%S+' do set[w] = true end
  return set
end

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

-- Agent CLIs (claude, codex, opencode; also run as `node <cli>`), whose
-- cwd is what the relative paths they print are under (features/paths.lua)
local AGENTS = set_of 'claude codex opencode'
local function is_agent(info)
  local argv = info.argv or {}
  local name = base(argv[1])
  if name == 'node' or name == 'bun' then name = (base(argv[2]):gsub('%.[cm]?js$', '')) end
  return AGENTS[name] == true or AGENTS[base(info.executable)] == true or is_claude(info)
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

local RESTORE_SHELL = os.getenv 'SHELL' or '/bin/zsh'

-- Run `cmd` in the login shell (right PATH and env) from `cwd`, and stay in
-- that shell when it exits. cd here rather than via the spawn's cwd: on
-- 20240203 a split or new tab with `args` ignores `cwd`.
local function shell_args(cmd, cwd)
  local cd = cwd and ('cd ' .. sh_quote(cwd) .. ' && ') or ''
  return { RESTORE_SHELL, '-lic', cd .. cmd .. '; exec ' .. sh_quote(RESTORE_SHELL) .. ' -l' }
end

local function hib_json(key)
  local ok, v = pcall(wezterm.json_parse, wezterm.GLOBAL[key] or '{}')
  return ok and type(v) == 'table' and v or {}
end

local function hib_store(key, v)
  wezterm.GLOBAL[key] = next(v) and wezterm.json_encode(v) or nil
end

-- A pane's hibernated session: from its stop in progress, or the command
-- line of its wake screen (`[python3] .../wez-hibernate --id <id> --cwd <dir> ...`)
local function hibernated_session(pane_id, info)
  local job = hib_json('hib_jobs')[tostring(pane_id)]
  if job then return job.id, job.cwd end
  local argv = info and info.argv or {}
  for i = 1, math.min(2, #argv) do
    if base(argv[i]) == 'wez-hibernate' and argv[i + 1] == '--id' and (argv[i + 2] or ''):match '^[%w_-]+$' then
      return argv[i + 2], argv[i + 3] == '--cwd' and argv[i + 4] or info.cwd
    end
  end
end
return {
  STATE_DIR = STATE_DIR, CLAUDE_DIR = CLAUDE_DIR, read_file = read_file, write_atomic = write_atomic,
  glob_quote = glob_quote, present = present, base = base, set_of = set_of, SHELLS = SHELLS,
  is_idle_shell = is_idle_shell, is_claude = is_claude, is_agent = is_agent, claude_session = claude_session,
  RESTORE_SHELL = RESTORE_SHELL, shell_args = shell_args, hib_json = hib_json, hib_store = hib_store,
  hibernated_session = hibernated_session,
}
