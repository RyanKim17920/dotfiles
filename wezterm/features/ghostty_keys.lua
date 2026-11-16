-- Pane and tab keys mirroring Ghostty's macOS defaults: CMD+D / CMD+SHIFT+D
-- split (ssh-aware ones come from ssh_aware when it is on), CMD+W closes the
-- pane, CMD+[ ] / CMD+OPT+arrows move focus, CMD+CTRL+arrows resize,
-- CMD+SHIFT+Enter zooms, swap / rotate / jump to panes, reorder tabs.
local wezterm = require 'wezterm'
local act = wezterm.action

local RESIZE_STEP = 5 -- cells per keypress

-- Home-row labels for PaneSelect (swap / jump)
local PANE_ALPHABET = 'asdfghjkl'

local M = {}

function M.apply(config, ctx)
  if not ctx.features.ssh_aware then
    -- Splits (Ghostty: cmd+d = right, cmd+shift+d = down)
    table.insert(config.keys, { key = 'd', mods = 'CMD', action = act.SplitHorizontal { domain = 'CurrentPaneDomain' } })
    table.insert(config.keys, { key = 'd', mods = 'CMD|SHIFT', action = act.SplitVertical { domain = 'CurrentPaneDomain' } })
  end
  for _, key in ipairs {
    -- Close the focused pane instead of the whole tab (Ghostty: cmd+w). The
    -- built-in confirm is a pane-scoped overlay (y = close, n / Esc = cancel)
    -- and is skipped for an idle shell (skip_close_confirmation_for_processes_named)
    { key = 'w', mods = 'CMD', action = act.CloseCurrentPane { confirm = true } },
    { key = 'w', mods = 'CTRL|SHIFT', action = act.CloseCurrentPane { confirm = true } },

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
    -- Jump to any pane by label
    { key = 'p', mods = 'CMD|SHIFT', action = act.PaneSelect { mode = 'Activate', alphabet = PANE_ALPHABET } },

    -- Reorder tabs: move the current tab one slot left/right
    { key = 'LeftArrow', mods = 'CMD|SHIFT', action = act.MoveTabRelative(-1) },
    { key = 'RightArrow', mods = 'CMD|SHIFT', action = act.MoveTabRelative(1) },
  } do table.insert(config.keys, key) end
end

return M
