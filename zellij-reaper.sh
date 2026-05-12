#!/usr/bin/env bash
# zellij-reaper.sh — safely reap stale zellij sessions.
#
# Reaps EXITED and IDLE sessions whose last activity was > threshold ago.
# NEVER reaps a session that has any client attached, has running commands
# in any pane, or was created with a `claude` command in its layout.
# Fail-closed: any uncertainty -> SKIP.
#
# Env overrides:
#   MAX_AGE_HOURS  if set, threshold in hours (takes precedence)
#   MAX_AGE_DAYS   threshold in days (default 3, used if MAX_AGE_HOURS unset)
#   DRY_RUN        default 1 (set to 0 to actually delete)
#   LOG            default ~/.cache/zellij-reaper.log
#   PROTECT_REGEX  default empty; sessions whose name matches will never be reaped

set -euo pipefail

DRY_RUN="${DRY_RUN:-1}"
LOG="${LOG:-$HOME/.cache/zellij-reaper.log}"
PROTECT_REGEX="${PROTECT_REGEX:-}"

RUNTIME_DIR="/run/user/$UID/zellij/contract_version_1"
SESSION_INFO_DIR="$HOME/.cache/zellij/contract_version_1/session_info"

now=$(date +%s)
if [ -n "${MAX_AGE_HOURS:-}" ]; then
  threshold_secs=$((MAX_AGE_HOURS * 3600))
  threshold_label="${MAX_AGE_HOURS}h"
else
  MAX_AGE_DAYS="${MAX_AGE_DAYS:-3}"
  threshold_secs=$((MAX_AGE_DAYS * 86400))
  threshold_label="${MAX_AGE_DAYS}d"
fi

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

server_pid_for() {
  local sock=$1
  pgrep -f "zellij --server ${sock}\$" 2>/dev/null | head -1
}

