-- Shared helpers: the palette, icons, toasts, prompts, pane lookups, shell
-- quoting, `wezterm cli`, file checks, and the peek and sidebar records that
-- features check before they touch a tab's layout.
local wezterm = require 'wezterm'

-- UI palette for the tab bar, prompts and pickers: Catppuccin Mocha, the
-- same flavor as Yazi (~/.config/yazi/theme.toml)
local C = {
  crust = '#11111b', mantle = '#181825', surface0 = '#313244', overlay0 = '#6c7086',
  text = '#cdd6f4', mauve = '#cba6f7', blue = '#89b4fa', peach = '#fab387', red = '#f38ba8',
}

-- Nerd Font glyphs; WezTerm bundles Symbols Nerd Font Mono as a fallback
local ICON = {
  rename = utf8.char(0xF03EB), window = utf8.char(0xF0614),
  server = utf8.char(0xF048B), folder = utf8.char(0xF024B),
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
  -- Until then the right status is this notice's (features/ports.lua's badge waits)
  wezterm.GLOBAL.notice_until = os.time() + math.ceil(ms / 1000) + 1
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

-- Peek state per tab (see replace_peek): 'origin|peek|zoomed' = the pane
-- that was clicked, the Yazi pane (split to its right, or alone in a new tab)
-- and whether to zoom the origin again once it closes. wezterm.GLOBAL
-- survives config reloads.
local PEEK_KEY = 'peek_for_tab_' -- .. tab id

local function peek_record(tab)
  local origin, peek, zoomed = (wezterm.GLOBAL[PEEK_KEY .. tab:tab_id()] or ''):match '^(%d+)|(%d+)|([01])$'
  if not peek then return nil end
  return { origin = tonumber(origin), peek = tonumber(peek), zoomed = zoomed == '1' }
end

local function set_peek_record(tab, rec) -- nil forgets the peek
  wezterm.GLOBAL[PEEK_KEY .. tab:tab_id()] = rec
    and string.format('%d|%d|%d', rec.origin, rec.peek, rec.zoomed and 1 or 0) or nil
end

-- True while a live peek pane is split into `tab`: layout surgery (rebuild,
-- pane moves, the sidebar) would destroy it. A peek in its own tab is not.
local function peek_open(tab)
  local rec = peek_record(tab)
  local peek = rec and mux_pane(rec.peek)
  local peek_tab = peek and peek:tab()
  return peek_tab ~= nil and peek_tab:tab_id() == tab:tab_id()
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

-- Yazi, used by the sidebar and by path peeks
local YAZI = '/opt/homebrew/bin/yazi'
-- GUI-launched WezTerm has a minimal PATH; yazi needs brew tools
local YAZI_PATH = '/opt/homebrew/bin:' .. wezterm.home_dir .. '/.local/bin:'
  .. (os.getenv 'PATH' or '/usr/bin:/bin:/usr/sbin:/sbin')

-- A Dock-launched GUI has no EDITOR, and Yazi's built-in text opener runs
-- ${EDITOR:-vi}: give every pane (and each peek) micro instead of vim
local EDITOR_ENV = { EDITOR = 'micro', VISUAL = 'micro' }
local function with_editor(env)
  for k, v in pairs(EDITOR_ENV) do env[k] = v end
  return env
end

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

-- Spawn spec (cwd, args, env) of the sidebar's Yazi; toggle_sidebar and the
-- session restore add direction and size
local function sidebar_spec(cwd)
  return {
    cwd = cwd,
    -- Pass the dir explicitly: yazi trusts an inherited $PWD over the real cwd
    args = { YAZI, cwd },
    set_environment_variables = {
      YAZI_SIDEBAR = '1',
      YAZI_CONFIG_HOME = wezterm.home_dir .. '/.config/yazi-sidebar',
      PATH = YAZI_PATH,
    },
  }
end

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
return {
  C = C, ICON = ICON, toast = toast, mux_pane = mux_pane, PEEK_KEY = PEEK_KEY,
  peek_record = peek_record, set_peek_record = set_peek_record, peek_open = peek_open,
  prompt_text = prompt_text, YAZI = YAZI, YAZI_PATH = YAZI_PATH, EDITOR_ENV = EDITOR_ENV,
  with_editor = with_editor, pane_cwd = pane_cwd, SIDEBAR_KEY = SIDEBAR_KEY,
  sidebar_spec = sidebar_spec, SPAWN_PATH = SPAWN_PATH, sh_quote = sh_quote,
  WEZTERM_CLI = WEZTERM_CLI, cli = cli, is_dir = is_dir, exists = exists,
}
