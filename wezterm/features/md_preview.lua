-- Side-by-side Markdown over ssh: remote mdedit asks (by user var) for its
-- preview pane next to the ssh pane.
local wezterm = require 'wezterm'
local core = require 'lib.core'
local ssh_lib = require 'lib.ssh'
local cli, sh_quote, pane_cwd, YAZI_PATH = core.cli, core.sh_quote, core.pane_cwd, core.YAZI_PATH
local pane_ssh_args = ssh_lib.pane_ssh_args

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

local M = {}

function M.apply()
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
end

return M
