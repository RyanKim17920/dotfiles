-- Clickable file paths: CMD+click on a path such as ~/.ssh/config,
-- /Users/me/x.md, ./foo.py, tasks/todo.md, README.md or src/app.py:42 opens a
-- Yazi "peek" on the right half of the clicked pane (or in a new tab when it
-- is narrow), with the file hovered and the preview maximized (YAZI_PEEK, see
-- ~/.config/yazi/init.lua), or the directory opened. Images too (Yazi
-- previews them); PDFs open in Preview instead (see preview_file). q quits Yazi and you are back in the pane you
-- clicked (see replace_peek). CMD+OPT+SHIFT+click Quick Looks a file instead,
-- and in an ssh pane right-click downloads the file or folder (see
-- download_remote).
-- OSC 8 file:// links (ls --hyperlink) are handled the same way; web URLs are
-- untouched.
local wezterm = require 'wezterm'
local act = wezterm.action
local core = require 'lib.core'
local ssh_lib = require 'lib.ssh'
local layout = require 'lib.layout'
local paths = require 'lib.paths'
local files = require 'lib.files'
local links = require 'lib.links'
local toast, mux_pane, cli, is_dir, pane_cwd = core.toast, core.mux_pane, core.cli, core.is_dir, core.pane_cwd
local peek_record, set_peek_record = core.peek_record, core.set_peek_record
local YAZI, YAZI_PATH, with_editor = core.YAZI, core.YAZI_PATH, core.with_editor
local SPAWN_PATH, sh_quote = core.SPAWN_PATH, core.sh_quote
local SSH_PANE, pane_ssh_args = ssh_lib.SSH_PANE, ssh_lib.pane_ssh_args
local split_fits, tab_geometry = layout.split_fits, layout.tab_geometry
local PEEK_SCHEME, uri_to_path, resolve_path = paths.PEEK_SCHEME, paths.uri_to_path, paths.resolve_path
local click_line, remote_cwd, resolve_remote = paths.click_line, paths.remote_cwd, paths.resolve_remote
local path_candidates, search_dirs, remember_dir = paths.path_candidates, paths.search_dirs, paths.remember_dir
local reveal_local, quicklook_local, preview_file = files.reveal_local, files.quicklook_local, files.preview_file
local reveal_remote, quicklook_remote, download_remote = files.reveal_remote, files.quicklook_remote, files.download_remote

-- Narrowest clicked pane (columns) whose right half is still a useful peek;
-- a narrower one gets the peek in a new tab instead
local PEEK_MIN_COLS = 80

-- Back to the pane the peek was opened from (and its tab), zoomed again if
-- it was before
local function show_origin(tab, origin, zoomed)
  origin:activate()
  if zoomed then tab:set_zoomed(true) end
end

-- Open a peek (`spec`: cwd, args, env) for the clicked `pane`: the right half
-- of that pane (a split of the pane itself, never top_level, see
-- repair_layout), focused. A pane under PEEK_MIN_COLS, or one that can't take
-- the split (split_fits), gets the peek in a new tab right after its own
-- instead. When Yazi quits the pane (or tab) closes and restore_peeks
-- re-activates `pane`. One peek per tab: a click while one is open opens the
-- new one in its place.
local function replace_peek(window, pane, spec)
  local tab = pane:tab()
  local origin, zoomed = pane, select(4, tab_geometry(tab))
  local rec = peek_record(tab)
  local old = rec and mux_pane(rec.peek)
  if rec then
    zoomed = rec.zoomed
    if old and old:pane_id() == pane:pane_id() then origin = mux_pane(rec.origin) or pane end
    set_peek_record(tab, nil)
  end
  spec.domain = 'DefaultDomain' -- local Yazi, even when the clicked pane is in a mux domain
  -- An open peek is split and then closed, so the new one takes over its
  -- cells: closing it first would not help, as 20240203 hands its cells back
  -- only after this handler returns
  local target = old
  if not old then
    tab:set_zoomed(false) -- a zoomed tab refuses splits and hides geometry
    if origin:get_dimensions().cols >= PEEK_MIN_COLS and split_fits(origin:pane_id(), '--right', 50) then
      target = origin
    end
  end
  local ok, peek = false, nil
  if target then
    target:tab():set_zoomed(false)
    spec.direction, spec.size = 'Right', 0.5
    ok, peek = pcall(target.split, target, spec)
    spec.direction, spec.size = nil, nil
  end
  if old then cli('kill-pane', '--pane-id', tostring(old:pane_id())) end
  if ok then
    peek:activate()
  else
    show_origin(tab, origin, zoomed)
    zoomed = false -- the origin tab keeps its zoom while the peek tab is open
    local mux_window = window:mux_window()
    local index = 0 -- 0-based position of the origin tab
    for i, t in ipairs(mux_window:tabs()) do
      if t:tab_id() == tab:tab_id() then index = i - 1 end
    end
    local peek_tab
    ok, peek_tab, peek = pcall(mux_window.spawn_tab, mux_window, spec)
    if not ok then
      toast(window, 'Peek: could not open a tab: ' .. tostring(peek_tab))
      return
    end
    peek_tab:activate()
    if index + 1 < #mux_window:tabs() - 1 then
      -- MoveTab moves the active tab; perform_action waits for it to finish
      window:perform_action(act.MoveTab(index + 1), peek)
    end
  end
  set_peek_record(tab, { origin = origin:pane_id(), peek = peek:pane_id(), zoomed = zoomed })
