#!/usr/bin/env bash
# Claude Code status line.
# Line 1: time, cwd, git branch, model
# Line 2: context bar, 5-hour and 7-day subscription usage (rate_limits)
# Fields: https://code.claude.com/docs/en/statusline#available-data

# Claude Code may run this without ~/.local/bin on PATH (remote hosts ship jq there).
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac

input=$(cat)

# One jq call for speed. Missing values become "" (rate_limits is absent on
# API-key auth and before the first API response; each window may be absent).
IFS=$'\x1f' read -r model cwd ctx_pct ctx_size h5_pct h5_reset d7_pct d7_reset < <(
  jq -r '[
    (.model.display_name // "Unknown"),
    (.workspace.current_dir // .cwd // "?"),
    (.context_window.used_percentage // ""),
    (.context_window.context_window_size // 0),
    (.rate_limits.five_hour.used_percentage // ""),
    (.rate_limits.five_hour.resets_at // ""),
    (.rate_limits.seven_day.used_percentage // ""),
    (.rate_limits.seven_day.resets_at // "")
  ] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null
)

model=${model:-Unknown}; cwd=${cwd:-?}

RESET=$'\033[0m'; BOLD=$'\033[1m'; CYAN=$'\033[1;36m'; YELLOW=$'\033[1;33m'
WHITE=$'\033[1;37m'; MAGENTA=$'\033[1;35m'; GREEN=$'\033[1;32m'; RED=$'\033[1;31m'
DIM=$'\033[0;37m'

# Color by percent: green <50, yellow 50-80, red >80 (sets $C, no fork)
pct_color() {
  local p=${1%.*}
  if (( p > 80 )); then C=$RED
  elif (( p >= 50 )); then C=$YELLOW
  else C=$GREEN; fi
}

read -r now clock <<<"$(date '+%s %H:%M')"

# Epoch -> formatted date: GNU date -d @N, falling back to BSD/macOS date -r N
epoch_date() { date -d "@$1" "$2" 2>/dev/null || date -r "$1" "$2"; }

# Format epoch seconds into $R: time of day if within 24h, else weekday + hour
fmt_reset() {
  R=""
  [[ "$1" =~ ^[0-9]+$ ]] || return
  if (( $1 - now < 86400 )); then
    R=$(epoch_date "$1" '+%-I:%M%p')
  else
    R=$(epoch_date "$1" '+%a %-I%p')
  fi
  R=${R/AM/am}; R=${R/PM/pm}
}

# Appends "5h 42% (resets 3:10pm)" or "5h –" to $OUT
limit_segment() {
  if [[ -z "$2" ]]; then
    OUT+="${DIM}$1 –${RESET}"
    return
  fi
  local p
  pct_color "$2"
  printf -v p '%.0f' "$2"
  OUT+="${DIM}$1${RESET} ${C}${p}%${RESET}"
  fmt_reset "$3"
  [[ -n "$R" ]] && OUT+=" ${DIM}(resets $R)${RESET}"
}

# Context bar (10 blocks)
bar="----------"; ctx_disp="?"; bar_color=$WHITE
if [[ -n "$ctx_pct" ]]; then
  printf -v ctx_disp '%.0f' "$ctx_pct"
  filled=$(( (ctx_disp + 5) / 10 )); (( filled > 10 )) && filled=10
  bar="##########"; bar="${bar:0:filled}----------"; bar=${bar:0:10}
  pct_color "$ctx_pct"; bar_color=$C
fi
ctx_size=${ctx_size:-0}
if (( ctx_size >= 1000 )); then ctx_size_fmt="$((ctx_size / 1000))k"; else ctx_size_fmt=$ctx_size; fi

# Git branch (worktree-aware); one git call, falls back to short SHA when detached
branch=""
if [[ -d "$cwd" ]]; then
  branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
  [[ "$branch" == HEAD ]] && branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
fi

SEP=" ${DIM}·${RESET} "

OUT="${CYAN}[$clock]${RESET} ${BOLD}${WHITE}${cwd##*/}${RESET}"
[[ -n "$branch" ]] && OUT+="${SEP}${GREEN}${branch}${RESET}"
OUT+="${SEP}${MAGENTA}${model}${RESET}"$'\n'
OUT+="${DIM}ctx${RESET} ${bar_color}[${bar}]${RESET} ${YELLOW}${ctx_disp}%${RESET} ${DIM}of ${ctx_size_fmt}${RESET}"
OUT+="$SEP"; limit_segment 5h "$h5_pct" "$h5_reset"
OUT+="$SEP"; limit_segment 7d "$d7_pct" "$d7_reset"
printf '%s\n' "$OUT"
