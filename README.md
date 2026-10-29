# dotfiles

My terminal setup on macOS: **WezTerm** (Ghostty-style splits that follow you
into ssh sessions), **Yazi** as a file sidebar and path previewer, and **micro**
as the editor, with a live glow preview for Markdown.

Targets WezTerm `20240203` and Apple Silicon
Homebrew paths (`/opt/homebrew/bin`).

## Layout

| Path | Installs to |
| --- | --- |
| `wezterm/wezterm.lua` | `~/.wezterm.lua` |
| `yazi/` | `~/.config/yazi/` |
| `yazi-sidebar/yazi.toml` | `~/.config/yazi-sidebar/yazi.toml` |
| `micro/settings.json` | `~/.config/micro/settings.json` |
| `bin/` | `~/.local/bin/` (`mdedit`, `mdview`, `mdpreview`, `glow-cached`, `yazi-open`, `clipimg-push`, `ssh-setup`, `ssh-pane`) |
| `claude/statusline.sh` | `~/.claude/statusline.sh` (Claude Code status line) |
| `zsh/snippets.zsh` | source it from `~/.zshrc` |

`~/.config/yazi-sidebar` is a second Yazi config used only by the CMD+E
sidebar. It has its own `yazi.toml` (single column, opens files in a split) and
symlinks `keymap.toml`, `theme.toml`, `package.toml`, `plugins` and `flavors`
to `../yazi/`.

Yazi `plugins/` and `flavors/` from `ya pkg` are not committed; `ya pkg install`
fetches them from `yazi/package.toml`. The one custom plugin,
`yazi/plugins/upscale.yazi`, is committed and symlinked by `install.sh`.

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
| CMD+click a path | Opens it in a Yazi peek inside the current tab, covering it (file hovered, preview maximized; images and PDFs too). The peek is a tiny split of the pane you clicked, zoomed over the tab, so that pane barely reflows; q closes Yazi and you are back in that pane with the layout (and any earlier zoom) as it was. One peek per tab: clicking again replaces it. Layout fixes, the sidebar and pane moves wait until it is closed. Works on `~/x`, `./x`, `/x`, bare relative paths like `src/app.py` or `README.md`, `x:12` / `x:12:3` / `x:12-40` and `file://` links. Paths a TUI hard-wrapped onto the next line (Claude Code's indented continuation) are rejoined from the pane text, whichever half you click |
| CMD+click a video or audio file | Same as CMD+OPT+click (mp4, mov, m4v, mkv, webm, avi, wmv, flv, mpg, mpeg, 3gp, mp3, wav, m4a, flac, aac, ogg, opus, aiff): these cannot play in the terminal, so they reveal in Finder instead of peeking. `.ts` and `.gif` still peek |
| CMD+OPT+click a path | Reveal it in Finder (`open -R`; directories open) so you can drag it into a browser upload, Slack, etc. In an ssh pane the file is first copied to `~/Downloads/<host>/` over the existing ControlMaster |
| CMD+click a path in an ssh pane | Open it in remote Yazi on that host (in-tab peek via `ssh-pane`, instant over the ControlMaster; never prompts, toasts if there is no live master). Relative paths resolve against the remote shell's cwd (OSC 7, sent by the `ssh-setup` bashrc block), else against the cwds of your processes on the host (e.g. Claude Code inside tmux; newest match wins) and the remote home, all in one round trip |
| CMD+OPT+SHIFT+click a path | Open the file in macOS Quick Look instead (a separate window). In an ssh pane the file is first copied to `~/Library/Caches/wezterm/peek/<host>/` over the master |
| CMD+click a localhost link in an ssh pane | `http://localhost:PORT` / `127.0.0.1` / `0.0.0.0` from Jupyter, TensorBoard, vite... on the remote: adds `ssh -O forward -L` on the existing ControlMaster (never a new login) and opens it locally, `?token=` kept. A busy local port moves to the next free one; forwards are reused |
| CMD+click an `ssh ... -L LPORT:HOST:RPORT ... host` command | Add those forwards to the existing ControlMaster for that host instead of running it, then open the latest localhost URL for that port from the scrollback (token filled in) or `http://localhost:LPORT/` (never a new login; config aliases are matched, so `me@login.example.org` finds the master opened as `myserver`) |
| CMD+click `http://localhost:LPORT/...` after such a hint | Uses the most recent `ssh -L LPORT:...` in the scrollback (works from local panes too), so a server on a compute node behind a login host opens directly. A stale forward of ours on LPORT is replaced; an old hand-started tunnel is left running and named by pid. `?token=<token>` is filled from the last `cat .../token` shown in this pane, else in the window's other panes, else the token file that last worked for that host and remote port (path remembered in `~/.local/state/wezterm/token-paths`, mode 600; never the token), read over the master and never logged |
| CMD+SHIFT+L | Same without a click: a port, a localhost URL or a whole `ssh -L` command |
| CMD+C / CMD+V (and SHIFT / CTRL variants) | Unified copy/paste. CTRL+C with no selection still sends ^C. Pasting an image in an ssh pane uploads it to the remote `~/.cache/clipimg/` and types the path |
| CMD+W / CTRL+SHIFT+W | Close the pane. WezTerm's own confirm, shown over that pane only: y closes, n or Esc cancels (Enter does nothing). Skipped when the pane only runs an idle shell (bash, zsh, sh, fish, nu; tmux still asks) |
| CMD+[ / CMD+] | Previous / next pane |
| CMD+OPT+arrows | Focus pane in that direction |
| CMD+CTRL+arrows | Resize pane |
| CMD+SHIFT+Enter | Zoom / unzoom pane |
| CMD+SHIFT+S | Swap the focused pane with a picked one |
| CMD+OPT+R / CMD+OPT+SHIFT+R | Rotate panes clockwise / counter-clockwise |
| CMD+SHIFT+R / CMD+CTRL+R | Rename the tab / window (empty input restores the automatic title) |
| CMD+SHIFT+P | Jump to a pane by label |

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
ssh-setup --all    # update every host set up before
```

Installs yazi, ya, micro, glow and resvg (static release binaries matching your local
versions, checksum-verified), your yazi/micro configs and the status line into
your home directory on a remote Linux host (x86_64 or aarch64). No sudo. It
adds one marked block to the remote `~/.bashrc` (PATH, `EDITOR=micro`, `y`,
and an OSC 7 prompt hook so WezTerm knows the remote cwd; inside tmux it uses
passthrough when `allow-passthrough` is on), replaced in place on updates,
backs up anything it replaces to `*.bak-ssh-setup`, and prints undo commands.
Re-running is a fast no-op when nothing changed.

Each host set up successfully is listed in `~/.local/state/ssh-setup/hosts`.
`ssh-setup --all` re-syncs those hosts in parallel and prints one line per
host. It only touches hosts with a live ControlMaster (`ssh -O check`) and
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