end

-- A peek pane has closed (Yazi quit): activate the pane (and tab) it came
-- from again and re-zoom it if the tab was zoomed there. WezTerm has no
-- pane-exit event, so update-status (every status_update_interval) notices.
local function restore_peeks(mux_window)
  for _, tab in ipairs(mux_window:tabs()) do
    local rec = peek_record(tab)
    if rec and not mux_pane(rec.peek) then
      set_peek_record(tab, nil)
      local origin = mux_pane(rec.origin)
      if origin then show_origin(tab, origin, rec.zoomed) end
    end
  end
end

local function open_peek(window, pane, path, line)
  local dir = is_dir(path)
  local env = with_editor { PATH = YAZI_PATH }
  if not dir then
    env.YAZI_PEEK = path
    env.YAZI_PEEK_LINE = line
  end
  replace_peek(window, pane, {
    cwd = dir and path or (path:match '^(.+)/' or '/'),
    args = { YAZI, path },
    set_environment_variables = env,
  })
end

local function open_remote_peek(window, pane, ssh, kind, path, line)
  -- $HOME/.local/bin first: ssh-setup's yazi and its previewers, else any yazi.
  -- This sh is non-interactive (no ~/.bashrc), so set the editor here too
  local script = 'export PATH="$HOME/.local/bin:$PATH" EDITOR=micro VISUAL=micro; '
    .. (kind == 'f' and ('export YAZI_PEEK=' .. sh_quote(path) .. '; ') or '')
    .. (kind == 'f' and line and ('export YAZI_PEEK_LINE=' .. sh_quote(line) .. '; ') or '')
    .. 'exec yazi ' .. sh_quote(path)
  local args = { SSH_PANE, '-t' }
  for k = 2, #ssh do table.insert(args, ssh[k]) end
  table.insert(args, 'sh -c ' .. sh_quote(script))
  replace_peek(window, pane, {
    cwd = wezterm.home_dir,
    args = args,
    set_environment_variables = { PATH = SPAWN_PATH },
  })
end

