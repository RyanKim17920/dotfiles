-- Port forwarding to this Mac over an ssh pane's existing ControlMaster.
local wezterm = require 'wezterm'
local act = wezterm.action
local core = require 'lib.core'
local ssh_lib = require 'lib.ssh'
local paths = require 'lib.paths'
local links = require 'lib.links'
local toast, prompt_text, ICON = core.toast, core.prompt_text, core.ICON
local SSH_OPTS_WITH_VALUE, SSH_PANE, ssh_split_args = ssh_lib.SSH_OPTS_WITH_VALUE, ssh_lib.SSH_PANE, ssh_lib.ssh_split_args
local ssh_cmd, ssh_batch_cmd, ssh_master_pid = ssh_lib.ssh_cmd, ssh_lib.ssh_batch_cmd, ssh_lib.ssh_master_pid
local live_master = ssh_lib.live_master
local ssh_host, pane_ssh_args = ssh_lib.ssh_host, ssh_lib.pane_ssh_args
local remote_word = paths.remote_word

local SSH_FORWARD_SCHEME = 'ssh-forward:' -- see forward_command

-- Localhost links and ssh -L tunnel commands. A server on a remote host
-- (Jupyter, TensorBoard, vite, ...) prints http://localhost:PORT/..., often
-- with a tunnel hint like `ssh -N -L 8790:node-1:8765 me@login.example.org`
-- when it runs on a compute node behind a login host. Forwards are added to
-- the existing ControlMaster for that host (`ssh -O forward`), never a new
-- login:
--  * CMD+click an `ssh ... -L ...` command: add its forwards instead of
--    running it.
--  * CMD+click http://localhost:PORT/...: the most recent `ssh ... -L
--    PORT:...` command in the pane's scrollback gives the host and target
--    (this works from a local pane too); otherwise, in an ssh pane, the same
--    port on that host's localhost is forwarded. Then the URL opens locally,
--    path and query kept. A placeholder like ?token=<token> is filled from
--    a token file read over the same master: the most recent `cat .../token`
--    in this pane's scrollback, else in the window's other panes (newest
--    first), else the file that last worked for that host and remote port
--    (see TOKEN_PATHS_FILE). The token is never logged, shown or written to
--    disk; only the file's path is remembered.
-- Local port conflicts: a forward of ours for another target is cancelled
-- and replaced; one added through the master some other way is cancelled if
-- its -L spec shows up in the scrollback or a running ssh command line; a
-- standalone ssh tunnel (an old `ssh -N -L`) is left alone and named by pid;
-- otherwise the next free port is used and the URL rewritten. Ports below
-- 1024 map to 8000+port. Forwards are remembered in wezterm.GLOBAL and reused
-- while the master still listens on them.

-- Remote target per URL host, also the host used in the rewritten URL
local LOOPBACK = {
  localhost = 'localhost', ['127.0.0.1'] = '127.0.0.1', ['0.0.0.0'] = 'localhost', ['[::1]'] = '[::1]',
}
local FORWARD_KEY = 'ssh_forward_' -- .. master args .. '|' .. target:rport -> local port
local FORWARD_PORT_KEY = 'ssh_forward_port_' -- .. local port -> "args\ttarget\trport" (ours)
local FORWARD_INDEX_KEY = 'ssh_forward_ports' -- " lport lport ... " with a FORWARD_PORT_KEY record
local SCROLLBACK_LINES = 2000

-- { scheme, host, rport, rest } for a loopback http(s) URL, else nil. A
-- link rule may have taken in a closing quote or paren from shell text like
-- `(open 'http://localhost:8766/#otc=...')`: cut at a quote, drop unmatched
-- closing parens.
local function parse_loopback_url(uri)
  uri = uri:gsub('[\'"`].*$', '')
  while uri:sub(-1) == ')' and select(2, uri:gsub('%(', '')) < select(2, uri:gsub('%)', '')) do
    uri = uri:sub(1, -2)
  end
  local scheme, host, port, rest = uri:match '^(https?)://(%[::1%])(:?%d*)(.*)$'
  if not scheme then
    scheme, host, port, rest = uri:match '^(https?)://([^/:?#]+)(:?%d*)(.*)$'
  end
  if not scheme or not LOOPBACK[host:lower()] or not (rest == '' or rest:match '^[/?#]') then
    return nil
  end
  local rport = tonumber(port:sub(2)) or (scheme == 'https' and 443 or 80)
  return { scheme = scheme, host = host:lower(), rport = rport, rest = rest }
end

