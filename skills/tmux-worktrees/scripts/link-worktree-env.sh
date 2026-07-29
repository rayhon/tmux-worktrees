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
SVC_STATE_MODE=()
for ((i=0; i<SVC_COUNT; i++)); do
  SVC_LABELS+=("$(yq ".services[$i].label" "$YAML")")
  SVC_BASE_PORTS+=("$(yq ".services[$i].port" "$YAML")")
  SVC_CWDS+=("$(yq ".services[$i].cwd // \".\"" "$YAML")")
  # Per-service Miniflare/wrangler `.wrangler/state` policy (R2/KV/D1/DO/cache):
  #   shared  → symlink the whole state dir to main  → one live cache all
  #             worktrees read+write (safe: workerd does NOT exclusively lock
  #             the sqlite — WAL allows concurrent multi-process access; verified).
  #             Use for append-mostly shared caches (mcp-hub crawl-data, agent-hub
  #             SOPs/configs) so a cache entry made in any worktree is seen by all.
  #   private → full copy of the state dir from main at setup → an independent,
  #             point-in-time clone. Use for app data that must NOT be shared
  #             across branches (web fortypirates-apps: per-user workspace
  #             snapshots + experiences). Overwrites/deletes stay local — no
  #             cross-worktree corruption because nothing is shared.
  #   (unset) → fall back to the legacy `mirror_with_sqlite_copies` hybrid.
  SVC_STATE_MODE+=("$(yq ".services[$i].wrangler_state // \"\"" "$YAML")")
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

# --- Global hybrid-mirror list -----------------------------------------------
# Paths from `mirror_with_sqlite_copies:` get the hybrid treatment: symlink
# whole subtrees that have NO SQLite descendants, COPY SQLite lock files in
# place. Designed for `.wrangler/state` so each worktree owns its own
# miniflare SQLite locks (workerd needs that) while sharing the big
# immutable R2 blobs with parent.
GLOBAL_HYBRID_MIRRORS=()
hm_count=$(yq '.mirror_with_sqlite_copies | length' "$YAML" 2>/dev/null || echo 0)
[[ "$hm_count" == "null" ]] && hm_count=0
for ((j=0; j<hm_count; j++)); do
  GLOBAL_HYBRID_MIRRORS+=("$(yq ".mirror_with_sqlite_copies[$j]" "$YAML")")
done

# --- mirror_with_sqlite_copies: recursive hybrid mirror ----------------------
# If src has no *.sqlite* anywhere in its tree, symlink it whole (cheap).
# Otherwise: real dir, recurse into children. Sqlite files → cp. Other
# files → individual symlink. Other dirs → recurse.
hybrid_mirror() {
  local src="$1" dst="$2"
  if [[ ! -d "$src" ]]; then
    [[ -L "$dst" ]] && rm -f "$dst"
    ln -sfn "$src" "$dst"
    return
  fi
  # No SQLite anywhere under here → one symlink covers the whole subtree.
  if ! find "$src" -name '*.sqlite' -o -name '*.sqlite-shm' \
          -o -name '*.sqlite-wal' -o -name '*.sqlite-journal' \
          2>/dev/null | grep -q .; then
    [[ -L "$dst" ]] && rm -f "$dst"
    [[ -d "$dst" ]] && return   # already real-dir from a prior partial mirror — leave it
    ln -sfn "$src" "$dst"
    return
  fi
  # Has SQLite — real dir + recurse children.
  [[ -L "$dst" ]] && rm -f "$dst"
  mkdir -p "$dst"
  local entry name
  shopt -s nullglob dotglob
  for entry in "$src"/*; do
    name="$(basename "$entry")"
    case "$name" in
      *.sqlite|*.sqlite-shm|*.sqlite-wal|*.sqlite-journal)
        # Lock file — copy only if missing (preserve worktree's own writes).
        [[ -e "$dst/$name" ]] || cp "$entry" "$dst/$name"
        ;;
      *)
        if [[ -d "$entry" ]]; then
          hybrid_mirror "$entry" "$dst/$name"
        else
          [[ -e "$dst/$name" ]] || ln -sfn "$entry" "$dst/$name"
        fi
        ;;
    esac
  done
  shopt -u nullglob dotglob
}

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

  # Per-service `.wrangler/state` policy (shared symlink vs private copy).
  # Takes precedence over the legacy hybrid mirror for `.wrangler/state`.
  state_mode="${SVC_STATE_MODE[$i]}"
  if [[ -n "$state_mode" && "$state_mode" != "null" ]]; then
    src_state="$src/.wrangler/state"
    dst_state="$dst/.wrangler/state"
    if [[ -d "$src_state" ]]; then
      # Clear any prior mirror (symlink OR real dir) so re-runs are idempotent.
      rm -rf "$dst_state"
      mkdir -p "$(dirname "$dst_state")"
      case "$state_mode" in
        shared)
          # One live cache shared with main (and thus every other 'shared'
          # worktree, since they all symlink the same main dir). Concurrent
          # multi-process access is safe (WAL). Zero disk.
          ln -sfn "$src_state" "$dst_state"
          echo "    wrangler_state=shared (symlink → main)" >&2
          ;;
        private)
          # Independent point-in-time clone. cp -R copies main's real files
          # (blobs + sqlite + kv/do/cache). Writes stay local — no sharing,
          # no cross-worktree corruption. -R (not -RL): main's own state is
          # real dirs, so nothing to dereference.
          cp -R "$src_state" "$dst_state"
          echo "    wrangler_state=private (own copy of $(du -sh "$src_state" 2>/dev/null | cut -f1))" >&2
          ;;
        *)
          echo "    ⚠ unknown wrangler_state='$state_mode' (expected shared|private) — skipped" >&2
          ;;
      esac
    fi
  fi

  # Hybrid mirror: symlink subtrees, copy SQLite lock files in place. Legacy
  # path for any `mirror_with_sqlite_copies:` entry. NOTE: `.wrangler/state` is
  # now driven by the per-service `wrangler_state:` policy above; keep it OUT of
  # `mirror_with_sqlite_copies` to avoid double-processing. This block remains
  # for any OTHER hybrid path a project might declare.
  if [[ ${#GLOBAL_HYBRID_MIRRORS[@]} -gt 0 ]]; then
    for rel_path in "${GLOBAL_HYBRID_MIRRORS[@]}"; do
      src_path="$src/$rel_path"
      dst_path="$dst/$rel_path"
      [[ -e "$src_path" ]] || continue
      mkdir -p "$(dirname "$dst_path")"
      hybrid_mirror "$src_path" "$dst_path"
      echo "    hybrid-mirror $rel_path (blobs symlinked, SQLite copied)" >&2
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
  # Use setsid when available (Linux), else nohup (macOS doesn't ship setsid).
  # `& disown` makes the subshell exit 0 immediately, so checking $? after
  # backgrounding won't catch a missing setsid — branch on existence instead.
  if command -v setsid >/dev/null 2>&1; then
    ( setsid bash -c "
      echo \$\$ > '$PIDFILE'
      trap 'rm -f \"$PIDFILE\"' EXIT
      cd '$WORKTREE_ABS' && npm install && touch '$OKFILE'
    " >"$LOG" 2>&1 </dev/null & disown ) 2>/dev/null
  else
    ( nohup bash -c "
      echo \$\$ > '$PIDFILE'
      trap 'rm -f \"$PIDFILE\"' EXIT
      cd '$WORKTREE_ABS' && npm install && touch '$OKFILE'
    " >"$LOG" 2>&1 </dev/null & disown ) 2>/dev/null
  fi
else
  echo "  node_modules + install sentinel present — skipping npm install" >&2
fi

# --- Project post-create hooks -----------------------------------------------
# The project can declare `post_create:` in tmux-worktree.yaml — a list of shell
# commands run ONCE here, from the worktree root, after env is wired. This keeps
# project-specific setup (e.g. installing git hooks) out of the generic skill
# and out of the global Claude WorktreeCreate hook. Commands should be
# idempotent (they run on every worktree creation). Failures are warned, not
# fatal — a bad post_create step shouldn't abort worktree wiring.
pc_count=$(yq '.post_create | length' "$YAML" 2>/dev/null || echo 0)
[[ "$pc_count" =~ ^[0-9]+$ ]] || pc_count=0
if [[ "$pc_count" -gt 0 ]]; then
  echo "→ Running $pc_count post_create command(s) from tmux-worktree.yaml…" >&2
  for ((p=0; p<pc_count; p++)); do
    pc_cmd="$(yq -r ".post_create[$p]" "$YAML")"
    [[ -n "$pc_cmd" && "$pc_cmd" != "null" ]] || continue
    echo "  • $pc_cmd" >&2
    ( cd "$WORKTREE_ABS" && bash -c "$pc_cmd" ) >&2 \
      || echo "  ⚠ post_create failed (non-fatal): $pc_cmd" >&2
  done
fi

echo "" >&2
echo "✓ Worktree env wired at $WORKTREE_ABS" >&2
echo "  Start services: ~/.claude/skills/tmux-worktrees/scripts/tmux-worktrees.sh" >&2
