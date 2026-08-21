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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# --- Keep our own artifacts out of git's view --------------------------------
# `.wt-env.json` and `.wt-port-offset` are wiring output, not project content, and
# the project has no reason to gitignore files a tool it does not depend on writes.
# Left visible they read as untracked changes, which is not cosmetic: a supervisor
# that refuses to discard a worktree holding uncommitted work (firstmate's teardown
# does exactly this) sees them and blocks the teardown, so wiring a worktree would
# make it undisposable. `info/exclude` is per-worktree, untracked and invisible to
# the project's own .gitignore, which is precisely the scope this needs.
exclude_wiring_artifacts() {
  local excl
  excl="$(git -C "$WORKTREE_ABS" rev-parse --git-path info/exclude 2>/dev/null)" || return 0
  [[ -n "$excl" ]] || return 0
  mkdir -p "$(dirname "$excl")"
  local rel
  for rel in .wt-env.json .wt-port-offset .npm-install.log .npm-install.pid .npm-install.ok .npm-install.lock-hash; do
    grep -qxF "$rel" "$excl" 2>/dev/null || printf '%s\n' "$rel" >> "$excl"
  done
}
exclude_wiring_artifacts

# --- No yaml: degrade, do not die --------------------------------------------
# A project without tmux-worktree.yaml used to get NOTHING from this script — it
# exited 1 even though the caller (th-postcreate) had already seeded a valid
# .wt-port-offset. That made the yaml a PREREQUISITE for any wiring at all, so an
# unconfigured project's worktree left an agent with no port information and no
# copied env files.
#
# Minimal mode instead: claim/keep the offset, copy any env files found at the
# worktree root, and write .wt-env.json carrying the offset. No services, no
# symlinks, no state policy — those genuinely need the yaml. Adopting the yaml
# becomes an upgrade rather than an entry fee, and a consumer can always read the
# manifest without caring which mode produced it.
if [[ ! -f "$YAML" ]]; then
  echo "→ no tmux-worktree.yaml at $MAIN_ROOT — minimal mode (offset + env files only)" >&2

  THIS_NAME="$(basename "$WORKTREE_ABS")"
  OFFSET_FILE="$WORKTREE_ABS/.wt-port-offset"
  OFFSET=""
  [[ -f "$OFFSET_FILE" ]] && OFFSET="$(tr -dc '0-9' < "$OFFSET_FILE")"
  # The MACHINE-WIDE allocator (scripts/wt-offset.sh) owns the number, so a pool
  # slot, a .claude/worktrees checkout and a different repo can never share an
  # offset. .wt-port-offset stays the per-worktree cache consumers read, so
  # nothing downstream changes. Local scan kept only as a fallback.
  if [[ -x "$SCRIPT_DIR/wt-offset.sh" ]]; then
    OFFSET="$("$SCRIPT_DIR/wt-offset.sh" claim "$WORKTREE_ABS")"
  else
    USED=""
    for d in "$MAIN_ROOT/.claude/worktrees"/*/; do
      [[ -f "$d/.wt-port-offset" ]] || continue
      [[ "$(cd "$d" && pwd)" == "$WORKTREE_ABS" ]] && continue
      USED="$USED $(tr -dc '0-9' < "$d/.wt-port-offset")"
    done
    OFFSET=10
    while [[ " $USED " == *" $OFFSET "* ]]; do OFFSET=$((OFFSET + 10)); done
  fi
  printf '%s\n' "$OFFSET" > "$OFFSET_FILE"
  echo "  offset +$OFFSET" >&2

  # Env files carry secrets, so copy (never symlink) and only when absent, so a
  # re-run cannot clobber edits the worktree has already made.
  for ef in .env.local .env.prod .dev.vars .env; do
    if [[ -f "$MAIN_ROOT/$ef" && ! -e "$WORKTREE_ABS/$ef" ]]; then
      cp "$MAIN_ROOT/$ef" "$WORKTREE_ABS/$ef"
      echo "  copied $ef" >&2
    fi
  done

  esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
  cat > "$WORKTREE_ABS/.wt-env.json" <<JSON
{
  "version": 1,
  "mode": "minimal",
  "worktree": "$(esc "$WORKTREE_ABS")",
  "main": "$(esc "$MAIN_ROOT")",
  "branch": "$(esc "$(git -C "$WORKTREE_ABS" rev-parse --abbrev-ref HEAD 2>/dev/null)")",
  "offset": $OFFSET,
  "services": [],
  "symlinks": [],
  "note": "No tmux-worktree.yaml at the repo root. Add the project's base port to this offset when starting a service, e.g. wrangler dev --port \$((8790 + $OFFSET))."
}
JSON
  echo "→ Wrote $WORKTREE_ABS/.wt-env.json (minimal: offset only)" >&2
  echo "✓ Worktree wired in minimal mode at $WORKTREE_ABS" >&2
  exit 0
fi

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

# The MACHINE-WIDE allocator (scripts/wt-offset.sh) owns the number, so a pool
# slot, a .claude/worktrees checkout and a different repo can never share an
# offset. .wt-port-offset stays the per-worktree cache consumers read, so
# nothing downstream changes. Local scan kept only as a fallback.
if [[ -x "$SCRIPT_DIR/wt-offset.sh" ]]; then
  OFFSET="$("$SCRIPT_DIR/wt-offset.sh" claim "$WORKTREE_ABS")"
else
  USED=""
  for d in "$MAIN_ROOT/.claude/worktrees"/*/; do
    [[ -f "$d/.wt-port-offset" ]] || continue
    [[ "$(cd "$d" && pwd)" == "$WORKTREE_ABS" ]] && continue
    USED="$USED $(tr -dc '0-9' < "$d/.wt-port-offset")"
  done
  OFFSET=10
  while [[ " $USED " == *" $OFFSET "* ]]; do OFFSET=$((OFFSET + 10)); done
