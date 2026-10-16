-- WezTerm config: pane/split keybindings mirroring Ghostty's macOS defaults.
local wezterm = require 'wezterm'
local act = wezterm.action

local config = wezterm.config_builder()

-- Match Ghostty's `working-directory = ~/Desktop`
config.default_cwd = wezterm.home_dir .. '/Desktop'

-- Make the inactive pane visibly dimmer so the focused split is obvious
config.inactive_pane_hsb = { saturation = 0.8, brightness = 0.7 }

-- Render at the MacBook's 120Hz ProMotion rate instead of the 60fps default
config.max_fps = 120

-- Render via WebGpu (Metal) instead of the OpenGL default: measured ~40% lower
-- memory footprint (~70-118 MB vs ~137-187 MB with 3 panes), same look
config.front_end = 'WebGpu'

local RESIZE_STEP = 5 -- cells per keypress

-- File sidebar (VS Code style): CMD+E toggles a narrow Yazi pane on the left
-- of the tab. It uses ~/.config/yazi-sidebar (single column; text files open in
-- micro in a new pane to its right via ~/.local/bin/yazi-open).
local SIDEBAR_CELLS = 32
local YAZI = '/opt/homebrew/bin/yazi'
-- GUI-launched WezTerm has a minimal PATH; yazi needs brew tools
local YAZI_PATH = '/opt/homebrew/bin:' .. wezterm.home_dir .. '/.local/bin:'
  .. (os.getenv 'PATH' or '/usr/bin:/bin:/usr/sbin:/sbin')

-- Directory of a pane: Url object on 20240203+, string on older builds,
-- falling back to the foreground process's cwd.
local function pane_cwd(pane)
  local url = pane:get_current_working_dir()
  if type(url) == 'userdata' and url.file_path then
    return url.file_path
  elseif type(url) == 'string' then
    return (url:gsub('^file://[^/]*', ''))
  end
  local info = pane:get_foreground_process_info()
  return info and info.cwd or wezterm.home_dir
end

local function toggle_sidebar(window, pane)
  local tab = pane:tab()
  -- Sidebar pane id per tab; wezterm.GLOBAL survives config reloads
  local key = 'sidebar_pane_for_tab_' .. tab:tab_id()
  local sidebar_id = wezterm.GLOBAL[key]

  -- Sidebar already open in this tab: close it
  for _, p in ipairs(tab:panes()) do
    if p:pane_id() == sidebar_id then
      p:activate()
      window:perform_action(act.CloseCurrentPane { confirm = false }, p)
      wezterm.GLOBAL[key] = nil
      return
    end
  end

  -- Yazi only exists on this Mac; don't try to run it inside ssh/mux domains
  if pane:get_domain_name() ~= 'local' then
    window:toast_notification('wezterm', 'File sidebar only works in local tabs', nil, 3000)
    return
  end

  local cwd = pane_cwd(pane)
  local sidebar = pane:split {
    direction = 'Left',
    top_level = true,
    size = SIDEBAR_CELLS,
    cwd = cwd,
    -- Pass the dir explicitly: yazi trusts an inherited $PWD over the real cwd
    args = { YAZI, cwd },
    set_environment_variables = {
      YAZI_SIDEBAR = '1',
      YAZI_CONFIG_HOME = wezterm.home_dir .. '/.config/yazi-sidebar',
      PATH = YAZI_PATH,
    },
  }
  wezterm.GLOBAL[key] = sidebar:pane_id()
end

-- ssh helpers shared by smart splits, image paste, clickable paths and port
-- forwarding.

-- PATH for spawned ssh/ssh-pane (GUI-launched WezTerm has a minimal PATH),
-- so they run the same ssh as an interactive shell
local SPAWN_PATH = '/opt/homebrew/bin:' .. (os.getenv 'PATH' or '/usr/bin:/bin:/usr/sbin:/sbin')

local function sh_quote(s)
  return "'" .. s:gsub("'", [['\'']]) .. "'"
end

-- ssh options that take a value (from `man ssh`)
local SSH_OPTS_WITH_VALUE = {}
for c in ('bcDEeFIiJLlmOopQRSWw'):gmatch '.' do SSH_OPTS_WITH_VALUE[c] = true end
-- Of those, the ones carried over so the new connection matches
local SSH_OPTS_KEPT = { l = true, p = true, F = true, J = true, i = true }

-- ssh wrapper that offers Enter-to-reconnect when the connection drops
local SSH_PANE = wezterm.home_dir .. '/.local/bin/ssh-pane'

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
local function pane_ssh_args(pane)
  local info = pane:get_domain_name() == 'local' and pane:get_foreground_process_info()
  if not info then return nil end
  local argv = info.argv or {}
  local function base(k) return (argv[k] or ''):match '[^/]*$' end
  if (info.executable or ''):match '[^/]*$' == 'ssh' or base(1) == 'ssh' or base(1) == 'ssh-pane' then
    return ssh_split_args(argv, 1)
  elseif base(2) == 'ssh-pane' then
    return ssh_split_args(argv, 2)
  end
  return nil
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
-- logs in on its own
local function ssh_batch_cmd(ssh)
  return ssh_cmd(ssh, '-o', 'BatchMode=yes', '-o', 'ControlMaster=no')
end

-- pid (string) of the live ControlMaster for the pane's host, or nil. Only
-- asks the master socket (-O check), so it never connects or prompts.
local function ssh_master_pid(ssh)
  local ok, _, err = wezterm.run_child_process(ssh_cmd(ssh, '-O', 'check'))
  return ok and ((err or ''):match 'pid=(%d+)' or '?') or nil
