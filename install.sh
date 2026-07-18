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
  "skills/tmux-worktrees/scripts/wt-up.sh"
  "skills/tmux-worktrees/scripts/wt-down.sh"
  "skills/tmux-worktrees/scripts/herdr-worktrees.sh"
  "skills/tmux-worktrees/scripts/herdr-relabel.sh"
  "skills/tmux-worktrees/scripts/th-postcreate.sh"
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

# --- 4. Register treehouse post_create hook (pooled worktrees + herdr) --------
# Optional path: if `treehouse` is installed, wire its user-level post_create hook
# so every pooled worktree auto-wires (offset ports, env, .wrangler mirror) the
# same way the WorktreeCreate hook does. treehouse IGNORES repo-level hooks for
# safety, so this MUST live in ~/.config/treehouse/config.toml. Idempotent and
# non-destructive: only adds our line, preserves any existing [hooks].
TH_CFG="$HOME/.config/treehouse/config.toml"
TH_HOOK="$HOME/.claude/skills/tmux-worktrees/scripts/th-postcreate.sh"
if command -v treehouse >/dev/null 2>&1; then
  mkdir -p "$(dirname "$TH_CFG")"
  if [[ -f "$TH_CFG" ]] && grep -q "th-postcreate.sh" "$TH_CFG" 2>/dev/null; then
    echo "  treehouse post_create hook already present — skipping" >&2
  elif [[ -f "$TH_CFG" ]] && grep -q "post_create" "$TH_CFG" 2>/dev/null; then
    echo "→ NOTE: $TH_CFG already defines post_create." >&2
    echo "  Add this command to it manually so pooled worktrees auto-wire:" >&2
    echo "    bash $TH_HOOK" >&2
  else
    echo "→ Registering treehouse post_create hook in $TH_CFG" >&2
    {
      [[ -f "$TH_CFG" ]] && cat "$TH_CFG"
      echo ""
      echo "# Added by tmux-worktrees install: wire pooled worktrees (offset ports,"
      echo "# env, .wrangler mirror) for the herdr/treehouse flow. Repo-level hooks"
      echo "# are ignored by treehouse, so this must live here."
      echo "[hooks]"
      echo "post_create = [\"bash $TH_HOOK\"]"
    } > "$TH_CFG.tmp" && mv "$TH_CFG.tmp" "$TH_CFG"
    echo "  done" >&2
  fi
else
  echo "  (treehouse not installed — skipping pooled-worktree hook; install treehouse to use the herdr flow)" >&2
fi

echo "" >&2
echo "✓ tmux-worktrees installed." >&2
echo "  /tmux-worktrees is now available in any Claude Code session." >&2
echo "  Next: add tmux-worktree.yaml at your repo root, then type /tmux-worktrees" >&2
echo "  Pooled worktrees over herdr:  scripts/wt-up.sh <branch>   (see SKILL.md)" >&2
