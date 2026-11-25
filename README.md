# dotfiles

My terminal setup on macOS: **WezTerm** (Ghostty-style splits that follow you
into ssh sessions), **Yazi** as a file sidebar and path previewer, and **micro**
as the editor, with a live glow preview for Markdown.

Targets WezTerm `20240203` and Apple Silicon
Homebrew paths (`/opt/homebrew/bin`).

## Layout

| Path | Installs to |
| --- | --- |
| `wezterm/wezterm.lua` (+ `lib/`, `features/`) | `~/.wezterm.lua` (a symlink; the modules are found next to the real file) |
| `yazi/` | `~/.config/yazi/` |
| `yazi-sidebar/yazi.toml` | `~/.config/yazi-sidebar/yazi.toml` |
| `micro/settings.json` | `~/.config/micro/settings.json` |
| `bin/` | `~/.local/bin/` (`mdedit`, `mdview`, `mdpreview`, `glow-cached`, `yazi-open`, `clipimg-push`, `ssh-setup`, `ssh-pane`, `wez-claude-session`, `wez-hibernate`) |
| `claude/statusline.sh` | `~/.claude/statusline.sh` (Claude Code status line) |
| `zsh/snippets.zsh` | source it from `~/.zshrc` |
| `macos/wez-drag/` | `~/.local/bin/wez-drag` (built, not copied: run `macos/wez-drag/build.sh`; needs only the Command Line Tools) |

`~/.config/yazi-sidebar` is a second Yazi config used only by the CMD+E
sidebar. It has its own `yazi.toml` (single column, opens files in a split) and
symlinks `keymap.toml`, `theme.toml`, `package.toml`, `plugins` and `flavors`
to `../yazi/`.

Yazi `plugins/` and `flavors/` from `ya pkg` are not committed; `ya pkg install`
fetches them from `yazi/package.toml`. The one custom plugin,
`yazi/plugins/upscale.yazi`, is committed and symlinked by `install.sh`.

## WezTerm features

Each feature below is a module in `wezterm/features/` (shared code in
`wezterm/lib/`) with a flag in the `features` table at the top of
`wezterm/wezterm.lua`; all are on. To turn some off without editing the
tracked file, create `wezterm/local.lua` (gitignored) and reload once (CMD+R):

```lua
return { hibernation = false, sidebar = false }
```

A feature that is off leaves WezTerm's defaults for its keys. The click
add-ons (`finder_reveal` to `downloads`) need `paths` and are skipped without
it. Unknown flags and skipped features are logged as `features:` warnings.

| Flag | Feature |
| --- | --- |
| `tab_bar` | Catppuccin retro tab bar (number, icon, name / ssh host / cwd) and pickers |
| `ghostty_keys` | Ghostty-style pane keys: CMD+D splits, CMD+W, focus, resize, zoom, swap, rotate, jump, tab order |
| `ssh_aware` | CMD+D / CMD+T / CMD+N from an ssh pane open the same host; CMD+SHIFT+T / N stay local |
| `copy_paste` | Unified CMD/CTRL+C/V, image paste into ssh panes |
| `sidebar` | CMD+E Yazi sidebar |
| `rename` | CMD+SHIFT+R / CMD+CTRL+R rename tab / window |
| `paths` | CMD+click a path: Yazi peek, local or over ssh |
| `finder_reveal` | CMD+OPT+click: reveal in Finder |
| `quicklook` | CMD+OPT+SHIFT+click: Quick Look |
| `media_reveal` | CMD+click on video / audio reveals it in Finder |
| `pdf_preview` | CMD+click on a PDF opens Preview |
| `downloads` | Right-click a path in an ssh pane downloads it; so does `g m` in remote Yazi |
| `drag` | Finder drag and drop through the `wez-drag` helper: `g o` / `g i` in Yazi, CMD+SHIFT+U drop zone |
| `port_forward` | CMD+click localhost URLs and `ssh -L` commands, CMD+SHIFT+L |
| `ports` | CMD+SHIFT+I ports list, new-port toasts and a right-status badge for ssh hosts |
| `layout_repair` | CMD+SHIFT+= and refit after window resizes |
| `fullscreen_refit` | Refit fullscreen after a monitor is unplugged |
| `pane_moves` | CMD+OPT+T / N / 1..9 move panes, CMD+SHIFT+M merges windows |
| `md_preview` | Side-by-side Markdown preview for `mdedit` over ssh |
| `session_restore` | Session restore (below), CMD+SHIFT+O, CMD+OPT+SHIFT+O |
| `hibernation` | Hibernation of idle agent panes (below) |
| `reload_toast` | "config reloaded" toast |

