#!/usr/bin/env bash
# link-worktree-env.sh — symlink per-service env files + declared paths from the
# main checkout into a new worktree. Fully generic: service paths come from
# scripts/tmux-worktree.yaml.
#
# Called automatically by the WorktreeCreate hook; safe to re-run.
# Usage: ./scripts/link-worktree-env.sh <worktree-dir>

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <worktree-dir>" >&2; exit 1
fi

WORKTREE_DIR="$1"
[[ -d "$WORKTREE_DIR" ]] || { echo "✗ $WORKTREE_DIR does not exist" >&2; exit 1; }
if ! command -v yq >/dev/null 2>&1; then
  echo "→ yq not found, installing via brew..." >&2
  brew install yq
fi

GIT_COMMON_DIR="$(git -C "$WORKTREE_DIR" rev-parse --git-common-dir)"
MAIN_ROOT="$(cd "$GIT_COMMON_DIR/.." && pwd)"
WORKTREE_ABS="$(cd "$WORKTREE_DIR" && pwd)"

[[ "$MAIN_ROOT" == "$WORKTREE_ABS" ]] && { echo "✗ $WORKTREE_DIR is the main checkout, not a worktree" >&2; exit 1; }

YAML="$MAIN_ROOT/tmux-worktree.yaml"
[[ -f "$YAML" ]] || { echo "✗ missing $YAML — create it at the repo root" >&2; exit 1; }

ENV_FILES=(".env.local" ".env.prod" ".dev.vars")
SVC_COUNT=$(yq '.services | length' "$YAML")

for ((i=0; i<SVC_COUNT; i++)); do
  rel=$(yq ".services[$i].cwd // \".\"" "$YAML")
  src="$MAIN_ROOT/$rel"
  dst="$WORKTREE_ABS/$rel"

  [[ -d "$dst" ]] || continue
  echo "→ Linking $rel" >&2

  # Standard env files
  for f in "${ENV_FILES[@]}"; do
    if [[ -f "$src/$f" ]]; then
      ln -sfn "$src/$f" "$dst/$f"
      echo "    linked $f" >&2
    fi
  done

  # Extra symlinks declared in the YAML (e.g. .wrangler/state)
  sym_count=$(yq ".services[$i].symlinks | length" "$YAML" 2>/dev/null || echo 0)
  for ((j=0; j<sym_count; j++)); do
    rel_path=$(yq ".services[$i].symlinks[$j]" "$YAML")
    src_path="$src/$rel_path"
    dst_path="$dst/$rel_path"
    if [[ -e "$src_path" ]]; then
      mkdir -p "$(dirname "$dst_path")"
      ln -sfn "$src_path" "$dst_path"
      echo "    linked $rel_path" >&2
    fi
  done
done

# Background npm install on first setup.
# Writes .npm-install.pid while running so tmux-worktrees.sh can gate service
# panes — otherwise dev panes race a partial node_modules and all fail.
if [[ ! -d "$WORKTREE_ABS/node_modules" ]]; then
  LOG="$WORKTREE_ABS/.npm-install.log"
  PIDFILE="$WORKTREE_ABS/.npm-install.pid"
  echo "" >&2
  echo "→ Starting npm install in background" >&2
  echo "  Watch: tail -f $LOG" >&2
  nohup bash -c "echo \$\$ > '$PIDFILE'; trap 'rm -f \"$PIDFILE\"' EXIT; cd '$WORKTREE_ABS' && npm install" >"$LOG" 2>&1 </dev/null &
  disown || true
else
  echo "  node_modules present — skipping npm install" >&2
fi

echo "" >&2
echo "✓ Worktree env linked at $WORKTREE_ABS" >&2
echo "  Start services: ~/.claude/skills/tmux-worktrees/scripts/tmux-worktrees.sh" >&2
