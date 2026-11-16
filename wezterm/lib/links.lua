-- Link clicks. Mouse bindings (bind_click) open the link under the cursor,
-- also inside apps that grab the mouse, after noting a click mode. One
-- open-uri handler takes every click: WezTerm stops at the first handler
-- that returns false, so features don't register their own but fill a slot
-- here, tried in SLOTS order.
local wezterm = require 'wezterm'
local act = wezterm.action
local ssh_lib = require 'lib.ssh'
local paths = require 'lib.paths'
local pane_ssh_args, uri_to_path = ssh_lib.pane_ssh_args, paths.uri_to_path

-- CMD+OPT+click reveals the path in Finder instead (drag it from there into
-- a browser upload, Slack, ...): `open -R` for files, `open` for directories.
-- A remote file is first copied to ~/Downloads/<host>/ over the existing
-- ControlMaster. CMD+OPT+SHIFT+click opens a file in macOS Quick Look
-- instead (a remote one is copied to ~/Library/Caches/wezterm/peek/<host>/
-- first). The mouse binding sets 'reveal <time>' or 'look <time>' right
-- before opening the link; it is consumed by the next open-uri and ignored
-- once stale.
local LINK_MODE_KEY = 'link_mode_next_link'

-- CMD+click opens links/paths even inside apps that capture the mouse
-- (Claude Code, less, micro); CMD+OPT+click reveals a path in Finder and
-- CMD+OPT+SHIFT+click Quick Looks it (see LINK_MODE_KEY). mouse_reporting=true
-- covers those apps; the plain entries cover normal shells. The Down events
-- are swallowed so the click isn't also sent to the app or start a selection.
local function open_link(mode)
  return wezterm.action_callback(function(window, pane)
    wezterm.GLOBAL[LINK_MODE_KEY] = mode and (mode .. ' ' .. os.time()) or nil
    window:perform_action(act.OpenLinkAtMouseCursor, pane)
  end)
end

-- Bindings are built in a fixed order (ipairs, not pairs): each
-- action_callback is named by a per-evaluation counter, and the GUI may bind
-- the names from one config evaluation to the callbacks of another, so a
-- random pairs order sent plain CMD+click to the Quick Look callback.
-- Each `mods` is bound once (paths and port_forward both want CMD+click).
local bound = {}
local function bind_click(config, mods, mode)
  if bound[mods] then return end
  bound[mods] = true
  for _, reporting in ipairs { false, true } do
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
      action = open_link(mode),
    })
  end
end

-- open-uri slots: `ssh -L` commands and localhost URLs (port_forward) are
-- tried before paths. A slot gets (window, pane, uri, click), click being
-- { reveal, look, download } from the click mode; it returns false when it
-- handled the link, nil to pass it on (to WezTerm's default opener last).
local SLOTS = { 'forward', 'path' }
local slots = {}

local function handle(slot, fn)
  local first = next(slots) == nil
  slots[slot] = fn
  if not first then return end
  wezterm.on('open-uri', function(window, pane, uri)
    -- One GUI log line per click (~/.local/share/wezterm/wezterm-gui-log-*.txt);
    -- web URLs only up to host:port so tokens stay out of the log
    wezterm.log_info('open-uri: ' .. (uri:match '^%a[%w+.-]*://[^/?#]*' or uri))
    local mode, clicked = (wezterm.GLOBAL[LINK_MODE_KEY] or ''):match '^(%a+) (%d+)$'
    wezterm.GLOBAL[LINK_MODE_KEY] = nil
    if not clicked or os.time() - tonumber(clicked) > 2 then mode = nil end
    local click = { reveal = mode == 'reveal', look = mode == 'look', download = mode == 'download' }
    -- Right-click is for paths in ssh panes only: nothing happens on web links
    -- and `ssh -L` commands, like before it was bound
    if click.download and not (pane_ssh_args(pane) and uri_to_path(uri)) then return false end
    for _, name in ipairs(SLOTS) do
      if slots[name] and slots[name](window, pane, uri, click) == false then return false end
    end
  end)
end

return { LINK_MODE_KEY = LINK_MODE_KEY, open_link = open_link, bind_click = bind_click, handle = handle }
