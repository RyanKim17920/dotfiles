-- Rename tabs and windows: CMD+SHIFT+R / CMD+CTRL+R.
local wezterm = require 'wezterm'
local act = wezterm.action
local core = require 'lib.core'
local ICON, prompt_text = core.ICON, core.prompt_text

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

local M = {}

function M.apply(config)
  for _, key in ipairs {
    -- Rename the tab / window (see rename_prompt)
    { key = 'r', mods = 'CMD|SHIFT', action = rename_prompt 'tab' },
    { key = 'r', mods = 'CMD|CTRL', action = rename_prompt 'window' },
  } do table.insert(config.keys, key) end

  -- WezTerm's default window title ([Z] zoomed, [i/N] tab index, pane title)
  -- unless the window was renamed
  wezterm.on('format-window-title', function(tab, _, tabs)
    if (tab.window_title or '') ~= '' then return tab.window_title end
    local zoomed = tab.active_pane.is_zoomed and '[Z] ' or ''
    local index = #tabs > 1 and string.format('[%d/%d] ', tab.tab_index + 1, #tabs) or ''
    return zoomed .. index .. tab.active_pane.title
  end)
end

return M
