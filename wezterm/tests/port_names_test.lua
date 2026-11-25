-- Tests for lib/port_names.lua: what a listening port is, from real-world
-- command lines (/proc/<pid>/cmdline with its NULs as \31, and `ps -o args=`
-- lines), its cwd and its page title. Run tests/run.sh.
local wezterm = require 'wezterm'
package.path = os.getenv 'WZT_SRC' .. '/?.lua;' .. package.path
assert(wezterm.home_dir:match '^/tmp/wz', 'HOME must be a fake /tmp/wz* one')
local names = require 'lib.port_names'

local failed, passed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
    io.stderr:write('PASS ', name, '\n')
  else
    failed = failed + 1
    io.stderr:write('FAIL ', name, ': got ', tostring(got), ', want ', tostring(want), '\n')
  end
end

-- A /proc cmdline as REMOTE_SCRIPT sends it: each argument NUL-ended, the
-- NULs turned into \31
local function proc(...)
  return table.concat({ ... }, '\31') .. '\31'
end
local function from_proc(...)
  return names.describe(names.split_cmdline(proc(...)))
end

-- 1. /proc command lines -> names
local CASES = {
  -- the examples
  { 'http.server', { 'python3', '-m', 'http.server', '8000' } },
  { 'myapp serve', { '/w/.venv/bin/python', '-m', 'myapp', 'serve', '--port', '8765' } },
  { 'pkg.server', { 'python', '-m', 'pkg.server', '--pidfile', '/x/server.pid' } },
  { 'train_viz.py', { 'python', 'foo/train_viz.py', '--x' } },
  { 'Jupyter Lab', { '/home/u/.venv/bin/python', '/home/u/.venv/bin/jupyter-lab', '--no-browser' } },
  { 'Jupyter Lab', { 'jupyter-lab' } },
  { 'Jupyter Lab', { 'jupyter', 'lab', '--port', '8888' } },
  { 'Jupyter Lab', { '/usr/bin/python3', '-m', 'jupyter', 'lab' } },
  { 'Jupyter Lab', { 'python', '-m', 'jupyterlab' } },
  { 'Jupyter Notebook', { 'python', '-m', 'notebook', '--port=9999' } },
  { 'Jupyter Notebook', { 'jupyter-notebook' } },
  { 'Jupyter Server', { 'jupyter', 'server' } },
  { 'Jupyter kernel', { 'python', '-m', 'ipykernel_launcher', '-f', '/run/user/1/jupyter/kernel-1.json' } },
  { 'TensorBoard · runs', { 'tensorboard', '--logdir', 'runs' } },
  { 'TensorBoard · logs', { '/env/bin/python', '/env/bin/tensorboard', '--logdir=/scratch/exp/logs/' } },
  { 'TensorBoard · runs', { 'python', '-m', 'tensorboard.main', '--logdir', 'runs', '--port', '6006' } },
  { 'TensorBoard', { 'tensorboard', '--port', '6006' } },
  { 'Streamlit · app.py', { 'streamlit', 'run', 'app.py', '--server.port', '8501' } },
  { 'Streamlit · app.py', { 'python', '-m', 'streamlit', 'run', 'src/app.py' } },
  { 'uvicorn · main:app', { 'uvicorn', 'main:app', '--host', '0.0.0.0', '--port', '8000' } },
  { 'uvicorn · app.api:create_app', { 'python', '-m', 'uvicorn', 'app.api:create_app', '--factory' } },
  { 'gunicorn · wsgi:app', { 'gunicorn', '-w', '4', '-b', '0.0.0.0:8000', 'wsgi:app' } },
  { 'flask run', { 'flask', 'run' } },
  { 'flask · hello', { 'flask', '--app', 'hello', 'run' } },
  { 'flask · hello', { 'env', 'FLASK_APP=hello', 'flask', 'run' } },
  { 'flask run', { 'python', '-m', 'flask', 'run', '--port', '5001' } },
  { 'Gradio · app.py', { 'gradio', 'app.py' } },
  { 'vite', { 'node', '/w/app/node_modules/vite/bin/vite.js' } },
  { 'vite', { 'node', '/w/app/node_modules/.bin/vite', '--port', '5173' } },
  { 'next dev', { 'node', '/w/app/node_modules/next/dist/bin/next', 'dev' } },
  { 'next dev', { 'next', 'dev' } },
  { 'Next.js', { 'next-server (v14.2.3)' } },
  { 'npm run dev', { 'npm', 'run', 'dev' } },
  { 'pnpm dev', { 'pnpm', 'dev' } },
  { 'code-server', { 'code-server', '--bind-addr', '0.0.0.0:8080' } },
  { 'code-server', { '/usr/lib/code-server/lib/node', '/usr/lib/code-server/out/node/entry' } },
  { 'VS Code Server', { '/home/u/.vscode-server/bin/abc/node', '/home/u/.vscode-server/bin/abc/out/server-main.js' } },
  { 'Ollama', { 'ollama', 'serve' } },
  { 'Ollama runner', { '/usr/local/bin/ollama', 'runner', '--model', '/blobs/sha256-1' } },
  { 'vLLM · Llama-3.1-8B-Instruct', { 'vllm', 'serve', 'meta-llama/Llama-3.1-8B-Instruct', '--port', '8000' } },
  { 'vLLM · qwen2.5-7b', { 'python', '-m', 'vllm.entrypoints.openai.api_server', '--model', '/models/qwen2.5-7b/' } },
  { 'vLLM · Mistral-7B', { 'vllm', 'serve', '--model=mistralai/Mistral-7B', '--port', '8000' } },
  { 'SGLang · Qwen2-7B', { 'python3', '-m', 'sglang.launch_server', '--model-path', 'Qwen/Qwen2-7B' } },
  { 'llama.cpp · m.gguf', { 'llama-server', '-m', '/models/m.gguf', '--port', '8080' } },
  { 'torchrun · train.py', { 'python', '-m', 'torch.distributed.run', '--nproc_per_node', '2', 'train.py' } },
  { 'Django', { 'python', 'manage.py', 'runserver', '0.0.0.0:8000' } },
  { 'MLflow', { 'mlflow', 'ui', '--port', '5000' } },
  -- wrappers
  { 'serve.py', { 'conda', 'run', '-n', 'ml', '--no-capture-output', 'python', 'serve.py' } },
  { 'Jupyter Lab', { 'micromamba', 'run', '-p', '/envs/x', 'jupyter', 'lab' } },
  { 'Jupyter Lab', { 'uv', 'run', '--with', 'jupyter', 'jupyter', 'lab' } },
  { 'app.py', { 'uv', 'run', 'app.py' } },
  { 'app.py', { 'uv', 'run', '--', 'python', 'app.py' } },
  { 'uvicorn · main:app', { 'poetry', 'run', 'uvicorn', 'main:app', '--reload' } },
  { 'train_viz.py', { 'nohup', 'python', 'train_viz.py' } },
  { 'train_viz.py', { 'env', 'X=1', 'Y=2', 'python', '-u', 'train_viz.py' } },
  { 'train_viz.py', { '/usr/bin/env', '-i', 'PATH=/bin', 'python3', 'train_viz.py' } },
  { 'x.py', { 'nice', '-n', '10', 'nohup', 'env', 'CUDA_VISIBLE_DEVICES=0', 'python', 'x.py' } },
  { 'x.py', { 'timeout', '1h', 'python', 'x.py' } },
  { 'x.py', { 'taskset', '-c', '0-3', 'python', 'x.py' } },
  { 'x.py', { 'stdbuf', '-oL', 'python', 'x.py' } },
  { 'http-server', { 'npx', 'http-server', '-p', '8080' } },
  { 'Jupyter Lab', { 'uvx', '--from', 'jupyterlab', 'jupyter-lab' } },
  { 'Jupyter Lab', { 'uv', 'tool', 'run', 'jupyter-lab' } },
  { 'http.server', { 'sh', '-c', 'python -m http.server 8000' } },
  { 'run.sh', { 'bash', 'run.sh' } },
  -- python and node options
  { 'http.server', { 'python3.11', '-X', 'dev', '-u', '-m', 'http.server' } },
  { 'http.server', { 'python', '-mhttp.server' } },
  { 'python -c', { 'python', '-c', 'import http.server' } },
  { 'python', { 'python' } },
  { 'server.js', { 'node', '--inspect=0.0.0.0:9229', '-r', 'dotenv/config', 'server.js' } },
  { 'main.ts', { 'deno', 'run', '-A', 'main.ts' } },
  -- generic: the program, with the subcommand that is the point
  { 'my-server', { './my-server', '--port', '9000' } },
  { 'app.jar', { 'java', '-Xmx2g', '-jar', '/opt/app.jar' } },
  { 'hugo server', { 'hugo', 'server' } },
  { 'mkdocs serve', { 'mkdocs', 'serve' } },
  -- spaces in paths survive NUL separation
  { 'serve app.py', { 'python', '/home/u/My Project/serve app.py' } },
  { 'Streamlit · my app.py', { 'streamlit', 'run', 'my app.py' } },
  -- a quoted argument stays one
  { 'http.server', { 'sh', '-c', 'exec python -m http.server' } },
}
for _, c in ipairs(CASES) do
  eq('proc: ' .. table.concat(c[2], ' '), from_proc(table.unpack(c[2])), c[1])
