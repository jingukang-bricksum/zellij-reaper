#!/usr/bin/env bash
# install.sh — install/upgrade zellij-reaper on this machine.
# Idempotent: safe to re-run.
#
# Hard requirements: bash 4+, systemd user instance, awk, grep, stat, pgrep
# Soft requirements:
#   - zellij : if missing, install proceeds and the timer becomes a no-op
#              until zellij is installed later.
#   - ss     : if missing, attach detection falls back to zellij's metadata
#              only (still safe — that is the primary signal).
#
# Usage:
#   ./install.sh                # install / upgrade
#   ./install.sh --uninstall    # remove everything

set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREFIX_BIN="$HOME/.local/bin"
PREFIX_UNIT="$HOME/.config/systemd/user"
SCRIPT_PATH="$PREFIX_BIN/zellij-reaper.sh"
SERVICE_PATH="$PREFIX_UNIT/zellij-reaper.service"
TIMER_PATH="$PREFIX_UNIT/zellij-reaper.timer"

# --- colors (auto-disable on non-tty or NO_COLOR=1) ---
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m';   C_RESET=$'\033[0m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
  C_CYAN=$'\033[36m'
else
  C_BOLD= C_DIM= C_RESET= C_GREEN= C_YELLOW= C_RED= C_CYAN=
fi

section() { printf '\n%s▸ %s%s\n'  "$C_BOLD"  "$*" "$C_RESET"; }
ok()      { printf '  %s✓%s %s\n'  "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf '  %s⚠%s %s\n'  "$C_YELLOW" "$C_RESET" "$*"; }
err()     { printf '  %s✗%s %s\n'  "$C_RED" "$C_RESET" "$*" >&2; }
note()    { printf '    %s%s%s\n'  "$C_DIM"  "$*" "$C_RESET"; }
hr()      {
  local w=60
  printf '%s' "$C_DIM"
  printf '─%.0s' $(seq 1 "$w")
  printf '%s\n' "$C_RESET"
}
banner()  {
  hr
  printf '  %szellij-reaper%s %sinstaller%s\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
  hr
}

uninstall() {
  banner
  section "Uninstalling"
  if systemctl --user list-unit-files zellij-reaper.timer >/dev/null 2>&1; then
    systemctl --user disable --now zellij-reaper.timer >/dev/null 2>&1 || true
    ok "timer disabled"
  fi
  local removed=0
  for f in "$SCRIPT_PATH" "$SERVICE_PATH" "$TIMER_PATH"; do
    [ -f "$f" ] && rm -f "$f" && { ok "removed $(dim_path "$f")"; removed=$((removed+1)); }
  done
  systemctl --user daemon-reload 2>/dev/null || true
  [ "$removed" = 0 ] && warn "nothing to remove"
  note "log file ~/.cache/zellij-reaper.log left in place"
  echo
  exit 0
}

# Shorten $HOME in a path to ~ for display.
dim_path() { printf '%s' "${1/#$HOME/\~}"; }

# Compute the next-fire time from LastTriggerUSec + 1h (matches OnUnitActiveSec
# in the timer unit). systemd's NextElapseUSecRealtime is unreliable on some
# environments (WSL2, oneshot-after-enable), but LastTriggerUSec is stable.
next_fire_time() {
  local last
  last=$(systemctl --user show zellij-reaper.timer --value -p LastTriggerUSec 2>/dev/null || true)
  if [ -z "$last" ] || [ "$last" = "n/a" ]; then
    echo "every 1h"
    return
  fi
  local last_ts now_ts next_ts diff
  last_ts=$(date -d "$last" +%s 2>/dev/null || echo "")
  if [ -z "$last_ts" ]; then
    echo "every 1h"
    return
  fi
  now_ts=$(date +%s)
  next_ts=$((last_ts + 3600))
  diff=$((next_ts - now_ts))
  if   [ "$diff" -le 0 ];    then echo "every 1h (next: due now)"
  elif [ "$diff" -lt 60 ];   then echo "every 1h (next in ${diff}s)"
  elif [ "$diff" -lt 3600 ]; then echo "every 1h (next in $((diff/60))m at $(date -d "@$next_ts" '+%H:%M'))"
  else                            echo "every 1h (next at $(date -d "@$next_ts" '+%a %H:%M'))"
  fi
}

[ "${1:-}" = "--uninstall" ] && uninstall

banner

# --- preflight ---
section "Preflight"

if ! command -v systemctl >/dev/null; then
  err "systemctl not found — systemd is required."
  exit 1
fi
if ! systemctl --user show-environment >/dev/null 2>&1; then
  err "systemd user instance not available"
  note "WSL: set [boot] systemd=true in /etc/wsl.conf and run 'wsl --shutdown'"
  note "host: log in via systemd-logind (or 'sudo loginctl enable-linger \$USER')"
  exit 1
fi
ok "systemd user instance"

missing_core=""
for cmd in bash awk grep stat pgrep ps; do
  command -v "$cmd" >/dev/null || missing_core="$missing_core $cmd"
done
if [ -n "$missing_core" ]; then
  err "missing required tools:$missing_core"; exit 1
fi
ok "core tools (bash, awk, grep, stat, pgrep, ps)"

if command -v zellij >/dev/null; then
  ok "zellij $(zellij --version 2>/dev/null | awk '{print $2}')"
else
  warn "zellij not found in PATH"
  note "install will proceed; the timer will no-op until zellij is installed later"
fi

if command -v ss >/dev/null; then
  ok "ss (iproute2)"
else
  warn "ss (iproute2) not found"
  note "attach detection will use zellij's session-metadata.kdl only (still safe)"
fi

for src in "$REPO_DIR/zellij-reaper.sh" \
           "$REPO_DIR/systemd/zellij-reaper.service" \
           "$REPO_DIR/systemd/zellij-reaper.timer"; do
  [ -f "$src" ] || { err "missing source file: $src"; exit 1; }
done

# --- install files ---
section "Installing files"
mkdir -p "$PREFIX_BIN" "$PREFIX_UNIT"

install -m 0755 "$REPO_DIR/zellij-reaper.sh"              "$SCRIPT_PATH"
install -m 0644 "$REPO_DIR/systemd/zellij-reaper.service" "$SERVICE_PATH"
install -m 0644 "$REPO_DIR/systemd/zellij-reaper.timer"   "$TIMER_PATH"
ok "$(dim_path "$SCRIPT_PATH")"
ok "$(dim_path "$SERVICE_PATH")"
ok "$(dim_path "$TIMER_PATH")"

# --- enable timer ---
section "Enabling timer"
systemctl --user daemon-reload
ok "daemon reloaded"
if systemctl --user enable --now zellij-reaper.timer >/dev/null 2>&1; then
  ok "zellij-reaper.timer enabled and active"
else
  err "failed to enable timer"
  exit 1
fi

# --- linger ---
section "Enabling linger"
if loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
  ok "linger already enabled"
elif loginctl enable-linger "$USER" 2>/dev/null; then
  ok "linger enabled"
else
  warn "could not enable linger"
  note "run: sudo loginctl enable-linger $USER"
fi

# --- summary ---
echo
hr
printf '  %sInstall complete%s\n' "$C_BOLD" "$C_RESET"
hr
printf '  %s%-12s%s%s\n' "$C_CYAN" "schedule:"  "$C_RESET" "  $(next_fire_time)"
printf '  %s%-12s%s%s\n' "$C_CYAN" "log:"       "$C_RESET" "  $(dim_path "$HOME/.cache/zellij-reaper.log")"
printf '  %s%-12s%s%s\n' "$C_CYAN" "configure:" "$C_RESET" "  $(dim_path "$SERVICE_PATH")"
printf '                %s(edit MAX_AGE_HOURS or DRY_RUN, then daemon-reload)%s\n' "$C_DIM" "$C_RESET"
printf '  %s%-12s%s%s\n' "$C_CYAN" "run now:"   "$C_RESET" "  systemctl --user start zellij-reaper.service"
printf '  %s%-12s%s%s\n' "$C_CYAN" "uninstall:" "$C_RESET" "  ./install.sh --uninstall"
hr
echo