end

-- Destination without user@, for messages and file names
local function ssh_host(ssh)
  return (ssh[#ssh]:gsub('^.*@', ''))
end

-- Clickable file paths: CMD+click on a path such as ~/.ssh/config,
-- /Users/me/x.md, ./foo.py, tasks/todo.md, README.md or src/app.py:42 opens a
-- temporary Yazi pane on the right of the tab with the file hovered and the
-- preview maximized (YAZI_PEEK, see ~/.config/yazi/init.lua), or the directory
-- opened. q quits Yazi and closes the pane. OSC 8 file:// links (ls
-- --hyperlink, Claude Code) are handled the same way; web URLs are untouched.
local PEEK_SCHEME = 'yazi-open-path:'
local PEEK_SIZE = 0.45

local function toast(window, msg, ms)
  window:toast_notification('wezterm', msg, nil, ms or 3000)
end

local function is_dir(path)
  local ok = pcall(wezterm.read_dir, path)
  return ok
end

local function exists(path)
  if is_dir(path) then return true end
  local f = io.open(path, 'r')
  if f then f:close() return true end
  return false
end

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
-- :line, :line:col or :first-last, then each %-decoded (My%20File.md)
local function path_variants(text)
  local out = { text }
  local stripped = text:match '^(.-):%d+[:-]%d+$' or text:match '^(.-):%d+$'
  if stripped and stripped ~= '' then table.insert(out, stripped) end
  for i = 1, #out do
    local decoded = percent_decode(out[i])
    if decoded ~= out[i] then table.insert(out, decoded) end
  end
  return out
end

-- Existing absolute path for `text` (see path_variants), resolving ~ and
-- relative paths against `cwd`; nil if nothing exists.
local function resolve_path(text, cwd)
  for _, c in ipairs(path_variants(text)) do
    if c == '~' or c:sub(1, 2) == '~/' then
      c = wezterm.home_dir .. c:sub(2)
    elseif c:sub(1, 1) ~= '/' then
      c = cwd .. '/' .. c
    end
    c = normalize(c)
    if exists(c) then return c end
  end
  return nil
end

-- Split the peek pane off `pane` from `spec` (cwd, args, env). One peek
-- pane per tab: the previous one is closed if it's still open.
local function replace_peek(window, pane, spec)
  local tab = pane:tab()
  local key = 'peek_pane_for_tab_' .. tab:tab_id()
  for _, p in ipairs(tab:panes()) do
    if p:pane_id() == wezterm.GLOBAL[key] and p:pane_id() ~= pane:pane_id() then
      p:activate()
      window:perform_action(act.CloseCurrentPane { confirm = false }, p)
      pane:activate()
      break
    end
  end
  spec.direction, spec.top_level, spec.size = 'Right', true, PEEK_SIZE
  wezterm.GLOBAL[key] = pane:split(spec):pane_id()
end

local function open_peek(window, pane, path)
  local dir = is_dir(path)
  local env = { PATH = YAZI_PATH }
  if not dir then env.YAZI_PEEK = path end
  replace_peek(window, pane, {
    cwd = dir and path or (path:match '^(.+)/' or '/'),
    args = { YAZI, path },
    set_environment_variables = env,
  })
end

-- Paths clicked in a local pane running ssh live on the remote host. They
-- are resolved there over the existing ControlMaster and opened in remote
-- Yazi (installed by ssh-setup, whose synced init.lua handles YAZI_PEEK)
-- through ssh-pane. Relative paths resolve against the remote shell's cwd
-- when it reports one with OSC 7, else against the remote home.

-- The remote shell's cwd from OSC 7 (file://<remote host>/dir), or nil
local function remote_cwd(pane)
  local url = pane:get_current_working_dir()
  if type(url) == 'userdata' and url.host and not is_local_host(url.host) then
    return url.file_path
  end
  return nil
end

-- Shell word for path text on the remote: ~ becomes "$HOME"
local function remote_word(text, rcwd)
  if text == '~' then return '"$HOME"' end
  if text:sub(1, 2) == '~/' then return '"$HOME"' .. sh_quote(text:sub(2)) end
  if text:sub(1, 1) == '/' then return sh_quote(text) end
  if rcwd then return sh_quote(rcwd .. '/' .. text) end
  return '"$HOME"/' .. sh_quote(text)
end

-- Prints "d <dir>" or "f <file>" (absolute, ./.. collapsed) for the first
-- candidate that exists; exit 1 if none does
local REMOTE_RESOLVE = [[
for p in %s; do
  if [ -d "$p" ]; then
    cd -- "$p" && printf 'd %%s\n' "$(pwd)" && exit 0
  elif [ -e "$p" ]; then
    d=$(cd -- "$(dirname -- "$p")" && pwd) && printf 'f %%s\n' "${d%%/}/$(basename -- "$p")" && exit 0
  fi
done
exit 1]]

-- kind ('f' or 'd') and absolute path of `text` on the pane's host, or nil
-- and a message
local function resolve_remote(ssh, text, rcwd)
  if not ssh_master_pid(ssh) then
    return nil, 'No live ssh connection to ' .. ssh_host(ssh) .. ' (ControlMaster)'
  end
  local words = {}
  for _, v in ipairs(path_variants(text)) do table.insert(words, remote_word(v, rcwd)) end
  local cmd = ssh_batch_cmd(ssh)
  table.insert(cmd, 'sh -c ' .. sh_quote(string.format(REMOTE_RESOLVE, table.concat(words, ' '))))
  local ok, out = wezterm.run_child_process(cmd)
  local kind, path
  if ok then kind, path = out:match '^([fd]) (/[^\n]*)' end
  if not kind then return nil, 'Not found on ' .. ssh_host(ssh) .. ': ' .. text end
  return kind, path
end

local function open_remote_peek(window, pane, ssh, kind, path)
  -- $HOME/.local/bin first: ssh-setup's yazi and its previewers, else any yazi
  local script = 'export PATH="$HOME/.local/bin:$PATH"; '
    .. (kind == 'f' and ('export YAZI_PEEK=' .. sh_quote(path) .. '; ') or '')
    .. 'exec yazi ' .. sh_quote(path)
  local args = { SSH_PANE, '-t' }
  for k = 2, #ssh do table.insert(args, ssh[k]) end
  table.insert(args, 'sh -c ' .. sh_quote(script))
  replace_peek(window, pane, {
    cwd = wezterm.home_dir,
    args = args,
    set_environment_variables = { PATH = SPAWN_PATH },
  })
end

-- CMD+OPT+click reveals the path in Finder instead (drag it from there into
-- a browser upload, Slack, ...): `open -R` for files, `open` for directories.
-- A remote file is first copied to ~/Downloads/<host>/ over the existing
-- ControlMaster. The mouse binding sets this flag right before opening the
-- link; it is consumed by the next open-uri and ignored once stale.
local REVEAL_KEY = 'reveal_next_link'

local function reveal_local(path)
  wezterm.background_child_process(is_dir(path) and { '/usr/bin/open', path }
    or { '/usr/bin/open', '-R', path })
end

-- sh -c script: dir name cmd... ; runs cmd (cat of the remote file) into
-- dir/name via a .part file, then reveals it, or notifies on failure
local FETCH_SCRIPT = [[
dir=$1 name=$2; shift 2
mkdir -p "$dir" && "$@" > "$dir/$name.part" && mv -f "$dir/$name.part" "$dir/$name" && exec open -R "$dir/$name"
rm -f "$dir/$name.part"
osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "wezterm"' -e 'end run' "Copy failed: $name"]]

local function reveal_remote(window, ssh, kind, path)
  local host = ssh_host(ssh)
  if kind == 'd' then
    toast(window, 'Remote directory, not copied: ' .. host .. ':' .. path)
    return
  end
  local sub = host:gsub('[^%w.-]', '_')
  local cmd = { '/bin/sh', '-c', FETCH_SCRIPT, 'sh', wezterm.home_dir .. '/Downloads/' .. sub,
    path:match '[^/]+$' }
  for _, a in ipairs(ssh_batch_cmd(ssh)) do table.insert(cmd, a) end
  table.insert(cmd, 'cat -- ' .. sh_quote(path))
  wezterm.background_child_process(cmd)
  toast(window, 'Copying ' .. host .. ':' .. path .. ' to ~/Downloads/' .. sub .. '/')
end

-- Localhost links from ssh panes: http://localhost:8888/?token=... printed
-- by Jupyter, TensorBoard, vite, ... on the remote host. Clicking one adds a
-- local forward on the pane's existing ControlMaster (`ssh -O forward`,
-- never a new login) and opens the URL locally, path and query kept. A busy
-- local port moves to the next free one (the URL is rewritten to match);
-- ports below 1024 map to 8000+port. Forwards are remembered per host and
-- port in wezterm.GLOBAL and reused while the master still listens on them.

-- Remote target per URL host, also the host used in the rewritten URL
local LOOPBACK = {
  localhost = 'localhost', ['127.0.0.1'] = '127.0.0.1', ['0.0.0.0'] = 'localhost', ['[::1]'] = '[::1]',
}
local FORWARD_KEY = 'ssh_forward_' -- .. ssh args .. '|' .. target:port -> local port

-- { scheme, host, rport, rest } for a loopback http(s) URL, else nil
local function parse_loopback_url(uri)
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

-- pid (string) of the process listening on local TCP `port`, or nil
local function listener_pid(port)
  local ok, out = wezterm.run_child_process {
    '/usr/sbin/lsof', '-nP', '-iTCP:' .. port, '-sTCP:LISTEN', '-t',
  }
  return ok and out:match '%d+' or nil
end

-- Forward remote target:rport over the pane's master. Returns the local
-- port and whether it was reused, or nil and a message.
local function ssh_forward(ssh, target, rport)
  local pid = ssh_master_pid(ssh)
  if not pid then
    return nil, 'No live ssh connection to ' .. ssh_host(ssh) .. ' (ControlMaster); not forwarding'
  end
  local key = FORWARD_KEY .. table.concat(ssh, ' ', 2) .. '|' .. target .. ':' .. rport
  local known = wezterm.GLOBAL[key]
  if known and listener_pid(known) == pid then return known, true end
  local first = rport >= 1024 and rport or 8000 + rport
  for lport = first, math.min(first + 20, 65535) do
    -- lsof can't see other users' listeners; a failed bind just moves on
    if not listener_pid(lport) and wezterm.run_child_process(
        ssh_cmd(ssh, '-O', 'forward', '-L', lport .. ':' .. target .. ':' .. rport)) then
      wezterm.GLOBAL[key] = lport
      return lport, false
    end
  end
  return nil, 'No free local port in ' .. first .. '-' .. math.min(first + 20, 65535)
end

local function open_forwarded(window, ssh, url)
  local target = LOOPBACK[url.host]
  local lport, reused = ssh_forward(ssh, target, url.rport)
  if not lport then
    toast(window, reused, 4000)
    return
  end
  toast(window, (reused and 'Using forward ' or 'Forwarded ') .. ssh_host(ssh) .. ':' .. url.rport
    .. ' → localhost:' .. lport)
  wezterm.open_with(url.scheme .. '://' .. target .. ':' .. lport .. url.rest)
end

-- CMD+SHIFT+L: forward a port (or a pasted localhost URL) without a click
local forward_prompt = act.PromptInputLine {
  description = 'Forward remote port (or paste a localhost URL):',
  action = wezterm.action_callback(function(window, pane, line)
    line = (line or ''):match '^%s*(.-)%s*$'
    if line == '' then return end
    local ssh = pane_ssh_args(pane)
    local url = parse_loopback_url(line:match '^%d+$' and ('http://localhost:' .. line .. '/') or line)
    if not ssh then
      toast(window, 'Not an ssh pane')
    elseif not url then
      toast(window, 'Expected a port number or a localhost URL')
    else
      open_forwarded(window, ssh, url)
    end
  end),
}

wezterm.on('open-uri', function(window, pane, uri)
  local clicked = wezterm.GLOBAL[REVEAL_KEY]
  wezterm.GLOBAL[REVEAL_KEY] = nil
  local reveal = clicked ~= nil and os.time() - clicked <= 2
  local ssh = pane_ssh_args(pane)
  local url = ssh and parse_loopback_url(uri)
  if url then
    open_forwarded(window, ssh, url)
    return false
  end

  local text, host = uri_to_path(uri)
  if not text then return end -- web URL etc.: default opener
  local custom = uri:sub(1, #PEEK_SCHEME) == PEEK_SCHEME

  if ssh then
    local kind, path = resolve_remote(ssh, text, remote_cwd(pane))
    if not kind then
      toast(window, path)
      return false
    end
    if reveal then
      reveal_remote(window, ssh, kind, path)
    else
      open_remote_peek(window, pane, ssh, kind, path)
    end
    return false
  end
  if host then return end -- file://otherhost outside ssh: default opener

  local path = pane:get_domain_name() == 'local' and resolve_path(text, pane_cwd(pane))
  if not path then
    if custom then
      toast(window, 'Not found: ' .. text, 2000)
      return false
    end
    return -- file:// we can't resolve: let the default opener try
  end
  if reveal then
    reveal_local(path)
  else
    open_peek(window, pane, path)
  end
  return false
end)

-- Paths are recognized at the start of a line or after whitespace, a quote,
-- backtick, bracket, = or * (markdown **bold**), so the /a/b inside URLs
-- never matches. Group 1 is the path (with any :line[:col] or :first-last).
-- WezTerm compiles these with fancy-regex, so lookarounds work.
config.hyperlink_rules = wezterm.default_hyperlink_rules()

-- Anchored paths: ~/, ./, ../ or /. They stop at whitespace, quotes,
-- backticks, brackets and * and never end in . , : ; ! ? so prose
-- punctuation stays out.
table.insert(config.hyperlink_rules, {
  regex = [=[(?:^|[\s"'`(\[{<=*])((?:~|\.\.?)?/[^\s"'`()\[\]{}<>*]*[^\s"'`()\[\]{}<>*.,:;!?])]=],
  format = PEEK_SCHEME .. '$1',
  highlight = 1,
})

-- Bare relative paths as Claude Code prints them (tasks/todo.md,
-- src/app.py:42, README.md). To keep prose like and/or, 1/2, 10/16/2026,
-- e.g., 1.2.3 and example.com out, one must be
--  * dir/.../file.ext (extension starts with a letter),
--  * three or more segments starting with a letter (bin/tools/ssh-pane),
--  * dir/ followed by whitespace or punctuation,
--  * name.ext with a known source/doc extension, a common dotfile, or a
--    Makefile/Dockerfile/Justfile.
-- Segments never end in a dot, so a sentence's final period is left out.
-- Unknown paths only toast when clicked.
local REL_START = [=[(?<![^\s"'`(\[{<=*])]=] -- like the boundary above, not consumed
local REL_FIRST = [=[\.?[\w@+](?:[\w.@+~-]*[\w@+~-])?]=]
local REL_FIRST_ALPHA = [=[\.?[A-Za-z_](?:[\w.@+~-]*[\w@+~-])?]=]
local REL_SEG = [=[\.?[\w@+~-](?:[\w.@+~-]*[\w@+~-])?]=]
local REL_EXTS = 'md|markdown|txt|rst|py|pyi|ipynb|js|mjs|cjs|jsx|ts|tsx|vue|svelte|lua|sh|bash'
  .. '|zsh|fish|json|jsonl|toml|ya?ml|ini|cfg|conf|env|lock|rs|go|c|h|cc|cpp|hpp|cu|java|kt'
  .. '|swift|rb|php|sql|css|scss|html?|xml|csv|tsv|log|tex|bib|pdf|png|jpe?g|gif|svg|webp'
  .. '|mp4|mov|zip|gz|tgz|tar|patch|diff|proto|tf|nix|vim'
local REL_DOTFILES = [=[[\w-]*rc|env|gitignore|gitconfig|gitattributes|profile|zprofile|editorconfig|dockerignore]=]
table.insert(config.hyperlink_rules, {
  regex = REL_START .. '((?:'
    .. REL_FIRST_ALPHA .. '(?:/' .. REL_SEG .. '){2,}/?'
    .. '|' .. REL_FIRST .. '(?:/' .. REL_SEG .. [=[)*/[\w@+~.-]*\.[A-Za-z]\w*]=]
    .. '|' .. REL_FIRST .. '(?:/' .. REL_SEG .. [=[)*/(?=$|[\s"'`)\]}>*,;:!?])]=]
    .. '|' .. REL_FIRST .. [=[\.(?i:]=] .. REL_EXTS .. [=[)\b]=]
    .. [=[|\.(?:]=] .. REL_DOTFILES .. [=[)\b(?:\.[\w-]+)*]=]
    .. [=[|(?:Makefile|Dockerfile|Justfile)\b]=]
    .. [=[)(?::\d+(?:[:-]\d+)?)?)]=],
  format = PEEK_SCHEME .. '$1',
  highlight = 1,
})

-- SSH-aware splits (VS Code style): splitting a local pane whose foreground
-- process is plain `ssh` opens a fresh shell on the same host. Relies on
-- ControlMaster in ~/.ssh/config, so the new connection is instant. The new
-- pane runs ssh through ssh-pane: it closes when that session exits normally,
-- but a dropped connection leaves it open with Enter to reconnect.
local function smart_split(direction)
  return wezterm.action_callback(function(window, pane)
    local args = pane_ssh_args(pane)
    if args then
      pane:split {
        direction = direction,
        args = args,
        cwd = pane_cwd(pane),
        set_environment_variables = { PATH = SPAWN_PATH },
      }
    elseif direction == 'Right' then
      window:perform_action(act.SplitHorizontal { domain = 'CurrentPaneDomain' }, pane)
    else
      window:perform_action(act.SplitVertical { domain = 'CurrentPaneDomain' }, pane)
    end
  end)
end

-- Unified copy/paste (VS Code terminal style): CMD+C, CMD+SHIFT+C,
-- CTRL+SHIFT+C and CTRL+C all run smart_copy; the V variants run smart_paste.
local CLIPIMG = wezterm.home_dir .. '/.local/bin/clipimg-push'

-- Copy the selection (and clear it) if there is one. Otherwise CTRL+C passes
-- through as a raw ^C so interrupt still works; CMD+C does nothing.
local function smart_copy(passthrough)
  return wezterm.action_callback(function(window, pane)
    if window:get_selection_text_for_pane(pane) ~= '' then
      window:perform_action(act.CopyTo 'ClipboardAndPrimarySelection', pane)
      window:perform_action(act.ClearSelection, pane)
    elseif passthrough then
      window:perform_action(act.SendKey { key = 'c', mods = 'CTRL' }, pane)
    end
  end)
end

-- Paste, image-aware. `clipimg-push --check` (~0.1s, synchronous) decides:
--  * image + local pane running ssh: Claude Code on the remote host can't read
--    this Mac's clipboard but accepts a path, so clipimg-push uploads the image
--    to ~/.cache/clipimg/ on that host (via the ControlMaster) in the
--    background and types the remote path into the pane.
--  * image + any other pane: send a raw Ctrl+V; local Claude Code reads the
--    image from the macOS clipboard itself on that keypress.
--  * no image: normal bracketed paste of the clipboard text.
local smart_paste = wezterm.action_callback(function(window, pane)
  if not wezterm.run_child_process { CLIPIMG, '--check' } then
    window:perform_action(act.PasteFrom 'Clipboard', pane)
    return
  end
  local args = pane_ssh_args(pane)
  if args then
    local cmd = { '/usr/bin/env', 'PATH=' .. YAZI_PATH, CLIPIMG, tostring(pane:pane_id()) }
    for k = 2, #args do table.insert(cmd, args[k]) end -- drop leading ssh-pane
    wezterm.background_child_process(cmd)
  else
    window:perform_action(act.SendKey { key = 'v', mods = 'CTRL' }, pane)
  end
end)

-- SSH-aware new tab/window: from a local pane running ssh, open a fresh
-- ssh-pane to the same host (instant via ControlMaster); otherwise the default
-- spawn.
local function smart_spawn(new_window)
  return wezterm.action_callback(function(window, pane)
    local args = pane_ssh_args(pane)
    if args then
      local spec = {
        args = args,
        cwd = pane_cwd(pane),
        set_environment_variables = { PATH = SPAWN_PATH },
      }
      window:perform_action(new_window and act.SpawnCommandInNewWindow(spec)
        or act.SpawnCommandInNewTab(spec), pane)
    else
      window:perform_action(new_window and act.SpawnWindow or act.SpawnTab 'CurrentPaneDomain', pane)
    end
  end)
end

-- Layout-preserving merge. A WezTerm tab is a binary split tree, so its panes
-- can always be divided by one full-height (vertical) or full-width
-- (horizontal) cut into two groups. Recursing on that rebuilds the tree: the
-- top-left pane of the tab moves over as a new tab, then each cut becomes a
-- `split-pane --move-pane-id` of the first group's top-left pane, pulling in
-- the second group's top-left pane at a proportional --percent.
-- Pane records: { id, left, top, width, height } in cells (the shape of
-- tab:panes_with_info() and `wezterm cli list --format json` geometry).
local WEZTERM_CLI = '/opt/homebrew/bin/wezterm'

-- Run `wezterm cli <args...>`; returns success, stderr
local function cli(...)
  local ok, _, err = wezterm.run_child_process { WEZTERM_CLI, 'cli', ... }
  return ok, err
end

-- Top-left pane of a group
local function anchor_of(group)
  local a = group[1]
  for _, p in ipairs(group) do
    if p.top < a.top or (p.top == a.top and p.left < a.left) then a = p end
  end
  return a
end

local CUT_AXES = {
  { pos = 'left', size = 'width', flag = '--right' },
  { pos = 'top', size = 'height', flag = '--bottom' },
}

-- First full-length cut through `group`: returns first, second, flag, percent
-- (second group's share of the span), or nil if no clean cut exists.
local function find_cut(group)
  for _, axis in ipairs(CUT_AXES) do
    local lo, hi = math.huge, -math.huge
    for _, p in ipairs(group) do
      lo = math.min(lo, p[axis.pos])
      hi = math.max(hi, p[axis.pos] + p[axis.size])
    end
    for _, cand in ipairs(group) do
      local edge = cand[axis.pos] + cand[axis.size]
      local first, second, clean = {}, {}, true
      for _, p in ipairs(group) do
        if p[axis.pos] + p[axis.size] <= edge then
          table.insert(first, p)
        elseif p[axis.pos] >= edge then
          table.insert(second, p)
        else
          clean = false
          break
        end
      end
      if clean and #first > 0 and #second > 0 then
        local start2 = math.huge
        for _, p in ipairs(second) do start2 = math.min(start2, p[axis.pos]) end
        -- WezTerm floors span * percent / 100, so round the percent up
        local pct = math.ceil(100 * (hi - start2) / (hi - lo) - 1e-9)
        return first, second, axis.flag, math.max(1, math.min(99, pct))
      end
    end
  end
  return nil
end

-- Split steps { target, flag, percent, move } that rebuild `group` from its
-- anchor, appended to `steps`; false if some sub-group has no clean cut.
local function plan_splits(group, steps)
  if #group <= 1 then return true end
  local first, second, flag, pct = find_cut(group)
  if not first then return false end
  table.insert(steps, {
    target = anchor_of(first).id, flag = flag, percent = pct, move = anchor_of(second).id,
  })
  return plan_splits(first, steps) and plan_splits(second, steps)
end

-- Move one tab's panes into window `target_window` as a single new tab with the
-- same layout. Panes that can't be placed (no clean cut, or a cli call
-- failed) become separate tabs. Returns panes moved, whether layout was kept.
local function merge_tab(panes, target_window)
  local moved, pending = 0, {}
  for _, p in ipairs(panes) do pending[p.id] = true end
  local function to_new_tab(id)
    pending[id] = nil
    if cli('move-pane-to-new-tab', '--pane-id', tostring(id),
        '--window-id', tostring(target_window)) then
      moved = moved + 1
      return true
    end
    return false
  end

  local steps = {}
  local exact = plan_splits(panes, steps)
  if not exact then steps = {} end
  if to_new_tab(anchor_of(panes).id) then
    for _, s in ipairs(steps) do
      pending[s.move] = nil
      if cli('split-pane', '--pane-id', tostring(s.target), s.flag,
          '--percent', tostring(s.percent), '--move-pane-id', tostring(s.move)) then
        moved = moved + 1
      else
        exact = false
        break
      end
    end
  else
    exact = false
  end
  for _, p in ipairs(panes) do
    if pending[p.id] then to_new_tab(p.id) end
  end
  return moved, exact
end

-- Merge every other window into this one, one new tab per source tab with its
-- split layout kept, in window order then tab order. Emptied windows close on
-- their own once their last pane leaves.
local merge_windows = wezterm.action_callback(function(window, pane)
  local cur = window:mux_window():window_id()
  -- Capture all geometry before anything moves
  local tabs = {}
  for _, w in ipairs(wezterm.mux.all_windows()) do
    if w:window_id() ~= cur then
      for _, t in ipairs(w:tabs()) do
        t:set_zoomed(false) -- zoom hides the other panes' real geometry
        local panes = {}
        for _, info in ipairs(t:panes_with_info()) do
          table.insert(panes, {
            id = info.pane:pane_id(), left = info.left, top = info.top,
            width = info.width, height = info.height,
          })
        end
        if #panes > 0 then table.insert(tabs, panes) end
      end
    end
  end
  local total, moved, lost = 0, 0, 0
  for _, panes in ipairs(tabs) do
    local n, exact = merge_tab(panes, cur)
    total, moved = total + #panes, moved + n
    if not exact and #panes > 1 then lost = lost + 1 end
  end
  local msg = string.format('Merged %d tab%s (%d pane%s)', #tabs, #tabs == 1 and '' or 's',
    moved, moved == 1 and '' or 's')
  if lost > 0 then msg = msg .. '; layout lost in ' .. lost .. ' (split into tabs)' end
  if moved < total then msg = msg .. '; ' .. (total - moved) .. ' failed' end
  window:toast_notification('wezterm', msg, nil, 4000)
end)

-- Move this pane into tab N of this window (1-based, tab bar order) as a
-- split to the right of (flag '--right') or below ('--bottom') that tab's
-- active pane, then switch to tab N and focus it. A single-pane source tab
-- closes once its last pane leaves.
local function move_to_tab(n, flag)
  return wezterm.action_callback(function(window, pane)
    local tabs = window:mux_window():tabs()
    local target = tabs[n]
    if not target then
      window:toast_notification('wezterm', 'No tab ' .. n, nil, 2000)
      return
    end
    if target:tab_id() == pane:tab():tab_id() then
      window:toast_notification('wezterm', 'Already in tab ' .. n, nil, 2000)
      return
    end
    local id = tostring(pane:pane_id())
    local ok, err = cli('split-pane', '--pane-id', tostring(target:active_pane():pane_id()),
      flag, '--percent', '50', '--move-pane-id', id)
    if not ok then
      window:toast_notification('wezterm', 'Move failed: ' .. (err or '?'), nil, 4000)
      return
    end
    -- Activate the tab object, not index N-1: indices shift if the source tab closed
    target:activate()
    cli('activate-pane', '--pane-id', id)
  end)
end

-- Side-by-side Markdown over ssh. Locally ~/.local/bin/mdedit splits the pane
-- itself with `wezterm cli`; on a remote host it can't, so it sets user vars
-- (OSC 1337 SetUserVar, base64-decoded by WezTerm before this handler runs):
--  * mdedit_preview = "NONCE|/abs/path": if this is a local pane running ssh,
--    open `ssh -t HOST mdpreview PATH` to its right (instant via
--    ControlMaster) and keep focus on the editor.
--  * mdedit_close = NONCE: micro exited; kill that preview pane.
--  * mdpreview_reload: sent by mdpreview's watcher after a re-render; press
--    R in that pane so less reloads in place. send_text is raw input, not a
--    bracketed paste.
-- Local panes not running ssh ignore mdedit_*: local mdedit handles itself.
local MD_PREVIEW_KEY = 'md_preview_for_pane_' -- .. editor pane id -> "NONCE|PREVIEW_ID"

-- Kill the preview recorded for editor pane `editor_id` (only if its nonce
-- matches `nonce`, when given) and forget it.
local function close_md_preview(editor_id, nonce)
  local key = MD_PREVIEW_KEY .. editor_id
  local entry = wezterm.GLOBAL[key]
  if not entry then return end
  local n, preview = entry:match '^(.*)|(%d+)$'
  if nonce and n ~= nonce then return end
  wezterm.GLOBAL[key] = nil
  if preview then cli('kill-pane', '--pane-id', preview) end
end

wezterm.on('user-var-changed', function(_, pane, name, value)
  if name == 'mdpreview_reload' then
    pane:send_text 'R'
  elseif name == 'mdedit_close' then
    close_md_preview(pane:pane_id(), value)
  elseif name == 'mdedit_preview' then
    local nonce, path = value:match '^([^|]*)|(/.*)$'
    local ssh = nonce and pane_ssh_args(pane)
    if not ssh then return end
    close_md_preview(pane:pane_id()) -- stale preview from an mdedit that died
    local args = { 'ssh', '-t' }
    for k = 2, #ssh do table.insert(args, ssh[k]) end
    -- One remote command string; the remote shell expands $HOME
    table.insert(args, '"$HOME/.local/bin/mdpreview" ' .. sh_quote(path))
    local preview = pane:split {
      direction = 'Right',
      size = 0.5,
      args = args,
      cwd = pane_cwd(pane),
      set_environment_variables = { PATH = YAZI_PATH },
    }
    pane:activate()
    wezterm.GLOBAL[MD_PREVIEW_KEY .. pane:pane_id()] = nonce .. '|' .. preview:pane_id()
  end
end)

-- Tab / window renaming: a prompt sets an explicit title; empty input goes
-- back to the automatic one. Tab titles already win over pane titles in the
-- default tab bar; window titles need the format-window-title handler below.
local function rename_prompt(what)
  return act.PromptInputLine {
    description = 'Rename ' .. what .. ' (empty = automatic title):',
    action = wezterm.action_callback(function(window, _, line)
      if line == nil then return end -- Esc
      if what == 'tab' then
        window:active_tab():set_title(line)
      else
        window:mux_window():set_title(line)
      end
    end),
  }
end

-- WezTerm's default window title ([Z] zoomed, [i/N] tab index, pane title)
-- unless the window was renamed
wezterm.on('format-window-title', function(tab, _, tabs)
  if (tab.window_title or '') ~= '' then return tab.window_title end
  local zoomed = tab.active_pane.is_zoomed and '[Z] ' or ''
  local index = #tabs > 1 and string.format('[%d/%d] ', tab.tab_index + 1, #tabs) or ''
  return zoomed .. index .. tab.active_pane.title
end)

config.keys = {
  -- Unified copy/paste (see smart_copy / smart_paste above)
  { key = 'c', mods = 'CMD', action = smart_copy(false) },
  { key = 'c', mods = 'CMD|SHIFT', action = smart_copy(false) },
  { key = 'c', mods = 'CTRL|SHIFT', action = smart_copy(false) },
  { key = 'c', mods = 'CTRL', action = smart_copy(true) },
  { key = 'v', mods = 'CMD', action = smart_paste },
  { key = 'v', mods = 'CMD|SHIFT', action = smart_paste },
  { key = 'v', mods = 'CTRL|SHIFT', action = smart_paste },
  { key = 'v', mods = 'CTRL', action = smart_paste },

  -- Toggle the Yazi file sidebar for this tab
  { key = 'e', mods = 'CMD', action = wezterm.action_callback(toggle_sidebar) },

  -- Splits (Ghostty: cmd+d = right, cmd+shift+d = down); ssh-aware
  { key = 'd', mods = 'CMD', action = smart_split 'Right' },
  { key = 'd', mods = 'CMD|SHIFT', action = smart_split 'Bottom' },

  -- Close the focused pane instead of the whole tab (Ghostty: cmd+w)
  -- Confirm with a picker so Enter (or y) closes and n/Esc cancels
  { key = 'w', mods = 'CMD', action = act.InputSelector {
    title = 'Close this pane?  (Enter/y = close, n/Esc = cancel)',
    choices = { { id = 'yes', label = 'Yes, close it' }, { id = 'no', label = 'No' } },
    alphabet = 'yn',
    action = wezterm.action_callback(function(window, pane, id)
      if id == 'yes' then
        window:perform_action(act.CloseCurrentPane { confirm = false }, pane)
      end
    end),
  } },

  -- Cycle panes (Ghostty: cmd+[ / cmd+])
  { key = '[', mods = 'CMD', action = act.ActivatePaneDirection 'Prev' },
  { key = ']', mods = 'CMD', action = act.ActivatePaneDirection 'Next' },

  -- Move focus directionally (Ghostty: cmd+opt+arrows)
  { key = 'LeftArrow', mods = 'CMD|OPT', action = act.ActivatePaneDirection 'Left' },
  { key = 'RightArrow', mods = 'CMD|OPT', action = act.ActivatePaneDirection 'Right' },
  { key = 'UpArrow', mods = 'CMD|OPT', action = act.ActivatePaneDirection 'Up' },
  { key = 'DownArrow', mods = 'CMD|OPT', action = act.ActivatePaneDirection 'Down' },

  -- Resize focused pane (Ghostty: cmd+ctrl+arrows)
  { key = 'LeftArrow', mods = 'CMD|CTRL', action = act.AdjustPaneSize { 'Left', RESIZE_STEP } },
  { key = 'RightArrow', mods = 'CMD|CTRL', action = act.AdjustPaneSize { 'Right', RESIZE_STEP } },
  { key = 'UpArrow', mods = 'CMD|CTRL', action = act.AdjustPaneSize { 'Up', RESIZE_STEP } },
  { key = 'DownArrow', mods = 'CMD|CTRL', action = act.AdjustPaneSize { 'Down', RESIZE_STEP } },

  -- Zoom/unzoom focused pane to fill the tab (Ghostty: cmd+shift+enter)
  { key = 'Enter', mods = 'CMD|SHIFT', action = act.TogglePaneZoomState },

  -- Reshape: swap the focused pane with one you pick (shows letter labels)
  { key = 's', mods = 'CMD|SHIFT', action = act.PaneSelect { mode = 'SwapWithActive' } },
  -- Reshape: rotate pane positions within the tab
  { key = 'r', mods = 'CMD|OPT', action = act.RotatePanes 'Clockwise' },
  { key = 'r', mods = 'CMD|SHIFT|OPT', action = act.RotatePanes 'CounterClockwise' },
  -- Rename the tab / window (see rename_prompt)
  { key = 'r', mods = 'CMD|SHIFT', action = rename_prompt 'tab' },
  { key = 'r', mods = 'CMD|CTRL', action = rename_prompt 'window' },
  -- Jump to any pane by label
  { key = 'p', mods = 'CMD|SHIFT', action = act.PaneSelect { mode = 'Activate' } },

  -- Reorder tabs: move the current tab one slot left/right
  { key = 'LeftArrow', mods = 'CMD|SHIFT', action = act.MoveTabRelative(-1) },
  { key = 'RightArrow', mods = 'CMD|SHIFT', action = act.MoveTabRelative(1) },

  -- New tab/window, ssh-aware (see smart_spawn); CMD+SHIFT variants are always local
  { key = 't', mods = 'CMD', action = smart_spawn(false) },
  { key = 'n', mods = 'CMD', action = smart_spawn(true) },
  { key = 't', mods = 'CMD|SHIFT', action = act.SpawnTab 'DefaultDomain' },
  { key = 'n', mods = 'CMD|SHIFT', action = act.SpawnWindow },

  -- Move the focused pane out into a new tab / new window
  { key = 't', mods = 'CMD|OPT', action = wezterm.action_callback(function(_, pane)
    pane:move_to_new_tab()
  end) },
  { key = 'n', mods = 'CMD|OPT', action = wezterm.action_callback(function(_, pane)
    pane:move_to_new_window()
  end) },
  -- Pull every other window's tabs into this window, keeping split layouts
  { key = 'm', mods = 'CMD|SHIFT', action = merge_windows },
  -- ssh pane: forward a remote port to this Mac and open it (see open_forwarded)
  { key = 'l', mods = 'CMD|SHIFT', action = forward_prompt },
}

-- Move the focused pane into tab N (1-9) as a split: CMD+OPT+N = right of
-- that tab's active pane, CMD+OPT+SHIFT+N = below it. phys: keys so Option/
-- Shift symbols (¡, !, ...) don't stop the digits from matching.
for n = 1, 9 do
  table.insert(config.keys, { key = 'phys:' .. n, mods = 'CMD|OPT', action = move_to_tab(n, '--right') })
  table.insert(config.keys, { key = 'phys:' .. n, mods = 'CMD|OPT|SHIFT', action = move_to_tab(n, '--bottom') })
end

-- CMD+click opens links/paths even inside apps that capture the mouse
-- (Claude Code, less, micro); CMD+OPT+click reveals a path in Finder (see
-- REVEAL_KEY). mouse_reporting=true covers those apps; the plain entries
-- cover normal shells. The Down events are swallowed so the click isn't also
-- sent to the app or start a selection.
local function open_link(reveal)
  return wezterm.action_callback(function(window, pane)
    wezterm.GLOBAL[REVEAL_KEY] = reveal and os.time() or nil
    window:perform_action(act.OpenLinkAtMouseCursor, pane)
  end)
end

config.mouse_bindings = {}
for _, reporting in ipairs { false, true } do
  for mods, reveal in pairs { CMD = false, ['CMD|OPT'] = true } do
    table.insert(config.mouse_bindings, {
      event = { Down = { streak = 1, button = 'Left' } },
      mods = mods,
      mouse_reporting = reporting,
      action = act.Nop,
    })
    table.insert(config.mouse_bindings, {
      event = { Up = { streak = 1, button = 'Left' } },
      mods = mods,
      mouse_reporting = reporting,
      action = open_link(reveal),
    })
  end
end

return config
