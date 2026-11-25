-- Tests for clicked-path resolution (lib/paths.lua). Run tests/run.sh; it
-- loads this file as a WezTerm config (`wezterm ls-fonts`) under a fake
-- HOME, with a fake ssh first in PATH and a fixture tree in $WZT_ROOT, and
-- reads the PASS/FAIL lines it writes to stderr.
local wezterm = require 'wezterm'
local ROOT, SHIMS = os.getenv 'WZT_ROOT', os.getenv 'WZT_SHIMS'
package.path = os.getenv 'WZT_SRC' .. '/?.lua;' .. package.path
assert(ROOT and SHIMS, 'run this through tests/run.sh')
-- The fake ssh must win over /opt/homebrew/bin/ssh: patch core before
-- lib.ssh and lib.paths copy SPAWN_PATH
local core = require 'lib.core'
core.SPAWN_PATH = SHIMS .. ':' .. core.SPAWN_PATH
local paths = require 'lib.paths'
local agent = require 'lib.agent'

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

-- What open_path does with the candidates: the first that exists (in the
-- fake file system `fs`, a set of absolute paths), the clicked text last
local function pick(lines, text, fs)
  local cands = paths.line_candidates(lines, text)
  table.insert(cands, text)
  for _, c in ipairs(cands) do
    if fs[c] then return c end
  end
end
local function has(list, want)
  for _, v in ipairs(list) do
    if v == want then return true end
  end
  return false
end

-- 1. The screenshot: a Claude Code answer hard-wrapped mid-word, each
-- continuation indented, prose after an em dash (user name replaced)
local SHOT = split(table.concat({
  '  Screenshots, using Classification F1 against Segmentation F1:',
  '  /tmp/claude-1000/-home-user-pr',
  '  oj/1673a7e7-252a-4127-a63b-ab96a4c3',
  '  2fc2/scratchpad/shot/pareto.png — runs',
  '  only. 2 of 72 are on the front:',
  '  sl25m-focal-19 (0.7593, 0.6186) and',
}, '\n'))
local PARETO = '/tmp/claude-1000/-home-user-proj/1673a7e7-252a-4127-a63b-ab96a4c32fc2/scratchpad/shot/pareto.png'
local FS = { [PARETO] = true, ['/tmp/claude-1000'] = true }
for _, piece in ipairs { '/tmp/claude-1000/-home-user-pr', 'oj/1673a7e7-252a-4127-a63b-ab96a4c3',
  '2fc2/scratchpad/shot/pareto.png' } do
  eq('screenshot: click ' .. piece, pick(SHOT, piece, FS), PARETO)
