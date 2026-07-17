#!/usr/bin/env bash
# herdr-relabel.sh — relabel the herdr tab for a worktree to its CURRENT git
# branch, across every running herdr session. Idempotent; safe to call anytime.
#
# The launcher labels a tab at spawn time, but a later `git checkout`/`git switch`
# inside the worktree leaves the tab showing the old branch. This reconciles the
# tab label to the live branch. A git `post-checkout` hook (installed by wt-up)
# calls this on every branch switch so labels never go stale.
#
# Usage:  herdr-relabel.sh [<worktree-dir>]   (default: $PWD)
set -euo pipefail

DIR="${1:-$PWD}"
command -v herdr >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# resolve to the worktree TOP (physical), which is where the main pane sits.
TOP=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null) || exit 0
TOP=$(cd "$TOP" && pwd -P)

# current branch → label (slashes → dashes); detached HEAD ⇒ free[-<slot>].
BR=$(git -C "$TOP" symbolic-ref --short -q HEAD 2>/dev/null || true)
if [[ -z "$BR" ]]; then
  slot=$(printf '%s\n' "$TOP" | sed -nE 's#.*/\.treehouse/[^/]+/([0-9]+)(/|$).*#\1#p')
  LABEL="free${slot:+-$slot}"
else
  LABEL="${BR//\//-}"
fi

# scan every RUNNING session for a tab whose main pane is rooted at this worktree
# top, and rename it. A worktree normally lives in one tab, but relabel all hits.
sessions=$(herdr session list --json 2>/dev/null \
  | jq -r '.sessions[]? | select(.running==true) | .name' 2>/dev/null) || exit 0

while IFS= read -r S; do
  [[ -n "$S" ]] || continue
  # tab_ids whose pane cwd (trailing slash normalized) equals the worktree top.
  tabs=$(HERDR_SESSION="$S" herdr pane list --session "$S" 2>/dev/null \
    | jq -r --arg d "$TOP" \
      '.result.panes[]? | select((.cwd|rtrimstr("/"))==$d) | .tab_id' 2>/dev/null \
    | sort -u)
  while IFS= read -r T; do
    [[ -n "$T" ]] || continue
    cur=$(HERDR_SESSION="$S" herdr tab list --session "$S" 2>/dev/null \
      | jq -r --arg t "$T" '.result.tabs[]? | select(.tab_id==$t) | .label' 2>/dev/null)
    [[ "$cur" == "$LABEL" ]] && continue
    HERDR_SESSION="$S" herdr tab rename "$T" "$LABEL" --session "$S" >/dev/null 2>&1 \
      && echo "↻ [$S] '$cur' → '$LABEL'" >&2 || true
  done <<< "$tabs"
done <<< "$sessions"