## WezTerm keys

| Keys | Action |
| --- | --- |
| CMD+D / CMD+SHIFT+D | Split right / down. In a pane running `ssh`, the new pane opens ssh (via `ssh-pane`) to the same host |
| CMD+T / CMD+N | New tab / window, ssh-aware the same way |
| CMD+SHIFT+T / CMD+SHIFT+N | New tab / window, always local |
| CMD+OPT+T / CMD+OPT+N | Move the focused pane to a new tab / window |
| CMD+OPT+1..9 | Send the focused pane to tab N, split to the right |
| CMD+OPT+SHIFT+1..9 | Send the focused pane to tab N, split below |
| CMD+SHIFT+M | Merge all other windows into this one, keeping split layouts |
| CMD+SHIFT+= | Fix layout: if the tab's panes spill past the window edge (a WezTerm 20240203 bug no resize undoes), rebuild the tab with the same proportions, position, title and focus; processes keep running. Also runs on its own after window resizes, pane moves and merges |
| CMD+SHIFT+← / → | Reorder tabs |
| CMD+E | Toggle the Yazi file sidebar (local tabs only); a full-height column on the left, also in tabs that already have splits |
| CMD+click a path | Opens it in a Yazi peek on the right half of the pane you clicked (file hovered, preview maximized; images too), focused and not zoomed. A pane narrower than 80 columns gets the peek in a new tab right after its own instead. q closes Yazi and you are back in the pane (and tab) you clicked, with any earlier zoom restored. One peek per tab: clicking again opens the new file in the same place. Layout fixes, the sidebar and pane moves wait until it is closed. Works on `~/x`, `./x`, `/x`, bare relative paths like `src/app.py` or `README.md` (tried against the pane's cwd, then the cwd of an agent CLI running in it (claude, codex, opencode), then the directories of absolute paths shown nearby in the pane, hard-wrapped ones included, and of your recent clicks on that host, so a bare `plot.png` an agent CLI prints under a directory it named earlier opens; last a `find` up to 4 levels under the cwd, 1 s at most), `x:12` / `x:12:3` / `x:12-40` and `file://` links. Paths a TUI hard-wrapped onto the next lines (Claude Code's indented continuation, mid-word too, up to 6 lines) are rejoined from the pane text, whichever line you click; trailing prose after an em dash and punctuation are left out. WezTerm 20240203 does not say where you clicked, so a piece shown twice (two paths whose first lines match) is taken from its lowest place. Paths with spaces work unquoted too (`/Volumes/My Disk/clip.mp4`, click any word of it): the click extends the word across spaces and line breaks and takes the longest spelling that exists (one round trip in ssh panes, given up after 5 s). Quoted (`"..."`, `'...'`, backticks) and backslash-escaped (`My\ Disk`) paths are one link |
| CMD+click a PDF | Opens it in macOS Preview (full zoom and scroll) instead of peeking, in the background with a toast, and a toast if it fails. In an ssh pane it is first copied over the existing ControlMaster to `~/Library/Caches/wezterm/peek/<host>/<hash of the remote path>/<name>` (never a login; toasts if there is no live master); a cached copy whose size and mtime still match is reused |
| CMD+click a video or audio file | Same as CMD+OPT+click (mp4, mov, m4v, mkv, webm, avi, wmv, flv, mpg, mpeg, 3gp, mp3, wav, m4a, flac, aac, ogg, opus, aiff): these cannot play in the terminal, so they reveal in Finder instead of peeking. `.ts` and `.gif` still peek |
| CMD+OPT+click a path | Reveal it in Finder (`open -R`; directories open) so you can drag it into a browser upload, Slack, etc. In an ssh pane the file is first copied to `~/Downloads/<host>/` over the existing ControlMaster |
| CMD+click a path in an ssh pane | Open it in remote Yazi on that host (peek via `ssh-pane`, placed the same way, instant over the ControlMaster; never prompts, toasts if there is no live master). Relative paths resolve against the remote shell's cwd (OSC 7, sent by the `ssh-setup` bashrc block), then the cwds of your agent CLIs on the host (claude, codex, opencode, e.g. inside tmux; newest first), then the directories shown in the pane and of recent clicks (as above), else against the cwds of your other processes there (newest match wins) and the remote home, else a 1 s `find`, all in one round trip. When sshd refuses one more session on the master (MaxSessions, too many ssh tabs to that host) the toast says so |
| CMD+OPT+SHIFT+click a path | Open the file in macOS Quick Look instead (a separate window). In an ssh pane the file is first copied to `~/Library/Caches/wezterm/peek/<host>/` over the master |
| CMD+click a localhost link in an ssh pane | `http://localhost:PORT` / `127.0.0.1` / `0.0.0.0` from Jupyter, TensorBoard, vite... on the remote: adds `ssh -O forward -L` on the existing ControlMaster (never a new login) and opens it locally, `?token=` kept. A busy local port moves to the next free one; forwards are reused |
| CMD+click an `ssh ... -L LPORT:HOST:RPORT ... host` command | Add those forwards to the existing ControlMaster for that host instead of running it, then open the URL printed with it (`ssh -fN -L ... && open 'http://localhost:LPORT/#otc=...'`, fragment and all), else the latest localhost URL for that port from the scrollback (token filled in), else `http://localhost:LPORT/` (never a new login; bundled flags like `-fN`/`-NfL` and commands hard-wrapped by an agent's TUI work; config aliases are matched by `ssh -G` hostname and user, so `me@login.example.org` finds the master opened as `myserver`). Works while sshd refuses new sessions (MaxSessions): `-O forward` only talks to the master |
| CMD+click `http://localhost:LPORT/...` after such a hint | Uses the most recent `ssh -L LPORT:...` in the scrollback (works from local panes too), so a server on a compute node behind a login host opens directly. A stale forward of ours on LPORT is replaced; an old hand-started tunnel is left running and named by pid. `?token=<token>` is filled from the last `cat .../token` shown in this pane, else in the window's other panes, else the token file that last worked for that host and remote port (path remembered in `~/.local/state/wezterm/token-paths`, mode 600; never the token), read over the master and never logged |
| CMD+SHIFT+L | Same without a click: a port, a localhost URL or a whole `ssh -L` command |
| CMD+SHIFT+I | Ports, VS Code style: one list of the TCP ports your processes listen on in the focused ssh pane's host (with the process; `ss`, else `/proc/net/tcp`), on this Mac, and the forwards made here. `ssh -L` commands on screen (this pane, then the window's others) come first as `⇄ :8766 (from screen: open with token)`: Enter forwards them on the live master for their host and opens the printed URL, as CMD+click does (a toast if no master is live). Enter on a remote port forwards it over the existing ControlMaster (`ssh -O forward`, ports below 1024 to 8000+port, busy ports handled as above) and opens `http://localhost:PORT`; on a local port opens it; on a forward stops it (`-O cancel`). While an ssh pane has focus and its master is live, the host is listed every 10 s in the background (one `-O check` and one ssh session over the master, never a login); a port of yours that starts listening toasts once, and the right status shows `⇄ N ports · CMD+SHIFT+I` |
| CMD+C / CMD+V (and SHIFT / CTRL variants) | Unified copy/paste. CTRL+C with no selection still sends ^C. CTRL+V pastes only in ssh panes; in local panes the raw key goes through, for Claude Code's image paste. Pasting an image in an ssh pane uploads it to the remote `~/.cache/clipimg/` and types the path |
| Right-click a path in an ssh pane | Download the file or folder to `~/Downloads/<host>/` in the background over the ControlMaster (tar, so the remote only needs ssh and tar; never logs in, toasts if there is no live master), then reveal it in Finder. Toasts at start and end, with the size. A different item of the same name is kept and the new one numbered (`name (1).ext`); an identical one is reused. Unbound elsewhere. An app that grabs the mouse still gets the press but not the release |
| `g m` in Yazi on an ssh host | Download the selected files and folders (or the hovered one) the same way. Yazi sets the `wez_download` user var, which WezTerm honours only in a local pane running ssh; at most 50 items per request. Inside tmux it uses passthrough: always on before tmux 3.3, turned on for that pane on 3.3+. Ships with `ssh-setup` (the keymap) |
| `g o` in Yazi | Drag the selected files and folders (or the hovered one) out: a small floating window by the mouse shows them; drag it to Finder, the Desktop, Mail... It closes after the drop, on Esc or after 60 s idle. Local Yazi runs `wez-drag` itself; on an ssh host Yazi sets the `wez_drag_out` user var and WezTerm first copies the items over the live ControlMaster to `~/Library/Caches/wezterm/drag/<host>/` (never a new login; toasts if there is no live master; at most 50 items) |
| `g i` in Yazi / CMD+SHIFT+U | Drop zone: a small window that takes files and folders dropped from Finder and copies them into Yazi's folder (`g i`, user var `wez_drag_in`) or the focused pane's cwd (CMD+SHIFT+U; an ssh pane's remote cwd from OSC 7, else the remote home). Over ssh each item goes as `tar` over the live ControlMaster. Nothing is overwritten: a taken name becomes `name (1).ext`. A toast reports the result |
| CMD+W / CTRL+SHIFT+W | Close the pane. WezTerm's own confirm, shown over that pane only: y closes, n or Esc cancels (Enter does nothing). Skipped when the pane only runs an idle shell (bash, zsh, sh, fish, nu; tmux still asks) |
| CMD+[ / CMD+] | Previous / next pane |
| CMD+OPT+arrows | Focus pane in that direction |
| CMD+CTRL+arrows | Resize pane |
| CMD+SHIFT+Enter | Zoom / unzoom pane |
| CMD+SHIFT+S | Swap the focused pane with a picked one |
| CMD+OPT+R / CMD+OPT+SHIFT+R | Rotate panes clockwise / counter-clockwise |
| CMD+SHIFT+R / CMD+CTRL+R | Rename the tab / window (empty input restores the automatic title) |
| CMD+SHIFT+P | Jump to a pane by label |
| CMD+SHIFT+O | Reopen the session from before this launch (`session.prev.json`) on demand |
| CMD+OPT+SHIFT+O | Toggle restoring the last session at launch (`no-restore` flag file) |

The tab bar, prompts and pickers use the Catppuccin Mocha palette (same as
the Yazi flavor). Each tab shows its number, an icon and its title: the name
you gave it (CMD+SHIFT+R), else the host for ssh tabs (server icon), else the
pane title or the cwd's name.

The ssh-aware actions reuse the original pane's `-l -p -F -J -i` options and
are instant if you use `ControlMaster` in `~/.ssh/config`, e.g.

```
Host *
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 10m
```

## Session restore

Like a browser, quitting WezTerm (or a reboot or crash) and reopening it brings
back the windows (size, workspace), tabs in order with their custom titles,
split layouts with proportions, the active tab and pane, zoom and the Yazi
sidebar. No process is kept alive; panes are re-created and what ran in them
is run again, through the login shell so the pane stays a shell afterwards:

* **Claude Code** panes: `claude --resume <session id>`, the exact
  conversation. The id comes from a `SessionStart` hook (below); for a
  process started before the hook, from the `sessions/<pid>.json` Claude Code
  keeps for it (in `~/.claude*`) or a `--resume <id>` on its command line.
  Without an id the original command is only typed at the prompt.
* **ssh / ssh-pane** panes: reconnect through `ssh-pane`. Hosts are staggered,
  and further panes to a host wait for its ControlMaster, so you log in once.
  Hosts listed in `~/.local/state/wezterm/restore-skip-hosts` (one per line,
  `#` comments; or `WEZTERM_RESTORE_SKIP_HOSTS=a,b`) are never reconnected.
* **Any other command**: re-run with its exact arguments in its cwd. Commands
  that could do damage or duplicate work are only typed at the prompt, not run
  (`rm mv cp dd sudo kill shutdown ssh-setup scp rsync tee ...`, `git push
  commit reset rebase merge ...`, package-manager install/remove/update, docker
  `rm/prune/stop`, `kubectl delete/apply`, `terraform apply/destroy`, and `sh
  -c` strings with those words or a `>` redirect). See `DENY_*` in
  `wezterm/features/session_restore.lua`. An interpreter running a script on PATH (`python
  ~/.local/bin/tool`) comes back as `tool`; Yazi drops its `--cwd-file` and
  runs through the `y` function; commands on a `$TMPDIR` file are only typed.
* An idle shell comes back as a shell in its cwd (also in folders such as
  `~/Desktop` that macOS privacy protection keeps WezTerm from listing).

State is saved to `~/.local/state/wezterm/session.json` (atomic write, only
when it changed and has settled for a poll; WezTerm 20240203 has no quit
event, so the last settled state is restored). At launch the previous file is
kept as `session.prev.json`, as is a session whose windows were all closed
before a new one opened. Window positions cannot be read by this WezTerm
version, so only sizes are restored. Disable with `WEZTERM_NO_RESTORE=1` or
CMD+OPT+SHIFT+O (creates/removes `~/.local/state/wezterm/no-restore`).

Add the hook to `~/.claude/settings.json` (it records the id per pane in
`~/.local/state/wezterm/claude/<WEZTERM_PANE>`; silent, never fails, skips
`claude -p` runs):

```json
"hooks": { "SessionStart": [ { "hooks": [
  { "type": "command", "command": "\"$HOME/.local/bin/wez-claude-session\"", "timeout": 5 }
] } ] }
```

## Hibernation

A Claude Code pane left idle for an hour is put to sleep to free its memory:
the process is stopped (SIGTERM) and the pane keeps showing its last screen,
dimmed, under a "💤 Hibernated <time>" banner (`bin/wez-hibernate`). Any key
or a click resumes the same conversation with `claude --resume <id>` in its
cwd, through the same shell. Session restore saves a sleeping pane as the
Claude Code pane it was.

Idle means, for the whole hour: the screen above the input box unchanged, the
process tree the same and at about no CPU (under 1.5%), not the focused pane,
and nothing written to the session's files: its transcript, the directory
beside it (subagent transcripts, tool results) and its temp directory under
`/private/tmp/claude-<uid>/` (task outputs). Subagents run inside the
process, so those files are the surest sign they are at work. Every check is
repeated right before the stop, and any doubt keeps it awake: anything
running under it besides its MCP servers (a shell, tool command, build,
`sleep`, `ssh`, `tmux`, ...), a spinner, "esc to interrupt", running agents
or background tasks, a dialog or permission prompt, a draft in the input
box, no known session id, session files that cannot be found or read, or a
pane that would not survive the exit.
Reasons a pane stays awake go to the WezTerm log (`hibernate:`). Disable with
`~/.local/state/wezterm/hibernate-off` or `WEZTERM_HIBERNATE=0`.

## Yazi keys added

| Key | Action |
| --- | --- |
| T | Maximize / restore the preview pane |
| R | `mdview`: read the hovered Markdown file full screen (glow, paged with `less -R`; q returns) |
| Enter on `.md` | `mdedit`: micro on the left, live glow preview on the right |
| g r | Reveal the hovered file in Finder (macOS only; a no-op on remote hosts) |

Side-by-side Markdown also works over SSH in WezTerm: on the remote host,
`mdedit` sets a WezTerm user var and `~/.wezterm.lua` opens the preview
(`ssh -t <host> mdpreview <file>`) next to the ssh pane, closing it when micro
exits. Inside tmux this needs `set -g allow-passthrough on`; in other
terminals it is plain micro.

Markdown previews in Yazi are rendered with glow (piper plugin) using the Catppuccin style in `glow/catppuccin.json` (headings differ by colour and bar, no `#` prefixes).

Small raster images (icons, small screenshots) are enlarged to about 80% of the
preview pane (at most 8x) by the `upscale` previewer instead of being drawn at
native pixel size. It resizes with `sips` on macOS or ImageMagick
(`magick`/`convert`) on Linux into Yazi's cache; without either it falls back
to the normal preview. SVG previews need `resvg`.

## Dependencies

```sh
brew install --cask wezterm
brew install yazi poppler glow micro fzf jq resvg
```

Zsh snippets assume [oh-my-zsh](https://ohmyz.sh) plus these third-party plugins:

```sh
ZC=${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins
git clone https://github.com/Aloxaf/fzf-tab $ZC/fzf-tab
git clone https://github.com/zsh-users/zsh-autosuggestions $ZC/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting $ZC/zsh-syntax-highlighting
```

The fzf-tab `cd` preview uses `eza` if installed.

## Install

```sh
git clone https://github.com/RyanKim17920/dotfiles ~/dotfiles
~/dotfiles/install.sh
```

`install.sh` symlinks everything into place (so `git pull` updates it), moves
any existing file to `<name>.bak-<timestamp>` first, and runs `ya pkg install`.
It never deletes anything. Then add to `~/.zshrc`:

```sh
source ~/dotfiles/zsh/snippets.zsh
```

Make sure `~/.local/bin` is on your `PATH`. For the status line, point
`statusLine` in `~/.claude/settings.json` at it:

```json
"statusLine": { "type": "command", "command": "~/.claude/statusline.sh", "padding": 0 }
```

## ssh-setup

```sh
ssh-setup <host>   # set up or update one host
ssh-setup --all    # update every known host with a live connection
ssh-setup --all --dry-run   # only print what --all would do
```

Installs yazi, ya, micro, glow and resvg (static release binaries matching your local
versions, checksum-verified), your yazi/micro configs and the status line into
your home directory on a remote Linux host (x86_64 or aarch64). No sudo. It
adds one marked block to the remote `~/.bashrc` (PATH, `EDITOR=micro`, `y`,
and an OSC 7 prompt hook so WezTerm knows the remote cwd; inside tmux it uses
passthrough when `allow-passthrough` is on) and one to `~/.tmux.conf`
(`set-clipboard on`, `allow-passthrough on`, read by new tmux servers only; a
running one keeps its options until it restarts), replaced in place on updates,
backs up anything it replaces to `*.bak-ssh-setup`, and prints undo commands.
Re-running is a fast no-op when nothing changed. Remote micro gets
`"clipboard": "terminal"`, so its copy reaches this Mac over OSC 52 like Yazi's
(WezTerm honors setting the clipboard, and ignores requests to read it).

Each host set up successfully is listed in `~/.local/state/ssh-setup/hosts`.
`ssh-setup --all` re-syncs those hosts, plus any other host in `~/.ssh/config`
(and its Includes) that has a live connection, in parallel, and prints one
line per host (updated, skipped or FAILED) and the totals. It only touches
hosts with a live ControlMaster (`ssh -O check`) and
rides that connection only (a dead master makes the run fail instead of
logging in), so a host behind 2FA is skipped with `not connected (open an ssh
pane to it first)` rather than prompted.

Caveats:

- Needs non-interactive ssh. If the host wants a password or 2FA, open a
  `ssh <host>` session first so a ControlMaster connection exists.
- Local tools required: `curl jq shasum unzip bsdtar`.
- `mdedit` and `mdpreview` are shipped too, so Enter on `.md` in remote Yazi
  opens the side-by-side preview when you are in WezTerm (see above).
- PDF previews on the remote need `pdftoppm` (poppler-utils).
- resvg (SVG previews) is only shipped to x86_64 hosts; upstream publishes no
  Linux aarch64 binary. Small-image upscaling on the remote needs ImageMagick.
- Hosts that cannot run arbitrary commands (e.g. a forced-command bastion)
  can be refused by alias or resolved hostname:
  `export SSH_SETUP_SKIP_HOSTS="bastion other-host"`.
- Set `GITHUB_TOKEN` if you hit GitHub API rate limits.

## Disconnects & reconnecting

`bin/ssh-pane` wraps ssh. The ssh-aware WezTerm splits/tabs use it, and the
`ssh` function in `zsh/snippets.zsh` routes interactive `ssh` through it.

- When the connection drops (ssh exits 255) the pane stays open with
  `[disconnected from host — Enter: reconnect · q: close]`. Enter (or `r`)
  re-runs the identical ssh command; `q`, Ctrl+D or Ctrl+C closes. Quick
  repeated failures back off a few seconds between attempts.
- A normal exit (you typed `exit`, the remote command finished) closes the
  pane as before.
- After ssh exits, mouse reporting, a stuck alternate screen, a hidden cursor
  and keypad mode are reset (zsh also resets all but the alternate screen
  before every prompt), so a dropped `micro`/`less`/`yazi` no longer floods
  the shell with mouse escape codes.
- `ssh -G/-O/-Q/-V/-W`, pipes and scripts (git, scp, rsync) bypass it.

Programs on the server still die with the connection. Run them inside tmux on
the server so they survive drops; since a reconnect re-runs the same command,
`ssh -t host tmux new -A -s work` puts you straight back in the session.
`ServerAliveInterval 15` / `ServerAliveCountMax 4` under `Host *` makes a dead
connection show up in about a minute instead of hanging.

## License

MIT
