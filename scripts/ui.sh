# Shared terminal UI helpers for the XPS NixOS wrapper scripts.
# Source this file; do not execute it.
# shellcheck shell=bash
#
# v2 — Dracula truecolor palette (matches assets/EDM115-newline2.omp.json),
# gradient banner, rich-style progress bars, recap box. The v1 API
# (ui_header/ui_rule/ui_section/ui_ok/ui_warn/ui_fail/ui_tail_log/
# ui_spin_while/run_step/ui_duration) is preserved for bootstrap/verify;
# ./update uses the new helpers below.

if [[ -t 1 ]]; then
  _rgb() { printf '\033[38;2;%s;%s;%sm' "$@"; }
  UI_FG=$(_rgb 248 248 242)      # #f8f8f2
  UI_GREY=$(_rgb 98 114 164)     # #6272a4 (dim text)
  UI_DK=$(_rgb 68 71 90)         # #44475a (rules, bar track)
  UI_CYAN=$(_rgb 139 233 253)    # #8be9fd
  UI_GREEN=$(_rgb 80 250 123)    # #50fa7b
  UI_RED=$(_rgb 255 85 85)       # #ff5555
  UI_YELLOW=$(_rgb 241 250 140)  # #f1fa8c
  UI_ORANGE=$(_rgb 255 184 108)  # #ffb86c
  UI_PINK=$(_rgb 255 121 198)    # #ff79c6
  UI_PURPLE=$(_rgb 189 147 249)  # #bd93f9
  UI_DIM=$'\033[2m'
  UI_BOLD=$'\033[1m'
  UI_RESET=$'\033[0m'
  unset -f _rgb
else
  UI_FG='' UI_GREY='' UI_DK='' UI_CYAN='' UI_GREEN='' UI_RED='' UI_YELLOW=''
  UI_ORANGE='' UI_PINK='' UI_PURPLE='' UI_DIM='' UI_BOLD='' UI_RESET=''
fi

UI_RULE_WIDTH=70
UI_SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

ui_rule() {
  local line
  printf -v line '%*s' "$UI_RULE_WIDTH" ''
  printf '%s%s%s\n' "$UI_DK" "${line// /─}" "$UI_RESET"
}

ui_header() {
  printf '%s%s%s\n' "$UI_BOLD" "$*" "$UI_RESET"
  ui_rule
}

ui_section() {
  printf '\n%s%s%s\n' "$UI_BOLD" "$*" "$UI_RESET"
}

# ui_duration <seconds> -> "52s" / "2m 04s"
ui_duration() {
  local s=$1
  if (( s >= 60 )); then
    printf '%dm %02ds' $((s / 60)) $((s % 60))
  else
    printf '%ds' "$s"
  fi
}

# ui_mmss <seconds> -> "1:42"
ui_mmss() { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

# ui_ok/ui_warn/ui_fail <label> [detail]
ui_ok()   { printf '  %s✓%s %-18s %s%s%s\n' "$UI_GREEN" "$UI_RESET" "$1" "$UI_GREY" "${2:-}" "$UI_RESET"; }
ui_warn() { printf '  %s!%s %-18s %s%s%s\n' "$UI_YELLOW" "$UI_RESET" "$1" "$UI_YELLOW" "${2:-}" "$UI_RESET"; }
ui_fail() { printf '  %s✗%s %-18s %s%s%s\n' "$UI_RED" "$UI_RESET" "$1" "$UI_RED" "${2:-}" "$UI_RESET"; }

# ui_tail_log <logfile> [lines] — indented dim excerpt for failure reporting
ui_tail_log() {
  local logfile=$1 lines=${2:-15}
  [[ -r $logfile ]] || return 0
  printf '%s' "$UI_GREY"
  tail -n "$lines" "$logfile" | sed 's/^/    /'
  printf '%s' "$UI_RESET"
}

# ui_grad_text <text> — bold per-character purple→pink gradient (no newline)
ui_grad_text() {
  local text=$1 n=${#1} d i r g b
  d=$(( n - 1 )); (( d < 1 )) && d=1
  for (( i = 0; i < n; i++ )); do
    r=$(( 189 + (255 - 189) * i / d ))
    g=$(( 147 + (121 - 147) * i / d ))
    b=$(( 249 + (198 - 249) * i / d ))
    printf '\033[1m\033[38;2;%d;%d;%dm%s' "$r" "$g" "$b" "${text:i:1}"
  done
  printf '%s' "$UI_RESET"
}

# ui_bar <pct> <width> <color> — rich-style ━━━━──── bar (no newline)
ui_bar() {
  local pct=$1 width=$2 color=$3 f i
  f=$(( pct * width / 100 )); (( f > width )) && f=$width
  printf '%s' "$color"
  for (( i = 0; i < f; i++ )); do printf '━'; done
  printf '%s' "$UI_DK"
  for (( i = f; i < width; i++ )); do printf '─'; done
  printf '%s' "$UI_RESET"
}

# ui_box <color> <icon> <line1> [line2] — 64-wide recap box
ui_box() {
  local color=$1 icon=$2 l1=$3 l2=${4:-} w=64 pad i
  printf '\n%s  ╭' "$UI_DK"; for (( i = 0; i < w; i++ )); do printf '─'; done; printf '╮%s\n' "$UI_RESET"
  pad=$(( w - 3 - ${#l1} )); (( pad < 0 )) && pad=0
  printf '%s  │%s %s%s%s%s %s%*s%s│%s\n' \
    "$UI_DK" "$UI_RESET" "${UI_BOLD}${color}" "$icon" "$UI_RESET" '' "$l1" "$pad" '' "$UI_DK" "$UI_RESET"
  if [[ -n $l2 ]]; then
    pad=$(( w - 3 - ${#l2} )); (( pad < 0 )) && pad=0
    printf '%s  │%s   %s%s%s%*s%s│%s\n' \
      "$UI_DK" "$UI_RESET" "$UI_GREY" "$l2" "$UI_RESET" "$pad" '' "$UI_DK" "$UI_RESET"
  fi
  printf '%s  ╰' "$UI_DK"; for (( i = 0; i < w; i++ )); do printf '─'; done; printf '╯%s\n' "$UI_RESET"
}

# ui_spin_while <label> <pid...> — spinner until every pid has exited.
# Does not collect exit statuses; callers still `wait` each pid.
ui_spin_while() {
  local label=$1; shift
  local i=0 pid alive
  if [[ ! -t 1 ]]; then
    wait "$@" 2>/dev/null || true
    return 0
  fi
  while :; do
    alive=false
    for pid in "$@"; do
      kill -0 "$pid" 2>/dev/null && { alive=true; break; }
    done
    $alive || break
    printf '\r  %s%s%s %s' "$UI_CYAN" "${UI_SPIN:i++ % 10:1}" "$UI_RESET" "$label"
    sleep 0.1
  done
  printf '\r\033[2K'
}

# run_step <label> <logfile> <cmd...>
# Runs the command with output captured to the logfile, showing a spinner.
# Prints a ✓/✗ line with duration; returns the command's exit status.
run_step() {
  local label=$1 logfile=$2; shift 2
  local start=$SECONDS rc=0 pid
  mkdir -p "$(dirname -- "$logfile")"
  "$@" >"$logfile" 2>&1 &
  pid=$!
  ui_spin_while "$label" "$pid"
  wait "$pid" || rc=$?
  local dur
  dur=$(ui_duration $((SECONDS - start)))
  if (( rc == 0 )); then
    ui_ok "$label" "($dur)"
  else
    ui_fail "$label" "failed after $dur"
    ui_tail_log "$logfile"
  fi
  return "$rc"
}
