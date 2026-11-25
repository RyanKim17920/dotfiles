-- ssh helpers shared by smart splits, image paste, clickable paths, port
-- forwarding, the tab bar and session restore. They read the ssh command a
-- local pane runs and only ride its existing ControlMaster.
local wezterm = require 'wezterm'
local core = require 'lib.core'
local SPAWN_PATH = core.SPAWN_PATH

-- ssh options that take a value (from `man ssh`)
local SSH_OPTS_WITH_VALUE = {}
for c in ('bcDEeFIiJLlmOopQRSWw'):gmatch '.' do SSH_OPTS_WITH_VALUE[c] = true end
-- Of those, the ones carried over so the new connection matches
local SSH_OPTS_KEPT = { l = true, p = true, F = true, J = true, i = true }

-- ssh wrapper that offers Enter-to-reconnect when the connection drops
local SSH_PANE = wezterm.home_dir .. '/.local/bin/ssh-pane'
-- $0 of the sh -c script that waits before running ssh-pane when a session
-- is restored (see SSH_RESTORE_SCRIPT)
local RESTORE_TAG = 'wez-restore'

-- argv of an ssh process -> args for a fresh ssh-pane to the same destination
-- (remote command dropped), or nil if no destination is found.
local function ssh_split_args(argv, first)
  local kept, i = {}, (first or 1) + 1
  while i <= #argv do
    local a = argv[i]
    if a == '--' then
      i = i + 1
      break
    elseif a:sub(1, 1) ~= '-' or a == '-' then
      break
    end
    -- Walk bundled flags like -tt or -4p2222
    for j = 2, #a do
      local c = a:sub(j, j)
      if SSH_OPTS_WITH_VALUE[c] then
        local value = a:sub(j + 1)
        if value == '' then
          i = i + 1
          value = argv[i]
        end
        if value and SSH_OPTS_KEPT[c] then
          table.insert(kept, '-' .. c)
          table.insert(kept, value)
        end
        break
      end
    end
    i = i + 1
  end
  local dest = argv[i]
  if not dest then return nil end
  local args = { SSH_PANE }
  for _, v in ipairs(kept) do table.insert(args, v) end
  table.insert(args, dest)
  return args
end

-- { SSH_PANE, <kept opts...>, dest } when the pane is a local pane whose
-- foreground process is ssh or ssh-pane, else nil. Shared by smart splits,
-- image paste, clickable paths and port forwarding. ssh-pane is a #!/bin/sh
-- script, so its argv is { '/bin/sh', '.../ssh-pane', <ssh args...> }: parse
-- from the ssh-pane entry.
local function info_ssh_args(info)
  local argv = info.argv or {}
  local function base(k) return (argv[k] or ''):match '[^/]*$' end
  if (info.executable or ''):match '[^/]*$' == 'ssh' or base(1) == 'ssh' or base(1) == 'ssh-pane' then
    return ssh_split_args(argv, 1)
  elseif base(2) == 'ssh-pane' then
    return ssh_split_args(argv, 2)
  elseif base(1) == 'sh' and argv[4] == RESTORE_TAG then
    return ssh_split_args(argv, 5)
  end
  return nil
end

local function pane_ssh_args(pane)
  local info = pane:get_domain_name() == 'local' and pane:get_foreground_process_info()
  return info and info_ssh_args(info) or nil
end

-- `ssh <opts...> <kept opts...> dest` for a pane_ssh_args result, run with
-- SPAWN_PATH so it is the same ssh as the pane's and computes the same
-- ControlPath (%C)
local function ssh_cmd(ssh, ...)
  local cmd = { '/usr/bin/env', 'PATH=' .. SPAWN_PATH, 'ssh', ... }
  for k = 2, #ssh do table.insert(cmd, ssh[k]) end
  return cmd
end

-- ssh_cmd that can only ride an existing ControlMaster: never prompts, never
-- logs in on its own. ProxyCommand=false makes it fail at once instead of
-- connecting when there is no master; ssh refuses it next to -J, whose
-- jump host is part of the ControlPath (%C), so a -J pane goes without.
local function ssh_batch_cmd(ssh)
  for k = 2, #ssh do
    if ssh[k] == '-J' then return ssh_cmd(ssh, '-o', 'BatchMode=yes', '-o', 'ControlMaster=no') end
  end
  return ssh_cmd(ssh, '-o', 'BatchMode=yes', '-o', 'ControlMaster=no', '-o', 'ProxyCommand=false')
end

-- pid (string) of the live ControlMaster for the pane's host, or nil. Only
-- asks the master socket (-O check), so it never connects or prompts.
local function ssh_master_pid(ssh)
  local ok, _, err = wezterm.run_child_process(ssh_cmd(ssh, '-O', 'check'))
  return ok and ((err or ''):match 'pid=(%d+)' or '?') or nil
end