-- A clicked link that port forwarding (if on) passed on: a path is resolved
-- (in an ssh pane on that host) and opened in a peek, or as the click mode
-- (lib/links.lua) and the media_reveal / pdf_preview features say
local function open_path(window, pane, uri, click, ctx)
  local reveal, look, download = click.reveal, click.look, click.download
  local is_media, is_pdf = ctx.is_media, ctx.is_pdf
  local ssh = pane_ssh_args(pane)

  local text, host = uri_to_path(uri)
  if not text then return end -- web URL etc.: default opener
  local custom = uri:sub(1, #PEEK_SCHEME) == PEEK_SCHEME
  -- Directories besides the cwd that a relative path may be in (see
  -- search_dirs), keyed by host so recent clicks on one don't leak to another
  local host_key = ssh and ('ssh ' .. table.concat(ssh, ' ', 2)) or 'local'
  local dirs = {}
  if custom and text:sub(1, 1) ~= '/' and text:sub(1, 1) ~= '~' then dirs = search_dirs(pane, text, host_key) end

  if ssh then
    -- The longer spellings (see path_candidates) and the clicked text, in
    -- one round trip; the first that exists wins
    local texts, wrapped = {}, false
    if custom then texts, wrapped = path_candidates(pane, text) end
    table.insert(texts, text)
    local kind, path, which = resolve_remote(ssh, texts, remote_cwd(pane), dirs)
    if which and which < #texts then
      text = texts[which]
    elseif kind == 'd' and wrapped then
      toast(window, "Path: couldn't resolve wrapped path: " .. text)
      return false
    end
    if not kind then
      toast(window, path)
      return false
    end
    remember_dir(host_key, path, kind == 'd')
    if download then
      download_remote(window, ssh, { path })
    elseif reveal or (kind == 'f' and is_media(path)) then
      reveal_remote(window, ssh, kind, path)
    elseif kind == 'f' and look then
      quicklook_remote(window, ssh, path)
    elseif kind == 'f' and is_pdf(path) then
      preview_file(window, path, ssh)
    else
      open_remote_peek(window, pane, ssh, kind, path, click_line(text, path))
    end
    return false
  end
  -- Outside ssh a file:// host is this Mac under some name (OSC 7 / ls
  -- --hyperlink use the DHCP name, which changes): use the path if it exists
  local cwd = pane_cwd(pane)
  local path = pane:get_domain_name() == 'local' and resolve_path(text, cwd, dirs)
  if custom and path ~= false then
    -- The longest existing spelling with spaces or across a wrap (see
    -- path_candidates) beats the clicked piece, even one that exists
    local cands, wrapped = path_candidates(pane, text)
    local full
    for _, c in ipairs(cands) do
      full = resolve_path(c, cwd, dirs)
      if full then
        text = c
        break
      end
    end
    if full then
      path = full
    elseif path and is_dir(path) and wrapped then
      toast(window, "Path: couldn't resolve wrapped path: " .. text)
      return false
    end
  end
  if not path then
    if custom then
      toast(window, 'Path: not found: ' .. text, 2000)
      return false
    end
    return -- file:// we can't resolve: let the default opener try
  end
  remember_dir(host_key, path, is_dir(path))
  if reveal or (not look and not is_dir(path) and is_media(path)) then
    reveal_local(path)
    if not reveal then toast(window, 'Finder: ' .. (path:match '[^/]+$' or path), 2000) end
  elseif look and not is_dir(path) then
    quicklook_local(window, path)
  elseif not is_dir(path) and is_pdf(path) then
    preview_file(window, path)
  else
    open_peek(window, pane, path, click_line(text, path))
  end
  return false
end

local M = {}

