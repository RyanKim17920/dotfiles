-- Resolving clicked path text: local paths (~, relative to the pane's cwd,
-- :line suffixes, %-encoding, backslash escapes), paths on an ssh pane's host
-- (one round trip over its ControlMaster, see REMOTE_RESOLVE), the longer
-- spellings of paths with spaces or hard-wrapped by a TUI (path_candidates)
-- and the directories a relative path may be under (search_dirs, find_spec).
local wezterm = require 'wezterm'
local core = require 'lib.core'
local ssh_lib = require 'lib.ssh'
local sh_quote, exists = core.sh_quote, core.exists
local ssh_gated_cmd, ssh_host = ssh_lib.ssh_gated_cmd, ssh_lib.ssh_host

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


-- Text a TUI hard-wrapped: Claude Code and the like break a long path onto
-- the next line themselves (newline + indentation, often behind a gutter
-- such as │ or ⎿), mid-word when it has no space or hyphen to break at, so
-- the screen shows one piece of it per line. Such a line ends in a path
-- character and the next one starts with one (continues).
local WRAP_LINES = 6 -- lines a wrapped path spans at most
local GUTTERS = { '│', '┃', '⎿', '●', '⏺', '▎', '▏', '•', '>', '*', '`', '|' }

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

-- May line k + 1 of `lines` continue a path that ends line k?
local function continues(lines, k)
  local next = lines[k + 1]
  return next ~= nil and body(lines[k]):match '[%w/_~@+%%.-]$' ~= nil
    and body(next):match '^[%w/._~@+%%-]' ~= nil
end

-- The pane's last `n` logical lines (a soft-wrapped line is one)
local function pane_lines(pane, n)
  local ok, all = pcall(pane.get_logical_lines_as_text, pane, n)
  local lines = {}
  for line in ((ok and all or '') .. '\n'):gmatch '([^\n]*)\n' do table.insert(lines, line) end
  return lines
end

-- A bare name or relative path (README.md, figs/plot.png) is often printed
-- by a program that means a directory shown elsewhere on screen, or one a
-- recent click resolved, not the shell's cwd. search_dirs lists those
-- directories for resolve_path and resolve_remote: for each absolute (or ~)
-- path in the pane's last SCAN_DIR_LINES lines (one a TUI hard-wrapped
-- rejoined, see wrapped_tail), the path itself (it may be a directory), its
-- parent and, for a text like figs/plot.png, the part of it before a figs
-- segment, nearest to the clicked line first, then the directories of the
-- last clicks on the same host (remember_dir), newest first; de-duplicated,
-- at most MAX_DIRS. Nothing is checked here, so this costs no round trip;
-- the caller tests `dir/text` for each.
local SCAN_DIR_LINES, MAX_DIRS, MAX_RECENT = 2000, 60, 10
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

-- Line i's last word joined with the first word of each line below that
-- continues it (see continues), as is: one string per line joined. A path
-- a TUI hard-wrapped then shows whole (/tmp/a/b-c + d/x.png -> /tmp/a/b-cd/x.png).
local function wrapped_tail(lines, i)
  local out, acc, k = {}, body(lines[i]):match '(%S+)$', i
  while acc and k - i < WRAP_LINES and continues(lines, k) do
    local next = body(lines[k + 1])
    local w = next:match '^%S+'
    acc = acc .. w
    table.insert(out, acc)
    if w ~= next then break end -- the path ends on that line
    k = k + 1
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

-- search_dirs for the pane text `lines` and the host's recent click dirs
local function dirs_from_lines(lines, text, recent)
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
      if lines[i] then
        local found = line_paths(lines[i])
        for _, joined in ipairs(wrapped_tail(lines, i)) do
          for _, p in ipairs(line_paths(joined)) do table.insert(found, p) end
        end
        for _, p in ipairs(found) do
          p = p:sub(1, 1) == '/' and normalize(p) or p
          add(p)
          add(p:match '^(.+)/[^/]*$' or '')
          if first then add(prefix_before(p, first) or '') end
        end
      end
    end
    if #dirs >= MAX_DIRS then break end
  end
  for _, d in ipairs(recent or {}) do add(d) end
  return dirs
end

local function search_dirs(pane, text, host_key)
  return dirs_from_lines(pane_lines(pane, SCAN_DIR_LINES), text, (recent_dirs(host_key)))
end

-- "29:15", "29" or nil: the :line[:col] (or :first-last) a clicked path
-- carried, unless `path` really ends with it (a file named a:5)
local function click_line(text, path)
  local spec = text:match ':(%d+:%d+)$' or text:match ':(%d+)[:-]%d+$' or text:match ':(%d+)$'
  if spec and path:sub(-#spec - 1) ~= ':' .. spec then return spec end
end

-- Last resort for a relative path no directory above holds: a `find` for
-- it under the pane's (or agent's) cwd, at most FIND_DEPTH directories
-- down and FIND_SECS seconds per base. find_spec gives { pattern (a -path
-- glob after */), depth } for clicked `text`, or nil for an absolute one.
local FIND_DEPTH, FIND_SECS = 4, 1
local TIME_LIMIT = 'alarm shift; exec @ARGV or exit 127' -- perl -e: alarm survives the exec

