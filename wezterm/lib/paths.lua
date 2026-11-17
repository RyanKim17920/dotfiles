-- Resolving clicked path text: local paths (~, relative to the pane's cwd,
-- :line suffixes, %-encoding, backslash escapes), paths on an ssh pane's host
-- (one round trip over its ControlMaster, see REMOTE_RESOLVE) and the longer
-- spellings of paths with spaces or hard-wrapped by a TUI (path_candidates).
local wezterm = require 'wezterm'
local core = require 'lib.core'
local ssh_lib = require 'lib.ssh'
local sh_quote, exists = core.sh_quote, core.exists
local ssh_batch_cmd, ssh_master_pid, ssh_host = ssh_lib.ssh_batch_cmd, ssh_lib.ssh_master_pid, ssh_lib.ssh_host

-- Scheme of the links the path hyperlink rules make (features/paths.lua)
local PEEK_SCHEME = 'yazi-open-path:'

-- Collapse `.`/`..`/empty segments of an absolute path
local function normalize(path)
  local parts = {}
  for seg in path:gmatch '[^/]+' do
    if seg == '..' then
      table.remove(parts)
    elseif seg ~= '.' then
      table.insert(parts, seg)
    end
  end
  return '/' .. table.concat(parts, '/')
end

local function percent_decode(s)
  return (s:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end))
end

local function is_local_host(host)
  local here = wezterm.hostname()
  return host == '' or host == 'localhost' or host == here or host == (here:gsub('%..*$', ''))
end

