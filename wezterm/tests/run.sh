#!/bin/sh
# Runs tests/paths_test.lua inside `wezterm ls-fonts` under a fake HOME in a
# fresh /tmp/wz* dir, with tests/shims (fake ssh, ps, readlink) first in
# PATH; prints the results and exits 1 on any failure or Lua error.
set -u
here=$(cd "$(dirname "$0")" && pwd)
home=$(mktemp -d /tmp/wzXXXXXX) || exit 1
case $home in /tmp/wz*) ;; *) echo "refusing: HOME $home is not a fake one" >&2; exit 1 ;; esac
trap 'rm -rf "$home"' EXIT
root=$home/root
mkdir -p "$root/proj/1673a7e7-252a-4127-a63b-ab96a4c32fc2/scratchpad/shot" "$root/agent-cwd/notes"
: > "$root/proj/1673a7e7-252a-4127-a63b-ab96a4c32fc2/scratchpad/shot/pareto.png"
: > "$root/agent-cwd/notes/plan.md"
out=$(HOME=$home WZT_ROOT=$root WZT_SHIMS=$here/shims WZT_SRC=$(dirname "$here") \
  FAKE_SSH_LOG=$root/ssh.log PATH="$here/shims:$PATH" \
  wezterm --config-file "$here/paths_test.lua" ls-fonts 2>&1 >/dev/null)
# The whole config (with the path link rules) must load cleanly too;
# wezterm exits 0 even on Lua errors, so look at what it logs
cfg=$(HOME=$home wezterm --config-file "$(dirname "$here")/wezterm.lua" ls-fonts 2>&1 >/dev/null | grep ERROR)
[ -n "$cfg" ] && out="$out
$cfg"
printf '%s\n' "$out" | grep -E '^(PASS|FAIL|RESULT)|ERROR'
printf '%s\n' "$out" | grep -qE '^FAIL|ERROR' && exit 1
printf '%s\n' "$out" | grep -q '^RESULT' || exit 1
