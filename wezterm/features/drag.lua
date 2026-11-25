-- Finder drag and drop in both directions through the wez-drag helper
-- (macos/wez-drag): WezTerm 20240203 can't start a drag and has no file-drop
-- event, so a small floating window does it.
--   Out: Yazi's g o sets the user var wez_drag_out (see files.request_paths).
--        In an ssh pane the files are first copied over the pane's
--        ControlMaster to CACHE/<host>/<hash of path>/, then `wez-drag out`
--        shows them to drag to Finder, the Desktop, Mail...
--   In:  Yazi's g i sets wez_drag_in to "NONCE\n<cwd>", and CMD+SHIFT+U opens
--        the same drop zone for the focused pane's directory (an ssh pane's
--        remote cwd from OSC 7, else the remote home). `wez-drag in` prints
--        what was dropped; each item is sent with tar over the master (or
--        copied, in a local pane). Nothing is overwritten: a name that is
--        taken becomes `name (1).ext`.
-- All of it runs in the background (DRAG_SCRIPT) and reports through a
-- status file, toasted by files.enable_polling. Remote work is gated on a
-- live master (ssh_lib.MASTER_SH) and never logs in.
local wezterm = require 'wezterm'
local core = require 'lib.core'
local ssh_lib = require 'lib.ssh'
local files = require 'lib.files'
local toast = core.toast
local pane_ssh_args, ssh_host = ssh_lib.pane_ssh_args, ssh_lib.ssh_host

local M = {}

local HELPER = wezterm.home_dir .. '/.local/bin/wez-drag'
local CACHE = wezterm.home_dir .. '/Library/Caches/wezterm/drag/'
-- Most items one drag out may fetch (each is its own ssh + tar)
local MAX_ITEMS = 50

-- Run where the files land (remote or local): $1 dest dir, $2 name of the one
-- item in the tar stream on stdin. Unpacks into a temp dir next to it, then
-- moves it to the first free name of `name`, `name (1).ext`, ... and prints
-- that name.
local UNTAR = [[
d=$1 n=$2
cd -- "$d" 2>/dev/null || { echo "cannot open $d" >&2; exit 3; }
tmp=$(mktemp -d ./.wez-drop.XXXXXX 2>/dev/null) || { echo "cannot write to $d" >&2; exit 3; }
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
tar -xf - -C "$tmp" || exit 4
[ -e "$tmp/$n" ] || [ -L "$tmp/$n" ] || { echo "nothing arrived for $n" >&2; exit 4; }
stem=$n ext=
if [ -f "$tmp/$n" ]; then
  case $n in ?*.*) stem=${n%.*} ext=.${n##*.} ;; esac
fi
t=$n k=0
while [ -e "$t" ] || [ -L "$t" ]; do k=$((k + 1)); t="$stem ($k)$ext"; done
mv -- "$tmp/$n" "./$t" || exit 5
printf '%s\n' "$t"]]

