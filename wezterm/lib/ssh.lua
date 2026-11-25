-- ssh helpers shared by smart splits, image paste, clickable paths, port
-- forwarding, the tab bar and session restore. They read the ssh command a
-- local pane runs and only ride its existing ControlMaster.
local wezterm = require 'wezterm'
local core = require 'lib.core'
local SPAWN_PATH = core.SPAWN_PATH
-- bg_hosts: ssh destinations (as typed, no user@) whose WezTerm remote
-- commands ride a background master; wezterm.lua sets it from ssh_bg_hosts
local M = { bg_hosts = {} }

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

-- Destination without user@, for messages and file names
local function ssh_host(ssh)
  return (ssh[#ssh]:gsub('^.*@', ''))
end

-- `ssh <opts...> <kept opts...> dest` for a pane_ssh_args result, run with
-- SPAWN_PATH so it is the same ssh as the pane's and computes the same
-- ControlPath (%C)
local function ssh_cmd(ssh, ...)
  local cmd = { '/usr/bin/env', 'PATH=' .. SPAWN_PATH, 'ssh', ... }
  for k = 2, #ssh do table.insert(cmd, ssh[k]) end
  return cmd
end

-- pid (string) of the live ControlMaster for the pane's host, or nil. Only
-- asks the master socket (-O check), so it never connects or prompts.
local function ssh_master_pid(ssh)
  local ok, _, err = wezterm.run_child_process(ssh_cmd(ssh, '-O', 'check'))
  return ok and ((err or ''):match 'pid=(%d+)' or '?') or nil
end

-- Background master ----------------------------------------------------------
-- sshd caps the sessions on one connection (MaxSessions, 10 by default), so
-- a host with many ssh tabs over one ControlMaster refuses WezTerm's own
-- remote commands (path checks, downloads, drag, previews). For the hosts in
-- M.bg_hosts (the ssh_bg_hosts setting in wezterm.lua / local.lua), those
-- ride a second master that WezTerm keeps at BG_CP instead. It is started in
-- the background with BatchMode=yes, so it only ever comes up with key auth:
-- never a prompt, never a 2FA push. Until it is live, the pane's own master
-- is used as before. Port forwards (-O forward/cancel) stay on the pane's
-- own master: they open no session.
local BG_CP = wezterm.home_dir .. '/.ssh/cm-wezbg-%C'
-- At most one start per host per BG_RETRY seconds, doubled after each
-- failure (recorded in BG_STATE_DIR/<host>) up to BG_RETRY_MAX
local BG_RETRY, BG_RETRY_MAX = 60, 3600
local BG_STATE_DIR = wezterm.home_dir .. '/.local/state/wezterm/ssh-bg/'
local BG_LAST_KEY = 'ssh_bg_last_' -- .. host -> os.time() of the last start
local BG_INFO_KEY = 'ssh_bg_info_' -- .. args -> { path, why } (see bg_info)
-- Hosts behind Duo (2FA) by alias or resolved hostname: never given a
-- background master, whatever the list says
local DUO_MARKERS = { 'delta' }

-- The host's background master socket (BG_CP expanded by ssh -G, which
-- never connects) and why it may never have one (a Duo host by alias or
-- resolved hostname, or one that prefers keyboard-interactive or password
-- auth), or nil. Cached per argument list.
local function bg_info(ssh)
  local key = BG_INFO_KEY .. table.concat(ssh, ' ', 2)
  local cached = wezterm.GLOBAL[key]
  if cached then return cached.path, cached.why ~= '' and cached.why or nil end
  local ok, out = wezterm.run_child_process(ssh_cmd(ssh, '-o', 'ControlPath=' .. BG_CP, '-G'))
  out = '\n' .. (ok and out or '')
  local path, why = out:match '\ncontrolpath ([^\n]+)', nil
  local names = { ssh_host(ssh):lower(), (out:match '\nhostname ([^\n]+)' or ''):lower() }
  for _, name in ipairs(names) do
    for _, marker in ipairs(DUO_MARKERS) do
      if name:find(marker, 1, true) then why = 'a Duo (2FA) host' end
    end
  end
  local prefer = (out:match '\npreferredauthentications ([^\n]+)' or ''):lower()
  if prefer:find('keyboard-interactive', 1, true) or prefer:find('password', 1, true) then
    why = 'it prefers ' .. prefer .. ' authentication'
  end
  if not why and not path then why = 'ssh -G failed' end
  wezterm.GLOBAL[key] = { path = path or '', why = why or '' }
  if why then wezterm.log_warn('ssh: no background master for ' .. ssh_host(ssh) .. ': ' .. why) end
  return path, why
end

-- Whether the host is in the list and allowed a background master
local function bg_enabled(ssh)
  local host = ssh_host(ssh)
  for _, h in ipairs(M.bg_hosts) do
    if h == host then return not select(2, bg_info(ssh)) end
  end
  return false
end

-- The host's state file: failed starts in a row, then the last error
local function bg_state(ssh)
  return BG_STATE_DIR .. ssh_host(ssh):gsub('[^%w.-]', '_')
end

-- argv that starts the background master for the host and records the
-- outcome in its state file: the one ssh here that may log in, and only
-- with keys (BatchMode=yes; no tty, no askpass). It goes through the host's
-- own ProxyCommand/ProxyJump like the user's tabs; ClearAllForwardings
-- keeps the config's LocalForwards off it.
local BG_START_SH = [[
st=$1; shift
mkdir -p "$(dirname "$st")"
if err=$(ssh "$@" 2>&1 </dev/null); then
  rm -f "$st"
else
  n=$(head -n 1 "$st" 2>/dev/null)
  printf '%s\n%s\n' "$((${n:-0} + 1))" "$(printf '%s' "$err" | tail -n 1)" > "$st"
fi
]]
local function bg_start_cmd(ssh)
  local argv = { '/usr/bin/env', 'PATH=' .. SPAWN_PATH, 'SSH_ASKPASS_REQUIRE=never', 'sh', '-c', BG_START_SH,
    'sh', bg_state(ssh),
    '-o', 'BatchMode=yes', '-o', 'ControlMaster=yes', '-o', 'ControlPath=' .. BG_CP,
    '-o', 'ControlPersist=4h', '-o', 'ServerAliveInterval=30', '-o', 'ClearAllForwardings=yes', '-fN' }
  for k = 2, #ssh do table.insert(argv, ssh[k]) end
  return argv
end

-- Seconds to wait between starts for the host: BG_RETRY, doubled per
-- recorded failure
local function bg_retry(ssh)
  local f = io.open(bg_state(ssh))
  local fails = f and tonumber(f:read '*l' or '') or 0
  if f then f:close() end
  return math.min(BG_RETRY * 2 ^ fails, BG_RETRY_MAX)
end

-- The host's background master socket when that master is live, else nil;
-- starts it (without waiting, rate-limited) when the host is enabled but it
-- is not. Only asks the socket (-O check).
local function bg_path(ssh)
  if not bg_enabled(ssh) then return nil end
  local path = bg_info(ssh)
  if wezterm.run_child_process(ssh_cmd(ssh, '-o', 'BatchMode=yes', '-S', path, '-O', 'check')) then
    return path
  end
  local key, now = BG_LAST_KEY .. ssh_host(ssh), os.time()
  if now - (wezterm.GLOBAL[key] or 0) >= bg_retry(ssh) then
    wezterm.GLOBAL[key] = now
    wezterm.background_child_process(bg_start_cmd(ssh))
  end
  return nil
end

-- Toast text for a session the server refused on a shared connection
-- (sshd MaxSessions) in ssh's stderr `err`, or nil for any other error.
-- `ssh` (a pane_ssh_args result) names the host, when known.
local function refusal_note(err, ssh)
  if not (err or ''):find('refused by peer', 1, true) then return nil end
  local host = ssh and ssh_host(ssh) or 'the host'
  local fix = ssh and bg_enabled(ssh)
    and "WezTerm's own connection to it is starting, try again in a few seconds"
    or 'close an ssh tab or pane to it'
  return 'ssh: ' .. host .. ' refused one more session on the shared connection (sshd MaxSessions); ' .. fix
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

-- live_master, but for running remote commands: the host's background
-- master once it is live (see bg_path), else the pane's own one. Port
-- forwards keep to live_master.
local function command_master(ssh)
  local bg = bg_path(ssh)
  if bg then
    local gated = gated_args(ssh, bg)
    local pid = ssh_master_pid(gated)
    if pid then return gated, pid end
  end
  return live_master(ssh)
end

-- ssh_cmd that can only ride an existing ControlMaster: never prompts, never
-- logs in on its own. ProxyCommand=false makes it fail at once instead of
-- connecting when there is no master; ssh refuses it next to -J, whose
-- jump host is part of the ControlPath (%C), so a -J pane goes without.
-- It rides the background master (-S BG_CP) once that is live.
local function ssh_batch_cmd(ssh)
  local opts = { '-o', 'BatchMode=yes', '-o', 'ControlMaster=no' }
  local j = false
  for k = 2, #ssh do j = j or ssh[k] == '-J' end
  if not j then
    table.insert(opts, '-o')
    table.insert(opts, 'ProxyCommand=false')
  end
  local bg = bg_path(ssh)
  if bg then
    table.insert(opts, '-S')
    table.insert(opts, bg)
  end
  return ssh_cmd(ssh, table.unpack(opts))
end

-- Shell functions for background scripts that must ride the pane's live
-- ControlMaster and never cause a new login (one host uses Duo). Each takes
-- the ssh args of a pane_ssh_args result without SSH_PANE (kept opts...,
-- dest); run them under master_env so ssh computes the same ControlPath.
--   master_gate ARGS...       set $cp to the master's socket once `-O check`
--                             says it is live (asks ssh -G and the socket
--                             only), else set $why and return 1. Not in a
--                             $(...) subshell: $cp must reach the caller.
--                             $WEZ_BG_CP (the background master, see
--                             bg_path) comes first when set and live
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
  if [ -n "${WEZ_BG_CP:-}" ]; then
    cp=$WEZ_BG_CP
    master_ssh -O check "$@" >/dev/null 2>&1 && return 0
  fi
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
-- `/usr/bin/env <vars>` for a MASTER_SH script about `ssh` (a
-- pane_ssh_args result): SPAWN_PATH, and WEZ_BG_CP once the host's
-- background master is live
local function master_env(ssh)
  local bg = bg_path(ssh)
  return { '/usr/bin/env', 'PATH=' .. SPAWN_PATH, bg and ('WEZ_BG_CP=' .. bg) or nil }
end

local function ssh_gated_cmd(ssh, cmd)
  local argv = master_env(ssh)
  for _, a in ipairs { 'sh', '-c', GATED_SH, 'sh', cmd } do table.insert(argv, a) end
  for k = 2, #ssh do table.insert(argv, ssh[k]) end
  return argv
end

M.SSH_OPTS_WITH_VALUE, M.SSH_OPTS_KEPT, M.SSH_PANE = SSH_OPTS_WITH_VALUE, SSH_OPTS_KEPT, SSH_PANE
M.RESTORE_TAG, M.ssh_split_args, M.info_ssh_args = RESTORE_TAG, ssh_split_args, info_ssh_args
M.pane_ssh_args, M.ssh_cmd, M.ssh_batch_cmd = pane_ssh_args, ssh_cmd, ssh_batch_cmd
M.ssh_master_pid, M.ssh_host, M.MASTER_SH = ssh_master_pid, ssh_host, MASTER_SH
M.ssh_gated_cmd, M.control_path, M.gated_args = ssh_gated_cmd, control_path, gated_args
M.live_master, M.command_master, M.master_env = live_master, command_master, master_env
M.refusal_note, M.BG_CP, M._test = refusal_note, BG_CP, { bg_start_cmd = bg_start_cmd, bg_path = bg_path }
return M