function M.apply(config, ctx)
  wezterm.on('update-status', function(window) restore_peeks(window:mux_window()) end)

  -- Paths are recognized at the start of a line or after whitespace, a quote,
  -- backtick, bracket, = or * (markdown **bold**), so the /a/b inside URLs
  -- never matches. Group 1 is the path (with any :line[:col] or :first-last).
  -- WezTerm compiles these with fancy-regex, so lookarounds work.

  -- Anchored paths: ~/, ./, ../ or /. They stop at whitespace, quotes,
  -- backticks, brackets and * (unless backslash-escaped, as in My\ Disk) and
  -- never end in . , : ; ! ? so prose punctuation stays out.
  table.insert(config.hyperlink_rules, {
    regex = [=[(?:^|[\s"'`(\[{<=*])((?:~|\.\.?)?/(?:\\.|[^\s"'`()\[\]{}<>*\\])*(?:\\.|[^\s"'`()\[\]{}<>*\\.,:;!?]))]=],
    format = PEEK_SCHEME .. '$1',
    highlight = 1,
  })

  -- Quoted anchored paths ("/My Disk/a b.mp4", '~/x y', `./a (1).txt`) are
  -- one link up to the closing quote, spaces and brackets included. Unquoted
  -- ones with spaces are rebuilt when clicked (see path_candidates).
  for _, q in ipairs { '"', "'", '`' } do
    table.insert(config.hyperlink_rules, {
      regex = [=[(?:^|[\s(\[{<=:,])]=] .. q .. [=[((?:~|\.\.?)?/[^]=] .. q .. [=[]*[^\s]=] .. q .. [=[])]=] .. q,
      format = PEEK_SCHEME .. '$1',
      highlight = 1,
    })
  end

  -- Bare relative paths as Claude Code prints them (tasks/todo.md,
  -- src/app.py:42, README.md). To keep prose like and/or, 1/2, 10/16/2026,
  -- e.g., 1.2.3 and example.com out, one must be
  --  * dir/.../file.ext (extension starts with a letter),
  --  * three or more segments starting with a letter (bin/tools/ssh-pane),
  --  * dir/ followed by whitespace or punctuation,
  --  * name.ext with a known source/doc extension, a common dotfile, or a
  --    Makefile/Dockerfile/Justfile.
  -- Segments never end in a dot, so a sentence's final period is left out.
  -- Unknown paths only toast when clicked.
  local REL_START = [=[(?<![^\s"'`(\[{<=*])]=] -- like the boundary above, not consumed
  local REL_FIRST = [=[\.?[\w@+](?:[\w.@+~-]*[\w@+~-])?]=]
  local REL_FIRST_ALPHA = [=[\.?[A-Za-z_](?:[\w.@+~-]*[\w@+~-])?]=]
  local REL_SEG = [=[\.?[\w@+~-](?:[\w.@+~-]*[\w@+~-])?]=]
  local REL_EXTS = 'md|markdown|txt|rst|py|pyi|ipynb|js|mjs|cjs|jsx|ts|tsx|vue|svelte|lua|sh|bash'
    .. '|zsh|fish|json|jsonl|toml|ya?ml|ini|cfg|conf|env|lock|rs|go|c|h|cc|cpp|hpp|cu|java|kt'
    .. '|swift|rb|php|sql|css|scss|html?|xml|csv|tsv|log|tex|bib|pdf|png|jpe?g|gif|svg|webp'
    .. '|mp4|mov|zip|gz|tgz|tar|patch|diff|proto|tf|nix|vim'
  local REL_DOTFILES = [=[[\w-]*rc|env|gitignore|gitconfig|gitattributes|profile|zprofile|editorconfig|dockerignore]=]
  table.insert(config.hyperlink_rules, {
    regex = REL_START .. '((?:'
      .. REL_FIRST_ALPHA .. '(?:/' .. REL_SEG .. '){2,}/?'
      .. '|' .. REL_FIRST .. '(?:/' .. REL_SEG .. [=[)*/[\w@+~.-]*\.[A-Za-z]\w*]=]
      .. '|' .. REL_FIRST .. '(?:/' .. REL_SEG .. [=[)*/(?=$|[\s"'`)\]}>*,;:!?])]=]
      .. '|' .. REL_FIRST .. [=[\.(?i:]=] .. REL_EXTS .. [=[)\b]=]
      .. [=[|\.(?:]=] .. REL_DOTFILES .. [=[)\b(?:\.[\w-]+)*]=]
      .. [=[|(?:Makefile|Dockerfile|Justfile)\b]=]
      .. [=[)(?::\d+(?:[:-]\d+)?)?)]=],
    format = PEEK_SCHEME .. '$1',
    highlight = 1,
  })

  -- A line that is nothing but one word with a / in it (after indentation
  -- or a gutter) is most likely the middle of a path a TUI hard-wrapped
  -- mid-word over three or more lines, like the `oj/1673a7e7-252a` of
  -- `/tmp/claude-1000/-home-user-pr` + `oj/1673a7e7-252a` +
  -- `2fc2/shot/plot.png`, which no other rule links; path_candidates
  -- rebuilds the whole path from it.
  table.insert(config.hyperlink_rules, {
    regex = [=[^[\s│┃▎▏]*([\w@+~%-][\w.@+~%-]*(?:/[\w.@+~%-]*)+)\s*$]=],
    format = PEEK_SCHEME .. '$1',
    highlight = 1,
  })

  links.handle('path', function(window, pane, uri, click) return open_path(window, pane, uri, click, ctx) end)
  -- CMD+click opens links/paths even inside apps that capture the mouse
  -- (Claude Code, less, micro)
  links.bind_click(config, 'CMD', false)
end

return M