local function find_spec(text)
  local rel = text:match '^(.-):%d+[:-]%d+$' or text:match '^(.-):%d+$' or text
  rel = rel:gsub('^%./', ''):gsub('\\(.)', '%1')
  if rel == '' or rel:match '^[/~]' or ('/' .. rel .. '/'):find('/../', 1, true) then return nil end
  local _, slashes = rel:gsub('/', '')
  return { pattern = (rel:gsub('[%*%?%[%]\\]', '\\%0')), depth = FIND_DEPTH + slashes }
end

-- Path `find` turns up for `spec` (find_spec) under the first of `bases`
-- that has it, or nil
local function find_local(spec, bases)
  for _, b in ipairs(bases) do
    if b ~= '' and b ~= '/' then
      local _, out = wezterm.run_child_process {
        '/usr/bin/perl', '-e', TIME_LIMIT, tostring(FIND_SECS), '/usr/bin/find', b,
        '-maxdepth', tostring(spec.depth), '(', '-name', '.git', '-o', '-name', 'node_modules', ')',
        '-prune', '-o', '-path', '*/' .. spec.pattern, '-print', '-quit',
      }
      local hit = (out or ''):match '^(/[^\n]+)'
      if hit then return hit end
    end
  end
end

-- Paths clicked in a local pane running ssh live on the remote host. They
-- are resolved there over the existing ControlMaster and opened in remote
-- Yazi (installed by ssh-setup, whose synced init.lua handles YAZI_PEEK)
-- through ssh-pane. Relative paths resolve against the remote shell's cwd
-- when it reports one with OSC 7 (ssh-setup's ~/.bashrc block does), the
-- cwds of agent CLIs there (inside tmux they report nothing), the
-- directories on screen and of recent clicks (search_dirs), the cwds of the
-- user's other processes and the remote home, then a find; see
-- REMOTE_RESOLVE.

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
-- (the n-th), exit 1 if none does. Arguments are A:<absolute path> or
-- R:<relative path>. A relative path is tried against $RCWD (the shell's
-- OSC 7 cwd), the cwds of the user's agent CLIs (claude, codex, opencode;
-- newest first), each of $DIRS (newline-separated, see search_dirs; a
-- leading ~ is $HOME) in that order, then against the cwds of the user's
-- other processes (Linux /proc; those on a tty named claude/node/python/bash
-- first, other tty ones next, the rest last) and $HOME; of several of those
-- last matches the newest (mtime) wins, the earlier one in that order on a
-- tie. `/` is never a base. When nothing exists and $FIND is set, a find
-- for */$FIND under $RCWD, the newest agent's cwd or $HOME (the first two
-- of them; FIND_SECS each, where `timeout` exists) answers as argument
-- $FIND_N.
local REMOTE_RESOLVE = [[
emit() {
  if [ -d "$1" ]; then
    cd -- "$1" && printf 'd %s %s\n' "$n" "$(pwd)" && exit 0
  else
    d=$(cd -- "$(dirname -- "$1")" && pwd) && printf 'f %s %s\n' "$n" "${d%/}/$(basename -- "$1")" && exit 0
  fi
}
# first_in BASES REL: emit BASE/REL for the first of the newline-separated
# BASES that has it
first_in() {
  while IFS= read -r b; do
    case $b in '~') b=$HOME ;; '~/'*) b=$HOME/${b#'~/'} ;; esac
    case $b in ''|/) continue ;; esac
    [ -e "$b/$2" ] && emit "$b/$2"
  done <<EOF
$1
EOF
}
mtime() { stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1" 2>/dev/null || echo 0; }
agents() {
  ps -u "$(id -u)" -o etimes=,pid=,comm=,args= 2>/dev/null | sort -n -k1,1 | while read -r t pid comm args; do
    case $comm in
      claude|codex|codex-*|opencode) ;;
      node|bun) case $args in */claude*|*/codex*|*/opencode*) ;; *) continue ;; esac ;;
      *) continue ;;
    esac
    c=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
    case $c in ''|/) continue ;; esac
    printf '%s\n' "$c"
  done | awk '!seen[$0]++'
}
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
AG= AGD= B= n=0
for w in "$@"; do
  n=$((n + 1))
  case $w in
    A:*) p=${w#A:}; [ -e "$p" ] && emit "$p" ;;
    R:*)
      r=${w#R:}
      first_in "$RCWD" "$r"
      [ -n "$AGD" ] || AG=$(agents) AGD=1
      first_in "$AG" "$r"
      first_in "$DIRS" "$r"
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
if [ -n "$FIND" ] && command -v timeout >/dev/null 2>&1; then
  [ -n "$AGD" ] || AG=$(agents)
  n=$FIND_N k=0
  while IFS= read -r b; do
    k=$((k + 1))
    [ "$k" -le 2 ] || break
    f=$(timeout "$FIND_SECS" find "$b" -maxdepth "$FIND_DEPTH" \( -name .git -o -name node_modules \) -prune \
      -o -path "*/$FIND" -print -quit 2>/dev/null)
    [ -n "$f" ] && emit "$f"
  done <<EOF
$(printf '%s\n' "$RCWD" "$AG" "$HOME" | awk '$0 != "" && $0 != "/" && !seen[$0]++')
EOF
fi
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
-- of the first of them that exists there (see REMOTE_RESOLVE; `find` is a
-- find_spec for the last of them, or nil), or nil and a message. It only
-- rides the pane's live ControlMaster (ssh_gated_cmd). The GUI waits for
-- this, so a remote that hangs (dead NFS mount, ...) is given up on after
-- REMOTE_RESOLVE_TIMEOUT seconds. Words past MAX_WORD_BYTES are left out:
-- the remote shell gets the script as one argument (Linux: 128 KiB at most).
local REMOTE_RESOLVE_TIMEOUT, MAX_WORD_BYTES = 5, 48 * 1024
local function resolve_remote(ssh, texts, rcwd, dirs, find)
  local words, owner, bytes = {}, {}, 0
  for t, text in ipairs(texts) do
    for _, w in ipairs(resolve_words(text)) do
      -- The clicked text (last) always goes in
      if t == #texts or bytes + #w <= MAX_WORD_BYTES then
        bytes = bytes + #w + 1
        table.insert(words, w)
        table.insert(owner, t)
      end
    end
  end
  local find_n = #owner
  while find_n > 1 and owner[find_n - 1] == #texts do find_n = find_n - 1 end
  local script = table.concat({
    'RCWD=' .. sh_quote(rcwd or ''),
    'DIRS=' .. sh_quote(table.concat(dirs or {}, '\n')),
    'FIND=' .. sh_quote(find and find.pattern or ''),
    'FIND_DEPTH=' .. (find and find.depth or 0) .. ' FIND_SECS=' .. FIND_SECS .. ' FIND_N=' .. find_n,
    'set -- ' .. table.concat(words, ' '),
    REMOTE_RESOLVE,
  }, '\n')
  local cmd = { '/usr/bin/perl', '-e', TIME_LIMIT, tostring(REMOTE_RESOLVE_TIMEOUT) }
  for _, a in ipairs(ssh_gated_cmd(ssh, 'sh -c ' .. sh_quote(script))) do table.insert(cmd, a) end
  local _, out, err = wezterm.run_child_process(cmd)
  local kind, n, path = (out or ''):match '^([fd]) (%d+) (/[^\n]*)'
  if kind then return kind, path, owner[tonumber(n)] end
  err = err or ''
  local why = err:match 'GATE: ([^\n]*)'
  if why then return nil, 'ssh: ' .. why end
  -- sshd's MaxSessions (10 by default) caps the sessions on one connection
  if err:find('refused', 1, true) then
    return nil, 'ssh: ' .. ssh_host(ssh) .. ' refused one more session on the shared connection'
      .. ' (sshd MaxSessions); close an ssh tab or pane to it'
  end
  return nil, 'Path: not found on ' .. ssh_host(ssh) .. ': ' .. texts[#texts]
end

-- Paths with spaces and hard-wrapped paths: a click only hands over the
-- token a hyperlink rule matched, i.e. one space-free piece of a path like
-- /Volumes/My Disk/clip.mp4, or one line's piece of a path a TUI broke over
-- lines (see continues). WezTerm 20240203 does not say where the click was,
-- so line_candidates looks at each place the piece shows as a whole word
-- in the pane's recent text, the bottom one first (at most MAX_SPOTS), and
-- rebuilds the longer spellings there: the piece extended by whole words to
-- the left and right and, where a line ends in a path character and the
-- next starts with one, across up to WRAP_LINES line breaks (joined as is
-- and with a space, indentation and gutters stripped), stopping at each
-- line on the way. Unquoted spaces are ambiguous, so the caller takes the
-- first candidate that exists: those of the bottom place first, longest
-- first. Prose stops the growth: an em or en dash (path.png — runs), and a
-- word ending in , ; : ! or ?, which is tried without it (path.png:);
-- quotes, brackets and trailing punctuation at either end are also tried
-- without. The piece itself is not among them.
local line_candidates, path_candidates
do
local SCAN_LINES = 500
local SPAN_WORDS = 10 -- words added at most, both sides together
local SPAN_CHARS = 1024
local MAX_SPOTS = 4
local OPENERS = '["\'`(%[{<=*]' -- what may precede a path (see the rules)
local DASHES = { ['—'] = true, ['–'] = true }

-- Does word `w` end a phrase (a path rarely goes on after , ; : ! ?)?
local function ends_phrase(w)
  return w:match '[,;:!?]["\'`)%]}>*]*$' ~= nil
end

-- Suffixes that extend a piece ending before `rest` (the remainder of line
-- k) by whole words, each as { text, words used }, into `out`; at the end of
-- the line the next one may continue it, joined as is or with a space
local function grow_right(lines, k, rest, acc, n, out, last)
  for sep, w in strip_gutter(rest, true):gmatch '(%s*)(%S+)' do
    if n >= SPAN_WORDS or DASHES[w] then return end
    acc, n = acc .. sep .. w, n + 1
    table.insert(out, { acc, n })
    local trimmed = acc:gsub('["\'`)%]}>*.,:;!?]+$', '')
    if trimmed ~= acc and not trimmed:match '%s$' then table.insert(out, { trimmed, n }) end
    if ends_phrase(w) then return end
  end
  if k < last and n < SPAN_WORDS and continues(lines, k) then
    local next = body(lines[k + 1])
    for _, join in ipairs { '', ' ' } do grow_right(lines, k + 1, join .. next, acc, n, out, last) end
  end
end

-- Prefixes the same way, to the left of a piece starting after `before`
local function grow_left(lines, k, before, acc, n, out, first)
  local words = {}
  for w, sep in strip_gutter(before, false):gmatch '(%S+)(%s*)' do table.insert(words, { w, sep }) end
  for j = #words, 1, -1 do
    local w, sep = words[j][1], words[j][2]
    if n >= SPAN_WORDS or DASHES[w] or ends_phrase(w) then return end
    acc, n = w .. sep .. acc, n + 1
    table.insert(out, { acc, n })
    local cut = w:match('^.*' .. OPENERS .. '(.+)$')
    if cut then table.insert(out, { cut .. sep .. acc:sub(#w + 1 + #sep), n }) end
  end
  if k > first and n < SPAN_WORDS and continues(lines, k - 1) then
    local prev = body(lines[k - 1])
    for _, join in ipairs { '', ' ' } do grow_left(lines, k - 1, prev .. join, acc, n, out, first) end
  end
end

-- Starts of the places `text` shows in `line` as a whole word: after the
-- line start, whitespace or one of OPENERS, and not followed by more of a
-- path (a path character, or a dot and a word character)
local function piece_starts(line, text)
  local found, from = {}, 1
  while true do
    local s = line:find(text, from, true)
    if not s then return found end
    local after = line:sub(s + #text, s + #text + 1)
    if (s == 1 or line:sub(s - 1, s - 1):match('[%s' .. OPENERS:sub(2)))
        and not after:match '^[%w/_~@+%%-]' and not after:match '^%.%w' then
      table.insert(found, s)
    end
    from = s + 1
  end
end

line_candidates = function(lines, text)
  local out, seen, spots = {}, { [text] = true }, 0
  for i = #lines, 1, -1 do
    local starts = piece_starts(lines[i], text)
    for j = #starts, 1, -1 do
      if spots == MAX_SPOTS then return out end
      spots = spots + 1
      local s = starts[j]
      local lefts, rights = { { '', 0 } }, { { '', 0 } }
      grow_left(lines, i, lines[i]:sub(1, s - 1), '', 0, lefts, math.max(i - WRAP_LINES, 1))
      grow_right(lines, i, lines[i]:sub(s + #text), '', 0, rights, math.min(i + WRAP_LINES, #lines))
      local cands = {}
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
      for _, c in ipairs(cands) do table.insert(out, c) end
    end
  end
  return out
end

path_candidates = function(pane, text)
  return line_candidates(pane_lines(pane, SCAN_LINES), text)
end
end
return {
  PEEK_SCHEME = PEEK_SCHEME, normalize = normalize, percent_decode = percent_decode,
  is_local_host = is_local_host, uri_to_path = uri_to_path, path_variants = path_variants,
  resolve_path = resolve_path, search_dirs = search_dirs, dirs_from_lines = dirs_from_lines,
  remember_dir = remember_dir, line_paths = line_paths, wrapped_tail = wrapped_tail,
  click_line = click_line, find_spec = find_spec, find_local = find_local,
  remote_cwd = remote_cwd, remote_word = remote_word, resolve_words = resolve_words,
  resolve_remote = resolve_remote, line_candidates = line_candidates,
  path_candidates = path_candidates,
}