fi
printf '%s\n' "$OFFSET" > "$OFFSET_FILE"

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
  #
  # INVARIANT — a bucket is (index file + blob folder); the policy MUST move
  # both halves together. Miniflare splits them across sibling directories:
  #     v3/r2/<bucket>/blobs/                 ← the blobs
  #     v3/r2/miniflare-R2BucketObject/*.sqlite ← the index, one file per bucket
  # so ONLY a whole-`state` symlink or a whole-`state` copy keeps a bucket
  # coherent. Anything that links/copies at bucket granularity shares blobs
  # while splitting the index → the two halves drift, and an overwrite in one
  # worktree deletes a blob the other worktree's index still points at.
  # (Observed: slot 4, wired under the legacy hybrid — 2592 index rows main
  # could not see, plus a deleted blob that blanked main's workspace.)
  # Never reintroduce a per-bucket path here.
  state_mode="${SVC_STATE_MODE[$i]}"
  if [[ -z "$state_mode" || "$state_mode" == "null" ]]; then
    echo "    ✗ service '${SVC_LABELS[$i]}' ($rel) has no wrangler_state: (expected shared|private)." >&2
    echo "      Refusing to fall through to the legacy hybrid mirror — it splits" >&2
    echo "      each bucket's index from its blobs. Declare the key in $YAML." >&2
    exit 1
  fi
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
          # Hard fail, never "skip": skipping leaves `.wrangler/state` to the
          # legacy hybrid, which is exactly the index/blob split this policy
          # exists to prevent.
          echo "    ✗ unknown wrangler_state='$state_mode' (expected shared|private)" >&2
          exit 1
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
      # Refuse any R2/wrangler state path: the hybrid symlinks blob dirs but
      # copies SQLite, which splits a bucket's index from its blobs. That is
      # the documented corruption source — `wrangler_state:` owns these paths.
      if [[ "$rel_path" == *".wrangler/state"* || "$rel_path" == *"/r2"* ]]; then
        echo "    ✗ '$rel_path' cannot be hybrid-mirrored — it would split a" >&2
        echo "      bucket's index from its blobs. Use wrangler_state: instead." >&2
        exit 1
      fi
      [[ -e "$src_path" ]] || continue
      mkdir -p "$(dirname "$dst_path")"
      hybrid_mirror "$src_path" "$dst_path"
      echo "    hybrid-mirror $rel_path (blobs symlinked, SQLite copied)" >&2
    done
  fi
