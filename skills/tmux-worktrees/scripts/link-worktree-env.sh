#!/usr/bin/env bash
# link-worktree-env.sh — set up per-worktree env so each app sees the right
# ports/URLs without runtime overrides. Reads tmux-worktree.yaml at repo root.
#
# For each service declared in the yaml:
#   - Copies (not symlinks) .env.local / .env.prod / .dev.vars from parent → worktree
#   - Rewrites `localhost:<base>` → `localhost:<base+offset>` for every service
#   - Upserts a PORT=<offset_port> line at the top of .env.local
#   - Symlinks the shared paths declared ONCE under the top-level `symlinks:`
#     list (e.g. .wrangler/state, src/data) into every service's cwd; a path
#     whose source is absent for a given service is skipped
#   - Kicks off npm install in the background on first setup
#
# The port offset is persisted ONCE in `.wt-port-offset` at the worktree root
# and read back by tmux-worktrees.sh, so the rewritten env files and the pane
# PORT exports can never disagree. A new worktree claims the lowest free
# multiple of 10 not already taken by a sibling worktree's marker.
#
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

# --- Resolve this worktree's port offset (single source of truth) ------------
# Persisted once in `.wt-port-offset` at the worktree root and never recomputed.
# Both this script (which rewrites the env files) and tmux-worktrees.sh (which
# exports PORT into each pane) read this same file, so they can't disagree —
# that disagreement was the "8787 vs offset" mismatch. A fresh worktree claims
# the lowest free multiple of 10 not already taken by a sibling's marker, so
# adding/removing worktrees never shifts an existing one's ports out from under
# a running dev server.
THIS_NAME="$(basename "$WORKTREE_ABS")"
OFFSET_FILE="$WORKTREE_ABS/.wt-port-offset"
OFFSET=""
[[ -f "$OFFSET_FILE" ]] && OFFSET="$(tr -dc '0-9' < "$OFFSET_FILE")"