end

-- 2. Splitting
do
  local a = names.split_cmdline(proc('python', '', 'x y.py'))
  eq('split: empty args dropped', #a, 2)
  eq('split: spaces kept in an argument', a[2], 'x y.py')
  eq('split: trailing NUL', #names.split_cmdline(proc 'jupyter-lab'), 1)
  -- A rewritten title ("nginx: master process ...") is one argument
  eq('split: nginx title', from_proc 'nginx: master process /usr/sbin/nginx -g daemon off;', 'nginx')
  eq('split: redis title', from_proc 'redis-server *:6379', 'redis-server')
  eq('split: gunicorn title', from_proc 'gunicorn: master [wsgi:app]', 'gunicorn')
  -- ps lines (macOS): words, paths with spaces rejoined where files exist
  eq('ps: words', names.describe(names.split_cmdline 'python3 -m http.server 8000'), 'http.server')
  local files = {
    ['/Users/u/My Project/.venv/bin/python'] = true, ['/Users/u/My Project/app.py'] = true,
    ['/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)'] = true,
    ['/usr/bin/python3'] = true,
  }
  local function exists(p) return files[p] == true end
  local argv = names.split_cmdline('/Users/u/My Project/.venv/bin/python /Users/u/My Project/app.py --port 1', exists)
  eq('ps: program with spaces', argv[1], '/Users/u/My Project/.venv/bin/python')
  eq('ps: script with spaces', argv[2], '/Users/u/My Project/app.py')
  eq('ps: then the options', argv[3], '--port')
  eq('ps: names the script', names.describe(argv), 'app.py')
  eq('ps: existing program not joined', names.split_cmdline('/usr/bin/python3 foo/bar.py', exists)[2], 'foo/bar.py')
  eq('ps: missing path left alone', names.split_cmdline('/gone/server --flag', exists)[1], '/gone/server')
  eq('ps: Mac app', names.describe(names.split_cmdline(
    '/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin) --type=utility',
    exists)), 'Visual Studio Code')
  eq('ps: empty', names.describe(names.split_cmdline '   '), nil)
  eq('nil argv', names.describe(nil), nil)
end

-- 3. Project folder
eq('project: last folder', names.project('/home/u/cswap', '/home/u'), 'cswap')
eq('project: trailing slash', names.project('/home/u/cswap/', '/home/u'), 'cswap')
eq('project: not home', names.project('/home/u', '/home/u'), nil)
eq('project: not home with slash', names.project('/home/u/', '/home/u'), nil)
eq('project: not /', names.project('/', '/home/u'), nil)
eq('project: none', names.project(nil, '/home/u'), nil)
eq('project: empty', names.project('', '/home/u'), nil)
eq('project: deleted dir', names.project('/scratch/run1 (deleted)', '/home/u'), 'run1')
eq('project: spaces', names.project('/Users/u/My Project', '/Users/u'), 'My Project')
eq('project: no home known', names.project('/data/proj', nil), 'proj')

-- 4. Titles: short and saying something
eq('title: entities and spaces', names.clean_title('  Swap &amp; Explorer\t', 'Streamlit · app.py'), 'Swap & Explorer')
eq('title: numeric entities', names.clean_title('Caf&#233; &#x41;pp', nil), 'Café App')
eq('title: index', names.clean_title('Index of /', 'http.server'), nil)
eq('title: listing', names.clean_title('Directory listing for /', 'http.server'), nil)
eq('title: empty', names.clean_title('', 'x'), nil)
eq('title: blank', names.clean_title('   ', 'x'), nil)
eq('title: nil', names.clean_title(nil, 'x'), nil)
eq('title: long', names.clean_title(string.rep('word ', 12), 'x'), nil)
eq('title: long, its first part', names.clean_title('Swapboard - Live dashboards for small training runs', 'x'),
  'Swapboard')
eq('title: long, pipe', names.clean_title('Run Monitor | An observability page for everything you run', 'x'),
  'Run Monitor')
eq('title: short with a dash kept whole', names.clean_title('Swap - Explorer', 'x'), 'Swap - Explorer')
eq('title: framework default', names.clean_title('Vite + React + TS', 'vite'), nil)
eq('title: Gradio default', names.clean_title('Gradio', 'Gradio · app.py'), nil)
eq('title: what it already says', names.clean_title('TensorBoard', 'TensorBoard · runs'), nil)
eq('title: JupyterLab vs Jupyter Lab', names.clean_title('JupyterLab', 'Jupyter Lab'), nil)
eq('title: an address', names.clean_title('127.0.0.1:8000', 'x'), nil)
eq('title: 404', names.clean_title('404 Not Found', 'x'), nil)
eq('title: meaningful', names.clean_title('Swap Explorer', 'Streamlit · app.py'), 'Swap Explorer')

-- 5. Labels, rows and toasts
local function label(info)
  local what, project = names.label(info)
  return tostring(what) .. ' | ' .. tostring(project)
end
local JL = names.split_cmdline(proc('python', '-m', 'jupyter', 'lab'))
eq('label: name and project', label { argv = JL, cwd = '/home/u/cswap', home = '/home/u', name = 'python' },
  'Jupyter Lab | cswap')
eq('label: train_viz', label { argv = names.split_cmdline(proc('python', 'train_viz.py')), cwd = '/w/cswap',
  name = 'python' }, 'train_viz.py | cswap')
eq('label: title wins', label { argv = JL, cwd = '/w/cswap', title = 'Swap Explorer', name = 'python' },
  'Swap Explorer | cswap')
eq('label: generic title loses', label { argv = JL, cwd = '/w/cswap', title = 'Index of /', name = 'python' },
  'Jupyter Lab | cswap')
eq('label: no cmdline, process name', label { cwd = '/w/cswap', name = 'python' }, 'python | cswap')
eq('label: nothing at all', label {}, 'nil | nil')
eq('label: project same as name dropped', label { argv = names.split_cmdline(proc 'cswap'), cwd = '/w/cswap' },
  'cswap | nil')
eq('row: name · project', names.row_text { what = 'Jupyter Lab', project = 'cswap' }, 'Jupyter Lab · cswap')
eq('row: no project', names.row_text { what = 'vite' }, 'vite')
eq('row: falls back to name', names.row_text { name = 'python' }, 'python')
eq('row: nothing', names.row_text {}, nil)
eq('toast: name (project)', names.toast_text { what = 'Jupyter Lab', project = 'cswap' }, 'Jupyter Lab (cswap)')
eq('toast: no project', names.toast_text { name = 'node' }, 'node')

io.stderr:write('RESULT ', passed, ' passed, ', failed, ' failed\n')
return {}