-- uri -> path text (may carry :line[:col]) plus, for file://otherhost/...
-- (e.g. ls --hyperlink inside ssh), that host; nil if not ours
local function uri_to_path(uri)
  if uri:sub(1, #PEEK_SCHEME) == PEEK_SCHEME then
    return uri:sub(#PEEK_SCHEME + 1)
  end
  local host, path = uri:match '^file://([^/]*)(/.*)$'
  if not path then return nil end
  path = percent_decode((path:gsub('[?#].*$', '')))
  if is_local_host(host) then return path end
  return path, host
end

-- Spellings of a clicked path to try in order: as is, without a trailing
-- :line, :line:col or :first-last, then each %-decoded (My%20File.md), then
-- each with shell backslash escapes removed (My\ File.md)
local function path_variants(text)
  local out = { text }
  local stripped = text:match '^(.-):%d+[:-]%d+$' or text:match '^(.-):%d+$'
  if stripped and stripped ~= '' then table.insert(out, stripped) end
  for i = 1, #out do
    local decoded = percent_decode(out[i])
    if decoded ~= out[i] then table.insert(out, decoded) end
  end
  for i = 1, #out do
    local unescaped = out[i]:gsub('\\(.)', '%1')
    if unescaped ~= out[i] then table.insert(out, unescaped) end
  end
  return out
end

-- `dir` with a leading ~ made the local home
local function expand_home(dir)
  if dir == '~' or dir:sub(1, 2) == '~/' then return wezterm.home_dir .. dir:sub(2) end
  return dir
end

-- Existing absolute path for `text` (see path_variants), resolving ~ and
-- relative paths against `cwd`, then each of `dirs` (see search_dirs) in
-- order; nil if nothing exists.
local function resolve_path(text, cwd, dirs)
  for _, c in ipairs(path_variants(text)) do
    if c == '~' or c:sub(1, 2) == '~/' or c:sub(1, 1) == '/' then
      c = normalize(expand_home(c))
      if exists(c) then return c end
    else
      for k = 0, #(dirs or {}) do
        local full = normalize(expand_home(k == 0 and cwd or dirs[k]) .. '/' .. c)
        if exists(full) then return full end
      end
    end
  end
  return nil
end

-- A bare name or relative path (README.md, figs/plot.png) is often printed
-- by a program that means a directory shown elsewhere on screen, or one a
-- recent click resolved, not the shell's cwd. search_dirs lists those
-- directories for resolve_path and resolve_remote: for each absolute (or ~)
-- path in the pane's last SCAN_DIR_LINES lines, the path itself (it may be a
-- directory), its parent and, for a text like figs/plot.png, the part of it
-- before a figs segment, nearest to the clicked line first, then the
-- directories of the last clicks on the same host (remember_dir), newest
-- first; de-duplicated, at most MAX_DIRS. Nothing is checked here, so this
-- costs no round trip; the caller tests `dir/text` for each.
local SCAN_DIR_LINES, MAX_DIRS, MAX_RECENT = 2000, 40, 10
local DIRS_KEY = 'path_click_dirs'
-- What may precede an absolute path on screen (as in the path link rules)
local DIR_BOUNDARY = '[%s"\'`(%[{<=*]'

local function recent_dirs(host_key)
  local ok, all = pcall(wezterm.json_parse, wezterm.GLOBAL[DIRS_KEY] or '{}')
  return ok and type(all) == 'table' and all[host_key] or {}, ok and type(all) == 'table' and all or {}
end

-- Remember the directory of a resolved click (`path`, a directory when
-- `is_dir`) on host `host_key` for later relative clicks
local function remember_dir(host_key, path, is_dir)
  local dir = is_dir and path or path:match '^(.+)/[^/]*$'
  if not dir or dir == '' then return end
  local list, all = recent_dirs(host_key)
  local out = { dir }
  for _, d in ipairs(list) do
    if d ~= dir and #out < MAX_RECENT then table.insert(out, d) end
  end
  all[host_key] = out
  wezterm.GLOBAL[DIRS_KEY] = wezterm.json_encode(all)
end

-- Absolute (or ~) paths in `line`, cleaned of trailing punctuation, a
-- :line[:col] suffix and a trailing /
local function line_paths(line)
  local out = {}
  for s, p in line:gmatch '()(~?/[^%s"\'`()%[%]{}<>*]+)' do
    if s == 1 or line:sub(s - 1, s - 1):match(DIR_BOUNDARY) then
      p = p:gsub('[.,:;!?]+$', ''):gsub(':%d+[:-]%d+$', ''):gsub(':%d+$', ''):gsub('/+$', '')
      if p ~= '' and p ~= '~' then table.insert(out, p) end
    end
  end
  return out
end

-- The part of absolute path `p` before the last segment equal to `first`
-- (the first segment of a clicked relative path like figs/plot.png), or nil
local function prefix_before(p, first)
  local found, from = nil, 1
  while true do
    local s, e = p:find('/' .. first, from, true)
    if not s then return found end
    local after = p:sub(e + 1, e + 1)
    if after == '' or after == '/' then found = p:sub(1, s - 1) end
    from = s + 1
  end
end

local function search_dirs(pane, text, host_key)
  local ok, all = pcall(pane.get_logical_lines_as_text, pane, SCAN_DIR_LINES)
  local lines = {}
  for line in ((ok and all or '') .. '\n'):gmatch '([^\n]*)\n' do table.insert(lines, line) end
  -- The clicked line: the last one showing `text`, else the bottom
  local at = #lines
  for i = #lines, 1, -1 do
    if lines[i]:find(text, 1, true) then
      at = i
      break
    end
  end
  local dirs, seen = {}, {}
  local function add(d)
    if d ~= '' and d ~= '/' and not seen[d] and #dirs < MAX_DIRS then
      seen[d] = true
      table.insert(dirs, d)
    end
  end
  -- A relative path with a directory part (figs/plot.png) may sit under a
  -- shown path's ancestor: the one just above its first segment
  local first = text:gsub('^%./', ''):match '^([^/]+)/'
  if first == '..' then first = nil end
  -- Lines by distance from the clicked one, the one above first on a tie
  for dist = 0, math.max(at - 1, #lines - at) do
    for _, i in ipairs(dist == 0 and { at } or { at - dist, at + dist }) do
      for _, p in ipairs(lines[i] and line_paths(lines[i]) or {}) do
        p = p:sub(1, 1) == '/' and normalize(p) or p
        add(p)
        add(p:match '^(.+)/[^/]*$' or '')
        if first then add(prefix_before(p, first) or '') end
      end
    end
    if #dirs >= MAX_DIRS then break end
  end
  for _, d in ipairs((recent_dirs(host_key))) do add(d) end
  return dirs
end

-- "29:15", "29" or nil: the :line[:col] (or :first-last) a clicked path
-- carried, unless `path` really ends with it (a file named a:5)
local function click_line(text, path)
  local spec = text:match ':(%d+:%d+)$' or text:match ':(%d+)[:-]%d+$' or text:match ':(%d+)$'
  if spec and path:sub(-#spec - 1) ~= ':' .. spec then return spec end
end

-- Paths clicked in a local pane running ssh live on the remote host. They
-- are resolved there over the existing ControlMaster and opened in remote
-- Yazi (installed by ssh-setup, whose synced init.lua handles YAZI_PEEK)
-- through ssh-pane. Relative paths resolve against the remote shell's cwd
-- when it reports one with OSC 7 (ssh-setup's ~/.bashrc block does), then
-- the directories on screen and of recent clicks (search_dirs), then the
-- cwds of the user's processes there (an agent CLI inside tmux reports
-- nothing) and the remote home; see REMOTE_RESOLVE.

-- The remote shell's cwd from OSC 7 (file://<remote host>/dir), or nil.
-- The local shell's last report is still there while ssh runs, and its
-- host is whatever name DHCP gave this Mac at the time (it changes between
-- networks), so a dir that exists here is taken as that stale local one.
local function remote_cwd(pane)
  local url = pane:get_current_working_dir()
  if type(url) == 'userdata' and url.host and not is_local_host(url.host)
      and not exists(url.file_path) then
    return url.file_path
  end
  return nil
end

-- Shell word for path text on the remote: ~ becomes "$HOME", relative
-- paths are under it
local function remote_word(text)
  if text == '~' then return '"$HOME"' end
  if text:sub(1, 2) == '~/' then return '"$HOME"' .. sh_quote(text:sub(2)) end
  if text:sub(1, 1) == '/' then return sh_quote(text) end
  return '"$HOME"/' .. sh_quote(text)
end

-- Remote side of a path click, one round trip. Prints "d <n> <dir>" or "f
-- <n> <file>" (absolute, ./.. collapsed) for the first argument that exists
-- (the n-th), exit 1 if none does. Arguments are A:<absolute path> or R:<relative path>. A
-- relative path is tried against $RCWD (the shell's OSC 7 cwd) first, then
-- each of $DIRS (newline-separated, see search_dirs; a leading ~ is $HOME)
-- in order, then against the cwds of the user's own processes (Linux /proc;
-- those on a tty named claude/node/python/bash first, other tty ones next,
-- the rest last) and $HOME; of several of those last matches the newest
-- (mtime) wins, the earlier one in that order on a tie. `/` is never a base.
local REMOTE_RESOLVE = [[
emit() {
  if [ -d "$1" ]; then
    cd -- "$1" && printf 'd %s %s\n' "$n" "$(pwd)" && exit 0
  else
    d=$(cd -- "$(dirname -- "$1")" && pwd) && printf 'f %s %s\n' "$n" "${d%/}/$(basename -- "$1")" && exit 0
  fi
}
mtime() { stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1" 2>/dev/null || echo 0; }
bases() {
  ps -u "$(id -u)" -o pid=,tty=,comm= 2>/dev/null | while read -r pid tty comm; do
    c=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
    case $c in ''|/) continue ;; esac
    r=2
    case $tty in
      '?'|'') ;;
      *) r=1; case $comm in claude|node|python*|bash) r=0 ;; esac ;;
    esac
    printf '%s %s\n' "$r" "$c"
  done | sort -n -k1,1 | awk '!seen[substr($0, 3)]++ { print substr($0, 3) }'
  printf '%s\n' "$HOME"
}
B= n=0
for w in "$@"; do
  n=$((n + 1))
  case $w in
    A:*) p=${w#A:}; [ -e "$p" ] && emit "$p" ;;
    R:*)
      r=${w#R:}
      [ -n "$RCWD" ] && [ -e "$RCWD/$r" ] && emit "$RCWD/$r"
      while IFS= read -r b; do
        case $b in '~') b=$HOME ;; '~/'*) b=$HOME/${b#'~/'} ;; esac
        [ -n "$b" ] && [ -e "$b/$r" ] && emit "$b/$r"
      done <<EOF
$DIRS
EOF
      [ -n "$B" ] || B=$(bases)
      best= bt=-1
      while IFS= read -r b; do
        [ -n "$b" ] && [ -e "$b/$r" ] || continue
        t=$(mtime "$b/$r")
        [ "$t" -gt "$bt" ] 2>/dev/null && best=$b/$r bt=$t
      done <<EOF
$B
EOF
      [ -n "$best" ] && emit "$best" ;;
  esac
done
exit 1]]