-- sh -c script: mode status helper args... [ssh args...]; no ssh args means
-- a local pane. Writes the status file (kind, path, message) as `download`
-- in files.FILE_SCRIPT does.
--   out <cache> <items> <remote tar> [ssh...]
--       items: one per line; local: /abs/path, remote: <hash>/abs/path,
--       fetched into <cache>/<hash>/ with <remote tar> (files.REMOTE_TAR)
--   in <label> <dest> <untar> [ssh...]
--       open the drop zone, then send each dropped item to <dest> with
--       <untar> (UNTAR)
local DRAG_SCRIPT = ssh_lib.MASTER_SH .. [[
mode=$1 st=$2 helper=$3; shift 3
nl='
'
report() {
  mkdir -p "$(dirname "$st")"
  printf '%s\n' "$1" "$2" "$3" > "$st.tmp" && mv -f "$st.tmp" "$st"
}
squote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# on_host CMD [ssh...]: run the sh command CMD on the host, or here
on_host() {
  c=$1; shift
  if [ "$#" -gt 0 ]; then master_ssh "$@" "$c"; else sh -c "$c"; fi
}
# Newline-separated $1 into "$@" of the helper, which never returns
drag() {
  set -f; IFS=$nl; set -- $1; unset IFS; set +f
  exec "$helper" out -- "$@"
}

drag_out() {
  cache=$1 items=$2 rtar=$3; shift 3
  if [ "$#" -eq 0 ]; then
    report opened '' ''
    drag "$items"
  fi
  master_gate "$@" || { report failed '' "$why"; return; }
  mkdir -p "$cache" || { report failed '' 'cannot write the cache'; return; }
  # Earlier drags' copies (Finder has its own by now)
  find "$cache" -mindepth 1 -maxdepth 1 -mtime +0 -exec rm -rf {} + 2>/dev/null
  list= n=0 failed=0 err=
  set -f; IFS=$nl
  for line in $items; do
    unset IFS; set +f
    n=$((n + 1)) h=${line%%/*} p=/${line#*/}
    d=$cache/$h
    rm -rf "$d" && mkdir -p "$d" || { report failed '' 'cannot write the cache'; return; }
    { on_host "sh -c $(squote "$rtar") sh $(squote "$p")" "$@" < /dev/null 2> "$d.err"
      echo $? > "$d.rc"; } | tar -xf - -C "$d" 2>> "$d.err"
    xrc=$? rc=$(cat "$d.rc")
    # read-only remote folders could not be replaced next time
    chmod -R u+rwX "$d"
    item=$(find "$d" -mindepth 1 -maxdepth 1 -print -quit)
    if [ "$xrc" -ne 0 ] || [ "$rc" -gt 2 ] || [ -z "$item" ]; then
      failed=$((failed + 1)) err=$(head -n 1 "$d.err")
      rm -rf "$d"
    else
      list=$list$nl$item
    fi
    rm -f "$d.err" "$d.rc"
    set -f; IFS=$nl
  done
  unset IFS; set +f
  if [ -z "$list" ]; then
    report failed '' "${err:-nothing came}"
  elif [ "$failed" -gt 0 ]; then
    report note '' "Drag: $failed of $n items could not be fetched: $err"
  else
    report opened '' ''
  fi
  [ -n "$list" ] && drag "$list"
}

drag_in() {
  label=$1 dest=$2 untar=$3; shift 3
  verb=Copy
  if [ "$#" -gt 0 ]; then
    verb=Upload
    master_gate "$@" || { report failed '' "$why"; return; }
  fi
  drops=$("$helper" in --dest "$label" | tr '\0' '\n')
  if [ -z "$drops" ]; then report opened '' ''; return; fi # cancelled
  # The window may have been open a while
  if [ "$#" -gt 0 ]; then
    master_gate "$@" || { report failed '' "$why"; return; }
  fi
  e=$(mktemp) || { report failed '' 'cannot make a temp file'; return; }
  ok=0 failed=0 err= renamed= one=
  set -f; IFS=$nl
  for p in $drops; do
    unset IFS; set +f
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then
      failed=$((failed + 1)) err="no such file: $p"
      set -f; IFS=$nl
      continue
    fi
    name=${p##*/}
    # No AppleDouble ._ files or Mac xattrs, which Linux tar warns about
    got=$(COPYFILE_DISABLE=1 tar -C "$(dirname -- "$p")" --no-xattrs --no-mac-metadata -cf - "./$name" 2> "$e" \
      | on_host "sh -c $(squote "$untar") sh $(squote "$dest") $(squote "$name")" "$@" 2>> "$e")
    if [ $? -eq 0 ] && [ -n "$got" ]; then
      ok=$((ok + 1)) one=$got
      [ "$got" = "$name" ] || renamed="$renamed, $name -> $got"
    else
      failed=$((failed + 1)) err=$(head -n 1 "$e")
    fi
    set -f; IFS=$nl
  done
  unset IFS; set +f
  rm -f "$e"
  [ "$ok" -eq 1 ] && what=$one || what="$ok items"
  msg="$verb: $what to $label"
  [ -z "$renamed" ] || msg="$msg (names taken, kept both: ${renamed#, })"
  [ "$failed" -eq 0 ] || msg="$msg; $failed failed: ${err:-unknown error}"
  if [ "$ok" -eq 0 ]; then report failed '' "${err:-unknown error}"; else report note '' "$msg"; fi
}

case $mode in
out) drag_out "$@" ;;
in) drag_in "$@" ;;
esac]]

