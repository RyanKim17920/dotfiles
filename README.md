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
| `bin/` | `~/.local/bin/` (`mdedit`, `mdview`, `mdpreview`, `glow-cached`, `yazi-open`, `clipimg-push`, `ssh-setup`) |
| `claude/statusline.sh` | `~/.claude/statusline.sh` (Claude Code status line) |
| `zsh/snippets.zsh` | source it from `~/.zshrc` |

`~/.config/yazi-sidebar` is a second Yazi config used only by the CMD+E
sidebar. It has its own `yazi.toml` (single column, opens files in a split) and
symlinks `keymap.toml`, `theme.toml`, `package.toml`, `plugins` and `flavors`
to `../yazi/`.

Yazi `plugins/` and `flavors/` are not committed; `ya pkg install` fetches
them from `yazi/package.toml`.

## WezTerm keys

| Keys | Action |
| --- | --- |
| CMD+D / CMD+SHIFT+D | Split right / down. In a pane running `ssh`, the new pane opens ssh to the same host |
| CMD+T / CMD+N | New tab / window, ssh-aware the same way |
| CMD+SHIFT+T / CMD+SHIFT+N | New tab / window, always local |
| CMD+OPT+T / CMD+OPT+N | Move the focused pane to a new tab / window |
| CMD+OPT+1..9 | Send the focused pane to tab N, split to the right |
| CMD+OPT+SHIFT+1..9 | Send the focused pane to tab N, split below |
| CMD+SHIFT+M | Merge all other windows into this one, keeping split layouts |
| CMD+SHIFT+← / → | Reorder tabs |
| CMD+E | Toggle the Yazi file sidebar (local tabs only) |
| CMD+click a path | Open it in a Yazi peek pane (file hovered, preview maximized). Works on `~/x`, `./x`, `/x`, `x:12` and `file://` links |
| CMD+C / CMD+V (and SHIFT / CTRL variants) | Unified copy/paste. CTRL+C with no selection still sends ^C. Pasting an image in an ssh pane uploads it to the remote `~/.cache/clipimg/` and types the path |
| CMD+W | Close pane, confirm with Enter or y (n/Esc cancels) |
| CMD+[ / CMD+] | Previous / next pane |
| CMD+OPT+arrows | Focus pane in that direction |
| CMD+CTRL+arrows | Resize pane |
| CMD+SHIFT+Enter | Zoom / unzoom pane |
| CMD+SHIFT+S | Swap the focused pane with a picked one |
| CMD+SHIFT+R / CMD+OPT+SHIFT+R | Rotate panes clockwise / counter-clockwise |
| CMD+SHIFT+P | Jump to a pane by label |

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

Side-by-side Markdown also works over SSH in WezTerm: on the remote host,
`mdedit` sets a WezTerm user var and `~/.wezterm.lua` opens the preview
(`ssh -t <host> mdpreview <file>`) next to the ssh pane, closing it when micro
exits. Inside tmux this needs `set -g allow-passthrough on`; in other
terminals it is plain micro.

Markdown previews in Yazi are rendered with glow (piper plugin).

## Dependencies

```sh
brew install --cask wezterm
brew install yazi poppler glow micro fzf jq
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
ssh-setup <host>
```

Installs yazi, ya, micro and glow (static release binaries matching your local
versions, checksum-verified), your yazi/micro configs and the status line into
your home directory on a remote Linux host (x86_64 or aarch64). No sudo. It
adds one marked block to the remote `~/.bashrc` (PATH, `EDITOR=micro`, `y`),
backs up anything it replaces to `*.bak-ssh-setup`, and prints undo commands.
Re-running is a fast no-op when nothing changed.

Caveats:

- Needs non-interactive ssh. If the host wants a password or 2FA, open a
  `ssh <host>` session first so a ControlMaster connection exists.
- Local tools required: `curl jq shasum unzip bsdtar`.
- `mdedit` and `mdpreview` are shipped too, so Enter on `.md` in remote Yazi
  opens the side-by-side preview when you are in WezTerm (see above).
- PDF previews on the remote need `pdftoppm` (poppler-utils).
- Hosts that cannot run arbitrary commands (e.g. a forced-command bastion)
  can be refused by alias or resolved hostname:
  `export SSH_SETUP_SKIP_HOSTS="bastion other-host"`.
- Set `GITHUB_TOKEN` if you hit GitHub API rate limits.

## License

MIT
