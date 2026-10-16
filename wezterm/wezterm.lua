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

-- UI palette for the tab bar, prompts and pickers: Catppuccin Mocha, the
-- same flavor as Yazi (~/.config/yazi/theme.toml)
local C = {
  crust = '#11111b', mantle = '#181825', surface0 = '#313244', overlay0 = '#6c7086',
  text = '#cdd6f4', mauve = '#cba6f7', blue = '#89b4fa', peach = '#fab387', red = '#f38ba8',
}

-- Nerd Font glyphs; WezTerm bundles Symbols Nerd Font Mono as a fallback
local ICON = {
  rename = utf8.char(0xF03EB), window = utf8.char(0xF0614), close = utf8.char(0xF0156),
  cancel = utf8.char(0xF073A), server = utf8.char(0xF048B), folder = utf8.char(0xF024B),
  forward = utf8.char(0xF0318), zoom = utf8.char(0xF0293), console = utf8.char(0xF018D),
}

-- Feedback for clicks, prompts and moves; messages read "<Area>: <what
-- happened>". WezTerm's macOS toasts use the deprecated NSUserNotification
-- API, which current macOS no longer displays (WezTerm never even shows up in
-- System Settings > Notifications), so the message also flashes in the tab
-- bar's right status for `ms` and goes to the GUI log.
local function toast(window, msg, ms)
  ms = ms or 3000
  window:toast_notification('WezTerm', msg, nil, ms)
  wezterm.log_info('notice: ' .. msg)
  local seq = (wezterm.GLOBAL.notice_seq or 0) + 1
  wezterm.GLOBAL.notice_seq = seq
  window:set_right_status(wezterm.format {
    { Background = { Color = C.surface0 } }, { Foreground = { Color = C.peach } },
    { Text = ' ' .. msg .. ' ' },
  })
  wezterm.time.call_after(ms / 1000, function()
    if wezterm.GLOBAL.notice_seq == seq then window:set_right_status('') end
  end)
end

-- Pane by id, or nil once it's gone: wezterm.mux.get_pane raises for a
-- missing pane on 20240203 instead of returning nil
local function mux_pane(id)
  local ok, pane = pcall(wezterm.mux.get_pane, id)
  return ok and pane or nil
end

-- Heading for PromptInputLine: accent icon, bold title, dim hint below
local function prompt_text(icon, title, hint)
  return wezterm.format {
    { Foreground = { Color = C.mauve } }, { Text = ' ' .. icon .. '  ' },
    { Attribute = { Intensity = 'Bold' } }, { Foreground = { Color = C.text } }, { Text = title },
    { Attribute = { Intensity = 'Normal' } }, { Foreground = { Color = C.overlay0 } },
    { Text = '\r\n    ' .. hint .. '\r\n' },
  }
end

-- Pickers in the same palette: PaneSelect labels as mauve tiles, command
-- palette and character selector on the darker mantle
config.pane_select_font_size = 40
config.pane_select_fg_color = C.crust
config.pane_select_bg_color = C.mauve
config.command_palette_fg_color = C.text
config.command_palette_bg_color = C.mantle
config.command_palette_font_size = 15
config.char_select_fg_color = C.text
config.char_select_bg_color = C.mantle
config.char_select_font_size = 15

-- Retro (cell-based) tab bar on crust; each tab is drawn by
-- format-tab-title below
config.use_fancy_tab_bar = false
config.tab_max_width = 32
config.colors = {
  tab_bar = {
    background = C.crust,
    new_tab = { bg_color = C.crust, fg_color = C.overlay0 },
    new_tab_hover = { bg_color = C.surface0, fg_color = C.text },
  },
}

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

-- Sidebar pane id per tab; wezterm.GLOBAL survives config reloads
local SIDEBAR_KEY = 'sidebar_pane_for_tab_' -- .. tab id

-- Pane geometry of a tab: { id, pane, left, top, width, height } records in
-- cells (the shape merge_tab below consumes), plus the tree's extent and
-- whether a pane is zoomed (zoom hides the real geometry)
local function tab_geometry(tab)
  local panes, cols, rows, zoomed = {}, 0, 0, false
  for _, info in ipairs(tab:panes_with_info()) do
    table.insert(panes, {
      id = info.pane:pane_id(), pane = info.pane, left = info.left, top = info.top,
      width = info.width, height = info.height,
    })
    cols = math.max(cols, info.left + info.width)
    rows = math.max(rows, info.top + info.height)
    zoomed = zoomed or info.is_zoomed
  end
  return panes, cols, rows, zoomed