done

# --- Background npm install (first time, or when deps drifted) ---------------
# Spawn via a double-fork so the install is reparented to PID 1 and survives
# any SIGHUP/SIGTERM from the caller (tmux kill, Claude session exit, etc).
# Writes a SUCCESS sentinel only on `npm install` exit code 0 — pane wait
# loops should block on the sentinel, NOT the pidfile, because a killed
# install also removes its pidfile on the way out (via trap) and would
# otherwise look indistinguishable from a clean finish.
#
# The sentinel alone is NOT a sufficient gate for a POOLED slot. A slot warmed
# weeks ago always has node_modules + the sentinel, so this block skipped while
# the lockfile had moved hundreds of packages ahead — leaving a half-installed
# tree whose dev server 500s on every route. wt-pool.sh has a drift gate for
# exactly that, but it only runs on the lease path; a slot reused by any other
# path never gets it. So compare the lockfile hash HERE too, which makes the
# gate hold no matter who wired the worktree.
LOCK_HASH_FILE="$WORKTREE_ABS/.npm-install.lock-hash"
lock_hash_now=""
if [[ -f "$WORKTREE_ABS/package-lock.json" ]]; then
  lock_hash_now="$( (shasum "$WORKTREE_ABS/package-lock.json" 2>/dev/null \
    || sha1sum "$WORKTREE_ABS/package-lock.json" 2>/dev/null) | awk '{print $1}' )"
fi
lock_hash_prev="$(cat "$LOCK_HASH_FILE" 2>/dev/null || true)"
deps_drifted=0
if [[ -n "$lock_hash_now" && "$lock_hash_now" != "$lock_hash_prev" ]]; then
  deps_drifted=1
fi

