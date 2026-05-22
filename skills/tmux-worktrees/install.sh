#!/usr/bin/env bash
# install.sh — one-time setup for the tmux-worktrees skill.
# Called automatically on first /tmux-worktrees invocation, or manually:
#   bash ~/.claude/skills/tmux-worktrees/install.sh
#
# What it does:
#   Adds WorktreeCreate hook to ~/.claude/settings.json
#
# Note: the /tmux-worktrees slash command is auto-registered by Claude Code
# because this skill lives in ~/.claude/skills/tmux-worktrees/. No extra step needed.

set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"

# --- WorktreeCreate hook ---------------------------------------------------
if ! grep -q "tmux-worktrees" "$SETTINGS" 2>/dev/null; then
  echo "→ Adding WorktreeCreate hook to $SETTINGS" >&2
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

echo "" >&2
echo "✓ tmux-worktrees installed." >&2
echo "  Next: create tmux-worktree.yaml at your repo root, then type /tmux-worktrees" >&2