local function have_helper(window)
  if core.exists(HELPER) then return true end
  toast(window, 'Drag: ~/.local/bin/wez-drag is missing; build it with macos/wez-drag/build.sh', 6000)
  return false
end

-- Start DRAG_SCRIPT in the background (the GUI never waits on it); `area`
-- and `what` name a failure in its toast
local function run(window, mode, area, what, args, ssh)
  local status = files.new_status()
  local cmd = { '/usr/bin/env', 'PATH=' .. core.SPAWN_PATH, '/bin/sh', '-c', DRAG_SCRIPT, 'sh', mode, status, HELPER }
  for _, a in ipairs(args) do table.insert(cmd, a) end
  for k = 2, #(ssh or {}) do table.insert(cmd, ssh[k]) end
  wezterm.background_child_process(cmd)
  files.track(window, status, what, area)
end

local function drag_out(window, pane, value)
  local paths, bad = files.request_paths(value)
  if bad > 0 then wezterm.log_warn('drag: ignored ' .. bad .. ' invalid path(s) in wez_drag_out') end
  if #paths == 0 then
    if bad > 0 then toast(window, 'Drag: no usable path in the request') end
    return
  elseif #paths > MAX_ITEMS then
    toast(window, 'Drag: ' .. #paths .. ' items selected, at most ' .. MAX_ITEMS
      .. '; select their folder instead', 6000)
    return
  end
  if not have_helper(window) then return end
  local what = #paths == 1 and paths[1] or (#paths .. ' items')
  local ssh = pane_ssh_args(pane)
  if not ssh then
    run(window, 'out', 'Drag', what, { '', table.concat(paths, '\n'), '' })
    return
  end
  -- "<8 hex>/abs/path": paths start with /
  local items = {}
  for _, p in ipairs(paths) do table.insert(items, files.short_hash(p) .. p) end
  local host = ssh_host(ssh)
  run(window, 'out', 'Drag', host .. ':' .. what,
    { CACHE .. files.host_dir(ssh), table.concat(items, '\n'), files.REMOTE_TAR }, ssh)
  toast(window, 'Drag: downloading ' .. what .. ' from ' .. host .. '…', 4000)
end

-- Open the drop zone for `dest` (absolute, or '.' for the remote home) on
-- the pane's host, or locally in a local pane
local function drop_in(window, pane, dest)
  if not have_helper(window) then return end
  local ssh = pane_ssh_args(pane)
  local label = ssh and (ssh_host(ssh) .. ':' .. (dest == '.' and '~' or dest)) or dest
  run(window, 'in', ssh and 'Upload' or 'Copy', label, { label, dest, UNTAR }, ssh)
end

-- OSC 7 hosts that mean this Mac rather than the ssh host
local LOCAL_HOST = wezterm.hostname():lower()
local function is_local_host(h)
  h = (h or ''):lower()
  return h == '' or h == 'localhost' or h == LOCAL_HOST or h == LOCAL_HOST:match '^[^.]*'
end

-- Where CMD+SHIFT+U drops: in an ssh pane the remote cwd that OSC 7 reported
-- (the ssh-setup bashrc block sends it), else '.', the remote home where ssh
-- starts; in a local pane its cwd
local function pane_dest(pane, ssh)
  if not ssh then return core.pane_cwd(pane) end
  local url = pane:get_current_working_dir()
  if type(url) == 'userdata' and not is_local_host(url.host) and (url.file_path or ''):sub(1, 1) == '/' then
    return url.file_path
  end
  return '.'
end

function M.apply(config)
  files.enable_polling()
  wezterm.on('user-var-changed', function(window, pane, name, value)
    if name == 'wez_drag_out' then
      drag_out(window, pane, value)
    elseif name == 'wez_drag_in' then
      local dirs = files.request_paths(value)
      if dirs[1] then drop_in(window, pane, dirs[1]) else toast(window, 'Drop: no usable folder in the request') end
    end
  end)
  table.insert(config.keys, {
    key = 'u', mods = 'CMD|SHIFT',
    action = wezterm.action_callback(function(window, pane)
      drop_in(window, pane, pane_dest(pane, pane_ssh_args(pane)))
    end),
  })
end

return M
