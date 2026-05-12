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

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[err]\033[0m  %s\n' "$*" >&2; }
ok()   { printf '\033[32m[ok]\033[0m   %s\n' "$*"; }

uninstall() {
  bold "=== uninstalling zellij-reaper ==="
  if systemctl --user list-unit-files zellij-reaper.timer >/dev/null 2>&1; then
    systemctl --user disable --now zellij-reaper.timer 2>/dev/null || true
  fi
  rm -fv "$SCRIPT_PATH" "$SERVICE_PATH" "$TIMER_PATH" 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
  ok "removed (log file ~/.cache/zellij-reaper.log left in place)"
  exit 0
}

[ "${1:-}" = "--uninstall" ] && uninstall

bold "=== preflight ==="

if ! command -v systemctl >/dev/null; then
  err "systemctl not found — systemd is required."
  exit 1
fi
if ! systemctl --user show-environment >/dev/null 2>&1; then
  err "systemd user instance not available."
  err "On WSL, ensure /etc/wsl.conf has [boot] systemd=true and 'wsl --shutdown' once."
  err "On a real machine, log in via systemd-logind (or run 'sudo loginctl enable-linger \$USER')."
  exit 1
fi
ok "systemd user instance available"

for cmd in bash awk grep stat pgrep ps; do
  command -v "$cmd" >/dev/null || { err "missing required tool: $cmd"; exit 1; }
done
ok "core tools present (bash awk grep stat pgrep ps)"

if command -v zellij >/dev/null; then
  ok "zellij found: $(zellij --version 2>/dev/null | head -1)"
else
  warn "zellij not found in PATH."
  warn "Install will proceed; the timer will no-op until zellij is installed later."
fi

if command -v ss >/dev/null; then
  ok "ss found: $(command -v ss)"
else
  warn "ss (iproute2) not found."
  warn "Attach detection will use zellij's session-metadata.kdl only (still safe)."
fi

# Verify source files exist next to this script.
for src in "$REPO_DIR/zellij-reaper.sh" \
           "$REPO_DIR/systemd/zellij-reaper.service" \
           "$REPO_DIR/systemd/zellij-reaper.timer"; do
  [ -f "$src" ] || { err "missing source file: $src"; exit 1; }
done

bold "=== installing files ==="
mkdir -p "$PREFIX_BIN" "$PREFIX_UNIT"

install -m 0755 "$REPO_DIR/zellij-reaper.sh"            "$SCRIPT_PATH"
install -m 0644 "$REPO_DIR/systemd/zellij-reaper.service" "$SERVICE_PATH"
install -m 0644 "$REPO_DIR/systemd/zellij-reaper.timer"   "$TIMER_PATH"
ok "wrote $SCRIPT_PATH"
ok "wrote $SERVICE_PATH"
ok "wrote $TIMER_PATH"

bold "=== enabling timer ==="
systemctl --user daemon-reload
systemctl --user enable --now zellij-reaper.timer >/dev/null
ok "timer enabled and active"

bold "=== enabling linger (so user systemd survives logout) ==="
if loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
  ok "linger already enabled"
else
  if loginctl enable-linger "$USER" 2>/dev/null; then
    ok "linger enabled"
  else
    warn "could not enable linger (try: sudo loginctl enable-linger $USER)"
  fi
fi

bold "=== install complete ==="
echo
systemctl --user list-timers zellij-reaper.timer --no-pager 2>/dev/null | head -2
echo
echo "Log:     ~/.cache/zellij-reaper.log"
echo "Tweak:   $SERVICE_PATH  (edit MAX_AGE_HOURS / DRY_RUN, then 'systemctl --user daemon-reload')"
echo "Run now: systemctl --user start zellij-reaper.service"
echo "Remove:  ./install.sh --uninstall"
