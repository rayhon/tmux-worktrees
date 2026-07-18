#!/bin/bash
# treehouse post_create hook: wire a pooled worktree the same way the
# tmux-worktrees WorktreeCreate hook does, but with a POOL-UNIQUE port offset so
# treehouse crew stacks never collide with the user's own .claude/worktrees
# stacks.
#
# link-worktree-env.sh honors a pre-seeded .wt-port-offset and only scans
# .claude/worktrees when it is absent. treehouse worktrees live under
# ~/.treehouse/<repo-hash>/<slot>/, so that scan would find nothing and every
# slot would land on +10. We instead derive a deterministic offset from the
# treehouse slot number and seed it, then hand off to link-worktree-env.sh.
#
# Offset scheme: 100 + slot*10  (slot 1 -> 110, slot 2 -> 120, ...). The user's
# own tmux-worktrees offsets start at +10 and climb by 10, so a +100 base keeps
# the pool clear of them until they exceed 9 concurrent worktrees.
#
# Registered as a USER-LEVEL treehouse hook (repo-level hooks are ignored by
# treehouse for safety). install.sh wires it into ~/.config/treehouse/config.toml
# pointing at this vendored copy under ~/.claude/skills/tmux-worktrees/scripts/.
set -euo pipefail

WT="${TREEHOUSE_DIR:-$PWD}"
# Resolve link-worktree-env.sh next to THIS script so the hook works wherever the
# skill is installed (defaults to ~/.claude/skills/tmux-worktrees/scripts/).
SC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINK="$SC/link-worktree-env.sh"
[[ -x "$LINK" ]] || LINK="$HOME/.claude/skills/tmux-worktrees/scripts/link-worktree-env.sh"

# Derive the treehouse slot number from the path .../.treehouse/<hash>/<slot>/...
slot="$(printf '%s\n' "$WT" | sed -nE 's#.*/\.treehouse/[^/]+/([0-9]+)(/|$).*#\1#p' | head -1)"
[[ -z "$slot" ]] && slot=1
offset=$(( 100 + slot * 10 ))

printf '%s\n' "$offset" > "$WT/.wt-port-offset"
echo "th-postcreate: seeded pool offset +$offset for slot $slot at $WT" >&2

# Wire env/ports/symlinks/.wrangler/npm-install via the user's own script.
if [[ -x "$LINK" ]]; then
  bash "$LINK" "$WT"
else
  echo "th-postcreate: WARNING link-worktree-env.sh not found at $LINK — worktree left unwired" >&2
fi