-- "[bind:]lport:host:rport" (host may be [v6]) -> { lport, host, rport }
local function parse_forward_spec(spec)
  local rest, rport = spec:match '^(.*):(%d+)$'
  if not rest then return nil end
  local head, host = rest:match '^(.*):(%[[^%]]+%])$'
  if not head then head, host = rest:match '^(.*):([^:]+)$' end
  local lport = head and (head:match '^(%d+)$' or head:match ':(%d+)$')
  if not lport then return nil end
  return { lport = tonumber(lport), host = host, rport = tonumber(rport) }
end

-- -L forwards anywhere after argv[first] (OpenSSH also takes options after
-- the destination); flags are walked like ssh_split_args does
local function collect_forwards(argv, first)
  local forwards, k = {}, first + 1
  while k <= #argv do
    local a = argv[k]
    if a:match '^%-%w' then
      for j = 2, #a do
        local c = a:sub(j, j)
        if SSH_OPTS_WITH_VALUE[c] then
          local value = a:sub(j + 1)
          if value == '' then
            k = k + 1
            value = argv[k]
          end
          local f = c == 'L' and value and parse_forward_spec(value)
          if f then table.insert(forwards, f) end
          break
        end
      end
    end
    k = k + 1
  end
  return forwards
end

-- Words of `text` from its first `ssh` word on (argv, index of `ssh`), or
-- nil. Quotes/backticks/parens around words and trailing prose punctuation
-- are dropped.
local function ssh_words(text)
  local argv, first = {}, nil
  for w in text:gmatch '%S+' do
    w = w:gsub('^[`\'"(]+', ''):gsub('[`\'".,;)]+$', '')
    if w ~= '' then
      table.insert(argv, w)
      if not first and w:match '[^/]*$' == 'ssh' then first = #argv end
    end
  end
  return first and argv, first
end

-- Text holding `ssh ... -L ... dest` -> pane_ssh_args-style args and its
-- forwards, or nil. Flags may be bundled (-fN -L, -NfL spec).
local function parse_ssh_text(text)
  local argv, first = ssh_words(text)
  if not argv then return nil end
  local ssh, forwards = ssh_split_args(argv, first), collect_forwards(argv, first)
  if not ssh or #forwards == 0 then return nil end
  return ssh, forwards
end

-- Whether an `ssh ...` command looks cut short by a hard wrap (an agent's
-- TUI breaks long lines itself): a -L whose spec is on the next line,
-- forwards but no destination yet, or a quote left open.
local function cut_short(cmd)
  if cmd:match '%s%-%w*L%s*$' then return true end
  local argv, first = ssh_words(cmd)
  if argv and #collect_forwards(argv, first) > 0 and not ssh_split_args(argv, first) then return true end
  return select(2, cmd:gsub("'", '')) % 2 == 1 or select(2, cmd:gsub('"', '')) % 2 == 1
end

local MAX_JOIN = 4 -- continuation lines a hard-wrapped command may take

-- `cmd` (the ssh command starting on lines[i]) with the hard-wrapped
-- continuation lines after it joined back on, and the index of its last
-- line. Continuations lose their indent; a quoted URL split mid-word is
-- joined without a space.
local function join_wrapped(lines, i, cmd)
  local j = i
  while j < #lines and j - i < MAX_JOIN and cut_short(cmd) do
    local more = lines[j + 1]:match '^%s*(.-)%s*$'
    if more == '' then break end
    j = j + 1
    cmd = cmd:gsub('%s+$', '')
    cmd = cmd .. (cmd:match '[\'"]https?://[^%s\'"]*$' and '' or ' ') .. more
  end
  return cmd, j
end

-- Loopback URLs in `text`, parsed, in order
local function loopback_urls(text)
  local urls = {}
  for u in text:gmatch 'https?://[^%s`\'"]+' do
    local url = parse_loopback_url((u:gsub('[.,;:)]+$', '')))
    if url then table.insert(urls, url) end
  end
  return urls
end

-- The first of `urls` on the local port of one of `forwards`, or nil
local function url_for(urls, forwards)
  for _, u in ipairs(urls) do
    for _, f in ipairs(forwards) do
      if u.rport == f.lport then return u end
    end
  end
  return nil
end

