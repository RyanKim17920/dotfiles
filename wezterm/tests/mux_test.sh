#!/bin/sh
# Checks path resolution against real pane text in a headless
# wezterm-mux-server (tests/mux_config.lua) with its own socket under a fake
# HOME in a fresh /tmp/wz* dir. `claude` there is a stub (sleep under that
# name). The server is stopped by its own PID only.
set -u
here=$(cd "$(dirname "$0")" && pwd)
server=/Applications/WezTerm.app/Contents/MacOS/wezterm-mux-server
command -v wezterm-mux-server >/dev/null 2>&1 && server=$(command -v wezterm-mux-server)
home=$(mktemp -d /tmp/wzXXXXXX) || exit 1
case $home in /tmp/wz*) ;; *) echo "refusing: HOME $home is not a fake one" >&2; exit 1 ;; esac
root=$home/root
mkdir -p "$root/proj/1673a7e7-252a-4127-a63b-ab96a4c32fc2/scratchpad/shot" "$root/agent-cwd/notes" "$home/bin"
: > "$root/proj/1673a7e7-252a-4127-a63b-ab96a4c32fc2/scratchpad/shot/pareto.png"
: > "$root/agent-cwd/notes/plan.md"
ln -s /bin/sleep "$home/bin/claude"
cp "$here/mux_config.lua" "$home/wezterm.lua"
pid=
cleanup() {
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  rm -rf "$home"
}
trap cleanup EXIT
export HOME="$home" WEZTERM_UNIX_SOCKET="$home/sock" WZT_ROOT="$root" WZT_SRC=$(dirname "$here")
unset WEZTERM_PANE
case $HOME in /tmp/wz*) ;; *) echo 'refusing: HOME is not fake' >&2; exit 1 ;; esac
"$server" --config-file "$home/wezterm.lua" --daemonize 2> "$home/server.log"
# The daemon writes its pid next to its socket's runtime dir
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pid=$(cat "$home/.local/share/wezterm/pid" 2>/dev/null)
  [ -n "$pid" ] && break
  sleep 0.5
done
case $(ps -p "${pid:-0}" -o command= 2>/dev/null) in
  *wezterm-mux-server*"$home"*) ;;
  *) echo "could not find the test server's pid" >&2; pid=; exit 1 ;;
esac
for _ in $(seq 1 30); do
  grep -q '^DONE' "$root/results" 2>/dev/null && break
  sleep 0.5
done
grep -v '^DONE' "$root/results" 2>/dev/null || { echo 'FAIL no results'; cat "$home/server.log"; exit 1; }
! grep -q '^FAIL' "$root/results"
