#!/bin/bash
# treehouse post_create hook: wire a pooled worktree the same way the
# tmux-worktrees WorktreeCreate hook does, so a crew stack never collides with
# the user's own .claude/worktrees stacks or with another repo's.
#
# Offsets come from the machine-wide allocator (wt-offset.sh); this hook claims
# one and hands off to link-worktree-env.sh, which also writes .wt-env.json — the
# manifest an agent working in the slot reads to find its own ports.
#
# It used to seed `100 + slot*10`, because link-worktree-env.sh allocated by
# scanning `.claude/worktrees` — a directory treehouse slots do not live in (they
# sit under ~/.treehouse/<repo-hash>/<slot>/), so without the seed every slot
# would have landed on +10. The +100 base kept the pool clear of the user's own
# worktrees, but only until either side passed nine, and it did nothing about two
# repos handing out the same number. One registry replaces both halves.
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
