# Shareable zsh snippets for this setup. Source from ~/.zshrc or copy the
# parts you want. The oh-my-zsh part assumes $ZSH points at your install.

# --- oh-my-zsh plugins ---
# fzf-tab, zsh-autosuggestions and zsh-syntax-highlighting are third-party:
# clone them into ${ZSH_CUSTOM:-$ZSH/custom}/plugins/ first (see README).
plugins=(git
git-extras
gh
z
fzf-tab
zsh-autosuggestions
zsh-syntax-highlighting
)
# source $ZSH/oh-my-zsh.sh   # (in your ~/.zshrc, after plugins=...)

# --- Zsh options ---
setopt autocd extendedglob histignorealldups sharehistory inc_append_history
setopt hist_ignore_space hist_reduce_blanks
HISTFILE=$HOME/.zsh_history
HISTSIZE=100000
SAVEHIST=200000

# --- fzf ---
if [[ -t 0 ]] && command -v fzf >/dev/null 2>&1; then
  # fzf keybindings (Ctrl+R, Ctrl+T, Alt+C) and completion (fzf >= 0.48)
  source <(fzf --zsh)
fi

# fzf-tab tweaks
zstyle ':completion:*:git-checkout:*' sort false
zstyle ':completion:*:descriptions' format '[%d]'
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
# let fzf-tab capture the unambiguous prefix instead of the zsh menu
zstyle ':completion:*' menu no
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza -1 --color=always $realpath'
zstyle ':fzf-tab:*' fzf-flags --color=fg:1,fg+:2 --bind=tab:accept
zstyle ':fzf-tab:*' use-fzf-default-opts yes
zstyle ':fzf-tab:*' switch-group '<' '>'

# --- Yazi: `y` opens yazi and cds into the last directory on exit ---
function y() {
	local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
	command yazi "$@" --cwd-file="$tmp"
	IFS= read -r -d '' cwd < "$tmp"
	[ -n "$cwd" ] && [ "$cwd" != "$PWD" ] && [ -d "$cwd" ] && builtin cd -- "$cwd"
	rm -f -- "$tmp"
}

# --- Default editor (used by yazi and others) ---
export EDITOR=micro
export VISUAL=micro

# --- Terminal-mode reset before each prompt ---
# A remote program that dies with the connection (micro, less, yazi over a
# dropped ssh) can leave mouse reporting on, so every mouse move prints escape
# codes into this shell. Turn mouse tracking off, show the cursor and reset
# cursor-key/keypad modes before each prompt. Cheap (one printf), and precmd
# runs before a prompt is drawn, never on the theme's TRAPALRM redraw.
autoload -Uz add-zsh-hook
_reset_term_modes() {
  [[ -t 1 ]] && printf '\e[?1000l\e[?1002l\e[?1003l\e[?1005l\e[?1006l\e[?1015l\e[?25h\e[?1l\e>'
  return 0
}
add-zsh-hook precmd _reset_term_modes

# --- ssh: offer to reconnect when an interactive session drops ---
# Interactive `ssh` goes through ssh-pane (Enter reconnects, q closes; see
# README). Scripts, git, scp and rsync don't use shell functions, and ssh-pane
# itself passes -G/-O/-Q/-V/-W queries and non-terminal use straight to ssh.
ssh() {
  if [[ -t 0 && -t 1 && -x ~/.local/bin/ssh-pane ]]; then
    ~/.local/bin/ssh-pane "$@"
  else
    command ssh "$@"
  fi
}
