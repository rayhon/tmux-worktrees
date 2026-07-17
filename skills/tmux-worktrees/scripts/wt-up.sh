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

# Install (idempotently) a post-checkout hook so the herdr tab label follows the
# branch on every later `git checkout`/`git switch` inside any worktree of this
# repo. Hooks live in the shared common dir, so one install covers all worktrees.
# Existing post-checkout content is preserved; we only append our marked block.
install_relabel_hook() {
  local gd hooks marker hook
  gd=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || return 0
  hooks="$gd/hooks"; mkdir -p "$hooks"
  marker="# >>> herdr-worktrees relabel hook >>>"
  # post-checkout fires on branch switch ($3==1); post-rewrite fires once after a
  # rebase completes. herdr-relabel.sh itself skips while an op is in progress, so
  # transient rebase checkouts never stamp a bogus label. Both run detached.
  hook="$hooks/post-checkout"
  if ! { [[ -f "$hook" ]] && grep -qF "$marker" "$hook"; }; then
    [[ -f "$hook" ]] || printf '#!/usr/bin/env bash\n' > "$hook"
    {
      printf '%s\n' "$marker"
      printf '[ "$3" = "1" ] && "%s/herdr-relabel.sh" "$(git rev-parse --show-toplevel 2>/dev/null)" >/dev/null 2>&1 &\n' "$SC"
      printf '# <<< herdr-worktrees relabel hook <<<\n'
    } >> "$hook"; chmod +x "$hook"; echo "→ installed post-checkout relabel hook: $hook" >&2
  fi
  hook="$hooks/post-rewrite"
  if ! { [[ -f "$hook" ]] && grep -qF "$marker" "$hook"; }; then
    [[ -f "$hook" ]] || printf '#!/usr/bin/env bash\n' > "$hook"
    {
      printf '%s\n' "$marker"
      printf '"%s/herdr-relabel.sh" "$(git rev-parse --show-toplevel 2>/dev/null)" >/dev/null 2>&1 &\n' "$SC"
      printf '# <<< herdr-worktrees relabel hook <<<\n'
    } >> "$hook"; chmod +x "$hook"; echo "→ installed post-rewrite relabel hook: $hook" >&2
  fi
}
install_relabel_hook "$REPO"

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

# 3. Restore this BRANCH's saved Claude session if we have one (so bringing a
#    branch back resumes its context), else start fresh. Either way we first
#    clear the pooled slot's own stale history so a reused slot never leaks the
#    previous occupant's conversation.
PROJ="$HOME/.claude/projects/$(printf '%s' "$SLOT" | sed 's#[/.]#-#g')"
ARCH="$HOME/.claude/wt-sessions/${BRANCH//\//-}"
mkdir -p "$PROJ"; rm -f "$PROJ"/*.jsonl 2>/dev/null || true
FRESH=1
if compgen -G "$ARCH/*.jsonl" >/dev/null 2>&1; then
  cp "$ARCH"/*.jsonl "$PROJ"/ 2>/dev/null && { FRESH=""; echo "→ restored prior context for '$BRANCH'" >&2; }
fi

# 4. launch the herdr stack (branch already checked out → tab shows the branch).
#    FRESH → strip -c so no resume; restored → keep -c so it resumes the branch.
#    (Env prefix must be a literal assignment, so branch on FRESH here.)
if [[ -n "$FRESH" ]]; then
  ( cd "$SLOT" && HERDR_WT_SESSION="$SESSION" HERDR_WT_FRESH=1 bash "$SC/herdr-worktrees.sh" "$SLOT" )
else
  ( cd "$SLOT" && HERDR_WT_SESSION="$SESSION" bash "$SC/herdr-worktrees.sh" "$SLOT" )
fi

echo "" >&2
echo "✓ ready. attach:  herdr --session $SESSION   → tab ${BRANCH//\//-}" >&2
echo "  done later (standby, safe):  $SC/wt-down.sh \"$SLOT\" $SESSION" >&2
printf '%s\n' "$SLOT"
