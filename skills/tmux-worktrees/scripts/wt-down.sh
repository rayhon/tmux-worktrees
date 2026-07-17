#!/usr/bin/env bash
# wt-down.sh — safely free a treehouse slot that has a herdr tab.
#
# ORDER MATTERS: close the herdr tab first, WAIT for its pane processes to exit,
# THEN treehouse return. Returning a slot while its herdr panes are still live
# lets treehouse's cwd process-sweep cascade up and kill the whole herdr session
# (disconnecting you). This sequence avoids that.
#
# Usage:
#   wt-down.sh <slot-path> [<session>] [<repo-dir>]
set -euo pipefail

SLOT="${1:?usage: wt-down.sh <slot-path> [session] [repo-dir]}"
SESSION="${2:-fmwt}"
REPO="${3:-$PWD}"
SLOT=$(cd "$SLOT" && pwd -P)

H() { HERDR_SESSION="$SESSION" herdr "$@" --session "$SESSION"; }

# 1. find the tab whose main pane cwd == SLOT (search every workspace), close it
tid=""
for wsid in $(H workspace list 2>/dev/null | jq -r '.result.workspaces[]?.workspace_id' 2>/dev/null); do
  while IFS=$'\t' read -r t cwd; do
    [[ -n "$cwd" ]] || continue
    rp=$(cd "$cwd" 2>/dev/null && pwd -P) || continue
    [[ "$rp" == "$SLOT" ]] && { tid="$t"; break; }
  done < <(H pane list --workspace "$wsid" 2>/dev/null | jq -r '.result.panes[]? | "\(.tab_id)\t\(.cwd)"' 2>/dev/null)
  [[ -n "$tid" ]] && break
done
if [[ -n "$tid" ]]; then
  H tab close "$tid" >/dev/null 2>&1 && echo "→ closed herdr tab $tid" >&2
fi

# 2. WAIT for the slot's processes (dev servers, shells) to actually exit before
#    returning — this is what keeps treehouse's sweep from taking herdr down.
for _ in $(seq 1 15); do
  pgrep -f "$SLOT" >/dev/null 2>&1 || break
  sleep 1
done

# 3. now it is safe to return the slot to the pool
( cd "$REPO" && treehouse return "$SLOT" --force )
echo "✓ freed $SLOT" >&2
