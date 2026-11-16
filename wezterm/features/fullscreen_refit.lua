-- Fullscreen refit after a monitor change. WezTerm's own (non-native)
-- fullscreen sets the window frame to the screen it was entered on and never
-- refits it (toggle_simple_fullscreen in window/src/os/macos/window.rs, same
-- on nightly). Unplug the external monitor and the window lands on the
-- laptop still at the monitor's size, so the panes run off the screen. On a
-- resize that leaves a fullscreen window bigger than every screen, wait for
-- the display change to settle, then leave and re-enter fullscreen, which
-- sizes it to the current screen. One try per oversize episode, so a wrong
-- guess can't loop toggling fullscreen.
local wezterm = require 'wezterm'
local act = wezterm.action

local SETTLE_SECONDS = 1
local refit = {} -- window id -> 'pending' or 'tried', until it fits again

-- True if the window (dims from get_dimensions) fits on some screen.
-- Compared in points: macOS dpi is 72 per backing scale unit
local function fits_a_screen(dims)
  local w = dims.pixel_width * 72 / dims.dpi
  local h = dims.pixel_height * 72 / dims.dpi
  for _, s in pairs(wezterm.gui.screens().by_name) do
    if w <= s.width / s.scale + 1 and h <= s.height / s.scale + 1 then return true end
  end
  return false
end

local function oversized_fullscreen(window)
  local dims = window:get_dimensions()
  return dims.is_full_screen and not fits_a_screen(dims), dims
end

local M = {}

function M.apply()
  wezterm.on('window-resized', function(window)
    local id = window:window_id()
    if not oversized_fullscreen(window) then
      refit[id] = nil
      return
    end
    if refit[id] then return end
    refit[id] = 'pending'
    wezterm.time.call_after(SETTLE_SECONDS, function()
      local ok, oversized, dims = pcall(oversized_fullscreen, window)
      if not ok or not oversized then
        refit[id] = nil
        return
      end
      refit[id] = 'tried'
      wezterm.log_info(string.format('Fullscreen: %dx%d px at %d dpi is bigger than every screen; refitting',
        dims.pixel_width, dims.pixel_height, dims.dpi))
      window:perform_action(act.ToggleFullScreen, window:active_pane())
      window:perform_action(act.ToggleFullScreen, window:active_pane())
    end)
  end)
end

return M
