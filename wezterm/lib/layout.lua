-- Pane geometry and layout surgery shared by the sidebar, pane moves, window
-- merges, layout repair and session restore: split_fits, the clean-cut split
-- plan (merge_tab) and rebuild_tab / repair_layout.
local wezterm = require 'wezterm'
local act = wezterm.action
local core = require 'lib.core'
local toast, mux_pane, peek_open, cli = core.toast, core.mux_pane, core.peek_open, core.cli
local SIDEBAR_KEY = core.SIDEBAR_KEY

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
local function rebuild_tab(window, tab, geometry, active_id)
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
  if peek_open(tab) then
    if not quiet then toast(window, 'Layout: close the peek (q) first', 2000) end
    return tab
  end
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
return {
  split_fits = split_fits, tab_geometry = tab_geometry, anchor_of = anchor_of, find_cut = find_cut,
  plan_splits = plan_splits, merge_tab = merge_tab, rebuild_tab = rebuild_tab,
  layout_overflows = layout_overflows, repair_layout = repair_layout,
}
