#!/usr/bin/env bash
# install.sh — one-time setup for the tmux-worktrees skill.
# Run once after copying this skill to ~/.claude/skills/tmux-worktrees/
#
# What it does:
#   1. Adds WorktreeCreate hook to ~/.claude/settings.json
#   2. Registers /tmux-worktrees slash command in ~/.claude/CLAUDE.md

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"

# --- 1. WorktreeCreate hook --------------------------------------------------
if ! grep -q "tmux-worktrees" "$SETTINGS" 2>/dev/null; then
  echo "→ Adding WorktreeCreate hook to $SETTINGS" >&2

  # Inject into the hooks object. Use python3 for safe JSON editing.
  python3 - "$SETTINGS" <<'EOF'
import json, sys

path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)

cfg.setdefault("hooks", {})["WorktreeCreate"] = [
    {
        "hooks": [
            {
                "type": "command",
                "command": (
                    "bash -c '"
                    "NAME=$(jq -r .name); "
                    "REPO=$(git rev-parse --show-toplevel); "
                    "SAFE=${NAME//\\\\//-}; "
                    "DIR=\"$REPO/.claude/worktrees/$SAFE\"; "
                    "git -C \"$REPO\" worktree add \"$DIR\" -b \"worktree-$NAME\" origin/HEAD >&2 || true; "
                    "if [[ -f \"$REPO/tmux-worktree.yaml\" ]]; then "
                    "  bash ~/.claude/skills/tmux-worktrees/scripts/link-worktree-env.sh \"$DIR\" >&2; "
                    "  bash ~/.claude/skills/tmux-worktrees/scripts/tmux-worktrees.sh --add \"$SAFE\" >&2; "
                    "fi; "
                    "echo \"$DIR\""
                    "'"
                )
            }
        ]
    }
]

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("  done")
EOF
else
  echo "  WorktreeCreate hook already present — skipping" >&2
fi

# --- 2. Slash command in CLAUDE.md -------------------------------------------
if ! grep -q "tmux-worktrees" "$CLAUDE_MD" 2>/dev/null; then
  echo "→ Registering /tmux-worktrees in $CLAUDE_MD" >&2
  cat >> "$CLAUDE_MD" <<'EOF'

# tmux-worktrees
- **tmux-worktrees** (`~/.claude/skills/tmux-worktrees/SKILL.md`) - launch a tmux dev session for the current repo's worktrees. Trigger: `/tmux-worktrees`
When the user types `/tmux-worktrees`, invoke the Skill tool with `skill: "tmux-worktrees"` before doing anything else.
EOF
  echo "  done" >&2
else
  echo "  /tmux-worktrees already registered — skipping" >&2
fi

echo "" >&2
echo "✓ tmux-worktrees skill installed." >&2
echo "  Next: create tmux-worktree.yaml at your repo root, then type /tmux-worktrees" >&2
