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

# Offsets come from the MACHINE-WIDE allocator (wt-offset.sh). The old
# `100 + slot*10` scheme existed only because link-worktree-env.sh could not see
# treehouse siblings (it scanned .claude/worktrees) and because per-repo offsets
# collided across projects. One registry for every worktree on the machine fixes
# both, so a pool slot, a .claude/worktrees checkout and another repo entirely
# can never share an offset. Seeding here is still useful: the number exists
# before link-worktree-env.sh runs, and claiming twice is idempotent.
OFFSETTER="$SC/wt-offset.sh"
[[ -x "$OFFSETTER" ]] || OFFSETTER="$HOME/.claude/skills/tmux-worktrees/scripts/wt-offset.sh"
if [[ -x "$OFFSETTER" ]]; then
  offset="$("$OFFSETTER" claim "$WT")"
  printf '%s\n' "$offset" > "$WT/.wt-port-offset"
  echo "th-postcreate: claimed machine-wide offset +$offset for $WT" >&2
else
  echo "th-postcreate: WARNING wt-offset.sh not found — link-worktree-env.sh will claim" >&2
fi

# Wire env/ports/symlinks/.wrangler/npm-install via the user's own script.
if [[ -x "$LINK" ]]; then
  bash "$LINK" "$WT"
else
  echo "th-postcreate: WARNING link-worktree-env.sh not found at $LINK — worktree left unwired" >&2
fi
