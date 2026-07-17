#!/usr/bin/env bash
# wt-down.sh — finish a task: save context, release the branch, and return the
# slot to the treehouse pool so it can be reassigned — WITHOUT killing herdr.
#
# This is safe because the launcher now starts the herdr server from $HOME (not
# the slot), so `treehouse return`'s cwd-sweep only reaps the slot's own pane
# shell, never the herdr session server. The session stays up and the tab stays
# viewable; the slot goes back to the pool for the next task.
#
# Usage:
#   wt-down.sh <slot-path> [<session>]
set -euo pipefail

SLOT="${1:?usage: wt-down.sh <slot-path> [session]}"
SESSION="${2:-fmwt}"
SLOT=$(cd "$SLOT" && pwd -P)
SC="$(cd "$(dirname "$0")" && pwd)"
# repo that owns this slot's pool (for `treehouse return`), derived from git.
REPO=$(cd "$(git -C "$SLOT" rev-parse --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd -P) || REPO=""

H() { HERDR_SESSION="$SESSION" herdr "$@" --session "$SESSION"; }

# 1. save this branch's Claude context (keyed by branch; the pooled slot path is
#    reused, so we archive per branch). Non-destructive copy.
BR=$(git -C "$SLOT" symbolic-ref --short HEAD 2>/dev/null || true)
if [[ -n "$BR" ]]; then
  PROJ="$HOME/.claude/projects/$(printf '%s' "$SLOT" | sed 's#[/.]#-#g')"
  if compgen -G "$PROJ/*.jsonl" >/dev/null 2>&1; then
    ARCH="$HOME/.claude/wt-sessions/${BR//\//-}"
    mkdir -p "$ARCH"; rm -f "$ARCH"/*.jsonl 2>/dev/null || true
    cp "$PROJ"/*.jsonl "$ARCH"/ 2>/dev/null && echo "→ saved Claude context for branch '$BR'" >&2
  fi
fi

# 2. release the branch (detach) so it can be checked out elsewhere.
git -C "$SLOT" checkout -q --detach 2>/dev/null || true

# 3. return the slot to the pool so treehouse can reassign it. Safe: the herdr
#    server runs from $HOME, so this reaps only the slot's pane shell.
if [[ -n "$REPO" ]]; then
  ( cd "$REPO" && treehouse return "$SLOT" --force ) 2>&1 | grep -iE 'returned|pool' >&2 || true
else
  echo "⚠ could not derive repo for '$SLOT' — return it manually: treehouse return \"$SLOT\" --force" >&2
fi

# 4. relabel the surviving tab to its standby name (free-<slot>) so it reads as
#    available. Runs from REPO (needs its yaml); only renames, never closes.
if [[ -n "$REPO" ]]; then
  ( cd "$REPO" && HERDR_WT_SESSION="$SESSION" bash "$SC/herdr-worktrees.sh" --sync-labels ) >/dev/null 2>&1 || true
fi

echo "✓ '${BR:-worktree}' done — context saved, slot returned to pool, herdr still up." >&2
