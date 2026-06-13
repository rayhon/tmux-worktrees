#!/usr/bin/env bash
# One-command install for the tmux-worktrees Claude Code skill.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/rayhon/tmux-worktrees/main/install.sh)
#
# What it does:
#   1. Downloads skill files to ~/.claude/skills/tmux-worktrees/
#   2. Registers the WorktreeCreate hook in ~/.claude/settings.json
#   3. Registers the PreToolUse worktree-edit guard (blocks accidental
#      edits to the parent repo while the session is inside a worktree)

set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/rayhon/tmux-worktrees/main"
SKILL_DIR="$HOME/.claude/skills/tmux-worktrees"
SETTINGS="$HOME/.claude/settings.json"

# --- 1. Download skill files --------------------------------------------------
echo "→ Installing skill to $SKILL_DIR" >&2
mkdir -p "$SKILL_DIR/scripts"

files=(
  "skills/tmux-worktrees/SKILL.md"
  "skills/tmux-worktrees/scripts/tmux-worktrees.sh"
  "skills/tmux-worktrees/scripts/tmux-worktree.conf"
  "skills/tmux-worktrees/scripts/jump-pane.sh"
  "skills/tmux-worktrees/scripts/link-worktree-env.sh"
  "skills/tmux-worktrees/scripts/prevent-parent-repo-edits.sh"
  "skills/tmux-worktrees/scripts/wait-for-install.sh"
)

for file in "${files[@]}"; do
  dest="$SKILL_DIR/${file#skills/tmux-worktrees/}"
  curl -fsSL "$REPO_URL/$file" -o "$dest"
done

chmod +x "$SKILL_DIR/scripts/"*.sh

echo "  done" >&2

# --- 2. Register WorktreeCreate hook ------------------------------------------
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
                    "git -C \"$REPO\" worktree add \"$DIR\" -b \"worktree-$NAME\" HEAD >&2 || true; "
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

# --- 3. Register PreToolUse worktree-edit guard -------------------------------
# Blocks Edit/Write/MultiEdit/NotebookEdit from accidentally touching the
# parent repo's working tree while the session's cwd is inside a worktree.
# Catches the "agent edits apps/web/foo.ts in parent instead of worktree" bug.
if ! grep -q "prevent-parent-repo-edits" "$SETTINGS" 2>/dev/null; then
  echo "→ Adding PreToolUse worktree-edit guard to $SETTINGS" >&2
  python3 - "$SETTINGS" <<'EOF'
import json, sys

path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)

hooks = cfg.setdefault("hooks", {})
preToolUse = hooks.setdefault("PreToolUse", [])
preToolUse.append({
    "matcher": "Edit|Write|MultiEdit|NotebookEdit",
    "hooks": [
        {
            "type": "command",
            "command": "~/.claude/skills/tmux-worktrees/scripts/prevent-parent-repo-edits.sh"
        }
    ]
})

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("  done")
EOF
else
  echo "  PreToolUse worktree-edit guard already present — skipping" >&2
fi

echo "" >&2
echo "✓ tmux-worktrees installed." >&2
echo "  /tmux-worktrees is now available in any Claude Code session." >&2
echo "  Next: add tmux-worktree.yaml at your repo root, then type /tmux-worktrees" >&2