end

-- Rebuilds a tab from a geometry list (defined with merge_tab below)
local rebuild_tab

local function toggle_sidebar(window, pane)
  local tab = pane:tab()
  local key = SIDEBAR_KEY .. tab:tab_id()
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
    toast(window, 'Sidebar: only works in local tabs')
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

local WEZTERM_CLI = '/opt/homebrew/bin/wezterm'

-- Run `wezterm cli <args...>`; returns success, stderr
local function cli(...)
  local ok, _, err = wezterm.run_child_process { WEZTERM_CLI, 'cli', ... }
  return ok, err
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
-- temporary Yazi "peek" tab right after the current one, with the file
-- hovered and the preview maximized (YAZI_PEEK, see ~/.config/yazi/init.lua),
-- or the directory opened. q quits Yazi, closes the tab and returns to the
-- tab the click came from. A tab rather than a split, so a TUI like Claude
-- Code is never resized under it. OSC 8 file:// links (ls --hyperlink) are
-- handled the same way; web URLs are untouched.
local PEEK_SCHEME = 'yazi-open-path:'
local SSH_FORWARD_SCHEME = 'ssh-forward:' -- see forward_command
local PEEK_KEY = 'peek_pane' -- pane id of the open peek tab

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

-- Runs a peek command, then (unless the tab was closed some other way)
-- switches back to the tab it was opened from: argv cli tab_id cmd...
local PEEK_WRAPPER = [[
cli=$1 tab=$2; shift 2
trap 'exit 129' HUP
"$@"; s=$?
"$cli" cli activate-tab --tab-id "$tab" >/dev/null 2>&1
exit $s]]

-- Open the peek tab for `path` from `spec` (cwd, args, env), right after the
-- tab of `pane`. One peek tab at a time: the previous one is closed first.
local function replace_peek(window, pane, spec, path)
  local old = wezterm.GLOBAL[PEEK_KEY]
  if old and old ~= pane:pane_id() and mux_pane(old) then
    cli('kill-pane', '--pane-id', tostring(old))
  end
  local origin = pane:tab():tab_id()
  local mux_window = window:mux_window()
  local index = 0
  for _, info in ipairs(mux_window:tabs_with_info()) do
    if info.tab:tab_id() == origin then index = info.index end
  end
  local args = { '/bin/sh', '-c', PEEK_WRAPPER, 'sh', WEZTERM_CLI, tostring(origin) }
  for _, a in ipairs(spec.args) do table.insert(args, a) end
  spec.args = args
  local tab, peek = mux_window:spawn_tab(spec)
  tab:set_title('Peek: ' .. (path:match '([^/]+)/?$' or path))
  tab:activate()
  window:perform_action(act.MoveTab(index + 1), peek)
  wezterm.GLOBAL[PEEK_KEY] = peek:pane_id()
end

local function open_peek(window, pane, path)
  local dir = is_dir(path)
  local env = { PATH = YAZI_PATH }
  if not dir then env.YAZI_PEEK = path end
  replace_peek(window, pane, {
    cwd = dir and path or (path:match '^(.+)/' or '/'),
    args = { YAZI, path },
    set_environment_variables = env,
  }, path)
end

-- Paths clicked in a local pane running ssh live on the remote host. They
-- are resolved there over the existing ControlMaster and opened in remote
-- Yazi (installed by ssh-setup, whose synced init.lua handles YAZI_PEEK)
-- through ssh-pane. Relative paths resolve against the remote shell's cwd
-- when it reports one with OSC 7, else against the remote home.

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

-- kind ('f' or 'd') and absolute path on the pane's host of the first of
-- `texts` that exists there, or nil and a message
local function resolve_remote(ssh, texts, rcwd)
  if not ssh_master_pid(ssh) then
    return nil, 'ssh: no live connection to ' .. ssh_host(ssh) .. ' (ControlMaster)'
  end
  local words = {}
  for _, text in ipairs(texts) do
    for _, v in ipairs(path_variants(text)) do table.insert(words, remote_word(v, rcwd)) end
  end
  local cmd = ssh_batch_cmd(ssh)
  table.insert(cmd, 'sh -c ' .. sh_quote(string.format(REMOTE_RESOLVE, table.concat(words, ' '))))
  local ok, out = wezterm.run_child_process(cmd)
  local kind, path
  if ok then kind, path = out:match '^([fd]) (/[^\n]*)' end
  if not kind then return nil, 'Path: not found on ' .. ssh_host(ssh) .. ': ' .. texts[1] end
  return kind, path
