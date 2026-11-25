-- Config for tests/mux_test.sh's headless wezterm-mux-server: at startup it
-- opens a pane that prints a hard-wrapped and a soft-wrapped path, a
-- soft-wrapped and a hard-wrapped `ssh -fN -L ... && open '...#otc=...'`
-- tunnel line (placeholders) and then runs a stub `claude` (sleep under that
-- name) in $WZT_ROOT/agent-cwd, and once the text is on screen checks path
-- resolution and tunnel detection against the real pane, writing PASS/FAIL
-- lines to $WZT_ROOT/results.
local wezterm = require 'wezterm'
local mux = wezterm.mux
local ROOT = os.getenv 'WZT_ROOT'
package.path = os.getenv 'WZT_SRC' .. '/?.lua;' .. package.path
local core = require 'lib.core'
local paths = require 'lib.paths'
local agent = require 'lib.agent'
local port_forward = require 'features.port_forward'
local ports = require 'features.ports'

local SHOT = ROOT .. '/proj/1673a7e7-252a-4127-a63b-ab96a4c32fc2/scratchpad/shot/pareto.png'
local SOFT = ROOT .. '/proj/' .. ('long-directory-name-'):rep(6) .. 'x/plot.png'
local function tunnel_line(port)
  local url = 'http://localhost:' .. port .. '/#otc=TOKEN_x-9'
  return 'ssh -fN -L ' .. port .. ':localhost:' .. port .. " USER@login-1.HOST.example && (open '" .. url
    .. "' 2>/dev/null || xdg-open '" .. url .. "')"
end

local function run_checks(pane_id)
  local out = {}
  local function eq(name, got, want)
    table.insert(out, (got == want and 'PASS ' or 'FAIL ') .. name
      .. (got == want and '' or (': got ' .. tostring(got) .. ', want ' .. tostring(want))))
  end
  local pane = core.mux_pane(pane_id)
  if not pane then
    eq('pane is there', nil, pane_id)
  else
    -- The hard-wrapped path: three lines, each piece clicked
    local cwd = core.pane_cwd(pane)
    for _, piece in ipairs { ROOT .. '/proj/1673a7e7-', '252a-4127-a63b-ab96a4c3',
      '2fc2/scratchpad/shot/pareto.png' } do
      local texts = paths.path_candidates(pane, piece)
      table.insert(texts, piece)
      local got
      for _, c in ipairs(texts) do
        got = paths.resolve_path(c, cwd, {})
        if got then break end
      end
      eq('mux: hard wrap, click ' .. piece:gsub('^' .. ROOT:gsub('%p', '%%%0'), '<root>'), got, SHOT)
    end
    -- The soft-wrapped one is one logical line, so one link
    local lines = pane:get_logical_lines_as_text(200)
    eq('mux: soft wrap is one logical line', lines:find(SOFT, 1, true) ~= nil, true)
    -- The pane runs the stub claude in agent-cwd; a relative path printed
    -- by it resolves there
    local info = pane:get_foreground_process_info()
    -- (macOS reports /tmp as /private/tmp)
    if info and info.cwd then info.cwd = info.cwd:gsub('^/private/tmp/', '/tmp/') end
    eq('mux: foreground is an agent', info and agent.is_agent(info), true)
    eq('mux: agent cwd', info and info.cwd, ROOT .. '/agent-cwd')
    eq('mux: relative via the agent cwd', paths.resolve_path('notes/plan.md', '/nonexistent', { info and info.cwd }),
      ROOT .. '/agent-cwd/notes/plan.md')
    -- A relative path whose base is a wrapped path on screen
    local dirs = paths.search_dirs(pane, 'scratchpad/shot/pareto.png', 'test')
    eq('mux: relative via a wrapped path on screen', paths.resolve_path('scratchpad/shot/pareto.png', '/nonexistent',
      dirs), SHOT)
    -- Tunnel lines: 8766 soft-wrapped by the terminal, 8767 hard-wrapped
    -- (each piece printed on its own indented line, the token split)
    local tunnels = port_forward.screen_tunnels({ mux_window = function() error 'none' end }, pane)
    local labels = {}
    for _, t in ipairs(tunnels) do
      labels[t.forwards[1].lport] = ports._test.tunnel_label(t) .. ' ' .. t.ssh[#t.ssh] .. ' ' .. (t.url and t.url.rest or '-')
    end
    eq('mux: soft-wrapped tunnel line', labels[8766],
      '⇄ :8766 (from screen: open with token) USER@login-1.HOST.example /#otc=TOKEN_x-9')
    eq('mux: hard-wrapped tunnel line', labels[8767],
      '⇄ :8767 (from screen: open with token) USER@login-1.HOST.example /#otc=TOKEN_x-9')
  end
  local f = io.open(ROOT .. '/results', 'w')
  f:write(table.concat(out, '\n') .. '\nDONE\n')
  f:close()
end

-- The 8767 line as an agent's TUI hard-wraps it: at a space, then inside
-- the token
local HARD = { tunnel_line(8767):match "^(.-8767) (.-otc=TOK)(EN.*)$" }

wezterm.on('mux-startup', function()
  local script = table.concat({
    "printf '  %s\\n' " .. core.sh_quote(ROOT .. '/proj/1673a7e7-') .. " '252a-4127-a63b-ab96a4c3'"
      .. " '2fc2/scratchpad/shot/pareto.png — runs' 'only. 2 of 72 are on the front:'",
    'printf "saved %s here\\n" ' .. core.sh_quote(SOFT),
    'printf "%s\\n" ' .. core.sh_quote(tunnel_line(8766)),
    "printf '  %s\\n' " .. core.sh_quote(HARD[1]) .. ' ' .. core.sh_quote(HARD[2]) .. ' ' .. core.sh_quote(HARD[3]),
    'cd ' .. core.sh_quote(ROOT .. '/agent-cwd') .. ' && exec claude 600',
  }, '\n')
  local _, pane = mux.spawn_window {
    args = { '/bin/sh', '-c', script },
    cwd = ROOT,
    width = 60,
    height = 30,
    set_environment_variables = { PATH = os.getenv 'HOME' .. '/bin:/usr/bin:/bin' },
  }
  local id = pane:pane_id()
  wezterm.time.call_after(2, function() run_checks(id) end)
end)

return { term = 'xterm-256color' }
