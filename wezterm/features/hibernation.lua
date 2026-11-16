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
-- CPU share of the process tree above which it is busy: measured, an idle
-- claude uses 0.6-0.7%, one whose subagents work 2-7%
local HIB_CPU = 0.015
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

return M