end

-- Hard-wrapped paths: TUIs like Claude Code break long lines themselves
-- (newline + indentation, often behind a gutter such as │ or ⎿), so a click
-- sees only one piece of a long path. wrapped_candidates rebuilds it from
-- the pane's recent text: the clicked piece plus the path characters that
-- continue it at the start of the next lines and/or end the previous ones,
-- longest first. `wrapped` is true when the piece ends its line and a
-- continuation follows, i.e. on its own it is likely a cut-off prefix.
local WRAP_LINES = 3 -- lines joined at most in each direction
local WRAP_SCAN_LINES = 500
local WRAP_GUTTERS = { '│', '┃', '⎿', '●', '⏺', '▎', '▏', '•', '>', '*', '`', '|' }
local PATH_CHARS = '[%w%._~/@+%%:-]'

-- `s` without leading (or, with at_end, trailing) whitespace and gutter marks
local function strip_gutter(s, at_end)
  repeat
    local before = s
    s = at_end and (s:gsub('%s+$', '')) or (s:gsub('^%s+', ''))
    for _, g in ipairs(WRAP_GUTTERS) do
      if at_end and s:sub(-#g) == g then
        s = s:sub(1, -#g - 1)
      elseif not at_end and s:sub(1, #g) == g then
        s = s:sub(#g + 1)
      end
    end
  until s == before
  return s
end

local function wrapped_candidates(pane, text)
  local ok, all = pcall(pane.get_lines_as_text, pane, WRAP_SCAN_LINES)
  local lines = {}
  for line in ((ok and all or '') .. '\n'):gmatch '([^\n]*)\n' do table.insert(lines, line) end
  for i = #lines, 1, -1 do
    local first, last = lines[i]:find(text, 1, true)
    if first then
      local prefixes, suffixes = { '' }, { '' }
      if strip_gutter(lines[i]:sub(last + 1), true) == '' then
        local acc = ''
        for k = i + 1, math.min(i + WRAP_LINES, #lines) do
          local rest = strip_gutter(lines[k], false)
          local frag = rest:match('^' .. PATH_CHARS .. '+')
          if not frag then break end
          acc = acc .. frag
          table.insert(suffixes, acc)
          if frag ~= (rest:gsub('%s+$', '')) then break end -- the path ends on this line
        end
      end
      if strip_gutter(lines[i]:sub(1, first - 1), false) == '' then
        local acc = ''
        for k = i - 1, math.max(i - WRAP_LINES, 1), -1 do
          local rest = strip_gutter(lines[k], true)
          local frag = rest:match(PATH_CHARS .. '+$')
          if not frag then break end
          acc = frag .. acc
          table.insert(prefixes, acc)
          if frag ~= strip_gutter(rest, false) then break end -- the path starts on this line
        end
      end
      local cands = {}
      for _, pre in ipairs(prefixes) do
        for _, suf in ipairs(suffixes) do
          if pre ~= '' or suf ~= '' then table.insert(cands, pre .. text .. suf) end
        end
      end
      table.sort(cands, function(a, b) return #a > #b end)
      return cands, #suffixes > 1
    end
  end
  return {}, false
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
  }, path)
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
    toast(window, 'Finder: ' .. host .. ':' .. path .. ' is a remote directory; not copied')
    return
  end
  local sub = host:gsub('[^%w.-]', '_')
  local cmd = { '/bin/sh', '-c', FETCH_SCRIPT, 'sh', wezterm.home_dir .. '/Downloads/' .. sub,
    path:match '[^/]+$' }
  for _, a in ipairs(ssh_batch_cmd(ssh)) do table.insert(cmd, a) end
  table.insert(cmd, 'cat -- ' .. sh_quote(path))
  wezterm.background_child_process(cmd)
  toast(window, 'Finder: copying ' .. host .. ':' .. path .. ' to ~/Downloads/' .. sub .. '/')
end

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
--    the most recent `cat .../token` in the scrollback, read over the same
--    master; the token is never logged, shown or written to disk.
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
local SCROLLBACK_LINES = 2000

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

-- Text holding `ssh ... -L ... dest` -> pane_ssh_args-style args and its
-- forwards, or nil. Quotes/backticks around words and trailing prose
-- punctuation are dropped.
local function parse_ssh_text(text)
  local argv, first = {}, nil
  for w in text:gmatch '%S+' do
    w = w:gsub('^[`\'"(]+', ''):gsub('[`\'".,;)]+$', '')
    if w ~= '' then
      table.insert(argv, w)
      if not first and w:match '[^/]*$' == 'ssh' then first = #argv end
    end
  end
  if not first then return nil end
  local ssh, forwards = ssh_split_args(argv, first), collect_forwards(argv, first)
  if not ssh or #forwards == 0 then return nil end
  return ssh, forwards
end

-- Tunnel commands ({ ssh, forwards }, oldest first), the last `cat <path
-- with "token">` and loopback URLs (parsed, oldest first) in the pane's
-- recent scrollback. Logical lines, so text soft-wrapped by the terminal
-- stays whole.
local function scrollback_hints(pane)
  local tunnels, token_path, urls = {}, nil, {}
  local ok, text = pcall(pane.get_logical_lines_as_text, pane, SCROLLBACK_LINES)
  for line in (ok and text or ''):gmatch '[^\n]+' do
    local cmd = line:match '%f[%w]ssh%s.*'
    if cmd and cmd:find('-', 1, true) then
      local ssh, forwards = parse_ssh_text(cmd)
      if ssh then table.insert(tunnels, { ssh = ssh, forwards = forwards }) end
    end
    for path in line:gmatch '%f[%w]cat%s+([^%s`\'"]+)' do
      if path:lower():find('token', 1, true) then token_path = (path:gsub('[.,;:)]+$', '')) end
    end
    for u in line:gmatch 'https?://[^%s`\'"]+' do
      local url = parse_loopback_url((u:gsub('[.,;:)]+$', '')))
      if url then table.insert(urls, url) end
    end
  end
  return tunnels, token_path, urls
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

-- Args whose ControlMaster is live for the destination of `ssh`, and the
-- master's pid; nil if none. A hint may spell the host differently from the
-- alias that started the master (me@login.example.org vs myserver): with
-- ControlPath %C that is the same socket, but a per-alias ControlPath (e.g.
-- %r@%h:%p set only under `Host myserver`) is not, so config aliases
-- resolving to the same hostname/port (user too, if any alias matches it)
-- are tried as well.
local function find_master(ssh)
  local pid = ssh_master_pid(ssh)
  if pid then return ssh, pid end
  local host, user, port = ssh_identity(ssh)
  if not host then return nil end
  local loose = {}
  for _, alias in ipairs(ssh_config_aliases()) do
    local cand = { SSH_PANE, alias }
    local h, u, p = ssh_identity(cand)
    if h == host and p == port then
      if u == user then
        pid = ssh_master_pid(cand)
        if pid then return cand, pid end
      else
        table.insert(loose, cand)
      end
    end
  end
  for _, cand in ipairs(loose) do
    pid = ssh_master_pid(cand)
    if pid then return cand, pid end
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

local function forward_key(ssh, target, rport)
  return FORWARD_KEY .. table.concat(ssh, ' ', 2) .. '|' .. target .. ':' .. rport
end

-- -O forward / -O cancel of lport:target:rport on master `ssh`, keeping the
-- GLOBAL records in step
local function add_forward(ssh, lport, target, rport)
  local spec = lport .. ':' .. target .. ':' .. rport
  if not wezterm.run_child_process(ssh_cmd(ssh, '-O', 'forward', '-L', spec)) then return false end
  wezterm.GLOBAL[forward_key(ssh, target, rport)] = lport
  wezterm.GLOBAL[FORWARD_PORT_KEY .. lport] = table.concat(ssh, '\t') .. '\n' .. target .. '\n' .. rport
  return true
end

local function cancel_forward(ssh, lport, target, rport)
  wezterm.run_child_process(ssh_cmd(ssh, '-O', 'cancel', '-L', lport .. ':' .. target .. ':' .. rport))
  if listener(lport) then return false end
  wezterm.GLOBAL[FORWARD_PORT_KEY .. lport] = nil
  wezterm.GLOBAL[forward_key(ssh, target, rport)] = nil
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

-- Forward local `want` (or a free port near it) to target:rport through
-- master `ssh` (pid `pid`). `seen` are -L forwards from the scrollback: what
-- a busy port may have been forwarded to, for cancelling. Returns the local
-- port, how ('new', 'reused' or 'tunnel') and an optional note; or nil and a
-- message.
local function ssh_forward(ssh, pid, target, rport, want, seen)
  want = want >= 1024 and want or 8000 + want
  local function same(f) return f.host == target and f.rport == rport end
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
  table.insert(cmd, 'head -c 4096 -- ' .. remote_word(path, nil))
  local ok, out = wezterm.run_child_process(cmd)
  return ok and out:match '^%s*(%S+)%s*$' or nil
end

-- Open loopback `url` in the browser on local port `lport`, its token
-- placeholder (if any) filled from `token_path` read over master `ssh`;
-- `notify` gets a note about the token. Returns "host:port" opened.
local function open_local(ssh, url, lport, token_path, notify)
  local rest, has_placeholder = fill_placeholder(url.rest, nil)
  if has_placeholder then
    local token = token_path and read_remote_token(ssh, token_path)
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

-- CMD+click on an `ssh ... -L ...` command: add its forwards
local function forward_command(window, pane, text)
  local ssh, forwards = parse_ssh_text(text)
  if not ssh then
    toast(window, 'Forward: no -L forward in that ssh command')
    return
  end
  local master, pid = find_master(ssh)
  if not master then
    toast(window, no_master_msg(ssh), 5000)
    return
  end
  local tunnels, token_path, urls = scrollback_hints(pane)
  local seen = all_forwards(tunnels)
  local done, open_url, open_port = {}, nil, nil
  for _, f in ipairs(forwards) do
    local lport, how, note = ssh_forward(master, pid, f.host, f.rport, f.lport, seen)
    table.insert(done, lport and describe_forward(master, lport, f.host, f.rport, how, note) or how)
    -- Open one: the first forward with a URL in the scrollback, else the first
    local url = lport and latest_url(urls, f.lport)
    if lport and (not open_port or (url and not open_url)) then
      open_url, open_port = url, lport
    end
  end
  local msg = 'Forward: ' .. table.concat(done, ' · ')
  if open_port then
    -- No URL printed: a token hint alone still gets the token in (Jupyter-style ?token=)
    local url = open_url or parse_loopback_url('http://localhost:' .. open_port
      .. (token_path and '/?token=<token>' or '/'))
    local token_note
    local opened = open_local(master, url, open_port, token_path, function(n) token_note = n end)
    msg = msg .. ' → opened ' .. opened .. (token_note and ('; ' .. token_note) or '')
  end
  toast(window, msg, 5000)
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
  open_local(master, url, lport, token_path, function(n) msg = msg .. '; ' .. n end)
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

wezterm.on('open-uri', function(window, pane, uri)
  -- One GUI log line per click (~/.local/share/wezterm/wezterm-gui-log-*.txt);
  -- web URLs only up to host:port so tokens stay out of the log
  wezterm.log_info('open-uri: ' .. (uri:match '^%a[%w+.-]*://[^/?#]*' or uri))
  local clicked = wezterm.GLOBAL[REVEAL_KEY]
  wezterm.GLOBAL[REVEAL_KEY] = nil
  local reveal = clicked ~= nil and os.time() - clicked <= 2
  if uri:sub(1, #SSH_FORWARD_SCHEME) == SSH_FORWARD_SCHEME then
    forward_command(window, pane, uri:sub(#SSH_FORWARD_SCHEME + 1))
    return false
  end
  local url = parse_loopback_url(uri)
  if url and open_forwarded(window, pane, url) then return false end
  local ssh = pane_ssh_args(pane)

  local text, host = uri_to_path(uri)
  if not text then return end -- web URL etc.: default opener
  local custom = uri:sub(1, #PEEK_SCHEME) == PEEK_SCHEME

  if ssh then
    local rcwd = remote_cwd(pane)
    local kind, path = resolve_remote(ssh, { text }, rcwd)
    if custom and kind ~= 'f' then
      local cands, wrapped = wrapped_candidates(pane, text)
      local full_kind, full = nil, nil
      if #cands > 0 then full_kind, full = resolve_remote(ssh, cands, rcwd) end
      if full_kind then
        kind, path = full_kind, full
      elseif kind == 'd' and wrapped then
        toast(window, "Path: couldn't resolve wrapped path: " .. text)
        return false
      end
    end
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
  -- Outside ssh a file:// host is this Mac under some name (OSC 7 / ls
  -- --hyperlink use the DHCP name, which changes): use the path if it exists
  local cwd = pane_cwd(pane)
  local path = pane:get_domain_name() == 'local' and resolve_path(text, cwd)
  if custom and path ~= false and not (path and not is_dir(path)) then
    -- Missing, or a directory that may be the cut-off start of a wrapped path
    local cands, wrapped = wrapped_candidates(pane, text)
    local full
    for _, c in ipairs(cands) do
      full = resolve_path(c, cwd)
      if full then break end
    end
    if full then
      path = full
    elseif path and wrapped then
      toast(window, "Path: couldn't resolve wrapped path: " .. text)
      return false
    end
  end
  if not path then
    if custom then
      toast(window, 'Path: not found: ' .. text, 2000)
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

-- WezTerm 20240203 takes a `split-pane --move-pane-id` pane out of its tab
-- before attempting the split, so a refused split ("No space for split!", or
-- a zoomed target tab) loses the pane. Mirror split_and_insert's checks
-- (mux/src/tab.rs) first: true if splitting pane `target_id` along `flag`
-- with `percent` for the new part will succeed.
local function split_fits(target_id, flag, percent)
  local target = mux_pane(target_id)
  local tab = target and target:tab()
  if not tab then return false end
  local size = tab:get_size()
  for _, info in ipairs(tab:panes_with_info()) do
    if info.is_zoomed then return false end
    if info.pane:pane_id() == target_id then
      local span = flag == '--right' and info.width or info.height
      local second = math.max(1, math.floor(span * percent / 100))
      return span - second - 1 >= 1
        and info.left + info.width <= size.cols and info.top + info.height <= size.rows
    end
  end
  return false
end

-- Move one tab's panes into window `target_window` as a single new tab with the
-- same layout. Panes that can't be placed (no clean cut, no room, or a cli
-- call failed) become separate tabs. Returns panes moved, whether layout was
-- kept.
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
      if not split_fits(s.target, s.flag, s.percent) then
        exact = false
        break
      end
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

-- Layout repair. WezTerm 20240203's `top_level` split on a tab with 2+ panes
-- shrinks the tab's recorded size without restoring it, and later resizes
-- apply only the difference from that size, so the panes end up wider (or
-- taller) than the window and no resize brings them back. The only cure is a
-- fresh tab: rebuild_tab moves the panes, layout kept, into a new tab
-- (sized like the window's active tab, so internally consistent) that takes
-- over the old tab's slot, title, active pane and sidebar. Processes keep
-- running; only their panes move.

-- Rebuild `tab` from `geometry` (records as tab_geometry returns, ids only
-- needed); `active_id` defaults to the tab's active pane. Returns the new
-- tab, or nil if nothing was rebuilt.
rebuild_tab = function(window, tab, geometry, active_id)
  if wezterm.GLOBAL.layout_repairing or not plan_splits(geometry, {}) then return nil end
  local mux_window = tab:window()
  local old_id, title = tab:tab_id(), tab:get_title()
  active_id = active_id or tab:active_pane():pane_id()
  local before = {} -- tabs left of the old one, to put the new one after them
  for _, t in ipairs(mux_window:tabs()) do
    if t:tab_id() == old_id then break end
    before[t:tab_id()] = true
  end

  wezterm.GLOBAL.layout_repairing = true
  local ok, err, exact = pcall(merge_tab, geometry, mux_window:window_id())
  wezterm.GLOBAL.layout_repairing = nil
  if not ok then
    toast(window, 'Layout: rebuild failed: ' .. tostring(err), 5000)
    return nil
  end
  if not exact then
    toast(window, 'Layout: no room to keep the split layout; some panes went to their own tabs', 5000)
  end

  local anchor = mux_pane(anchor_of(geometry).id)
  local new_tab = anchor and anchor:tab()
  if not new_tab or new_tab:tab_id() == old_id then return nil end
  if title ~= '' then new_tab:set_title(title) end
  local index, current = 0, nil
  for i, t in ipairs(mux_window:tabs()) do
    if before[t:tab_id()] then index = index + 1 end
    if t:tab_id() == new_tab:tab_id() then current = i - 1 end
  end
  new_tab:activate()
  if current and current ~= index then
    -- MoveTab moves the active tab; perform_action waits for it to finish
    window:perform_action(act.MoveTab(index), new_tab:active_pane())
  end
  local active = mux_pane(active_id)
  if active then active:activate() end
  local sidebar = wezterm.GLOBAL[SIDEBAR_KEY .. old_id]
  wezterm.GLOBAL[SIDEBAR_KEY .. old_id] = nil
  if sidebar then wezterm.GLOBAL[SIDEBAR_KEY .. new_tab:tab_id()] = sidebar end
  return new_tab
end

-- True if some pane of `tab` reaches past the tab's recorded size (zoomed
-- tabs hide their real geometry and are skipped)
local function layout_overflows(tab)
  local geometry, cols, rows, zoomed = tab_geometry(tab)
  local size = tab:get_size()
  return not zoomed and #geometry > 1 and (cols > size.cols or rows > size.rows)
end

-- Rebuild `tab` if its panes overflow; `quiet` skips the "nothing to fix"
-- notice. Returns the tab now holding those panes.
local function repair_layout(window, tab, quiet)
  if not tab or wezterm.GLOBAL.layout_repairing then return tab end
  if not layout_overflows(tab) then
    if not quiet then toast(window, 'Layout: panes already fit the window', 2000) end
    return tab
  end
  local geometry = tab_geometry(tab)
  local new_tab = rebuild_tab(window, tab, geometry)
  if not new_tab then
    toast(window, 'Layout: could not rebuild this tab', 4000)
    return tab
  end
  toast(window, string.format('Layout: refit %d panes to the window', #geometry), 3000)
  return new_tab
end

-- Manual fix (CMD+SHIFT+=) and automatic checks after window resizes
wezterm.on('fix-layout', function(window, pane) repair_layout(window, pane:tab(), false) end)
wezterm.on('window-resized', function(window, pane)
  if pane then repair_layout(window, pane:tab(), true) end
end)

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
  local msg = string.format('Merge: %d tab%s (%d pane%s)', #tabs, #tabs == 1 and '' or 's',
    moved, moved == 1 and '' or 's')
  if lost > 0 then msg = msg .. '; layout lost in ' .. lost .. ' (split into tabs)' end
  if moved < total then msg = msg .. '; ' .. (total - moved) .. ' failed' end
  toast(window, msg, 4000)
  repair_layout(window, window:mux_window():active_tab(), true)
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
      toast(window, 'Move: no tab ' .. n, 2000)
      return
    end
    if target:tab_id() == pane:tab():tab_id() then
      toast(window, 'Move: already in tab ' .. n, 2000)
      return
    end
    -- An overflowing or zoomed target refuses the split, and a refused
    -- --move-pane-id split loses the pane (see split_fits): fix those first
    target:set_zoomed(false)
    target = repair_layout(window, target, true)
    local id = tostring(pane:pane_id())
    local anchor = target:active_pane():pane_id()
    if not split_fits(anchor, flag, 50) then
      toast(window, 'Move: no room to split in tab ' .. n .. '; pane left where it was', 4000)
      return
    end
    local ok, err = cli('split-pane', '--pane-id', tostring(anchor),
      flag, '--percent', '50', '--move-pane-id', id)
    if not ok then
      toast(window, 'Move: failed: ' .. (err or '?'), 4000)
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
    description = prompt_text(what == 'tab' and ICON.rename or ICON.window, 'Rename ' .. what,
      'Enter applies · empty restores the automatic title · Esc cancels'),
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

-- Tab bar entry: " 1 <icon> <title> " where the title is the explicit one
-- (CMD+SHIFT+R), else the ssh host for ssh panes (server icon, peach), else
-- the pane title, or the cwd's name when the title is just the process name.
-- The active tab is lifted onto surface0 with a mauve index.
local function tab_label(tab)
  local p = tab.active_pane
  local proc = (p.foreground_process_name or ''):match '[^/]*$'
  local ssh
  if proc == 'ssh' or proc == 'sh' then -- ssh-pane runs under /bin/sh
    local pane = mux_pane(p.pane_id)
    ssh = pane and pane_ssh_args(pane)
  end
  local icon, text = ICON.console, p.title
  if ssh then
    icon, text = ICON.server, ssh_host(ssh)
  elseif text == '' or text == proc then
    local cwd = p.current_working_dir
    local dir = type(cwd) == 'userdata' and cwd.file_path or tostring(cwd or '')
    icon, text = ICON.folder, dir:match '([^/]+)/?$' or proc
  end
  if (tab.tab_title or '') ~= '' then text = tab.tab_title end
  return icon, text, ssh ~= nil
end

wezterm.on('format-tab-title', function(tab, _, _, _, hover, max_width)
  local icon, text, remote = tab_label(tab)
  local index = tostring(tab.tab_index + 1)
  local zoom = tab.active_pane.is_zoomed and (' ' .. ICON.zoom) or ''
  -- cells: " N " + icon + " " + text + zoom + " "
  text = wezterm.truncate_right(text, math.max(1, max_width - #index - 5 - (zoom ~= '' and 2 or 0)))
  local bg = tab.is_active and C.surface0 or (hover and C.mantle or C.crust)
  return {
    { Background = { Color = bg } },
    { Foreground = { Color = tab.is_active and C.mauve or C.overlay0 } },
    { Attribute = { Intensity = 'Bold' } }, { Text = ' ' .. index .. ' ' },
    { Attribute = { Intensity = tab.is_active and 'Bold' or 'Normal' } },
    { Foreground = { Color = remote and C.peach or (tab.is_active and C.blue or C.overlay0) } },
    { Text = icon .. ' ' },
    { Foreground = { Color = tab.is_active and C.text or C.overlay0 } },
    { Text = text .. zoom .. ' ' },
  }
end)

-- WezTerm's default window title ([Z] zoomed, [i/N] tab index, pane title)
-- unless the window was renamed
wezterm.on('format-window-title', function(tab, _, tabs)
  if (tab.window_title or '') ~= '' then return tab.window_title end
  local zoomed = tab.active_pane.is_zoomed and '[Z] ' or ''
  local index = #tabs > 1 and string.format('[%d/%d] ', tab.tab_index + 1, #tabs) or ''
  return zoomed .. index .. tab.active_pane.title
end)

-- Home-row labels for PaneSelect (swap / jump)
local PANE_ALPHABET = 'asdfghjkl'

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
    title = 'Close pane',
    description = 'Close this pane?   Enter / y = close    n / Esc = cancel',
    choices = {
      { id = 'yes', label = wezterm.format {
        { Foreground = { Color = C.red } }, { Attribute = { Intensity = 'Bold' } },
        { Text = ICON.close .. '  Close pane' },
      } },
      { id = 'no', label = wezterm.format {
        { Foreground = { Color = C.overlay0 } }, { Text = ICON.cancel .. '  Cancel' },
      } },
    },
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
  { key = 's', mods = 'CMD|SHIFT', action = act.PaneSelect { mode = 'SwapWithActive', alphabet = PANE_ALPHABET } },
  -- Reshape: rotate pane positions within the tab
  { key = 'r', mods = 'CMD|OPT', action = act.RotatePanes 'Clockwise' },
  { key = 'r', mods = 'CMD|SHIFT|OPT', action = act.RotatePanes 'CounterClockwise' },
  -- Rename the tab / window (see rename_prompt)
  { key = 'r', mods = 'CMD|SHIFT', action = rename_prompt 'tab' },
  { key = 'r', mods = 'CMD|CTRL', action = rename_prompt 'window' },
  -- Jump to any pane by label
  { key = 'p', mods = 'CMD|SHIFT', action = act.PaneSelect { mode = 'Activate', alphabet = PANE_ALPHABET } },

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
  -- Fix layout: refit panes that spill past the window edge (see repair_layout);
  -- macOS reports Shift+= as either key
  { key = '=', mods = 'CMD|SHIFT', action = act.EmitEvent 'fix-layout' },
  { key = '+', mods = 'CMD|SHIFT', action = act.EmitEvent 'fix-layout' },
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
