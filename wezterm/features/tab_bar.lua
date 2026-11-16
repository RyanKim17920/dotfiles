-- Tab bar and pickers in Catppuccin Mocha: a retro (cell-based) tab bar where
-- each tab shows its number, an icon and its title (the name you gave it,
-- else the ssh host, else the pane title or the cwd's name), plus matching
-- PaneSelect, command palette and character selector colors.
local wezterm = require 'wezterm'
local core = require 'lib.core'
local ssh_lib = require 'lib.ssh'
local C, ICON, mux_pane = core.C, core.ICON, core.mux_pane
local pane_ssh_args, ssh_host = ssh_lib.pane_ssh_args, ssh_lib.ssh_host

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

local M = {}

function M.apply(config)
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
end

return M
