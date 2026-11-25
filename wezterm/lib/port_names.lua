-- What a listening port is, from its process's command line, working folder
-- and page title, for the CMD+SHIFT+I list (features/ports.lua):
-- `python -m jupyter lab` in ~/cswap is "Jupyter Lab · cswap". Pure functions,
-- no WezTerm calls, so tests/port_names_test.lua covers them.
local M = {}

-- Last path component ("train_viz.py" of "foo/train_viz.py")
local function base(s)
  return (s:gsub('/+$', ''):match '[^/]*$')
end

local function starts_dash(w)
  return w:sub(1, 1) == '-'
end

-- argv from a /proc/<pid>/cmdline whose NULs came as \31 (exact), else from
-- a `ps -o args=` line (words). `exists(path)` lets a ps line's path with
-- spaces rejoin: an absolute word that is no file takes the next words until
-- they name one ("/Applications/Visual Studio Code.app/...").
function M.split_cmdline(s, exists)
  local argv = {}
  s = s or ''
  if s:find('\31', 1, true) then
    for w in (s .. '\31'):gmatch '(.-)\31' do
      if w ~= '' then table.insert(argv, w) end
    end
    -- A process that rewrote its title ("nginx: master process ...") is
    -- one argument with spaces
    if #argv > 1 or not (argv[1] or ''):find '%s' then return argv end
    s, argv = argv[1], {}
  end
  local words = {}
  for w in s:gmatch '%S+' do table.insert(words, w) end
  local i = 1
  while i <= #words do
    local w, used = words[i], 1
    if exists and w:sub(1, 1) == '/' and not exists(w) then
      local joined = w
      for j = i + 1, math.min(#words, i + 8) do
        joined = joined .. ' ' .. words[j]
        if exists(joined) then
          w, used = joined, j - i + 1
          break
        end
      end
    end
    table.insert(argv, w)
    i = i + used
  end
  return argv
end

-- Value of an option: "--model M", "--model=M" (any of `names`)
local function opt(args, names)
  for i, a in ipairs(args) do
    for _, n in ipairs(names) do
      if a == n then return args[i + 1] end
      if a:sub(1, #n + 1) == n .. '=' then return a:sub(#n + 2) end
    end
  end
end

-- First argument that is not an option (nor the value of one in `with_value`)
local function positional(args, with_value)
  local i = 1
  while args[i] do
    local a = args[i]
    if not starts_dash(a) then return a end
    i = i + ((with_value and with_value[a]) and 2 or 1)
  end
end

-- First argument that names a script or notebook
local function script_arg(args)
  for _, a in ipairs(args) do
    if not starts_dash(a) and (a:match '%.py$' or a:match '%.ipynb$' or a:match '%.R$') then return base(a) end
  end
end

-- "meta-llama/Llama-3.1-8B" and "/models/qwen-7b/" -> their last part
local function model_name(m)
  return m and m ~= '' and base(m) or nil
end

local function join(a, b)
  return b and (a .. ' · ' .. b) or a
end

-- An ASGI/WSGI app ("main:app", "app.server:create_app()"), not an address
local function app_arg(args)
  for _, a in ipairs(args) do
    if not starts_dash(a) and a:match '^[%a_][%w_%.]*:[%a_][%w_%.%(%)]*$' then return a end
  end
end

local function with_script(title)
  return function(args) return join(title, script_arg(args)) end
end

local function jupyter(kind)
  return function() return 'Jupyter ' .. kind end
end

local function vllm(args)
  local m = opt(args, { '--model' })
  if not m and args[1] == 'serve' and args[2] and not starts_dash(args[2]) then m = args[2] end
  return join('vLLM', model_name(m))
end

local function asgi(name)
  return function(args) return join(name, app_arg(args)) end
end

-- Programs (or python modules, or scripts by name) that say more than their
-- name. Each gets the arguments after it and the env wrapper's variables.
local TOOLS = {
  jupyter = function(args)
    local sub = args[1]
    if sub == 'lab' or sub == 'notebook' or sub == 'server' or sub == 'nbclassic' then
      return 'Jupyter ' .. (sub == 'nbclassic' and 'Notebook' or sub:sub(1, 1):upper() .. sub:sub(2))
    end
    return 'Jupyter'
  end,
  ['jupyter-lab'] = jupyter 'Lab', jupyterlab = jupyter 'Lab',
  ['jupyter-notebook'] = jupyter 'Notebook', notebook = jupyter 'Notebook', nbclassic = jupyter 'Notebook',
  ['jupyter-server'] = jupyter 'Server', jupyter_server = jupyter 'Server',
  ipykernel_launcher = function() return 'Jupyter kernel' end,
  ipykernel = function() return 'Jupyter kernel' end,
  tensorboard = function(args)
    return join('TensorBoard', model_name(opt(args, { '--logdir', '--logdir_spec' })))
  end,
  streamlit = with_script 'Streamlit',
  gradio = with_script 'Gradio',
  panel = with_script 'Panel',
  voila = with_script 'Voila',
  marimo = with_script 'marimo',
  torchrun = with_script 'torchrun',
  accelerate = with_script 'accelerate',
  deepspeed = with_script 'deepspeed',
  uvicorn = asgi 'uvicorn', gunicorn = asgi 'gunicorn', hypercorn = asgi 'hypercorn',
  daphne = asgi 'daphne', granian = asgi 'granian',
  flask = function(args, env)
    local app = opt(args, { '--app', '-A' }) or env.FLASK_APP
    return app and ('flask · ' .. app) or 'flask run'
  end,
  vllm = vllm,
  sglang = function(args) return join('SGLang', model_name(opt(args, { '--model-path', '--model' }))) end,
  ['text-generation-launcher'] = function(args) return join('TGI', model_name(opt(args, { '--model-id' }))) end,
  ['llama-server'] = function(args) return join('llama.cpp', model_name(opt(args, { '--model', '-m' }))) end,
  llama_cpp = function(args) return join('llama.cpp', model_name(opt(args, { '--model' }))) end,
  ollama = function(args) return args[1] == 'runner' and 'Ollama runner' or 'Ollama' end,
  mlflow = function() return 'MLflow' end,
  aim = function() return 'Aim' end,
  ['optuna-dashboard'] = function() return 'Optuna Dashboard' end,
  ['next-server'] = function() return 'Next.js' end,
  ['code-server'] = function() return 'code-server' end,
  ['webpack-dev-server'] = function() return 'webpack serve' end,
  php = function(args) return args[1] == '-S' and 'php -S' or nil end,
  ['manage.py'] = function(args) return args[1] == 'runserver' and 'Django' or nil end,
}
-- python -m <module> names that differ from their tool's
local MODULE_TOOL = {
  ['torch.distributed.run'] = 'torchrun', ['torch.distributed.launch'] = 'torchrun',
  ['sglang.launch_server'] = 'sglang', ['llama_cpp.server'] = 'llama_cpp',
}

-- Subcommands that are the point of a program ("hugo server", "next dev")
local SUBCOMMANDS = { dev = true, serve = true, server = true, start = true, preview = true, ui = true,
  up = true, web = true, watch = true }

-- Wrappers that run the rest of the command line: name -> options that take
-- a value (true: the wrapper's first non-option is its own, e.g. timeout's
-- duration)
local WRAPPERS = {
  nohup = {}, setsid = {}, exec = {}, time = {}, caffeinate = { ['-w'] = true, ['-t'] = true },
  nice = { ['-n'] = true }, ionice = { ['-c'] = true, ['-n'] = true, ['-p'] = true },
  stdbuf = { ['-i'] = true, ['-o'] = true, ['-e'] = true },
  timeout = { ['-s'] = true, ['-k'] = true, _first = true },
  taskset = { _first = true },
  numactl = { ['-N'] = true, ['-m'] = true, ['-C'] = true, ['-p'] = true, ['-i'] = true },
}
-- "<tool> run ..." (and "<tool> exec") that run the rest in an environment
local RUNNERS = {
  conda = { ['-n'] = true, ['--name'] = true, ['-p'] = true, ['--prefix'] = true, ['--cwd'] = true },
  uv = { ['--with'] = true, ['--python'] = true, ['-p'] = true, ['--project'] = true, ['--directory'] = true,
    ['--package'] = true, ['--extra'] = true, ['--group'] = true, ['--env-file'] = true, ['--index'] = true,
    ['--with-requirements'] = true, ['--with-editable'] = true },
  poetry = {}, pipenv = {}, pdm = {}, hatch = {}, rye = {}, pixi = { ['-e'] = true, ['--environment'] = true },
}
RUNNERS.mamba, RUNNERS.micromamba = RUNNERS.conda, RUNNERS.conda
-- Package runners: "npx vite" is vite. How many words to skip for the
-- runner at argv[i], or nil
local PKG_MANAGERS = { npm = true, pnpm = true, yarn = true, bun = true }
local function exec_words(argv, i)
  local name, sub = base(argv[i]), argv[i + 1]
  if name == 'npx' or name == 'pnpx' or name == 'bunx' or name == 'uvx' then return 1 end
  if PKG_MANAGERS[name] and (sub == 'exec' or sub == 'dlx' or sub == 'x') then return 2 end
  if name == 'pipx' and sub == 'run' then return 2 end
  if name == 'uv' and sub == 'tool' and argv[i + 2] == 'run' then return 3 end
end
local EXEC_VALUE = { ['--from'] = true, ['-p'] = true, ['--package'] = true, ['--with'] = true,
  ['--python'] = true, ['--spec'] = true }
local SHELLS = { sh = true, bash = true, zsh = true, dash = true, ash = true }

local PY_VALUE = { ['-X'] = true, ['-W'] = true, ['-Q'] = true }
local NODE_VALUE = { ['-r'] = true, ['--require'] = true, ['--import'] = true, ['--loader'] = true,
  ['--experimental-loader'] = true, ['--env-file'] = true, ['--title'] = true }

local function is_python(name)
  local n = name:lower()
  return n:match '^python[%d%.]*m?$' or n:match '^pypy[%d%.]*$' or n == 'ipython'
end
local function is_node(name)
  return name == 'node' or name == 'nodejs' or name == 'deno'
end

-- A program by name, with its args: TOOLS, then "prog sub", then the name
local function tool(name, args, env)
  local f = TOOLS[name]
  local label = f and f(args, env)
  if label then return label end
  if args[1] and SUBCOMMANDS[args[1]] then return name .. ' ' .. args[1] end
  return name
end

-- A script path (run by python, node ...): the package that ships it
-- ("node_modules/vite/bin/vite.js" is vite, ".vscode-server/..." is VS Code
-- Server), else the tool it is (".venv/bin/jupyter-lab"), else its name
local function script(path, args, env)
  if path:find('/.vscode-server/', 1, true) then return 'VS Code Server' end
  if path:find('/.cursor-server/', 1, true) then return 'Cursor Server' end
  if path:find('/code-server/', 1, true) then return 'code-server' end
  local pkg = path:match '.*node_modules/(@[^/]+/[^/]+)' or path:match '.*node_modules/([^/]+)'
  if pkg == '.bin' then pkg = path:match 'node_modules/%.bin/([^/]+)' end
  if pkg then return tool(base(pkg), args, env) end
  return tool(base(path), args, env)
end

-- Readable name of a command line (argv), or nil when there is nothing to
-- go on: wrappers (env, nohup, conda/uv/poetry run, npx ...) and the
-- interpreter are skipped for the script, module or tool they run.
function M.describe(argv)
  if not argv or #argv == 0 then return nil end
  local i, env = 1, {}
  local function rest() return { table.unpack(argv, i + 1) } end
  while argv[i] do
    local w = argv[i]
    local name = base(w)
    -- An .app bundle on a Mac ("/Applications/Visual Studio Code.app/...")
    local app = w:match '^/.-([^/]+)%.app/'
    if app then return app end
    if w:match '^[%a_][%w_]*=' then -- VAR=value before the command
      env[w:match '^([^=]+)'] = w:match '=(.*)$'
      i = i + 1
    elseif name == 'env' then
      i = i + 1
      while argv[i] and (starts_dash(argv[i]) or argv[i]:match '^[%a_][%w_]*=') do
        local a = argv[i]
        if a:match '^[%a_][%w_]*=' then env[a:match '^([^=]+)'] = a:match '=(.*)$' end
        i = i + ((a == '-u' or a == '-C' or a == '-S') and 2 or 1)
      end
    elseif WRAPPERS[name] then
      local spec = WRAPPERS[name]
      i = i + 1
      while argv[i] and starts_dash(argv[i]) do
        i = i + (spec[argv[i]] and 2 or 1)
      end
      if spec._first then i = i + 1 end
    elseif RUNNERS[name] and (argv[i + 1] == 'run' or argv[i + 1] == 'exec') then
      local spec = RUNNERS[name]
      i = i + 2
      while argv[i] and starts_dash(argv[i]) do
        local a = argv[i]
        i = i + 1
        if a == '--' then break end
        if spec[a] then i = i + 1 end
      end
      -- "uv run app.py" runs it with python
      if argv[i] and argv[i]:match '%.py$' then return script(argv[i], rest(), env) end
    elseif exec_words(argv, i) then
      i = i + exec_words(argv, i)
      while argv[i] and starts_dash(argv[i]) do
        i = i + (EXEC_VALUE[argv[i]] and 2 or 1)
      end
    elseif SHELLS[name] then
      i = i + 1
      while argv[i] and starts_dash(argv[i]) and argv[i] ~= '-c' do i = i + 1 end
      if argv[i] == '-c' then
        return argv[i + 1] and M.describe(M.split_cmdline(argv[i + 1])) or name
      end
      if not argv[i] then return name end
      return script(argv[i], rest(), env)
    elseif PKG_MANAGERS[name] then
      local sub = argv[i + 1]
      if not sub then return name end
      if sub == 'run' or sub == 'run-script' then
        return name .. ' run' .. (argv[i + 2] and (' ' .. argv[i + 2]) or '')
      end
      return name .. ' ' .. sub
    elseif is_python(name) then
      i = i + 1
      while argv[i] and starts_dash(argv[i]) do
        local a = argv[i]
        if a == '-m' or (a:match '^%-m.' and not a:match '^%-%-') then
          local mod = a == '-m' and argv[i + 1] or a:sub(3)
          if not mod then return name end
          if a == '-m' then i = i + 1 end
          local args = rest()
          local key = MODULE_TOOL[mod] or mod
          local first = key:match '^[^%.]+'
          local f = TOOLS[key] or TOOLS[first]
          return (f and f(args, env)) or (args[1] and SUBCOMMANDS[args[1]] and (mod .. ' ' .. args[1])) or mod
        end
        if a == '-c' then return name .. ' -c' end
        if a == '--' then
          i = i + 1
          break
        end
        i = i + (PY_VALUE[a] and 2 or 1)
      end
      if not argv[i] then return name end
      return script(argv[i], rest(), env)
    elseif is_node(name) then
      i = i + 1
      if (name == 'deno' or name == 'bun') and (argv[i] == 'run' or argv[i] == 'task') then
        if argv[i] == 'task' then return name .. ' task' .. (argv[i + 1] and (' ' .. argv[i + 1]) or '') end
        i = i + 1
      end
      while argv[i] and starts_dash(argv[i]) do
        local a = argv[i]
        if a == '-e' or a == '--eval' or a == '-p' or a == '--print' then return name .. ' -e' end
        i = i + (NODE_VALUE[a] and 2 or 1)
      end
      if not argv[i] then return name end
      return script(argv[i], rest(), env)
    elseif name == 'java' then
      local jar = opt(argv, { '-jar' })
      return jar and base(jar) or 'java'
    else
      -- A program rewritten as "nginx: master process" or "postgres:"
      return script((w:gsub(':$', '')), rest(), env)
    end
  end
  return nil
end

-- The project a process works in: its cwd's last folder, unless that is
-- the home folder or /
function M.project(cwd, home)
  if not cwd or cwd == '' then return nil end
  cwd = cwd:gsub(' %(deleted%)$', '')
  local trimmed = cwd:gsub('/+$', '')
  if trimmed == '' or (home and trimmed == home:gsub('/+$', '')) then return nil end
  return base(trimmed)
end

-- Titles that say nothing a name does not: defaults of frameworks, error
-- and listing pages, logins (lowercased, matched at the start)
local GENERIC_TITLES = {
  'index of', 'directory listing', 'error', 'not found', '404', '401', '403', '500', '502', 'bad request',
  'login', 'log in', 'sign in', 'redirect', 'loading', 'document', 'untitled', 'home page - select',
  'jupyter', 'tensorboard', 'streamlit', 'gradio', 'vite', 'react app', 'welcome to nginx', 'apache2',
  'code-server', 'ollama', 'swagger ui', 'fastapi', 'test page', 'it works', 'mlflow',
}

local function squash(s)
  return s:lower():gsub('[^%w]', '')
end

local ENTITIES = { amp = '&', lt = '<', gt = '>', quot = '"', apos = "'", nbsp = ' ' }

-- A page's <title> text, cleaned, if it is short and says something the
-- name `what` does not; else nil
function M.clean_title(title, what)
  if not title then return nil end
  local t = title:gsub('&#(%d+);', function(n)
    n = tonumber(n)
    return n and n < 0x110000 and utf8.char(n) or ''
  end):gsub('&#[xX](%x+);', function(n)
    n = tonumber(n, 16)
    return n and n < 0x110000 and utf8.char(n) or ''
  end):gsub('&(%a+);', function(e) return ENTITIES[e:lower()] end)
  t = t:gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')
  -- "Swapboard - Live dashboards for ..." is Swapboard
  if (utf8.len(t) or #t) > 40 then
    t = t:match '^(.-) [-|—–·:] ' or t
  end
  if t == '' or (utf8.len(t) or #t) > 40 then return nil end
  local low = t:lower()
  for _, g in ipairs(GENERIC_TITLES) do
    if low:sub(1, #g) == g then return nil end
  end
  if low:match '^[%d%.:/ ]+$' or low:match '^https?:' then return nil end
  -- "TensorBoard" adds nothing to "TensorBoard · runs"
  if what and squash(what):sub(1, #squash(t)) == squash(t) then return nil end
  return t
end

-- What a port's row shows and its project: `info` is { argv, cwd, home,
-- title, name } (name: the process name ss/lsof give, the fallback)
function M.label(info)
  local what = M.describe(info.argv) or info.name
  local title = M.clean_title(info.title, what)
  local project = M.project(info.cwd, info.home)
  local shown = title or what
  if project and shown and (squash(shown) == squash(project)) then project = nil end
  return shown, project
end

-- "Jupyter Lab · cswap" (a row) and "Jupyter Lab (cswap)" (a toast) of a
-- port { what, project, name }
function M.row_text(p)
  local what = p.what or p.name
  if not what then return nil end
  return p.project and (what .. ' · ' .. p.project) or what
end

function M.toast_text(p)
  local what = p.what or p.name
  if not what then return nil end
  return p.project and (what .. ' (' .. p.project .. ')') or what
end

return M