-- REMOTE_RESOLVE argument(s) for clicked path text (see path_variants)
local function resolve_words(text)
  local words = {}
  for _, v in ipairs(path_variants(text)) do
    if v == '~' then
      table.insert(words, '"A:$HOME"')
    elseif v:sub(1, 2) == '~/' then
      table.insert(words, '"A:$HOME"' .. sh_quote(v:sub(2)))
    elseif v:sub(1, 1) == '/' then
      table.insert(words, sh_quote('A:' .. v))
    else
      table.insert(words, sh_quote('R:' .. v))
    end
  end
  return words
end

-- kind ('f' or 'd'), absolute path on the pane's host and index in `texts`
-- of the first of them that exists there, or nil and a message. The GUI
-- waits for this, so a remote that hangs (dead NFS mount, ...) is given up
-- on after REMOTE_RESOLVE_TIMEOUT seconds (perl's alarm survives the exec).
local REMOTE_RESOLVE_TIMEOUT = 5
local function resolve_remote(ssh, texts, rcwd, dirs)
  if not ssh_master_pid(ssh) then
    return nil, 'ssh: no live connection to ' .. ssh_host(ssh) .. ' (ControlMaster)'
  end
  local words, owner = {}, {}
  for t, text in ipairs(texts) do
    for _, w in ipairs(resolve_words(text)) do
      table.insert(words, w)
      table.insert(owner, t)
    end
  end
  local script = 'RCWD=' .. sh_quote(rcwd or '') .. '\nDIRS=' .. sh_quote(table.concat(dirs or {}, '\n'))
    .. '\nset -- ' .. table.concat(words, ' ')
    .. '\n' .. REMOTE_RESOLVE
  local cmd = { '/usr/bin/perl', '-e', 'alarm shift; exec @ARGV or exit 127', tostring(REMOTE_RESOLVE_TIMEOUT) }
  for _, a in ipairs(ssh_batch_cmd(ssh)) do table.insert(cmd, a) end
  table.insert(cmd, 'sh -c ' .. sh_quote(script))
  local ok, out = wezterm.run_child_process(cmd)
  local kind, n, path
  if ok then kind, n, path = out:match '^([fd]) (%d+) (/[^\n]*)' end
  if not kind then return nil, 'Path: not found on ' .. ssh_host(ssh) .. ': ' .. texts[#texts] end
  return kind, path, owner[tonumber(n)]
end

-- Paths with spaces and hard-wrapped paths: a click only hands over the
-- token a hyperlink rule matched, i.e. one space-free piece of a path like
-- /Volumes/My Disk/clip.mp4, or one line's piece of a path a TUI like
-- Claude Code broke onto the next line itself (newline + indentation, often
-- behind a gutter such as │ or ⎿). path_candidates rebuilds the longer
-- spellings from the pane's recent text: the clicked piece extended by whole
-- words to the left and right, across line breaks (joined as is and with a
-- space, gutters stripped), longest first. Unquoted spaces are ambiguous, so
-- the caller takes the longest candidate that exists. Quotes, brackets and
-- trailing punctuation at either end are also tried without. `wrapped` is
-- true when the piece ends its line and a continuation follows, i.e. on its
-- own it is likely a cut-off prefix.
local path_candidates
do
local WRAP_LINES = 3 -- lines joined at most in each direction
local SCAN_LINES = 500
local SPAN_WORDS = 8 -- words added at most, both sides together
local SPAN_CHARS = 1024
local GUTTERS = { '│', '┃', '⎿', '●', '⏺', '▎', '▏', '•', '>', '*', '`', '|' }
local OPENERS = '["\'`(%[{<=*]' -- what may precede a path (see the rules)

-- `s` without leading (or, with at_end, trailing) whitespace and gutter marks
local function strip_gutter(s, at_end)
  repeat
    local before = s
    s = at_end and (s:gsub('%s+$', '')) or (s:gsub('^%s+', ''))
    for _, g in ipairs(GUTTERS) do
      if at_end and s:sub(-#g) == g then
        s = s:sub(1, -#g - 1)
      elseif not at_end and s:sub(1, #g) == g then
        s = s:sub(#g + 1)
      end
    end
  until s == before
  return s
end

-- A line's text between its gutters
local function body(line)
  return strip_gutter(strip_gutter(line, true), false)
end

-- Suffixes that extend a piece ending before `rest` (the remainder of line
-- k) by whole words, each as { text, words used }, into `out`; at the end of
-- the line the next one continues it, joined as is or with a space
local function grow_right(lines, k, rest, acc, n, out, last)
  for sep, w in strip_gutter(rest, true):gmatch '(%s*)(%S+)' do
    if n >= SPAN_WORDS then return end
    acc, n = acc .. sep .. w, n + 1
    table.insert(out, { acc, n })
    local trimmed = acc:gsub('["\'`)%]}>*.,:;!?]+$', '')
    if trimmed ~= acc and not trimmed:match '%s$' then table.insert(out, { trimmed, n }) end
  end
  if k < last and n < SPAN_WORDS then
    local next = body(lines[k + 1])
    if next == '' then return end
    for _, join in ipairs { '', ' ' } do grow_right(lines, k + 1, join .. next, acc, n, out, last) end
  end
end

-- Prefixes the same way, to the left of a piece starting after `before`
local function grow_left(lines, k, before, acc, n, out, first)
  local words = {}
  for w, sep in strip_gutter(before, false):gmatch '(%S+)(%s*)' do table.insert(words, { w, sep }) end
  for j = #words, 1, -1 do
    if n >= SPAN_WORDS then return end
    local w, sep = words[j][1], words[j][2]
    acc, n = w .. sep .. acc, n + 1
    table.insert(out, { acc, n })
    local cut = w:match('^.*' .. OPENERS .. '(.+)$')
    if cut then table.insert(out, { cut .. sep .. acc:sub(#w + 1 + #sep), n }) end
  end
  if k > first and n < SPAN_WORDS then
    local prev = body(lines[k - 1])
    if prev == '' then return end
    for _, join in ipairs { '', ' ' } do grow_left(lines, k - 1, prev .. join, acc, n, out, first) end
  end
end

-- Start of the last occurrence of `text` in `line` that begins a word (line
-- start, whitespace or one of OPENERS before it), or nil
local function find_piece(line, text)
  local found, from = nil, 1
  while true do
    local s = line:find(text, from, true)
    if not s then return found end
    if s == 1 or line:sub(s - 1, s - 1):match('[%s' .. OPENERS:sub(2)) then found = s end
    from = s + 1
  end
end

path_candidates = function(pane, text)
  local ok, all = pcall(pane.get_logical_lines_as_text, pane, SCAN_LINES)
  local lines = {}
  for line in ((ok and all or '') .. '\n'):gmatch '([^\n]*)\n' do table.insert(lines, line) end
  for i = #lines, 1, -1 do
    local s = find_piece(lines[i], text)
    if s then
      local e = s + #text - 1
      local lefts, rights = { { '', 0 } }, { { '', 0 } }
      grow_left(lines, i, lines[i]:sub(1, s - 1), '', 0, lefts, math.max(i - WRAP_LINES, 1))
      grow_right(lines, i, lines[i]:sub(e + 1), '', 0, rights, math.min(i + WRAP_LINES, #lines))
      local cands, seen = {}, { [text] = true }
      for _, l in ipairs(lefts) do
        for _, r in ipairs(rights) do
          local c = l[1] .. text .. r[1]
          if l[2] + r[2] <= SPAN_WORDS and #c <= SPAN_CHARS and not seen[c] then
            seen[c] = true
            table.insert(cands, c)
          end
        end
      end
      local order = {}
      for idx, c in ipairs(cands) do order[c] = idx end
      table.sort(cands, function(a, b)
        if #a ~= #b then return #a > #b end
        return order[a] < order[b]
      end)
      local wrapped = strip_gutter(lines[i]:sub(e + 1), true) == '' and i < #lines
        and body(lines[i + 1]):match '^[%w%._~/@+%%:-]' ~= nil
      return cands, wrapped
    end
  end
  return {}, false
end
end
return {
  PEEK_SCHEME = PEEK_SCHEME, normalize = normalize, percent_decode = percent_decode,
  is_local_host = is_local_host, uri_to_path = uri_to_path, path_variants = path_variants,
  resolve_path = resolve_path, search_dirs = search_dirs, remember_dir = remember_dir,
  line_paths = line_paths, click_line = click_line, remote_cwd = remote_cwd,
  remote_word = remote_word, resolve_words = resolve_words, resolve_remote = resolve_remote,
  path_candidates = path_candidates,
}
