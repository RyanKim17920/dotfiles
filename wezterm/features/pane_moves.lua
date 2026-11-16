-- Moving panes between tabs and windows: CMD+OPT+T / CMD+OPT+N to a new tab /
-- window, CMD+OPT+1..9 (SHIFT: below) into tab N as a split, CMD+SHIFT+M
-- merges every other window into this one with split layouts kept.
local wezterm = require 'wezterm'
local act = wezterm.action
local core = require 'lib.core'
local layout = require 'lib.layout'
local toast, peek_open, cli = core.toast, core.peek_open, core.cli
local merge_tab, repair_layout, split_fits = layout.merge_tab, layout.repair_layout, layout.split_fits

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
    if peek_open(target) then
      toast(window, 'Move: close the peek in tab ' .. n .. ' first', 2000)
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

local M = {}

function M.apply(config)
  for _, key in ipairs {
    -- Move the focused pane out into a new tab / new window
    { key = 't', mods = 'CMD|OPT', action = wezterm.action_callback(function(_, pane)
      pane:move_to_new_tab()
    end) },
    { key = 'n', mods = 'CMD|OPT', action = wezterm.action_callback(function(_, pane)
      pane:move_to_new_window()
    end) },
    -- Pull every other window's tabs into this window, keeping split layouts
    { key = 'm', mods = 'CMD|SHIFT', action = merge_windows },
  } do table.insert(config.keys, key) end

  -- Move the focused pane into tab N (1-9) as a split: CMD+OPT+N = right of
  -- that tab's active pane, CMD+OPT+SHIFT+N = below it. phys: keys so Option/
  -- Shift symbols (¡, !, ...) don't stop the digits from matching.
  for n = 1, 9 do
    table.insert(config.keys, { key = 'phys:' .. n, mods = 'CMD|OPT', action = move_to_tab(n, '--right') })
    table.insert(config.keys, { key = 'phys:' .. n, mods = 'CMD|OPT|SHIFT', action = move_to_tab(n, '--bottom') })
  end
end

return M
