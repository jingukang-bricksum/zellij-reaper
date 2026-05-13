#!/usr/bin/env bash
# zellij-reaper.sh — safely reap stale zellij sessions.
#
# Reaps EXITED and IDLE sessions whose last activity was > threshold ago.
# NEVER reaps a session that has any client attached, has running commands
# in any pane, or was created with a `claude` command in its layout.
# Fail-closed: any uncertainty -> SKIP.
#
# Env overrides:
#   MAX_AGE_HOURS  if set, threshold in hours (takes precedence). Set to 0 to
#                  disable the age check entirely (used by `zellij-reap force-run`).
#   MAX_AGE_DAYS   threshold in days (default 3, used if MAX_AGE_HOURS unset)
#   DRY_RUN        default 1 (set to 0 to actually delete)
#   LOG            default ~/.cache/zellij-reaper.log
#   LOCK           default ~/.cache/zellij-reaper.lock
#   PROTECT_REGEX  default empty; sessions whose name matches will never be reaped
#   AUTO_RENAME    default 1; rename surviving sessions whose name is still the
#                  zellij default (e.g. "marvellous-ocelot") to something derived
#                  from the first pane title or, failing that, the launch cwd.
#                  Set to 0 to disable.

set -euo pipefail

DRY_RUN="${DRY_RUN:-1}"
LOG="${LOG:-$HOME/.cache/zellij-reaper.log}"
LOCK="${LOCK:-$HOME/.cache/zellij-reaper.lock}"
PROTECT_REGEX="${PROTECT_REGEX:-}"
AUTO_RENAME="${AUTO_RENAME:-1}"

# Serialize concurrent runs: a timer-fired pass and a manual run must not both
# enumerate and delete sessions at once. Wait up to 5s for the lock; if another
# instance is still holding it, exit quietly without logging anything.
mkdir -p "$(dirname "$LOCK")"
exec 9>"$LOCK"
flock -w 5 9 || exit 0

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

# Echo the title of the first non-plugin pane (or empty).
first_pane_title() {
  local info=$1
  local f="$info/session-metadata.kdl"
  [ -f "$f" ] || { echo ""; return; }
  awk '
    /^    pane / { in_pane=1; is_plugin=0; title=""; next }
    in_pane && /^    \}/ {
      if (is_plugin==0 && title!="") { print title; exit }
      in_pane=0; next
    }
    in_pane && /is_plugin true/ { is_plugin=1 }
    in_pane && /title "/ { sub(/.*title "/,""); sub(/"$/,""); title=$0 }
  ' "$f"
}

# Echo the launch cwd recorded in session-layout.kdl (or empty).
session_launch_cwd() {
  local info=$1
  local f="$info/session-layout.kdl"
  [ -f "$f" ] || { echo ""; return; }
  awk '/^    cwd "/ { sub(/.*cwd "/,""); sub(/"$/,""); print; exit }' "$f"
}

# Sanitize a free-form pane title into a zellij-friendly session name.
# Strips Braille spinners and dingbats (claude/zellij decoration), then
# replaces everything that isn't a Unicode letter/number/underscore/dash with
# a single dash. Korean (and any non-ASCII letter) is preserved so distinct
# Korean-titled sessions get distinct names instead of all collapsing to the
# launch cwd. Falls back to an ASCII-only sed pass if perl is not installed.
# Returns empty string for uninformative input.
sanitize_name() {
  # Truncates to a byte length safe for zellij's Unix-domain socket path.
  # The runtime path is "/run/user/<uid>/zellij/contract_version_1/<name>",
  # and Linux caps that path at ~107 bytes. With UID=1000 the fixed prefix
  # is 41 bytes, leaving 66 for the name. We need room for our own suffixes
  # (_MMDD-HHMM = 10 bytes, plus an optional -NN collision tail = 3 bytes),
  # so the base is capped at 50 bytes here. Korean glyphs are 3 bytes each
  # in UTF-8, so a char-based 50-char limit could blow well past that —
  # we walk codepoints and stop before the byte budget runs out.
  local raw=$1 out
  if command -v perl >/dev/null 2>&1; then
    out=$(printf '%s' "$raw" | perl -CSDA -e '
      use Encode qw(encode_utf8);
      my $s = do { local $/; <STDIN> };
      $s =~ s/^\s+//;
      $s =~ s/[\x{2600}-\x{27BF}\x{2800}-\x{28FF}]+//g;  # symbols, dingbats, braille
      $s =~ s/^[^\p{L}\p{N}]+//;
      $s =~ s/[^\p{L}\p{N}_-]+/-/g;
      $s =~ s/-+/-/g;
      $s =~ s/^-+|-+$//g;
      $s = lc $s;
      my $max_bytes = 50;
      my $bytes = 0;
      my $out = "";
      for my $c (split //, $s) {
        my $cb = length(encode_utf8($c));
        last if $bytes + $cb > $max_bytes;
        $out .= $c;
        $bytes += $cb;
      }
      $out =~ s/-+$//;  # the truncation may have stranded a trailing dash
      print $out;
    ' 2>/dev/null)
  else
    # shellcheck disable=SC2018,SC2019  # ASCII-only fallback (1 byte per char)
    out=$(printf '%s' "$raw" \
      | sed -E 's|[^a-zA-Z0-9_-]+|-|g; s|-+|-|g; s|^-||; s|-$||' \
      | tr 'A-Z' 'a-z')
    out=${out:0:50}
    out=${out%-}
  fi
  case "$out" in
    "" | pane-* | tab-* | bash | zsh | sh | fish | dash) echo ""; return ;;
  esac
  printf '%s' "$out"
}

