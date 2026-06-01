#!/usr/bin/env bash
# Block until <WORKTREE_DIR>/.npm-install.ok exists.
# - If install is still running (live pidfile): just wait.
# - If install died mid-flight (no ok, no live pid): auto-restart it
#   detached, then continue waiting.
#
# Called by the per-service pane cmd in tmux-worktrees.sh.
# Usage: wait-for-install.sh <worktree-dir>

set -u

DIR="${1:-}"
if [[ -z "$DIR" ]]; then
  echo "wait-for-install.sh: missing worktree dir" >&2
  exit 1
fi

OK="$DIR/.npm-install.ok"
PIDFILE="$DIR/.npm-install.pid"
LOG="$DIR/.npm-install.log"

# Fast path: already done.
[[ -f "$OK" ]] && exit 0

start_install_bg() {
  local body
  body="echo \$\$ > '$PIDFILE'; trap 'rm -f \"$PIDFILE\"' EXIT; cd '$DIR' && npm install && touch '$OK'"

  # Prefer setsid (fully detached new session) if available; else nohup.
  if command -v setsid >/dev/null 2>&1; then
    ( setsid bash -c "$body" >>"$LOG" 2>&1 </dev/null & disown ) >/dev/null 2>&1
  else
    ( nohup bash -c "$body" >>"$LOG" 2>&1 </dev/null & disown ) >/dev/null 2>&1
  fi
}

while [[ ! -f "$OK" ]]; do
  if [[ -f "$PIDFILE" ]]; then
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "  waiting for npm install (tail $LOG)..."
      sleep 3
      continue
    fi
  fi
  echo "  npm install not running and no success sentinel — restarting in background..."
  rm -f "$PIDFILE" 2>/dev/null
  start_install_bg
  sleep 3
done

echo "  ✓ npm install complete"