if [[ ! -d "$WORKTREE_ABS/node_modules" ]] || [[ ! -f "$WORKTREE_ABS/.npm-install.ok" ]] \
   || [[ "$deps_drifted" == "1" ]]; then
  LOG="$WORKTREE_ABS/.npm-install.log"
  PIDFILE="$WORKTREE_ABS/.npm-install.pid"
  OKFILE="$WORKTREE_ABS/.npm-install.ok"
  rm -f "$OKFILE"   # clear any stale sentinel before re-install
  if [[ "$deps_drifted" == "1" && -f "$LOCK_HASH_FILE" ]]; then
    echo "  package-lock.json changed since last install — reinstalling" >&2
  elif [[ "$deps_drifted" == "1" ]]; then
    echo "  no install baseline recorded — installing to be sure" >&2
  fi
  echo "" >&2
  echo "→ Starting npm install in background (detached)" >&2
  echo "  Watch: tail -f $LOG" >&2
  # Use setsid when available (Linux), else nohup (macOS doesn't ship setsid).
  # `& disown` makes the subshell exit 0 immediately, so checking $? after
  # backgrounding won't catch a missing setsid — branch on existence instead.
  # The lockfile baseline is stamped by the install itself, on success only.
  # Stamping it from the caller regardless of outcome records a lie ("deps
  # match this lockfile") that makes every later drift check skip forever.
  #
  # And it is hashed AFTER npm returns, never before. `npm install` rewrites
  # package-lock.json whenever the lock is not already exactly what npm would
  # write (a different npm version, a lock generated by another tool, a manual
  # edit) — so a baseline taken from the PRE-install file names a lockfile that
  # no longer exists the moment the install finishes. Every later run then reads
  # a different hash, calls it drift, and reinstalls: the gate inverts from
  # "skip when unchanged" to "reinstall always". The baseline has to describe
  # the lockfile that `node_modules` actually corresponds to, which is the one
  # on disk when the install succeeded.
  INSTALL_CMD="cd '$WORKTREE_ABS' && npm install && touch '$OKFILE'"
  INSTALL_CMD="$INSTALL_CMD && { [[ -f package-lock.json ]] &&"
  INSTALL_CMD="$INSTALL_CMD { shasum package-lock.json 2>/dev/null || sha1sum package-lock.json; }"
  INSTALL_CMD="$INSTALL_CMD | awk '{print \$1}' > '$LOCK_HASH_FILE' || true; }"
  if command -v setsid >/dev/null 2>&1; then
    ( setsid bash -c "
      echo \$\$ > '$PIDFILE'
      trap 'rm -f \"$PIDFILE\"' EXIT
      $INSTALL_CMD
    " >"$LOG" 2>&1 </dev/null & disown ) 2>/dev/null
  else
    ( nohup bash -c "
      echo \$\$ > '$PIDFILE'
      trap 'rm -f \"$PIDFILE\"' EXIT
      $INSTALL_CMD
    " >"$LOG" 2>&1 </dev/null & disown ) 2>/dev/null
  fi
else
  echo "  node_modules + sentinel present, lockfile unchanged — skipping npm install" >&2
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

# Mirrors expand_placeholders() in tmux-worktrees.sh so the manifest carries the
# SAME resolved strings the launcher would run. Two implementations is a smell,
# but the alternative is sourcing the launcher (which starts panes), and a
# manifest that disagrees with the pane would be worse than a duplicate.
wt_expand() {
  local str="$1" idx="$2" k uk ap ib
  str="${str//\{PORT\}/$(( SVC_BASE_PORTS[idx] + OFFSET ))}"
  ib="$(yq -r ".services[$idx].inspector_port // 0" "$YAML" 2>/dev/null)"
  [[ "$ib" =~ ^[0-9]+$ && "$ib" != "0" ]] && str="${str//\{INSPECTOR_PORT\}/$(( ib + OFFSET ))}"
  for ((k=0; k<SVC_COUNT; k++)); do
    uk="$(printf '%s' "${SVC_LABELS[$k]}" | tr '[:lower:]' '[:upper:]')"
    ap=$(( SVC_BASE_PORTS[k] + OFFSET ))
    str="${str//\{${uk}_PORT\}/$ap}"
    str="${str//\{${uk}_URL\}/http://localhost:$ap}"
  done
  printf '%s' "$str"
}

# --- Resolved-environment manifest: .wt-env.json ------------------------------
# WHY A SECOND FILE. tmux-worktree.yaml is INTENT (base ports, policy, shared by
# every worktree); this is OUTCOME (what THIS worktree actually got). Without it a
# consumer has to find the yaml, have yq, know that `port:` is a base not a port,
# read .wt-port-offset separately, and do the arithmetic — five steps and a
# convention it must be told. With it, one query answers the only question that
# matters:  jq -r '.services[0].port' .wt-env.json
#
# The audience is any AGENT working in this worktree (Claude Code, a firstmate
# crewmate, CI) that must start services without knowing tmux, herdr or treehouse
# exist. It also records what LANDED — `wrangler_state: shared` in the yaml does
# not tell you whether you got a symlink, a real directory, or nothing at all.
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

MANIFEST="$WORKTREE_ABS/.wt-env.json"
{
  printf '{\n'
  printf '  "version": 1,\n'
  printf '  "worktree": "%s",\n' "$(json_escape "$WORKTREE_ABS")"
  printf '  "main": "%s",\n'     "$(json_escape "$MAIN_ROOT")"
  printf '  "branch": "%s",\n'   "$(json_escape "$(git -C "$WORKTREE_ABS" rev-parse --abbrev-ref HEAD 2>/dev/null)")"
  printf '  "offset": %s,\n'     "$OFFSET"
  printf '  "services": [\n'
  for ((m=0; m<SVC_COUNT; m++)); do
    m_label="$(json_escape "${SVC_LABELS[$m]}")"
    m_cwd="${SVC_CWDS[$m]}"
    m_base="${SVC_BASE_PORTS[$m]}"
    m_port=""
    [[ "$m_base" =~ ^[0-9]+$ ]] && m_port=$((m_base + OFFSET))
    m_insp="$(yq -r ".services[$m].inspector_port // \"\"" "$YAML" 2>/dev/null)"
    [[ "$m_insp" =~ ^[0-9]+$ ]] && m_insp=$((m_insp + OFFSET)) || m_insp=""
    # `cmd:` is the real key the launcher runs (there is no `start:`), and it
    # carries {PORT}/{LABEL_PORT} placeholders — resolve them so the manifest is
    # runnable as-is by an agent that never reads the yaml.
    m_cmd="$(yq -r ".services[$m].cmd // \"\"" "$YAML" 2>/dev/null)"
    [[ "$m_cmd" == "null" ]] && m_cmd=""
    [[ -n "$m_cmd" ]] && m_cmd="$(wt_expand "$m_cmd" "$m")"
    # What actually landed for .wrangler/state, not what was requested.
    m_state_path="$WORKTREE_ABS/${m_cwd%/}/.wrangler/state"
    [[ "$m_cwd" == "." ]] && m_state_path="$WORKTREE_ABS/.wrangler/state"
    if   [[ -L "$m_state_path" ]]; then m_landed="symlink"
    elif [[ -d "$m_state_path" ]]; then m_landed="copy"
    else                                m_landed="absent"; fi
    printf '    {"label": "%s", "cwd": "%s"' "$m_label" "$(json_escape "$m_cwd")"
    [[ -n "$m_port" ]] && printf ', "port": %s, "url": "http://localhost:%s"' "$m_port" "$m_port"
    [[ -n "$m_insp" ]] && printf ', "inspector_port": %s' "$m_insp"
    [[ -n "$m_cmd" ]] && printf ', "cmd": "%s"' "$(json_escape "$m_cmd")"
    # Resolved env: global `env:` first, then this service's own, same order and
    # precedence as the launcher's pane exports.
    printf ', "env": {'
    env_first=1
    while IFS=$'\t' read -r ek ev; do
      [[ -z "$ek" || "$ek" == "null" ]] && continue
      [[ $env_first -eq 0 ]] && printf ', '
      printf '"%s": "%s"' "$(json_escape "$ek")" "$(json_escape "$(wt_expand "$ev" "$m")")"
      env_first=0
    done < <( { yq -r '.env // {} | to_entries | .[] | [.key, .value] | @tsv' "$YAML" 2>/dev/null;
                yq -r ".services[$m].env // {} | to_entries | .[] | [.key, .value] | @tsv" "$YAML" 2>/dev/null; } )
    printf '}'

    printf ', "wrangler_state": "%s", "state_landed": "%s"}' \
      "$(json_escape "${SVC_STATE_MODE[$m]}")" "$m_landed"
    [[ $m -lt $((SVC_COUNT - 1)) ]] && printf ','
    printf '\n'
  done
  printf '  ],\n'
  printf '  "symlinks": ['
  for ((m=0; m<${#GLOBAL_SYMLINKS[@]}; m++)); do
    printf '"%s"' "$(json_escape "${GLOBAL_SYMLINKS[$m]}")"
    [[ $m -lt $(( ${#GLOBAL_SYMLINKS[@]} - 1 )) ]] && printf ', '
  done
  printf ']\n'
  printf '}\n'
} > "$MANIFEST"
echo "→ Wrote $MANIFEST (agents: jq -r '.services[0].port' .wt-env.json)" >&2

echo "" >&2
echo "✓ Worktree env wired at $WORKTREE_ABS" >&2
echo "  Start services: ~/.claude/skills/tmux-worktrees/scripts/tmux-worktrees.sh" >&2