end
do
  local cands = paths.line_candidates(SHOT, '2fc2/scratchpad/shot/pareto.png')
  local prose = false
  for _, c in ipairs(cands) do
    if c:find('—', 1, true) or c:find('runs', 1, true) or c:find('F1', 1, true) then prose = true end
  end
  check('screenshot: no em-dash prose or text past a colon in candidates', not prose)
  check('screenshot: few candidates', #cands <= 20, #cands)
end

-- 2. The same answer as the real pane showed it (hyphen breaks, two paths
-- whose first lines are identical): WezTerm 20240203 gives no click
-- position, so a piece is looked up bottom first
local TWO = split(table.concat({
  '  - /tmp/claude-1000/-home-user-proj/1673a7e7-',
  '    252a-4127-a63b-ab96a4c32fc2/scratchpad/shot/pareto.png — runs',
  '    only. 2 of 72 are on the front: sl25m-focal-l9 (0.7593,',
  '    0.6186) and vitb-native-s101 (0.7600, 0.6116).',
  '  - /tmp/claude-1000/-home-user-proj/1673a7e7-',
  '    252a-4127-a63b-ab96a4c32fc2/scratchpad/shot/pareto_fm.png —',
  '    with foundation models.',
}, '\n'))
local FM = PARETO:gsub('pareto%.png$', 'pareto_fm.png')
local FS2 = { [PARETO] = true, [FM] = true }
eq('two paths: click first continuation', pick(TWO, '252a-4127-a63b-ab96a4c32fc2/scratchpad/shot/pareto.png', FS2), PARETO)
eq('two paths: click second continuation', pick(TWO, '252a-4127-a63b-ab96a4c32fc2/scratchpad/shot/pareto_fm.png', FS2), FM)
eq('two paths: shared first line takes the bottom one', pick(TWO, '/tmp/claude-1000/-home-user-proj/1673a7e7-', FS2), FM)
eq('two paths: shared first line falls back to the one above', pick(TWO, '/tmp/claude-1000/-home-user-proj/1673a7e7-',
  { [PARETO] = true }), PARETO)

-- A narrow pane: a path over five lines, clicked on its last
do
  local parts = {}
  for i = 1, 5 do parts[i] = '/seg' .. i .. 'abcdefghij' end
  local whole = table.concat(parts)
  eq('five-line wrap', pick(split('  ' .. table.concat(parts, '\n  ')), parts[5], { [whole] = true }), whole)
end

-- 3. A soft-wrapped path is one logical line: the link is the whole path
local SOFT = split('saved to /data/runs/very/long/' .. ('x'):rep(150) .. '/plot.png for you')
local SOFT_PATH = '/data/runs/very/long/' .. ('x'):rep(150) .. '/plot.png'
eq('soft wrap: whole path', pick(SOFT, SOFT_PATH, { [SOFT_PATH] = true }), SOFT_PATH)

-- 4. Real spaces in a name, also wrapped at a space
eq('spaces: one line', pick(split('open /Volumes/My Disk/clip one.mp4 now'), '/Volumes/My',
  { ['/Volumes/My Disk/clip one.mp4'] = true, ['/Volumes/My'] = true }), '/Volumes/My Disk/clip one.mp4')
eq('spaces: wrapped at a space', pick(split '  see /Volumes/My Disk/Long\n  Folder/clip.mp4 there', 'Folder/clip.mp4',
  { ['/Volumes/My Disk/Long Folder/clip.mp4'] = true }), '/Volumes/My Disk/Long Folder/clip.mp4')

-- 5. Trailing punctuation and quotes after a wrapped path
for _, tail in ipairs { '.', ',', ')', ':', '"', "'", ').', '`,' } do
  eq('punctuation ' .. tail, pick(split('  ("/srv/app/very-long-na\n  me/plot.png' .. tail .. ' next'), 'me/plot.png',
    { ['/srv/app/very-long-name/plot.png'] = true }), '/srv/app/very-long-name/plot.png')
end

-- 6. file:line, wrapped too; the line is kept for the editor
do
  local cands = paths.line_candidates(split '  error in /srv/app/src/fo\n  o.py:42, fix it', 'o.py:42')
  check('file:line wrapped: candidate', has(cands, '/srv/app/src/foo.py:42'))
  eq('file:line: line kept', paths.click_line('/srv/app/src/foo.py:42', '/srv/app/src/foo.py'), '42')
  eq('file:line: find strips it', paths.find_spec('src/foo.py:42:7').pattern, 'src/foo.py')
  eq('find: glob characters escaped', paths.find_spec('a[1]/b*.png').pattern, 'a\\[1\\]/b\\*.png')
  eq('find: depth grows with the path', paths.find_spec('a/b/c.png').depth, 6)
  check('find: not for absolute or .. paths', not paths.find_spec('/a/b') and not paths.find_spec('../a')
    and not paths.find_spec('~/a'))
end

-- 7. The earlier "couldn't resolve wrapped path": a whole directory ending
-- its line, prose on the next one, opens the directory
do
  local lines = split '  Transcripts are in /srv/proj/subagents\n  and each one is a JSONL file.'
  eq('directory at line end', pick(lines, '/srv/proj/subagents', { ['/srv/proj/subagents'] = true }), '/srv/proj/subagents')
end

-- 8. A piece only counts where it is a whole word
eq('piece inside a longer path is skipped', #paths.line_candidates(split 'see /tmp/xyz.png', '/tmp/x'), 0)

-- 9. Relative paths: directories on screen, wrapped ones rejoined
do
  local lines = split '  wrote /a/b/scratchpad/shot/x.png\n  then scratchpad/shot/pareto.png'
  local dirs = paths.dirs_from_lines(lines, 'scratchpad/shot/pareto.png', {})
  check('rel: parent of the first segment from a path on screen', has(dirs, '/a/b'), table.concat(dirs, ' '))
  local wrapped = split(table.concat({ '  wrote /tmp/claude-1000/-home-user-pr', '  oj/1673a7e7-252a',
    '  /scratchpad/shot/x.png and', '  then scratchpad/shot/pareto.png' }, '\n'))
  dirs = paths.dirs_from_lines(wrapped, 'scratchpad/shot/pareto.png', { '/recent' })
  check('rel: base from a wrapped path on screen', has(dirs, '/tmp/claude-1000/-home-user-proj/1673a7e7-252a'),
    table.concat(dirs, ' '))
  eq('rel: recent click dirs come last', dirs[#dirs], '/recent')
end

-- 10. Agent CLIs
check('agent: claude', agent.is_agent { argv = { 'claude' } })
check('agent: node codex', agent.is_agent { argv = { 'node', '/usr/lib/node_modules/codex/bin/codex.js' } })
check('agent: opencode', agent.is_agent { argv = { '/usr/local/bin/opencode' } })
check('agent: not zsh', not agent.is_agent { argv = { '-zsh' } })

-- Integration on the fixture tree ($WZT_ROOT, made by run.sh)
local REAL = ROOT .. '/proj/1673a7e7-252a-4127-a63b-ab96a4c32fc2/scratchpad/shot/pareto.png'
do
  local lines = split('  ' .. ROOT .. '/proj/1673a7e7-\n  252a-4127-a63b-ab96a4c32fc2/scratchpad/shot/pareto.png — runs')
  local texts = paths.line_candidates(lines, '252a-4127-a63b-ab96a4c32fc2/scratchpad/shot/pareto.png')
  local got
  for _, c in ipairs(texts) do
    got = paths.resolve_path(c, ROOT, {})
    if got then break end
  end
  eq('local: wrapped path resolves', got, REAL)
  eq('local: relative via a dir on screen', paths.resolve_path('scratchpad/shot/pareto.png', '/nonexistent',
    paths.dirs_from_lines(split('  ' .. REAL), 'scratchpad/shot/pareto.png', {})), REAL)
  eq('local: find fallback', paths.find_local(paths.find_spec 'shot/pareto.png', { '/nonexistent', ROOT }), REAL)
  eq('local: find gives up on nothing', paths.find_local(paths.find_spec 'shot/nope.png', { ROOT }), nil)
end

-- Remote resolution through the fake ssh (tests/fake-ssh). The fake runs
-- the command here, so $WZT_ROOT stands in for the remote file system.
local SSH = { 'ssh-pane', '-p', '2222', 'user@fakehost' }
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
local function mode(m)
  local f = assert(io.open(ROOT .. '/ssh-mode', 'w'))
  f:write(m)
  f:close()
end
do
  mode 'up'
  local lines = split('  ' .. ROOT .. '/proj/1673a7e7-\n  252a-4127-a63b-ab96a4c32fc2/scratchpad/shot/pareto.png — runs')
  local texts = paths.line_candidates(lines, '252a-4127-a63b-ab96a4c32fc2/scratchpad/shot/pareto.png')
  table.insert(texts, '252a-4127-a63b-ab96a4c32fc2/scratchpad/shot/pareto.png')
  local kind, path, which = paths.resolve_remote(SSH, texts, nil, {})
  eq('remote: wrapped path', path, REAL)
  eq('remote: kind', kind, 'f')
  check('remote: which names the candidate', which and texts[which]:sub(1, 1) == '/', which)
  local runs = 0
  for _, l in ipairs(log_lines()) do
    if not l:find(' -G ', 1, true) and not l:find('-O check', 1, true) then
      runs = runs + 1
      check('remote: rides the master only', l:find('-o BatchMode=yes -o ControlMaster=no -o ProxyCommand=false -S '
        .. ROOT .. '/cm', 1, true) ~= nil, l:sub(1, 160))
    end
  end
  eq('remote: one round trip', runs, 1)

  eq('remote: relative via OSC 7 cwd', select(2, paths.resolve_remote(SSH, { 'shot/pareto.png' },
    ROOT .. '/proj/1673a7e7-252a-4127-a63b-ab96a4c32fc2/scratchpad', {})), REAL)
  eq('remote: relative via dirs on screen', select(2, paths.resolve_remote(SSH, { 'scratchpad/shot/pareto.png' },
    nil, { '/nonexistent', ROOT .. '/proj/1673a7e7-252a-4127-a63b-ab96a4c32fc2' })), REAL)
  -- The fake ps lists an agent (claude) whose /proc cwd the fake readlink
  -- maps to $WZT_ROOT/agent-cwd, which holds notes/plan.md
  eq('remote: relative via the agent cwd', select(2, paths.resolve_remote(SSH, { 'notes/plan.md' }, nil, {})),
    ROOT .. '/agent-cwd/notes/plan.md')
  local find = paths.find_spec 'shot/pareto.png:12'
  local kind2, path2, which2 = paths.resolve_remote(SSH, { 'x', 'shot/pareto.png:12' }, ROOT .. '/proj', {}, find)
  eq('remote: find fallback', path2, REAL)
  eq('remote: find answers for the clicked text', which2, 2)
  eq('remote: find kind', kind2, 'f')
  local _, msg = paths.resolve_remote(SSH, { 'nope/none.png' }, ROOT, {}, paths.find_spec 'nope/none.png')
  check('remote: not found', msg:find('not found', 1, true) ~= nil, msg)
  log_lines()

  -- A pane started with ssh -J: the gate sees it, the run does not
  local path3 = select(2, paths.resolve_remote({ 'ssh-pane', '-J', 'jumphost', 'user@fakehost' }, { '/etc' }, nil, {}))
  eq('remote -J: resolves', path3 and path3:gsub('^/private', ''), '/etc')
  local gate_j, run_j = false, true
  for _, l in ipairs(log_lines()) do
    if l:find(' -G ', 1, true) then
      gate_j = l:find('-J jumphost', 1, true) ~= nil
    elseif not l:find('-O check', 1, true) then
      run_j = l:find('-J', 1, true) ~= nil
    end
  end
  check('remote -J: gate keeps -J', gate_j)
  check('remote -J: run drops -J (ssh refuses it with ProxyCommand=false)', not run_j)
  local batch = table.concat(require('lib.ssh').ssh_batch_cmd { 'ssh-pane', '-J', 'j', 'h' }, ' ')
  check('batch -J: no ProxyCommand=false', not batch:find('ProxyCommand', 1, true), batch)
  batch = table.concat(require('lib.ssh').ssh_batch_cmd { 'ssh-pane', 'h' }, ' ')
  check('batch: ProxyCommand=false', batch:find('ProxyCommand=false', 1, true) ~= nil, batch)

  mode 'down'
  _, msg = paths.resolve_remote(SSH, { '/etc' }, nil, {})
  check('remote: no master, no login', msg:find('no live ssh connection', 1, true) ~= nil, msg)
  local ran = false
  for _, l in ipairs(log_lines()) do
    if not l:find(' -G ', 1, true) and not l:find('-O check', 1, true) then ran = true end
  end
  check('remote: no master, nothing run', not ran)

  mode 'refuse'
  _, msg = paths.resolve_remote(SSH, { '/etc' }, nil, {})
  check('remote: MaxSessions refusal is named', msg:find('MaxSessions', 1, true) ~= nil, msg)
  log_lines()
end

io.stderr:write(string.format('RESULT %d passed, %d failed\n', passed, failed))
return {}