if [[ -z "$OFFSET" || "$OFFSET" -le 0 ]]; then
  USED=""
  for d in "$MAIN_ROOT/.claude/worktrees"/*/; do
    [[ -f "$d/.wt-port-offset" ]] || continue
    [[ "$(cd "$d" && pwd)" == "$WORKTREE_ABS" ]] && continue   # skip self
    USED="$USED $(tr -dc '0-9' < "$d/.wt-port-offset")"
  done
  OFFSET=10
  while [[ " $USED " == *" $OFFSET "* ]]; do
    OFFSET=$((OFFSET + 10))
  done
  printf '%s\n' "$OFFSET" > "$OFFSET_FILE"
fi

echo "→ Worktree '$THIS_NAME' → offset +$OFFSET (persisted in .wt-port-offset)" >&2

# --- Read service base ports for the port-rewrite step -----------------------
SVC_LABELS=()
SVC_BASE_PORTS=()
SVC_CWDS=()
for ((i=0; i<SVC_COUNT; i++)); do
  SVC_LABELS+=("$(yq ".services[$i].label" "$YAML")")
  SVC_BASE_PORTS+=("$(yq ".services[$i].port" "$YAML")")
  SVC_CWDS+=("$(yq ".services[$i].cwd // \".\"" "$YAML")")
done

# --- Global symlink list -----------------------------------------------------
# Declared ONCE at the yaml root (not per service). Applied to every service's
# cwd; a path whose source doesn't exist for a given service is skipped, so the
# same list covers app-specific paths too (e.g. mcp-hub's src/data).
GLOBAL_SYMLINKS=()
gl_count=$(yq '.symlinks | length' "$YAML" 2>/dev/null || echo 0)
[[ "$gl_count" == "null" ]] && gl_count=0
for ((j=0; j<gl_count; j++)); do
  GLOBAL_SYMLINKS+=("$(yq ".symlinks[$j]" "$YAML")")
done

# --- rewrite_env: copy an env file and replace each base port -----------------
# Args: $1 = source file, $2 = destination file
rewrite_env() {
  local src="$1" dst="$2"
  local tmp
  tmp="$(mktemp)"
  cp "$src" "$tmp"
  for ((k=0; k<SVC_COUNT; k++)); do
    local base="${SVC_BASE_PORTS[$k]}"
    local new=$((base + OFFSET))
    # macOS sed needs an explicit empty backup arg
    sed -i.bak "s|localhost:${base}|localhost:${new}|g" "$tmp"
    rm -f "${tmp}.bak"
  done
  mv "$tmp" "$dst"
}

# --- upsert_port_line: ensure ".env.local" carries PORT=<service_port> --------
# Some app frameworks (e.g. Next.js) honor PORT in .env.local so a bare
# `npm run dev` listens on the worktree's port without a CLI override.
upsert_port_line() {
  local file="$1" port="$2"
  if grep -q "^PORT=" "$file" 2>/dev/null; then
    sed -i.bak "s|^PORT=.*|PORT=${port}|" "$file"
    rm -f "${file}.bak"
  else
    printf 'PORT=%s\n%s\n' "$port" "$(cat "$file")" > "$file.new"
    mv "$file.new" "$file"
  fi
}

# --- Per-service: copy env, rewrite ports, upsert PORT, link extras -----------
for ((i=0; i<SVC_COUNT; i++)); do
  rel="${SVC_CWDS[$i]}"
  src="$MAIN_ROOT/$rel"
  dst="$WORKTREE_ABS/$rel"
  port=$((SVC_BASE_PORTS[$i] + OFFSET))

  [[ -d "$dst" ]] || continue
  echo "→ Wiring $rel (port $port)" >&2

  for f in "${ENV_FILES[@]}"; do
    if [[ -f "$src/$f" ]]; then
      # If a previous run left a symlink here, remove it before copying
      [[ -L "$dst/$f" ]] && rm -f "$dst/$f"
      rewrite_env "$src/$f" "$dst/$f"
      echo "    copied $f (ports rewritten)" >&2
    fi
  done

  # Ensure PORT line in .env.local so `npm run dev` listens on the worktree port
  if [[ -f "$dst/.env.local" ]]; then
    upsert_port_line "$dst/.env.local" "$port"
    echo "    set PORT=$port in .env.local" >&2
  fi

  # Shared paths from the global `symlinks:` list. Missing sources are skipped,
  # so app-specific paths (e.g. mcp-hub's src/data) live in the same list.
  if [[ ${#GLOBAL_SYMLINKS[@]} -gt 0 ]]; then
    for rel_path in "${GLOBAL_SYMLINKS[@]}"; do
      src_path="$src/$rel_path"
      dst_path="$dst/$rel_path"
      if [[ -e "$src_path" ]]; then
        mkdir -p "$(dirname "$dst_path")"
        ln -sfn "$src_path" "$dst_path"
        echo "    linked $rel_path" >&2
      fi
    done
  fi
done

# --- Background npm install (first time only) --------------------------------
# Spawn via a double-fork so the install is reparented to PID 1 and survives
# any SIGHUP/SIGTERM from the caller (tmux kill, Claude session exit, etc).
# Writes a SUCCESS sentinel only on `npm install` exit code 0 — pane wait
# loops should block on the sentinel, NOT the pidfile, because a killed
# install also removes its pidfile on the way out (via trap) and would
# otherwise look indistinguishable from a clean finish.
if [[ ! -d "$WORKTREE_ABS/node_modules" ]] || [[ ! -f "$WORKTREE_ABS/.npm-install.ok" ]]; then
  LOG="$WORKTREE_ABS/.npm-install.log"
  PIDFILE="$WORKTREE_ABS/.npm-install.pid"
  OKFILE="$WORKTREE_ABS/.npm-install.ok"
  rm -f "$OKFILE"   # clear any stale sentinel before re-install
  echo "" >&2
  echo "→ Starting npm install in background (detached)" >&2
  echo "  Watch: tail -f $LOG" >&2
  ( setsid bash -c "
      echo \$\$ > '$PIDFILE'
      trap 'rm -f \"$PIDFILE\"' EXIT
      cd '$WORKTREE_ABS' && npm install && touch '$OKFILE'
    " >"$LOG" 2>&1 </dev/null & disown ) 2>/dev/null \
  || \
  ( nohup bash -c "
      echo \$\$ > '$PIDFILE'
      trap 'rm -f \"$PIDFILE\"' EXIT
      cd '$WORKTREE_ABS' && npm install && touch '$OKFILE'
    " >"$LOG" 2>&1 </dev/null & disown )
else
  echo "  node_modules + install sentinel present — skipping npm install" >&2
fi

echo "" >&2
echo "✓ Worktree env wired at $WORKTREE_ABS" >&2
echo "  Start services: ~/.claude/skills/tmux-worktrees/scripts/tmux-worktrees.sh" >&2