latest_activity() {
  local info=$1
  [ -d "$info" ] || { echo ""; return; }
  local m
  m=$(stat -c %Y "$info"/* 2>/dev/null | sort -n | tail -1)
  echo "${m:-}"
}

meta_field() {
  local info=$1 key=$2
  local f="$info/session-metadata.kdl"
  [ -f "$f" ] || { echo ""; return; }
  awk -v k="$key" '$1==k && NF>=2 {print $2; exit}' "$f"
}

client_attached() {
  local info=$1 sock=$2 srv=$3

  local meta_clients
  meta_clients=$(meta_field "$info" "connected_clients")
  if [ -n "$meta_clients" ] && [ "$meta_clients" -gt 0 ] 2>/dev/null; then
    echo "metadata:connected_clients=$meta_clients" >&2
    return 0
  fi

  if command -v ss >/dev/null; then
    local peer_inodes
    peer_inodes=$(ss -xp 2>/dev/null \
      | awk -v s="$sock" '$2=="ESTAB" && $5==s {print $8}')
    local peer holders h
    for peer in $peer_inodes; do
      holders=$(ss -xp 2>/dev/null \
        | awk -v ino="$peer" '$6==ino' \
        | grep -oE 'pid=[0-9]+' | sort -u | cut -d= -f2)
      [ -z "$holders" ] && return 2
      for h in $holders; do
        if [ "$h" != "$srv" ]; then
          echo "ss:peer-holder-pid=$h" >&2
          return 0
        fi
      done
    done
  fi

  if [ -z "$meta_clients" ] && ! command -v ss >/dev/null; then
    return 2
  fi
  return 1
}

is_claude_session() {
  local info=$1 srv=${2:-}
  local layout="$info/session-layout.kdl"

  if [ -f "$layout" ]; then
    grep -qE 'command="[^"]*\<claude\>' "$layout" 2>/dev/null && return 0
    grep -qE 'args[[:space:]]+".*\<claude\>' "$layout" 2>/dev/null && return 0
  fi

  if [ -n "$srv" ]; then
    local pid
    for pid in $(pgrep -P "$srv" 2>/dev/null || true); do
      local p
      for p in "$pid" $(pgrep -P "$pid" 2>/dev/null || true); do
        local comm
        comm=$(cat /proc/"$p"/comm 2>/dev/null || true)
        [ "$comm" = "claude" ] && return 0
      done
    done
  fi
  return 1
}

pane_titles_summary() {
  local info=$1
  local f="$info/session-metadata.kdl"
  [ -f "$f" ] || { echo ""; return; }
  awk '
    /^    pane / { in_pane=1; is_plugin=0; title=""; next }
    in_pane && /^    \}/ {
      if (is_plugin==0 && title!="") printf "%s%s", (n++?"|":""), substr(title,1,40)
      in_pane=0; next
    }
    in_pane && /is_plugin true/  { is_plugin=1 }
    in_pane && /title "/         { sub(/.*title "/,""); sub(/"$/,""); title=$0 }
    END { print "" }
  ' "$f"
}

decide() {
  local name=$1 status=$2

  if [ -n "$PROTECT_REGEX" ] && [[ "$name" =~ $PROTECT_REGEX ]]; then
    echo "SKIP protected by PROTECT_REGEX"
    return
  fi

  local info_dir="$SESSION_INFO_DIR/$name"
  if [ ! -d "$info_dir" ]; then
    echo "SKIP no session_info dir (unknown state)"
    return
  fi

  local srv_for_claude=""
  if [ -S "$RUNTIME_DIR/$name" ]; then
    srv_for_claude=$(server_pid_for "$RUNTIME_DIR/$name")
  fi
  if is_claude_session "$info_dir" "$srv_for_claude"; then
    echo "SKIP claude session (protected)"
    return
  fi

  local last_active
  last_active=$(latest_activity "$info_dir")
  if [ -z "$last_active" ]; then
    echo "SKIP cannot read activity time"
    return
  fi
  local age=$((now - last_active))
  local age_h=$((age / 3600))
  local age_d=$((age / 86400))

  if [ "$status" = "EXITED" ]; then
    if [ "$age" -lt "$threshold_secs" ]; then
      echo "SKIP EXITED but only ${age_h}h old"
      return
    fi
    echo "REAP EXITED, ${age_d}d ${age_h}h since last activity"
    return
  fi

  local sock="$RUNTIME_DIR/$name"
  if [ ! -S "$sock" ]; then
    echo "SKIP socket file missing for running session"
    return
  fi

  local srv_pid
  srv_pid=$(server_pid_for "$sock")
  if [ -z "$srv_pid" ]; then
    echo "SKIP server PID not found"
    return
  fi

  local attach_reason
  attach_reason=$(client_attached "$info_dir" "$sock" "$srv_pid" 2>&1 >/dev/null)
  case $? in
    0) echo "SKIP client attached ($attach_reason)"; return ;;
    2) echo "SKIP attach-check uncertain"; return ;;
  esac

  local shells sh busy=0
  shells=$(pgrep -P "$srv_pid" 2>/dev/null || true)
  if [ -z "$shells" ]; then
    echo "SKIP server has no shell children (transient)"
    return
  fi
  for sh in $shells; do
    if [ -n "$(pgrep -P "$sh" 2>/dev/null || true)" ]; then
      busy=1
      break
    fi
  done
  if [ "$busy" -eq 1 ]; then
    echo "SKIP IDLE check failed (running command in pane)"
    return
  fi

  if [ "$age" -lt "$threshold_secs" ]; then
    echo "SKIP IDLE but only ${age_h}h since last activity"
    return
  fi

  echo "REAP IDLE, ${age_d}d ${age_h}h since last activity"
}

main() {
  mkdir -p "$(dirname "$LOG")"
  log "=== reaper start (DRY_RUN=$DRY_RUN, threshold=$threshold_label) ==="

  if ! command -v zellij >/dev/null; then
    log "zellij not installed, nothing to do"
    log "=== reaper end ==="
    return 0
  fi

  local sessions_raw
  if ! sessions_raw=$(zellij list-sessions -n 2>/dev/null); then
    log "zellij list-sessions failed (no sessions or zellij broken)"
    log "=== reaper end ==="
    return 0
  fi
  if [ -z "$sessions_raw" ]; then
    log "no sessions"
    log "=== reaper end ==="
    return 0
  fi

  local line name status decision out titles
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    name=$(awk '{print $1}' <<<"$line")
    if grep -q EXITED <<<"$line"; then status=EXITED; else status=RUNNING; fi

    decision=$(decide "$name" "$status")
    titles=$(pane_titles_summary "$SESSION_INFO_DIR/$name")
    log "$name [$status] panes={${titles}} :: $decision"

    if [[ "$decision" == REAP* ]]; then
      if [ "$DRY_RUN" = 1 ]; then
        log "  -> DRY_RUN: would run: zellij delete-session $name -f"
      else
        if out=$(zellij delete-session "$name" -f 2>&1); then
          log "  -> deleted: $name :: ${out:-ok}"
        else
          log "  -> FAILED: $name :: $out"
        fi
      fi
    fi
  done <<<"$sessions_raw"

  log "=== reaper end ==="
}

main "$@"
