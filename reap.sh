#!/usr/bin/env bash
# reap.sh — manually trigger a zellij-reaper pass.
#
# Subcommands:
#   run         one normal pass (uses the systemd unit's env: respects
#               MAX_AGE_HOURS / DRY_RUN as configured for the timer)
#   force-run   bypass the last-activity threshold; any session that is
#               EXITED, or RUNNING with no client attached and no command
#               in any pane, gets reaped regardless of how recent its
#               activity was. Every other safety guard is still applied:
#                 - never reap a session with a connected client
#                 - never reap a session with a foreground command in a pane
#                 - never reap a session created with `command="claude"`
#                 - obey PROTECT_REGEX
#
# When installed via ./install.sh this file is also placed at
# ~/.local/bin/zellij-reap so you can run `zellij-reap run` from anywhere.

set -euo pipefail

REAPER="$HOME/.local/bin/zellij-reaper.sh"
SERVICE="zellij-reaper.service"
LOG="$HOME/.cache/zellij-reaper.log"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
  C_BOLD=''; C_DIM=''; C_RESET=''
  C_GREEN=''; C_YELLOW=''; C_RED=''
fi

section() { printf '\n%s▸ %s%s\n'  "$C_BOLD"  "$*" "$C_RESET"; }
ok()      { printf '  %s✓%s %s\n'  "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf '  %s⚠%s %s\n'  "$C_YELLOW" "$C_RESET" "$*"; }
err()     { printf '  %s✗%s %s\n'  "$C_RED" "$C_RESET" "$*" >&2; }
note()    { printf '    %s%s%s\n'  "$C_DIM"  "$*" "$C_RESET"; }

print_help() {
  cat <<'EOF'
zellij-reap — manually trigger a zellij-reaper pass

Usage:
  zellij-reap run         run one normal pass (uses the timer's threshold)
  zellij-reap force-run   bypass the age check; reap any idle/exited session
                          that passes every other safety guard
  zellij-reap --help      show this message

Safety guards always honored (in both modes):
  - never reap a session with a connected client
  - never reap a session with a foreground command in any pane
  - never reap a session whose layout has `command="claude"`
  - obey PROTECT_REGEX
EOF
}

require_install() {
  if [ ! -x "$REAPER" ]; then
    err "reaper not installed at $REAPER"
    note "run: ./install.sh   (or:  cd <repo> && ./install.sh)"
    exit 1
  fi
}

print_log_delta() {
  local mark=$1
  echo
  section "New log entries"
  if [ ! -f "$LOG" ]; then
    note "no log file (zellij not installed?)"
    echo
    return
  fi
  local delta
  delta=$(tail -c "+$((mark + 1))" "$LOG")
  if [ -z "$delta" ]; then
    warn "nothing new was logged"
    note "another reaper run may have been holding the lock — try again in a moment"
    echo
    return
  fi
  printf '%s\n' "$delta" | sed "s/^/  ${C_DIM}|${C_RESET} /"
  echo
}

run_normal() {
  require_install
  if ! systemctl --user list-unit-files "$SERVICE" >/dev/null 2>&1; then
    err "$SERVICE is not installed; run: ./install.sh"
    exit 1
  fi
  section "Running reaper (normal pass)"
  local mark=0
  [ -f "$LOG" ] && mark=$(wc -c <"$LOG")

  if systemctl --user start "$SERVICE"; then
    ok "complete"
  else
    err "reaper failed (check: systemctl --user status $SERVICE)"
    exit 1
  fi
  print_log_delta "$mark"
}

run_force() {
  require_install
  section "Running reaper (force — age check bypassed)"
  local mark=0
  [ -f "$LOG" ] && mark=$(wc -c <"$LOG")

  # Direct invocation with overrides; bypasses the systemd unit so we can
  # set MAX_AGE_HOURS=0. Other guards (attach, busy pane, claude session,
  # PROTECT_REGEX) are unconditional in the reaper script.
  if MAX_AGE_HOURS=0 DRY_RUN=0 "$REAPER"; then
    ok "complete"
  else
    err "reaper failed (see log)"
    exit 1
  fi
  print_log_delta "$mark"
}

case "${1:-}" in
  -h|--help|"")  print_help; exit 0 ;;
  run)           run_normal ;;
  force-run|force) run_force ;;
  *) printf 'unknown argument: %s\n\n' "$1" >&2; print_help >&2; exit 2 ;;
esac
