#!/usr/bin/env bash
# install.sh: symlink these dotfiles into place.
# Any existing file at a target is moved to <target>.bak-<timestamp> first;
# nothing is overwritten or deleted. Re-running is safe (correct links are skipped).
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

# link <source> <target>
link() {
	local src="$1" dst="$2"
	if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
		echo "ok      $dst"
		return
	fi
	mkdir -p "$(dirname "$dst")"
	if [ -e "$dst" ] || [ -L "$dst" ]; then
		mv "$dst" "$dst.bak-$STAMP"
		echo "backup  $dst -> $dst.bak-$STAMP"
	fi
	ln -s "$src" "$dst"
	echo "link    $dst -> $src"
}

link "$REPO/wezterm/wezterm.lua" "$HOME/.wezterm.lua"

for f in yazi.toml keymap.toml theme.toml package.toml init.lua; do
	link "$REPO/yazi/$f" "$HOME/.config/yazi/$f"
done

# Sidebar Yazi (CMD+E): own yazi.toml, everything else shared with ~/.config/yazi
link "$REPO/yazi-sidebar/yazi.toml" "$HOME/.config/yazi-sidebar/yazi.toml"
for f in keymap.toml theme.toml package.toml plugins flavors; do
	link "../yazi/$f" "$HOME/.config/yazi-sidebar/$f"
done

link "$REPO/micro/settings.json" "$HOME/.config/micro/settings.json"

for f in mdedit yazi-open clipimg-push ssh-setup glow-cached mdview mdpreview ssh-pane; do
	link "$REPO/bin/$f" "$HOME/.local/bin/$f"
done

link "$REPO/claude/statusline.sh" "$HOME/.claude/statusline.sh"

# Yazi plugins and flavor listed in package.toml
if command -v ya >/dev/null 2>&1; then
	ya pkg install
else
	echo "warning: 'ya' not found; run 'ya pkg install' after installing yazi" >&2
fi

echo
echo "Done. Add 'source $REPO/zsh/snippets.zsh' to ~/.zshrc (or copy what you want)."
