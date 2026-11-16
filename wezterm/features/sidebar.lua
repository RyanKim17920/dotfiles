-- File sidebar: CMD+E toggles a Yazi column on the left of the tab.
local wezterm = require 'wezterm'
local act = wezterm.action
local core = require 'lib.core'
local layout = require 'lib.layout'
local toast, peek_open, pane_cwd = core.toast, core.peek_open, core.pane_cwd
local SIDEBAR_KEY, sidebar_spec = core.SIDEBAR_KEY, core.sidebar_spec
local tab_geometry, rebuild_tab = layout.tab_geometry, layout.rebuild_tab

-- File sidebar (VS Code style): CMD+E toggles a narrow Yazi pane on the left
-- of the tab. It uses ~/.config/yazi-sidebar (single column; text files open in
-- micro in a new pane to its right via ~/.local/bin/yazi-open).
local SIDEBAR_CELLS = 32

-- Multi-pane tab: lay out `geometry` (the panes, extent cols x rows) shifted
-- right of a full-height sidebar column `sidebar_id`, `width` cells wide
local function with_sidebar(geometry, cols, rows, sidebar_id, width)
  local rest = math.max(1, cols - width - 1)
  local function x(v) return width + 1 + math.floor(v * rest / cols) end
  local out = { { id = sidebar_id, left = 0, top = 0, width = width, height = rows } }
  for _, p in ipairs(geometry) do
    local left = x(p.left)
    table.insert(out, {
      id = p.id, left = left, top = p.top, width = x(p.left + p.width) - left, height = p.height,
    })
  end
  return out
end

local function toggle_sidebar(window, pane)
  local tab = pane:tab()
  if peek_open(tab) then
    toast(window, 'Sidebar: close the peek (q) first', 2000)
    return
  end
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

  local spec = sidebar_spec(pane_cwd(pane))
  spec.direction = 'Left'
  spec.size = SIDEBAR_CELLS
  tab:set_zoomed(false) -- a zoomed tab refuses splits and hides geometry
  local geometry, cols, rows = tab_geometry(tab)
  if #geometry == 1 then
    -- One pane: a plain left split already spans the whole tab
    wezterm.GLOBAL[key] = pane:split(spec):pane_id()
    return
  end

  -- Several panes: WezTerm 20240203's `top_level` split leaves the tab's
  -- recorded size short of its panes (mux/src/tab.rs split_and_insert), so
  -- they later spill past the window edge. Instead spawn yazi as an ordinary
  -- split of the widest pane that fits, then rebuild the tab with it as a
  -- full-height column on the left.
  local size, host = tab:get_size(), nil
  for _, p in ipairs(geometry) do
    if p.left + p.width <= size.cols and p.width >= 3 and (not host or p.width > host.width) then
      host = p
    end
  end
  if not host then
    toast(window, 'Sidebar: no room for a split in this tab')
    return
  end
  spec.size = math.min(SIDEBAR_CELLS, host.width - 2)
  local sidebar = host.pane:split(spec):pane_id()
  local width = math.min(SIDEBAR_CELLS, math.max(1, cols - 2))
  local new_tab = rebuild_tab(window, tab, with_sidebar(geometry, cols, rows, sidebar, width), sidebar)
  wezterm.GLOBAL[SIDEBAR_KEY .. (new_tab or tab):tab_id()] = sidebar
end

local M = {}

function M.apply(config)
  for _, key in ipairs {
    -- Toggle the Yazi file sidebar for this tab
    { key = 'e', mods = 'CMD', action = wezterm.action_callback(toggle_sidebar) },
  } do table.insert(config.keys, key) end
end

return M