-- ControlPath ssh would use for `ssh` (a pane_ssh_args result; ssh -G never
-- connects), or nil when it has none. Cached in wezterm.GLOBAL per argument
-- list.
local CONTROL_PATH_KEY = 'ssh_control_path_' -- .. args -> path, or '' for none
local function control_path(ssh)
  local key = CONTROL_PATH_KEY .. table.concat(ssh, ' ', 2)
  local cached = wezterm.GLOBAL[key]
  if cached then return cached ~= '' and cached or nil end
  local ok, out = wezterm.run_child_process(ssh_cmd(ssh, '-G'))
  if not ok then return nil end
  local path = out:match '\ncontrolpath ([^\n]+)' or out:match '^controlpath ([^\n]+)'
  if path == 'none' then path = nil end
  wezterm.GLOBAL[key] = path or ''
  return path
end

-- Args like `ssh` that can only ever ride the master at `path`: ssh options
-- are first-wins, so these come before the pane's own. BatchMode never
-- prompts; ControlMaster=no never starts a master; ProxyCommand=false makes
-- a fallback direct connection (master died after the check) fail at once
-- instead of logging in; -S keeps the socket -O check just found live. A -J
-- is dropped: ssh refuses it next to ProxyCommand=false, and -S names the
-- master anyway.
local function gated_args(ssh, path)
  local args = { ssh[1], '-o', 'BatchMode=yes', '-o', 'ControlMaster=no',
    '-o', 'ProxyCommand=false', '-S', path }
  local k = 2
  while k <= #ssh do
    if ssh[k] == '-J' then
      k = k + 2
    else
      table.insert(args, ssh[k])
      k = k + 1
    end
  end
  return args
end

-- gated_args for the live ControlMaster of `ssh` and the master's pid, or
-- nil. Asks ssh -G and the socket (-O check, gated) only: never connects.
local function live_master(ssh)
  local path = control_path(ssh)
  if not path then return nil end
  local gated = gated_args(ssh, path)
  local pid = ssh_master_pid(gated)
  if not pid then return nil end
  return gated, pid
end

-- Shell functions for background scripts that must ride the pane's live
-- ControlMaster and never cause a new login (one host uses Duo). Each takes
-- the ssh args of a pane_ssh_args result without SSH_PANE (kept opts...,
-- dest); run them with PATH=SPAWN_PATH so ssh computes the same ControlPath.
--   master_gate ARGS...       set $cp to the master's socket once `-O check`
--                             says it is live (asks ssh -G and the socket
--                             only), else set $why and return 1. Not in a
--                             $(...) subshell: $cp must reach the caller
--   master_ssh ARGS... CMD    run CMD on the host over $cp. Safety options
--                             come first (ssh is first-wins), and
--                             ProxyCommand=false makes a master that died
--                             since the gate fail at once instead of logging in
local MASTER_SH = [[
master_ssh() {
  ssh -o BatchMode=yes -o ControlMaster=no -o ProxyCommand=false -S "$cp" "$@"
}
master_gate() {
  for h do :; done
  cp=$(ssh -G "$@" 2>/dev/null | sed -n 's/^controlpath //p' | head -n 1)
  if [ -z "$cp" ] || [ "$cp" = none ]; then
    why="no ControlMaster is configured for ${h#*@}"
    return 1
  fi
  master_ssh -O check "$@" >/dev/null 2>&1 || {
    why="no live ssh connection to ${h#*@}; log in first"
    return 1
  }
}
]]

-- argv that runs the sh command `cmd` on the pane's host (ssh: a
-- pane_ssh_args result) over its live ControlMaster (master_gate,
-- master_ssh), or writes "GATE: <why>" to stderr and exits 3 when there is
-- none. One local sh, one round trip; it never logs in. A -J (part of the
-- ControlPath, so kept for the gate) is dropped after it: ssh refuses -J
-- next to ProxyCommand=false, and -S names the master anyway.
local GATED_SH = MASTER_SH .. [[
c=$1; shift
master_gate "$@" || { printf 'GATE: %s\n' "$why" >&2; exit 3; }
skip=
for a do
  shift
  if [ -n "$skip" ]; then skip=; continue; fi
  case $a in -J) skip=1; continue ;; esac
  set -- "$@" "$a"
done
master_ssh "$@" "$c"
]]
local function ssh_gated_cmd(ssh, cmd)
  local argv = { '/usr/bin/env', 'PATH=' .. SPAWN_PATH, 'sh', '-c', GATED_SH, 'sh', cmd }
  for k = 2, #ssh do table.insert(argv, ssh[k]) end
  return argv
end

-- Destination without user@, for messages and file names
local function ssh_host(ssh)
  return (ssh[#ssh]:gsub('^.*@', ''))
end
return {
  SSH_OPTS_WITH_VALUE = SSH_OPTS_WITH_VALUE, SSH_OPTS_KEPT = SSH_OPTS_KEPT, SSH_PANE = SSH_PANE,
  RESTORE_TAG = RESTORE_TAG, ssh_split_args = ssh_split_args, info_ssh_args = info_ssh_args,
  pane_ssh_args = pane_ssh_args, ssh_cmd = ssh_cmd, ssh_batch_cmd = ssh_batch_cmd,
  ssh_master_pid = ssh_master_pid, ssh_host = ssh_host, MASTER_SH = MASTER_SH,
  ssh_gated_cmd = ssh_gated_cmd, control_path = control_path, gated_args = gated_args,
  live_master = live_master,
}
