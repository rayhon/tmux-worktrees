#!/usr/bin/env bash
# wt-up.sh — ONE command to get a working worktree on a branch, over treehouse + herdr.
#
# Does the whole flow so you never hand-run the steps:
#   1. lease a free treehouse slot (auto-wired: offset ports, env, .wrangler mirror)
#   2. put that slot on <branch> — fetch+checkout if it exists (local or origin),
#      else create it
#   3. launch the herdr stack (main + service panes, per-worktree ports), tab
#      named after the branch
#
# Usage:
#   wt-up.sh <branch> [<session>] [<repo-dir>]
#     <branch>    branch to work on (created if it doesn't exist anywhere)
#     <session>   herdr session to launch into (default: fmwt)
#     <repo-dir>  a checkout of the repo whose treehouse pool to lease from
#                 (default: current dir)
#
# Prints the slot path and the herdr attach line. Free it later with wt-down.sh.
set -euo pipefail

BRANCH="${1:?usage: wt-up.sh <branch> [session] [repo-dir]}"
SESSION="${2:-fmwt}"
REPO="${3:-$PWD}"
SC="$(cd "$(dirname "$0")" && pwd)"

command -v treehouse >/dev/null 2>&1 || { echo "treehouse not found" >&2; exit 1; }
[[ -d "$REPO/.git" || -f "$REPO/.git" ]] || { echo "not a git repo: $REPO" >&2; exit 1; }

# 1. lease a slot (path on stdout; banners to stderr)
SLOT=$(cd "$REPO" && treehouse get --lease)
[[ -d "$SLOT" ]] || { echo "treehouse did not return a slot" >&2; exit 1; }
echo "→ leased slot: $SLOT" >&2

# 2. put the slot on the branch. Prefer an existing branch (local or origin);
#    create only if it exists nowhere.
git -C "$SLOT" fetch origin "$BRANCH" >/dev/null 2>&1 || true
if git -C "$SLOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git -C "$SLOT" checkout -q "$BRANCH"
elif git -C "$SLOT" show-ref --verify --quiet "refs/remotes/origin/$BRANCH" \
     || git -C "$SLOT" rev-parse --verify --quiet "origin/$BRANCH" >/dev/null; then
  git -C "$SLOT" checkout -q -B "$BRANCH" --track "origin/$BRANCH"
else
  git -C "$SLOT" checkout -q -b "$BRANCH"
  echo "→ created new branch '$BRANCH'" >&2
fi
echo "→ on branch: $(git -C "$SLOT" rev-parse --abbrev-ref HEAD)" >&2

# 3. launch the herdr stack (branch already checked out → tab shows the branch).
#    HERDR_WT_FRESH=1: this is a NEW task on a (possibly reused) pool slot, so the
#    CLAUDE pane must start a fresh session, not resume the prior occupant's.
( cd "$SLOT" && HERDR_WT_SESSION="$SESSION" HERDR_WT_FRESH=1 bash "$SC/herdr-worktrees.sh" "$SLOT" )

echo "" >&2
echo "✓ ready. attach:  herdr --session $SESSION   → tab ${BRANCH//\//-}" >&2
echo "  free it later:  $SC/wt-down.sh \"$SLOT\" $SESSION" >&2
printf '%s\n' "$SLOT"
