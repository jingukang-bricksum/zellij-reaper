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
  zellij-reap run                run one normal pass (uses the timer's threshold)
  zellij-reap force-run          bypass the age check; reap any idle/exited
                                 session that passes every other safety guard
  zellij-reap recover [--dry-run]
                                 diagnose and repair sessions whose name made
                                 the runtime socket path exceed Linux's 107-byte
                                 limit (most often: too-long auto-renamed names
                                 from older releases). --dry-run reports only.
  zellij-reap --help             show this message

Safety guards always honored (run / force-run):
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

run_recover() {
  local dry=0
  [ "${1:-}" = "--dry-run" ] && dry=1

  local runtime_dir="/run/user/$UID/zellij/contract_version_1"
  local info_dir="$HOME/.cache/zellij/contract_version_1/session_info"
  local sock_limit=107
  local prefix_len=$((${#runtime_dir} + 1))    # +1 for the trailing slash
  local name_budget=$((sock_limit - prefix_len))

  section "Scanning"
  note "socket path limit: ${sock_limit} B"
  note "name byte budget:  ${name_budget} B  (path prefix is ${prefix_len} B)"
  [ "$dry" = 1 ] && note "DRY RUN — no changes will be made"

  # Collect candidate names from both `zellij ls` and disk, deduped.
  local -A seen=()
  local sessions=()
  local raw line n
  if raw=$(zellij list-sessions -n 2>/dev/null); then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      n=$(awk '{print $1}' <<<"$line")
      [ -n "${seen[$n]:-}" ] && continue
      seen[$n]=1
      sessions+=("$n")
    done <<<"$raw"
  fi
  if [ -d "$info_dir" ]; then
    local d
    for d in "$info_dir"/*/; do
      [ -d "$d" ] || continue
      n=$(basename "$d")
      [ -n "${seen[$n]:-}" ] && continue
      seen[$n]=1
      sessions+=("$n")
    done
  fi

  if [ "${#sessions[@]}" -eq 0 ]; then
    ok "no sessions found"
    echo
    return 0
  fi

  section "Diagnose"
  local broken=() s nb total
  for s in "${sessions[@]}"; do
    nb=$(printf '%s' "$s" | wc -c)
    total=$((nb + prefix_len))
    if [ "$total" -gt "$sock_limit" ]; then
      warn "$s"
      note "  name=${nb} B, full path=${total} B  ($((total - sock_limit)) over)"
      broken+=("$s")
    fi
  done

  if [ "${#broken[@]}" -eq 0 ]; then
    ok "all ${#sessions[@]} session(s) within budget"
    echo
    return 0
  fi

  echo
  if [ "$dry" = 1 ]; then
    section "Plan (dry run)"
    for s in "${broken[@]}"; do
      note "would: zellij delete-session -f, then kill server if alive, then rm disk traces  →  '$s'"
    done
    echo
    return 0
  fi

  section "Repair"
  local srv_pid acted cmdline pid
  for s in "${broken[@]}"; do
    acted=0

    # Diagnostic up front: show what's actually there.
    note "pre-state:"
    if [ -d "$info_dir/$s" ]; then
      note "  cache dir present: $info_dir/$s"
    else
      note "  cache dir absent"
    fi
    if [ -e "$runtime_dir/$s" ]; then
      note "  socket present:    $runtime_dir/$s"
    else
      note "  socket absent"
    fi
    # Find server PID. The strict `$` anchor would miss any server whose
    # cmdline has trailing args (older zellij, weird wrappers), so we list
    # all zellij --server processes and pick the one whose cmdline contains
    # this session's runtime path.
    srv_pid=""
    while IFS= read -r pid; do
      [ -z "$pid" ] && continue
      cmdline=$(tr '\0' ' ' </proc/"$pid"/cmdline 2>/dev/null) || continue
      case "$cmdline" in
        *"$runtime_dir/$s"*) srv_pid=$pid; break ;;
      esac
    done < <(pgrep -f "zellij --server" 2>/dev/null || true)
    if [ -n "$srv_pid" ]; then
      note "  server pid:        $srv_pid"
    else
      note "  no server process"
    fi

    # 1) Kill the server FIRST. The CLI can't reach it through a broken
    #    socket, and if we leave it running it will rewrite the cache dir
    #    we're about to remove (likely the cause of the "deleted via CLI
    #    but the entry came back" report).
    if [ -n "$srv_pid" ]; then
      if kill "$srv_pid" 2>/dev/null; then
        sleep 1
        if kill -0 "$srv_pid" 2>/dev/null; then
          kill -9 "$srv_pid" 2>/dev/null && note "  escalated to SIGKILL"
          sleep 0.5
        fi
        if ! kill -0 "$srv_pid" 2>/dev/null; then
          ok "killed server pid $srv_pid"
          acted=1
        else
          err "could not kill server pid $srv_pid (try running with elevated privileges)"
        fi
      else
        err "kill failed for pid $srv_pid"
      fi
    fi

    # 2) Try the CLI delete. Don't trust the exit code — check whether the
    #    cache dir actually went away. If it did and no server was left to
    #    recreate it, we're done. Otherwise fall through to disk cleanup.
    zellij delete-session "$s" -f >/dev/null 2>&1 || true
    sleep 0.3
    if [ ! -d "$info_dir/$s" ] && [ ! -e "$runtime_dir/$s" ]; then
      ok "cleaned via CLI: $s"
      acted=1
      continue
    fi

    # 3) Manual cleanup of anything left. The ":?" guard aborts the rm if
    #    the variable ever expands to empty (belt and suspenders against
    #    accidental `rm -rf /<empty>/name`).
    if [ -d "$info_dir/$s" ]; then
      if rm -rf "${info_dir:?}/$s" 2>/dev/null; then
        ok "removed cache: $info_dir/$s"
        acted=1
      else
        err "could not remove $info_dir/$s"
      fi
    fi
    if [ -e "$runtime_dir/$s" ]; then
      if rm -f "${runtime_dir:?}/$s" 2>/dev/null; then
        ok "removed socket: $runtime_dir/$s"
        acted=1
      else
        err "could not remove $runtime_dir/$s"
      fi
    fi

    # 4) Final verification — anything still there?
    sleep 0.3
    if [ -d "$info_dir/$s" ] || [ -e "$runtime_dir/$s" ]; then
      err "traces still present for '$s'"
      [ -d "$info_dir/$s" ] && note "  remaining: $info_dir/$s"
      [ -e "$runtime_dir/$s" ] && note "  remaining: $runtime_dir/$s"
      # Walk live zellij --server processes again to find the culprit.
      while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        cmdline=$(tr '\0' ' ' </proc/"$pid"/cmdline 2>/dev/null) || continue
        case "$cmdline" in
          *"$s"*)
            note "  server pid $pid is still alive (cmdline: $cmdline)"
            note "  → run: kill -9 $pid   then 'zellij-reap recover' again"
            break ;;
        esac
      done < <(pgrep -f "zellij --server" 2>/dev/null || true)
    elif [ "$acted" -eq 1 ]; then
      ok "cleaned up: $s"
    else
      note "nothing was acted on for '$s' (already gone?)"
    fi
  done

  echo
  section "Done"
  ok "${#broken[@]} broken session(s) processed"
  echo
}

case "${1:-}" in
  -h|--help|"")  print_help; exit 0 ;;
  run)           run_normal ;;
  force-run|force) run_force ;;
  recover)       shift; run_recover "$@" ;;
  *) printf 'unknown argument: %s\n\n' "$1" >&2; print_help >&2; exit 2 ;;
esac
