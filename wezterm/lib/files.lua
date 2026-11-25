-- Files opened outside the terminal, all run in the background by
-- FILE_SCRIPT: reveal in Finder, Quick Look, Preview, and copies from an ssh
-- pane's host over its ControlMaster (downloads, Preview and Quick Look
-- caches). Background copies report through status files that
-- enable_polling's update-status handler turns into toasts.
local wezterm = require 'wezterm'
local core = require 'lib.core'
local ssh_lib = require 'lib.ssh'
local toast, is_dir, sh_quote = core.toast, core.is_dir, core.sh_quote
local ssh_batch_cmd, ssh_host = ssh_lib.ssh_batch_cmd, ssh_lib.ssh_host

-- Quick Look (CMD+OPT+SHIFT+click), see LINK_MODE_KEY
local QUICKLOOK_PID = wezterm.home_dir .. '/.local/state/wezterm/quicklook.pid'
local PEEK_CACHE = wezterm.home_dir .. '/Library/Caches/wezterm/peek/'

-- sh -c script: pidfile mode args...
--   reveal <file>      select it in Finder (AppleScript, since `open -R` skips
--                      files under hidden paths like /private/tmp; falls back
--                      to `open -R` if osascript fails, e.g. Automation denied)
--   look <file>        Quick Look it; one panel at a time (the qlmanage
--                      started last time is closed first)
--   reveal-copy|look-copy <dir> <name> <cmd...>
--                      run cmd (cat of a remote file) into dir/name via a
--                      .part file, then reveal it in Finder or Quick Look
--                      it; notify on failure
--   download <dir> <status> <cmd...>
--                      unpack the tar stream of one file or folder that cmd
--                      writes into dir, under a numbered name if a different
--                      item already has that name (picked under a lock, so
--                      parallel downloads of the same name each keep their
--                      own copy), write the outcome to the
--                      status file (three lines: kind, path, size or error;
--                      see DOWNLOAD_NOTES) and reveal it in Finder. Exit 1-2
--                      are tar's "some files changed or were unreadable";
--                      higher is ssh or the remote shell failing.
--   preview <status> <file>
--                      open it in Preview; status as for download (kind
--                      `opened` or `failed`)
--   preview-copy <dir> <name> <status> <stat cmd> <cat cmd> <ssh...>
--                      copy a remote file into dir/name (ssh... + cat cmd)
--                      unless dir/.stamp still matches its size and mtime
--                      (ssh... + stat cmd), then preview it
local FILE_SCRIPT = [[
pf=$1 mode=$2; shift 2
reveal() {
  osascript -e 'on run argv' -e 'tell application "Finder"' \
    -e 'reveal POSIX file (item 1 of argv)' -e 'activate' -e 'end tell' \
    -e 'end run' "$1" >/dev/null 2>&1 || open -R -- "$1"
}
look() {
  old=$(cat "$pf" 2>/dev/null)
  case $(ps -o comm= -p "${old:-0}" 2>/dev/null) in *qlmanage) kill "$old" ;; esac
  mkdir -p "$(dirname "$pf")"
  qlmanage -p "$1" >/dev/null 2>&1 &
  echo $! > "$pf"
  wait $!
  # qlmanage aborts on video (AVKit: highlightedTimeRanges unsupported) and
  # shows nothing; reveal it in Finder instead (Space there previews it).
  # 143 = SIGTERM from the next Quick Look replacing this panel
  st=$?
  if [ "$st" -gt 128 ] && [ "$st" -ne 143 ]; then reveal "$1"; fi
}
report() { printf '%s\n' "$1" "$2" "$3" > "$st.tmp" && mv -f "$st.tmp" "$st"; }
download() {
  dir=$1 st=$2; shift 2
  mkdir -p "$dir" "$(dirname "$st")"
  tmp=$(mktemp -d "$dir/.download.XXXXXX") || { report failed "$dir" 'cannot write there'; return; }
  mkdir "$tmp/x"
  { "$@" 2> "$tmp/err"; echo $? > "$tmp/rc"; } | tar -xf - -C "$tmp/x" 2> "$tmp/xerr"
  xrc=$? rc=$(cat "$tmp/rc")
  # read-only remote folders could neither be renamed nor deleted here
  chmod -R u+rwX "$tmp/x"
  item=$(find "$tmp/x" -mindepth 1 -maxdepth 1 -print -quit)
  if [ "$xrc" -ne 0 ] || [ "$rc" -gt 2 ] || [ -z "$item" ]; then
    msg=$(tail -n 1 "$tmp/err")
    report failed '' "${msg:-$(tail -n 1 "$tmp/xerr")}"
    rm -rf "$tmp"
    return
  fi
  base=${item##*/} stem=${item##*/} ext=
  if [ -f "$item" ]; then
    case $base in ?*.*) stem=${base%.*} ext=.${base##*.} ;; esac
  fi
  dest=$dir/$base n=0 kind=done
  [ "$rc" -eq 0 ] || kind=partial
  # A lock left by a killed download is ignored after ~10s
  lock=$dir/.download.lock w=0
  until mkdir "$lock" 2>/dev/null || [ "$w" -ge 100 ]; do sleep 0.1; w=$((w + 1)); done
  while [ -e "$dest" ] || [ -L "$dest" ]; do
    if diff -rq "$dest" "$item" > /dev/null 2>&1; then kind=same; break; fi
    n=$((n + 1)) dest="$dir/$stem ($n)$ext"
  done
  [ "$kind" = same ] || mv -n "$item" "$dest"
  rmdir "$lock" 2>/dev/null
  rm -rf "$tmp"
  report "$kind" "$dest" "$(du -sh "$dest" | awk '{ print $1 }')"
  reveal "$dest"
}
fail() { report failed '' "$(tail -n 1 "$st.err" 2>/dev/null)"; rm -f "$st.err"; }
preview() {
  st=$1
  mkdir -p "$(dirname "$st")"
  if open -a Preview -- "$2" 2> "$st.err"; then report opened "$2" ''; rm -f "$st.err"; else fail; fi
}
preview_copy() {
  dir=$1 name=$2 st=$3 statcmd=$4 catcmd=$5; shift 5
  f=$dir/$name
  mkdir -p "$dir" "$(dirname "$st")" || { report failed '' 'cannot write the cache'; return; }
  stamp=$("$@" "$statcmd" 2> "$st.err") && [ -n "$stamp" ] || { fail; return; }
  if [ ! -f "$f" ] || [ "$(cat "$dir/.stamp" 2>/dev/null)" != "$stamp" ]; then
    rm -f "$dir/.stamp"
    "$@" "$catcmd" > "$f.part" 2> "$st.err" && mv -f "$f.part" "$f" \
      || { rm -f "$f.part"; fail; return; }
    printf '%s\n' "$stamp" > "$dir/.stamp"
  fi
  rm -f "$st.err"
  preview "$st" "$f"
}
if [ "$mode" = preview ]; then preview "$@"; exit; fi
if [ "$mode" = preview-copy ]; then preview_copy "$@"; exit; fi
if [ "$mode" = look ]; then look "$1"; exit; fi
if [ "$mode" = reveal ]; then reveal "$1"; exit; fi
if [ "$mode" = download ]; then download "$@"; exit; fi
dir=$1 name=$2; shift 2
if mkdir -p "$dir" && "$@" > "$dir/$name.part" && mv -f "$dir/$name.part" "$dir/$name"; then
  if [ "$mode" = look-copy ]; then look "$dir/$name"; else reveal "$dir/$name"; fi
  exit
fi
rm -f "$dir/$name.part"
osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "wezterm"' -e 'end run' "Copy failed: $name"]]

local function file_cmd(mode, ...)
  return { '/bin/sh', '-c', FILE_SCRIPT, 'sh', QUICKLOOK_PID, mode, ... }
end

local function reveal_local(path)
  wezterm.background_child_process(is_dir(path) and { '/usr/bin/open', path }
    or file_cmd('reveal', path))
end

local function quicklook_local(window, path)
  wezterm.background_child_process(file_cmd('look', path))
  toast(window, 'Quick Look: ' .. (path:match '[^/]+$' or path), 2000)
end

-- Copies from the pane's host over the master.
-- Copy remote file `path` into local `dir` over the master, then reveal or
-- Quick Look it (mode 'reveal-copy' / 'look-copy')
local function fetch_remote(ssh, path, mode, dir)
  local cmd = file_cmd(mode, dir, path:match '[^/]+$')
  for _, a in ipairs(ssh_batch_cmd(ssh)) do table.insert(cmd, a) end
  table.insert(cmd, 'cat -- ' .. sh_quote(path))
  wezterm.background_child_process(cmd)
end

-- Host as a safe local directory name
local function host_dir(ssh)
  return (ssh_host(ssh):gsub('[^%w.-]', '_'))
end

local function reveal_remote(window, ssh, kind, path)
  local host = ssh_host(ssh)
  if kind == 'd' then
    toast(window, 'Finder: ' .. host .. ':' .. path .. ' is a remote directory; not copied')
    return
  end
  local sub = host_dir(ssh)
  fetch_remote(ssh, path, 'reveal-copy', wezterm.home_dir .. '/Downloads/' .. sub)
  toast(window, 'Finder: copying ' .. host .. ':' .. path .. ' to ~/Downloads/' .. sub .. '/')
end

local function quicklook_remote(window, ssh, path)
  fetch_remote(ssh, path, 'look-copy', PEEK_CACHE .. host_dir(ssh))
  toast(window, 'Quick Look: copying ' .. ssh_host(ssh) .. ':' .. path, 2000)
end

-- Right-click on a path in an ssh pane: download the file or folder to
-- ~/Downloads/<host>/ in the background. tar works for both, keeps names with
-- spaces and needs nothing but ssh and tar on the host (rsync may be missing
-- there, and this Mac's is openrsync). The transfer outlives this config
-- (reloads, ...), so it is not waited for here: `download` in FILE_SCRIPT
-- leaves a status file, which update-status picks up. wezterm.time.call_after
-- would be dropped by a reload. preview_file tracks its copies the same way.
local DOWNLOADS_KEY = 'downloads' -- JSON list of { status, window, what, area? }
local DOWNLOAD_STATUS_DIR = wezterm.home_dir .. '/.local/state/wezterm/downloads/'
local DOWNLOAD_NOTES = {
  done = 'Download: %s (%s) in %s',
  partial = 'Download: %s (%s) in %s, INCOMPLETE: some files changed or were unreadable',
  same = 'Download: %s (%s) was already in %s',
}

-- $1: remote path. A symlink gets its target, not a dangling link.
local REMOTE_TAR = [[
p=$(readlink -f -- "$1" 2>/dev/null) || p=$1
[ "$p" != / ] || { echo 'refusing to download /' >&2; exit 3; }
cd -- "$(dirname -- "$p")" && exec tar -cf - -- "./$(basename -- "$p")"]]

local function set_downloads(list)
  wezterm.GLOBAL[DOWNLOADS_KEY] = #list > 0 and wezterm.json_encode(list) or nil
end

local function downloads()
  return wezterm.json_parse(wezterm.GLOBAL[DOWNLOADS_KEY] or '[]')
end

-- New status file path for a background copy
local function new_status()
  local seq = (wezterm.GLOBAL.download_seq or 0) + 1
  wezterm.GLOBAL.download_seq = seq
  return DOWNLOAD_STATUS_DIR .. os.time() .. '-' .. seq
end

-- Have update-status toast the outcome written to `status`
local function track(window, status, what, area)
  local list = downloads()
  table.insert(list, { status = status, window = window:window_id(), what = what, area = area })
  set_downloads(list)
end

-- Download each remote path in `paths` (a list) in parallel, each with its
-- own status file (so its own toast when done), after one toast for all
local function download_remote(window, ssh, paths)
  local sub = host_dir(ssh)
  for _, path in ipairs(paths) do
    local status = new_status()
    local cmd = file_cmd('download', wezterm.home_dir .. '/Downloads/' .. sub, status)
    for _, a in ipairs(ssh_batch_cmd(ssh)) do table.insert(cmd, a) end
    table.insert(cmd, 'sh -c ' .. sh_quote(REMOTE_TAR) .. ' sh ' .. sh_quote(path))
    wezterm.background_child_process(cmd)
    track(window, status, ssh_host(ssh) .. ':' .. path)
  end
  local what = #paths == 1 and (ssh_host(ssh) .. ':' .. paths[1])
    or (#paths .. ' items from ' .. ssh_host(ssh))
  toast(window, 'Download: ' .. what .. ' to ~/Downloads/' .. sub .. '/', 4000)
end

-- Paths of a user var request from remote Yazi (g m, g o): "NONCE\n/abs/path\n..."
-- (base64-decoded by WezTerm; the nonce makes a repeat request a change).
-- Returns the absolute paths, deduplicated, and how many lines were not one.
local function request_paths(value)
  local paths, seen, bad = {}, {}, 0
  for line in (value:match '^[^\n]*\n(.*)$' or ''):gmatch '[^\n]+' do
    if line:sub(1, 1) ~= '/' or line:find '[\0\r]' then
      bad = bad + 1
    elseif not seen[line] then
      seen[line] = true
      table.insert(paths, line)
    end
  end
  return paths, bad
end

-- 8 hex digits (FNV-1a) naming the cache folder of one remote path, so files
-- with the same name in different remote folders don't overwrite each other
local function short_hash(s)
  local h = 2166136261
  for k = 1, #s do h = ((h ~ s:byte(k)) * 16777619) & 0xffffffff end
  return string.format('%08x', h)
end

-- Open a PDF in Preview without blocking the GUI. A local one opens in
-- place; a remote one (ssh given) is copied over the master to
-- PEEK_CACHE/<host>/<hash of path>/<name> first, or reused from there when
-- its size and mtime are unchanged. Failures toast via update-status.
local function preview_file(window, path, ssh)
  local name = path:match '[^/]+$' or path
  local status = new_status()
  local cmd, what = file_cmd('preview', status, path), name
  if ssh then
    local q = sh_quote(path)
    cmd = file_cmd('preview-copy', PEEK_CACHE .. host_dir(ssh) .. '/' .. short_hash(path), name,
      status, 'sh -c ' .. sh_quote('{ stat -L -c "%s %Y" -- ' .. q .. ' || stat -L -f "%z %m" -- '
        .. q .. '; } 2>/dev/null || { echo "cannot read the file" >&2; exit 1; }'),
      'cat -- ' .. q)
    for _, a in ipairs(ssh_batch_cmd(ssh)) do table.insert(cmd, a) end
    what = ssh_host(ssh) .. ':' .. path
  end
  wezterm.background_child_process(cmd)
  track(window, status, what, 'Preview')
  toast(window, 'Preview: opening ' .. name .. (ssh and (' from ' .. ssh_host(ssh)) or '') .. '…', 2000)
end

local function download_note(d, kind, dest, info)
  if kind == 'opened' then return nil end -- preview_file: Preview shows it
  if kind == 'note' then return info end -- the copy wrote its own message
  if not DOWNLOAD_NOTES[kind] then
    info = ssh_lib.refusal_note(info) or info
    return (d.area or 'Download') .. ' failed: ' .. d.what .. ((info or '') ~= '' and (': ' .. info) or '')
  end
  local dir, name = dest:match '^(.*)/([^/]*)$'
  if dir:sub(1, #wezterm.home_dir + 1) == wezterm.home_dir .. '/' then
    dir = '~' .. dir:sub(#wezterm.home_dir + 1)
  end
  return string.format(DOWNLOAD_NOTES[kind], name, info, dir .. '/')
end

-- Every status file is taken and the list saved before the first toast:
-- finding the window yields, and other windows poll in the meantime
local function poll_downloads(window)
  local left, finished = {}, {}
  for _, d in ipairs(downloads()) do
    local f = io.open(d.status)
    if f then
      local kind, dest, info = f:read('a'):match '^([^\n]*)\n([^\n]*)\n([^\n]*)'
      f:close()
      os.remove(d.status)
      local note = download_note(d, kind, dest, info)
      if note then table.insert(finished, { d = d, note = note }) end
    else
      table.insert(left, d)
    end
  end
  set_downloads(left)
  for _, r in ipairs(finished) do
    -- It raises for a window closed since the click
    local ok, target = pcall(wezterm.gui.gui_window_for_mux_window, r.d.window)
    toast(ok and target or window, r.note, 8000)
  end
end

-- Toast the outcome of background copies (downloads, Preview copies) once
-- their status file appears. Registered once, by the first feature that needs it.
local polling = false
local function enable_polling()
  if polling then return end
  polling = true
  wezterm.on('update-status', function(window)
    if wezterm.GLOBAL[DOWNLOADS_KEY] then poll_downloads(window) end
  end)
end

return {
  QUICKLOOK_PID = QUICKLOOK_PID, PEEK_CACHE = PEEK_CACHE, FILE_SCRIPT = FILE_SCRIPT,
  file_cmd = file_cmd, reveal_local = reveal_local, quicklook_local = quicklook_local,
  reveal_remote = reveal_remote, quicklook_remote = quicklook_remote,
  download_remote = download_remote, preview_file = preview_file, enable_polling = enable_polling,
  REMOTE_TAR = REMOTE_TAR, host_dir = host_dir, short_hash = short_hash, new_status = new_status,
  track = track, request_paths = request_paths,
}