-- What lines of terminal text hint at: tunnel commands ({ ssh, forwards,
-- url }, oldest first; url is a loopback URL for one of the forwards in the
-- same command, like `ssh -fN -L ... && open 'http://localhost:...'`, or in
-- the lines right after it, up to a blank one), the last `cat <path with
-- "token">` and loopback URLs (parsed, oldest first).
local function hints_from_lines(lines)
  local tunnels, token_path, urls = {}, nil, {}
  local i = 1
  while i <= #lines do
    local chunk, last = lines[i], i
    local at = chunk:find '%f[%w]ssh%s'
    if at and chunk:find('-', at, true) then
      local cmd
      cmd, last = join_wrapped(lines, i, chunk:sub(at))
      chunk = chunk:sub(1, at - 1) .. cmd
      local ssh, forwards = parse_ssh_text(cmd)
      if ssh then
        local t = { ssh = ssh, forwards = forwards, url = url_for(loopback_urls(cmd), forwards) }
        -- Else a URL printed right after it (the rest of a wrapped line)
        for k = last + 1, math.min(last + MAX_JOIN, #lines) do
          if t.url or not lines[k]:find '%S' then break end
          t.url = url_for(loopback_urls(lines[k]), forwards)
        end
        table.insert(tunnels, t)
      end
    end
    for path in chunk:gmatch '%f[%w]cat%s+([^%s`\'"]+)' do
      if path:lower():find('token', 1, true) then token_path = (path:gsub('[.,;:)]+$', '')) end
    end
    for _, url in ipairs(loopback_urls(chunk)) do table.insert(urls, url) end
    i = last + 1
  end
  return tunnels, token_path, urls
end

-- hints_from_lines for the pane's recent scrollback. Logical lines, so text
-- soft-wrapped by the terminal stays whole.
local function scrollback_hints(pane)
  local ok, text = pcall(pane.get_logical_lines_as_text, pane, SCROLLBACK_LINES)
  local lines = {}
  for line in (ok and text or ''):gmatch '[^\n]+' do table.insert(lines, line) end
  return hints_from_lines(lines)
end

-- Most recent tunnel forwarding local `port`: its args and forward
local function find_tunnel(tunnels, port)
  for i = #tunnels, 1, -1 do
    for _, f in ipairs(tunnels[i].forwards) do
      if f.lport == port then return tunnels[i].ssh, f end
    end
  end
  return nil
end

-- "hostname user port" as ssh resolves them from the config (ssh -G never
-- connects)
local function ssh_identity(ssh)
  local ok, out = wezterm.run_child_process(ssh_cmd(ssh, '-G'))
  if not ok then return nil end
  local f = {}
  for line in out:gmatch '[^\n]+' do
    local k, v = line:match '^(%S+) (.*)$'
    if k and not f[k] then f[k] = v end
  end
  return f.hostname, f.user, f.port
end

-- Concrete Host aliases in ~/.ssh/config (no wildcards; Includes not read)
local function ssh_config_aliases()
  local f = io.open(wezterm.home_dir .. '/.ssh/config')
  if not f then return {} end
  local text = f:read 'a'
  f:close()
  local aliases = {}
  for line in text:gmatch '[^\n]+' do
    for alias in (line:match '^%s*[Hh][Oo][Ss][Tt]%s+(.-)%s*$' or ''):gmatch '%S+' do
      if not alias:find '[*?!]' then table.insert(aliases, alias) end
    end
  end
  return aliases
end

-- The ~/.ssh/config alias for the destination of `ssh` (same hostname and
-- port, an alias with the same user first), or nil: the name to show for a
-- host a tunnel line spells as user@FQDN. Only asks ssh -G.
local function host_alias(ssh)
  local host, user, port = ssh_identity(ssh)
  if not host then return nil end
  local loose
  for _, alias in ipairs(ssh_config_aliases()) do
    local h, u, p = ssh_identity { SSH_PANE, alias }
    if h == host and p == port then
      if u == user then return alias end
      loose = loose or alias
    end
  end
  return loose
end

-- Gated args (lib/ssh.lua gated_args) for the live ControlMaster of the
-- destination of `ssh`, and the master's pid; nil if none. A hint may spell
-- the host differently from the alias that started the master
-- (me@login.example.org vs myserver): with ControlPath %C that is the same
-- socket, but a per-alias ControlPath (e.g. %r@%h:%p set only under `Host
-- myserver`) is not, so config aliases that ssh -G resolves to the same
-- hostname, port and user are tried as well. Only when the hint names no
-- user (no user@, no -l) may an alias with another user stand in.
local function find_master(ssh)
  local gated, pid = live_master(ssh)
  if gated then return gated, pid end
  local host, user, port = ssh_identity(ssh)
  if not host then return nil end
  local named_user = ssh[#ssh]:find('@', 1, true) ~= nil
  for k = 2, #ssh - 1 do
    if ssh[k] == '-l' then named_user = true end
  end
  local loose = {}
  for _, alias in ipairs(ssh_config_aliases()) do
    local cand = { SSH_PANE, alias }
    local h, u, p = ssh_identity(cand)
    if h == host and p == port then
      if u == user then
        gated, pid = live_master(cand)
        if gated then return gated, pid end
      elseif not named_user then
        table.insert(loose, cand)
      end
    end
  end
  for _, cand in ipairs(loose) do
    gated, pid = live_master(cand)
    if gated then return gated, pid end
  end
  return nil
end

-- pid (string) and command name of the process listening on local TCP
-- `port`, or nil
local function listener(port)
  local ok, out = wezterm.run_child_process {
    '/usr/sbin/lsof', '-nP', '-iTCP:' .. port, '-sTCP:LISTEN', '-Fpc',
  }
  if not ok then return nil end
  return out:match '^p(%d+)', out:match '\nc([^\n]*)'
end

-- -L forwards for local `port` from running ssh command lines (`pid` only,
-- if given)
local function running_forwards(port, pid)
  local ok, out = wezterm.run_child_process(pid and { '/bin/ps', '-o', 'args=', '-p', pid }
    or { '/bin/ps', '-axo', 'args=' })
  local found = {}
  for line in (ok and out or ''):gmatch '[^\n]+' do
    if line:find('-', 1, true) and line:match '%f[%w]ssh%s' then
      local _, forwards = parse_ssh_text(line)
      for _, f in ipairs(forwards or {}) do
        if f.lport == port then table.insert(found, f) end
      end
    end
  end
  return found
end

-- localhost and 127.0.0.1 name the same remote target
local function norm_target(host) return host == 'localhost' and '127.0.0.1' or host end
local function same_target(a, b) return norm_target(a) == norm_target(b) end

local function forward_key(ssh, target, rport)
  return FORWARD_KEY .. table.concat(ssh, ' ', 2) .. '|' .. norm_target(target) .. ':' .. rport
end

-- Add or drop local `port` in the index of recorded forwards
local function index_forward(port, keep)
  local index = (wezterm.GLOBAL[FORWARD_INDEX_KEY] or ' '):gsub(' ' .. port .. ' ', ' ')
  wezterm.GLOBAL[FORWARD_INDEX_KEY] = keep and (index .. port .. ' ') or index
end

-- -O forward / -O cancel of lport:target:rport on master `ssh`, keeping the
-- GLOBAL records in step
local function add_forward(ssh, lport, target, rport)
  local spec = lport .. ':' .. target .. ':' .. rport
  if not wezterm.run_child_process(ssh_cmd(ssh, '-O', 'forward', '-L', spec)) then return false end
  wezterm.GLOBAL[forward_key(ssh, target, rport)] = lport
  wezterm.GLOBAL[FORWARD_PORT_KEY .. lport] = table.concat(ssh, '\t') .. '\n' .. target .. '\n' .. rport
  index_forward(lport, true)
  return true
end

local function cancel_forward(ssh, lport, target, rport)
  wezterm.run_child_process(ssh_cmd(ssh, '-O', 'cancel', '-L', lport .. ':' .. target .. ':' .. rport))
  if listener(lport) then return false end
  wezterm.GLOBAL[FORWARD_PORT_KEY .. lport] = nil
  wezterm.GLOBAL[forward_key(ssh, target, rport)] = nil
  index_forward(lport, false)
  return true
end

-- Master args and forward recorded as ours for local `port`, or nil
local function recorded_forward(port)
  local rec = wezterm.GLOBAL[FORWARD_PORT_KEY .. port]
  local args, target, rport = (rec or ''):match '^(.-)\n(.-)\n(%d+)$'
  if not args then return nil end
  local ssh = {}
  for v in args:gmatch '[^\t]+' do table.insert(ssh, v) end
  return ssh, { lport = port, host = target, rport = tonumber(rport) }
end

-- Every forward recorded as ours, { ssh, lport, host, rport } by local port.
-- A record outlives its master: check the port still listens.
local function recorded_forwards()
  local list = {}
  for port in (wezterm.GLOBAL[FORWARD_INDEX_KEY] or ''):gmatch '%d+' do
    local ssh, f = recorded_forward(tonumber(port))
    if ssh then
      f.ssh = ssh
      table.insert(list, f)
    end
  end
  table.sort(list, function(a, b) return a.lport < b.lport end)
  return list
end

-- Forward local `want` (or a free port near it) to target:rport through
-- master `ssh` (pid `pid`). `seen` are -L forwards from the scrollback: what
-- a busy port may have been forwarded to, for cancelling. Returns the local
-- port, how ('new', 'reused' or 'tunnel') and an optional note; or nil and a
-- message.
local function ssh_forward(ssh, pid, target, rport, want, seen)
  want = want >= 1024 and want or 8000 + want
  local function same(f) return same_target(f.host, target) and f.rport == rport end
  local note
  local lpid, lcmd = listener(want)
  if lpid then
    -- Which master holds `want` (one we forwarded through, or this one) and
    -- what it is known to forward there (our record, running ssh -L clients)
    local rec_ssh, rec = recorded_forward(want)
    local holder, held = nil, {}
    if rec_ssh and ssh_master_pid(rec_ssh) == lpid then
      holder, held = rec_ssh, { rec }
    elseif lpid == pid then
      holder = ssh
    end
    if holder then
      for _, f in ipairs(running_forwards(want)) do table.insert(held, f) end
      for _, f in ipairs(held) do
        if lpid == pid and same(f) then
          wezterm.GLOBAL[forward_key(ssh, target, rport)] = want
          return want, 'reused'
        end
      end
      local candidates = held
      for _, f in ipairs(seen or {}) do
        if f.lport == want and not same(f) then table.insert(candidates, f) end
      end
      for _, f in ipairs(candidates) do
        if cancel_forward(holder, want, f.host, f.rport) then
          note = 'replaced ' .. want .. ' → ' .. f.host .. ':' .. f.rport
          break
        end
      end
      if not note then note = want .. ' is held by ssh pid ' .. lpid .. ' for another target' end
    elseif lcmd == 'ssh' then
      for _, f in ipairs(running_forwards(want, lpid)) do
        if same(f) then return want, 'tunnel', 'ssh pid ' .. lpid end
      end
      note = want .. ' is held by an older ssh tunnel (pid ' .. lpid .. ', left running)'
    else
      note = want .. ' is used by ' .. (lcmd or '?') .. ' (pid ' .. lpid .. ')'
    end
    -- Still busy: an earlier forward of ours to the same target will do
    local known = wezterm.GLOBAL[forward_key(ssh, target, rport)]
    if listener(want) and known and known ~= want and listener(known) == pid then
      return known, 'reused', note
    end
  end
  local last = math.min(want + 20, 65535)
  for lport = want, last do
    -- lsof can't see other users' listeners; a failed bind just moves on
    if not listener(lport) and add_forward(ssh, lport, target, rport) then
      return lport, 'new', note
    end
  end
  return nil, 'Forward: no free local port in ' .. want .. '-' .. last .. (note and ('; ' .. note) or '')
end

local function is_loopback_target(target)
  return target == 'localhost' or target == '127.0.0.1' or target == '[::1]'
end

-- "localhost:8790 → node-1:8765 via myserver" (+ how/note)
local function describe_forward(master, lport, target, rport, how, note)
  local to = is_loopback_target(target) and (ssh_host(master) .. ':' .. rport)
    or (target .. ':' .. rport .. ' via ' .. ssh_host(master))
  local msg = 'localhost:' .. lport .. ' → ' .. to
  if how == 'reused' then msg = msg .. ' (existing)' end
  if how == 'tunnel' then msg = msg .. ' (existing tunnel, ' .. note .. ')' end
  if note and how ~= 'tunnel' then msg = msg .. '; ' .. note end
  return msg
end

local function all_forwards(tunnels)
  local seen = {}
  for _, t in ipairs(tunnels) do
    for _, f in ipairs(t.forwards) do table.insert(seen, f) end
  end
  return seen
end

local function no_master_msg(ssh)
  return 'Forward: no live ssh connection to ' .. ssh_host(ssh)
    .. ' (ControlMaster); open an ssh pane to it first'
end

-- Query value that is a placeholder: <token>, %3Ctoken%3E, {token}, TOKEN,
-- YOUR_TOKEN (a link rule may have cut a trailing >)
local function is_placeholder(v)
  return v:match '^<' or v:match '^%%3[Cc]' or v:match '^{' or v:match '^[A-Z_]*TOKEN[A-Z_]*$'
end

-- `rest` (path?query#frag) with placeholder values set to `value` (already
-- URL-encoded) or, if nil, their params dropped; plus whether any was found
local function fill_placeholder(rest, value)
  local path, query, frag = rest:match '^([^?#]*)%??([^#]*)(.*)$'
  local parts, found = {}, false
  for kv in query:gmatch '[^&]+' do
    local k, v = kv:match '^([^=]*)=(.*)$'
    if k and is_placeholder(v) then
      found = true
      if value then table.insert(parts, k .. '=' .. value) end
    else
      table.insert(parts, kv)
    end
  end
  if not found then return rest, false end
  return path .. (#parts > 0 and ('?' .. table.concat(parts, '&')) or '') .. frag, true
end

local function url_encode(s)
  return (s:gsub('[^%w%-._~]', function(c) return string.format('%%%02X', c:byte()) end))
end

-- One whitespace-free token from a remote file (first 4 KiB), or nil
local function read_remote_token(ssh, path)
  local cmd = ssh_batch_cmd(ssh)
  table.insert(cmd, 'head -c 4096 -- ' .. remote_word(path))
  local ok, out = wezterm.run_child_process(cmd)
  return ok and out:match '^%s*(%S+)%s*$' or nil
end

-- Token-file paths that worked, per "<ssh hostname> <remote port>", so a
-- later click finds the token without a `cat` hint even when the server
-- moved to another node. One "host port path" line each; paths only, never
-- tokens. Cached in wezterm.GLOBAL (TOKEN_PATH_KEY .. key).
local TOKEN_PATHS_FILE = wezterm.home_dir .. '/.local/state/wezterm/token-paths'
local TOKEN_PATH_KEY = 'token_path_'

local function read_token_paths()
  local paths = {}
  local f = io.open(TOKEN_PATHS_FILE)
  if not f then return paths end
  for line in f:lines() do
    local host, port, path = line:match '^(%S+) (%d+) (.+)$'
    if host then paths[host .. ' ' .. port] = path end
  end
  f:close()
  return paths
end

local function remembered_token_path(key)
  if not wezterm.GLOBAL.token_paths_loaded then
    for k, path in pairs(read_token_paths()) do wezterm.GLOBAL[TOKEN_PATH_KEY .. k] = path end
    wezterm.GLOBAL.token_paths_loaded = true
  end
  return wezterm.GLOBAL[TOKEN_PATH_KEY .. key]
end

local function remember_token_path(key, path)
  if remembered_token_path(key) == path then return end
  wezterm.GLOBAL[TOKEN_PATH_KEY .. key] = path
  local paths = read_token_paths()
  paths[key] = path
  -- Private file (mode 600) in a private dir, created before anything is written
  local dir = TOKEN_PATHS_FILE:match '^(.*)/'
  wezterm.run_child_process { '/bin/sh', '-c',
    'umask 077 && mkdir -p "$1" && touch "$2" && chmod 600 "$2"', 'sh', dir, TOKEN_PATHS_FILE }
  local lines = {}
  for k, v in pairs(paths) do table.insert(lines, k .. ' ' .. v) end
  table.sort(lines)
  local f = io.open(TOKEN_PATHS_FILE, 'w')
  if f then
    f:write(table.concat(lines, '\n') .. '\n')
    f:close()
  end
end

-- The window's panes other than `pane`, newest first
local function other_panes(window, pane)
  local others = {}
  local ok, tabs = pcall(function() return window:mux_window():tabs() end)
  for _, tab in ipairs(ok and tabs or {}) do
    for _, p in ipairs(tab:panes()) do
      if p:pane_id() ~= pane:pane_id() then table.insert(others, p) end
    end
  end
  table.sort(others, function(a, b) return a:pane_id() > b:pane_id() end)
  return others
end

-- Memoized finder for the token of the server on remote port `rport` behind
-- master `ssh`, trying in order: `hint` (this pane's `cat` path), `cat`
-- paths in the window's other panes (newest first), the remembered path for
-- that host and port. A path that yields a token is remembered.
local function token_finder(window, pane, ssh, rport, hint)
  local done, token
  return function()
    if done then return token end
    done = true
    local host = ssh_identity(ssh)
    local key = host and rport and (host .. ' ' .. rport)
    local tried = {}
    local function try(path)
      if token or not path or tried[path] then return end
      tried[path] = true
      token = read_remote_token(ssh, path)
      if token and key then remember_token_path(key, path) end
    end
    try(hint)
    if not token then
      for _, p in ipairs(other_panes(window, pane)) do
        local _, path = scrollback_hints(p)
        try(path)
      end
    end
    if key then try(remembered_token_path(key)) end
    return token
  end
end

-- Open loopback `url` in the browser on local port `lport`, its token
-- placeholder (if any) filled from `get_token()` (a token_finder);
-- `notify` gets a note about the token. Returns "host:port" opened.
local function open_local(url, lport, get_token, notify)
  local rest, has_placeholder = fill_placeholder(url.rest, nil)
  if has_placeholder then
    local token = get_token()
    if token then
      rest = fill_placeholder(url.rest, url_encode(token))
      notify 'token filled in'
    else
      notify 'token not found, opened without it'
    end
  end
  local host = LOOPBACK[url.host]
  wezterm.open_with(url.scheme .. '://' .. host .. ':' .. lport .. rest)
  return host .. ':' .. lport
end

-- Most recent scrollback URL for local `port`, or nil
local function latest_url(urls, port)
  for i = #urls, 1, -1 do
    if urls[i].rport == port then return urls[i] end
  end
  return nil
end

-- Add the forwards of a tunnel command (`ssh`, `forwards`, as
-- parse_ssh_text gives them) on the live master for its host, never running
-- the command or logging in, then open one in the browser: `url` (the
-- command's own, e.g. from `&& open '...#otc=...'`) if given, else the
-- latest URL for a forwarded port in `pane`'s scrollback. The URL is opened
-- as printed (path, query and fragment kept) with the local port swapped in
-- when it had to change.
local function forward_tunnel(window, pane, ssh, forwards, url)
  local master, pid = find_master(ssh)
  if not master then
    toast(window, no_master_msg(ssh), 5000)
    return
  end
  local tunnels, token_path, urls = scrollback_hints(pane)
  local seen = all_forwards(tunnels)
  local done, open_url, open_port, open_rport = {}, nil, nil, nil
  for _, f in ipairs(forwards) do
    local lport, how, note = ssh_forward(master, pid, f.host, f.rport, f.lport, seen)
    table.insert(done, lport and describe_forward(master, lport, f.host, f.rport, how, note) or how)
    -- Open one: the first forward with a URL, else the first
    local u = lport and ((url and url.rport == f.lport and url) or latest_url(urls, f.lport))
    if lport and (not open_port or (u and not open_url)) then
      open_url, open_port, open_rport = u, lport, f.rport
    end
  end
  local msg = 'Forward: ' .. table.concat(done, ' · ')
  if open_port then
    -- No URL printed: a findable token still gets in (Jupyter-style ?token=)
    local get_token = token_finder(window, pane, master, open_rport, token_path)
    local u = open_url or parse_loopback_url('http://localhost:' .. open_port
      .. (get_token() and '/?token=<token>' or '/'))
    local token_note
    local opened = open_local(u, open_port, get_token, function(n) token_note = n end)
    msg = msg .. ' → opened ' .. opened .. (token_note and ('; ' .. token_note) or '')
  end
  toast(window, msg, 5000)
end

-- CMD+click on an `ssh ... -L ...` command (or one entered at CMD+SHIFT+L):
-- add its forwards. A click on the first line of a hard-wrapped command gets
-- no destination: the scrollback's newest whole command starting with the
-- same -L is used.
local function forward_command(window, pane, text)
  local ssh, forwards = parse_ssh_text(text)
  if not ssh then
    local argv, first = ssh_words(text)
    local want = argv and collect_forwards(argv, first)[1]
    local tunnels = want and scrollback_hints(pane) or {}
    for i = #tunnels, 1, -1 do
      local f = tunnels[i].forwards[1]
      if not ssh and f.lport == want.lport and f.host == want.host and f.rport == want.rport then
        ssh, forwards = tunnels[i].ssh, tunnels[i].forwards
      end
    end
  end
  if not ssh then
    toast(window, 'Forward: no -L forward and destination in that ssh command')
    return
  end
  -- A whole line pasted at CMD+SHIFT+L may carry its URL
  forward_tunnel(window, pane, ssh, forwards, url_for(loopback_urls(text), forwards))
end

-- Tunnel commands on screen (scrollback) in `pane`, then the window's other
-- panes (newest first), newest first, one per destination and forwards:
-- { ssh, forwards, url, pane }. For the CMD+SHIFT+I list.
local function screen_tunnels(window, pane)
  local list, seen = {}, {}
  local panes = other_panes(window, pane)
  table.insert(panes, 1, pane)
  for _, p in ipairs(panes) do
    local tunnels = scrollback_hints(p)
    for i = #tunnels, 1, -1 do
      local t = tunnels[i]
      local key = ssh_host(t.ssh)
      for _, f in ipairs(t.forwards) do key = key .. ' ' .. f.lport .. ':' .. f.host .. ':' .. f.rport end
      if not seen[key] then
        seen[key] = true
        t.pane = p
        table.insert(list, t)
      end
    end
  end
  return list
end

-- Forward for a loopback URL clicked in `pane` and open it; false when
-- neither a tunnel hint nor an ssh pane says where it lives
local function open_forwarded(window, pane, url)
  local tunnels, token_path = scrollback_hints(pane)
  local ssh, f = find_tunnel(tunnels, url.rport)
  local target, rport = f and f.host, f and f.rport
  if not ssh then
    ssh = pane_ssh_args(pane)
    if not ssh then return false end
    target, rport = LOOPBACK[url.host], url.rport
  end
  local master, pid = find_master(ssh)
  if not master then
    toast(window, no_master_msg(ssh), 5000)
    return true
  end
  local lport, how, note = ssh_forward(master, pid, target, rport, url.rport, all_forwards(tunnels))
  if not lport then
    toast(window, how, 5000)
    return true
  end
  local msg = 'Forward: ' .. describe_forward(master, lport, target, rport, how, note)
  open_local(url, lport, token_finder(window, pane, master, rport, token_path),
    function(n) msg = msg .. '; ' .. n end)
  toast(window, msg, 5000)
  return true
end

-- CMD+SHIFT+L: forward without a click: a port, a localhost URL or a whole
-- `ssh -L` command
local forward_prompt = act.PromptInputLine {
  description = prompt_text(ICON.forward, 'Forward a remote port to this Mac',
    'Port (8888), localhost URL or an ssh -L command · Enter forwards and opens · Esc cancels'),
  action = wezterm.action_callback(function(window, pane, line)
    line = (line or ''):match '^%s*(.-)%s*$'
    if line == '' then return end
    if line:match '%f[%w]ssh%s' then
      forward_command(window, pane, line)
      return
    end
    local url = parse_loopback_url(line:match '^%d+$' and ('http://localhost:' .. line .. '/') or line)
    if not url then
      toast(window, 'Forward: expected a port, a localhost URL or an ssh -L command')
    elseif not open_forwarded(window, pane, url) then
      toast(window, 'Forward: not an ssh pane and no ssh -L hint for port ' .. url.rport)
    end
  end),
}

-- Shared with features/ports.lua
local M = {
  ssh_forward = ssh_forward, cancel_forward = cancel_forward,
  recorded_forwards = recorded_forwards, describe_forward = describe_forward,
  screen_tunnels = screen_tunnels, forward_tunnel = forward_tunnel,
  ssh_identity = ssh_identity, host_alias = host_alias,
  -- for tests
  _test = { parse_ssh_text = parse_ssh_text, hints_from_lines = hints_from_lines, find_master = find_master,
    parse_loopback_url = parse_loopback_url, ssh_forward = ssh_forward, forward_tunnel = forward_tunnel,
    forward_command = forward_command, same_target = same_target },
}

function M.apply(config)
  -- `ssh ... -L ... dest` commands (tunnel hints printed by servers and
  -- agents): CMD+click adds the forwards on the existing ControlMaster instead
  -- of running anything (see forward_command). The command runs to the end of
  -- the line or to a quote, backtick, ; | or &; the longer match wins over
  -- path rules inside it.
  table.insert(config.hyperlink_rules, {
    regex = [=[(?<![\w.-])(ssh\s+(?:[^\s`'";|&]+\s+)*?-\w*L\s*[^\s`'";|&]+(?:\s+[^\s`'";|&]+)*)]=],
    format = SSH_FORWARD_SCHEME .. '$1',
    highlight = 1,
  })

  -- A quoted localhost URL (`open 'http://localhost:8766/#otc=...'`): the
  -- whole URL, not the default rule's cut before a trailing _ or its take
  -- of a closing quote and paren
  table.insert(config.hyperlink_rules, {
    regex = [=[['"](https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(?::\d+)?(?:[/?#][^\s'"`]*)?)['"]]=],
    format = '$1',
    highlight = 1,
  })

  links.handle('forward', function(window, pane, uri)
    if uri:sub(1, #SSH_FORWARD_SCHEME) == SSH_FORWARD_SCHEME then
      forward_command(window, pane, uri:sub(#SSH_FORWARD_SCHEME + 1))
      return false
    end
    local url = parse_loopback_url(uri)
    if url and open_forwarded(window, pane, url) then return false end
  end)
  -- CMD+click opens links even inside apps that capture the mouse
  links.bind_click(config, 'CMD', false)
  for _, key in ipairs {
    -- ssh pane: forward a remote port to this Mac and open it (see open_forwarded)
    { key = 'l', mods = 'CMD|SHIFT', action = forward_prompt },
  } do table.insert(config.keys, key) end
end

return M
