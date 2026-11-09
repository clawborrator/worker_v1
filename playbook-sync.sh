#!/bin/sh
# playbook-sync: keep the worker's playbook checkout on the remote tip
# while the worker runs, so a merged playbook change goes live without
# a container restart.
#
# Started in the background by entrypoint.sh (as the worker user) when
# PLAYBOOK_SYNC_SECONDS is set to a positive integer. Every interval:
#
#   1. git fetch origin
#   2. if the remote ref moved: git merge --ff-only onto it
#   3. on success, run .bench/after-pull.sh from the repo if it exists
#      (per-playbook hook, e.g. re-ingest documents into a search index)
#
# Fast-forward only. This is for workers that never commit into their
# repo (Bench specialists: per-user memory lives on its own volume).
# A checkout that cannot fast-forward is left as-is and logged loudly
# on every attempt: that is an operator problem, not one to auto-resolve.
#
# Usage: playbook-sync <repo-dir> <interval-seconds> [ref]
# Log:   /workspace/.playbook-sync.log (capped at ~1 MB)

REPO_DIR="$1"
INTERVAL="$2"
REF="${3:-}"
LOG="/workspace/.playbook-sync.log"
HOOK_TIMEOUT="${PLAYBOOK_SYNC_HOOK_TIMEOUT:-600}"

log() {
  if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1048576 ]; then
    tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG"
}

case "$INTERVAL" in
  ''|*[!0-9]*) echo "[playbook-sync] interval must be a positive integer, got '$INTERVAL'" >&2; exit 2 ;;
esac
[ "$INTERVAL" -gt 0 ] || exit 0
[ -d "$REPO_DIR/.git" ] || { echo "[playbook-sync] no git checkout at $REPO_DIR" >&2; exit 2; }

if [ -n "$REF" ]; then
  TARGET="origin/$REF"
else
  TARGET="$(git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
fi
[ -n "$TARGET" ] || { log "!! no upstream ref for $REPO_DIR; sync disabled"; exit 2; }

log "started: $REPO_DIR tracking $TARGET every ${INTERVAL}s at $(git -C "$REPO_DIR" rev-parse --short HEAD)"

while :; do
  sleep "$INTERVAL"

  if ! git -C "$REPO_DIR" fetch origin --quiet 2>>"$LOG"; then
    log "!! fetch failed (network or REPO_PAT); staying on $(git -C "$REPO_DIR" rev-parse --short HEAD)"
    continue
  fi

  HEAD_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
  TARGET_SHA="$(git -C "$REPO_DIR" rev-parse "$TARGET" 2>/dev/null)"
  [ -n "$TARGET_SHA" ] || { log "!! $TARGET does not resolve"; continue; }
  [ "$HEAD_SHA" = "$TARGET_SHA" ] && continue

  if git -C "$REPO_DIR" merge --ff-only --quiet "$TARGET" 2>>"$LOG"; then
    log "updated $(echo "$HEAD_SHA" | cut -c1-7) -> $(echo "$TARGET_SHA" | cut -c1-7): $(git -C "$REPO_DIR" log -1 --format=%s)"
    HOOK="$REPO_DIR/.bench/after-pull.sh"
    if [ -f "$HOOK" ]; then
      if (cd "$REPO_DIR" && timeout "$HOOK_TIMEOUT" sh "$HOOK" "$HEAD_SHA" "$TARGET_SHA") >>"$LOG" 2>&1; then
        log "after-pull hook ok"
      else
        log "!! after-pull hook failed (exit $?)"
      fi
    fi
  else
    log "!! cannot fast-forward to $TARGET (local commits or dirty tree); RUNNING STALE PLAYBOOK"
  fi
done