# Decide a "good" new name: pane title first, fallback to cwd basename.
suggested_name() {
  local info=$1 candidate
  candidate=$(sanitize_name "$(first_pane_title "$info")")
  if [ -n "$candidate" ]; then
    printf '%s' "$candidate"
    return
  fi
  local cwd
  cwd=$(session_launch_cwd "$info")
  [ -z "$cwd" ] && return
  sanitize_name "$(basename "$cwd")"
}

# Format the session's last-activity time as "_MMDD-HHMM" for use as a suffix.
# Falls back to "now" if the activity time is unreadable.
activity_suffix() {
  local info=$1 ts
  ts=$(latest_activity "$info")
  [ -n "$ts" ] || ts=$(date +%s)
  date -d "@$ts" '+_%m%d-%H%M'
}

# Try to rename a surviving session to something derived from its content.
# Echoes a status line (caller logs it). No-op when AUTO_RENAME=0, when the
# current name is not the zellij default pattern, or when no better name can
# be derived.
maybe_rename() {
  # Always return 0 so the caller's `var=$(maybe_rename ...)` does not trip
  # `set -e` when we decide there is nothing to rename.
  local name=$1 info_dir=$2

  [ "$AUTO_RENAME" = 1 ] || return 0
  # No name-pattern gate: every surviving session that isn't attached or
  # otherwise filtered by the caller is eligible. Use PROTECT_REGEX to keep
  # specific names untouched.

  local base desired final
  base=$(suggested_name "$info_dir")
  [ -z "$base" ] && return 0
  desired="${base}$(activity_suffix "$info_dir")"
  [ "$desired" = "$name" ] && return 0

  # Collision avoidance against the *visible* session list. zellij also keeps
  # an internal cache of recently-used names that aren't on disk anymore and
  # will reject a rename to those with "A session by this name already exists";
  # we handle that by retrying with -2, -3, ... below.
  local existing n=2
  existing=$(zellij list-sessions -n -s 2>/dev/null || true)
  final=$desired
  while printf '%s\n' "$existing" | grep -qFx "$final"; do
    final="${desired}-${n}"
    n=$((n+1))
    [ "$n" -gt 99 ] && return 0
  done

  if [ "$DRY_RUN" = 1 ]; then
    echo "  -> DRY_RUN: would rename '$name' → '$final'"
    return 0
  fi

  local err
  while [ "$n" -le 99 ]; do
    if err=$(zellij --session "$name" action rename-session "$final" 2>&1); then
      echo "  -> renamed: $name → $final"
      return 0
    fi
    # Only retry on the specific "already exists" case; bail on anything else.
    case "$err" in
      *"already exists"*)
        final="${desired}-${n}"
        n=$((n+1))
        ;;
      *)
        echo "  -> rename FAILED: $name → $final :: $err"
        return 0
        ;;
    esac
  done
  echo "  -> rename gave up: $name → $desired (too many collisions)"
  return 0
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

  # Claude-session guard only protects RUNNING sessions. An EXITED claude
  # session is no longer doing any work, so let the normal age threshold
  # decide whether it stays around (so resurrect-able) or gets reaped.
  if [ "$status" != "EXITED" ]; then
    local srv_for_claude=""
    if [ -S "$RUNTIME_DIR/$name" ]; then
      srv_for_claude=$(server_pid_for "$RUNTIME_DIR/$name")
    fi
    if is_claude_session "$info_dir" "$srv_for_claude"; then
      echo "SKIP claude session (protected)"
      return
    fi
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
    # threshold_secs == 0 means "age check disabled" (force mode); never SKIP
    # on age in that case, even if mtime is in the future due to live updates.
    if [ "$threshold_secs" -gt 0 ] && [ "$age" -lt "$threshold_secs" ]; then
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

  if [ "$threshold_secs" -gt 0 ] && [ "$age" -lt "$threshold_secs" ]; then
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

  local line name status decision out titles rename_msg
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
    elif [ "$status" = "RUNNING" ]; then
      # Survived this pass — try to give it a more meaningful name.
      # Don't disturb sessions with attached clients or any uncertainty.
      case "$decision" in
        "SKIP client attached"*|"SKIP attach-check uncertain"*|"SKIP protected by PROTECT_REGEX")
          : ;;
        *)
          rename_msg=$(maybe_rename "$name" "$SESSION_INFO_DIR/$name")
          [ -n "$rename_msg" ] && log "$rename_msg"
          ;;
      esac
    fi
  done <<<"$sessions_raw"

  log "=== reaper end ==="
}

main "$@"
