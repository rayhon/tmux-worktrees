#!/usr/bin/env bash
# wt-pool.sh — warm worktree pool: lease/retire git worktrees so a new task
# reuses an already-provisioned tree (node_modules + env + port offset warm)
# instead of paying `npm install` up front.
#
# DRAFT — see WORKTREE-RECYCLE-DESIGN.md at the repo root for the full model.
#
# Model in one line: parked warm slots are `.claude/worktrees/_pool-N`; a lease
# does `git worktree move _pool-N <branch>` so the launcher (which keys
# window==dir==identity) treats it as an ordinary branch-named worktree with
# zero changes. Retire moves it back. node_modules/env/offset travel with the
# same-filesystem rename.
#
# Data-safety (this repo's topology): auth lives in cloud Neon (shared via env,
# no local DB to drift); real data lives in R2 whose dev blobs are symlinked
# from parent (always current). The only per-slot local state is SQLite locks,
# cleared on every lease. So a recycled slot never serves stale data.
#
# Commands:
#   wt-pool.sh provision [n]        # create n warm parked slots (default 1)
#   wt-pool.sh lease <branch> [base]# grab a warm slot, rebind to branch, launch
#   wt-pool.sh retire <branch>      # reset + park the slot back (dirty-guarded)
#   wt-pool.sh status               # show the registry
#
# Requires: git, jq, flock (util-linux; on macOS `brew install flock`), and the
# sibling scripts link-worktree-env.sh + tmux-worktrees.sh.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git rev-parse --show-toplevel)"
WT_DIR="$REPO/.claude/worktrees"
REGISTRY="$REPO/.wt-pool.json"
LOCK="$REPO/.wt-pool.lock"
YAML="$REPO/tmux-worktree.yaml"
LINK_ENV="$SKILL_DIR/link-worktree-env.sh"
LAUNCHER="$SKILL_DIR/tmux-worktrees.sh"

DEFAULT_BASE="${WT_POOL_BASE:-$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || echo main)}"
HEADROOM="$(yq '.headroom // 2'  "$YAML" 2>/dev/null || echo 2)"
POOL_MAX="$(yq '.pool_max // 6'  "$YAML" 2>/dev/null || echo 6)"

die() { echo "wt-pool: $*" >&2; exit 1; }
log() { echo "→ $*" >&2; }

command -v jq   >/dev/null || die "jq not found"
command -v git  >/dev/null || die "git not found"
[[ -f "$YAML" ]] || die "missing $YAML — run /tmux-worktrees first"

# --- registry helpers (all mutations under flock) ----------------------------
reg_init() { [[ -f "$REGISTRY" ]] || echo '{"slots":{}}' > "$REGISTRY"; }

# Run a jq transform on the registry atomically. Usage: reg_edit '<jq program>' [args...]
reg_edit() {
  local prog="$1"; shift
  local tmp; tmp="$(mktemp)"
  jq "$@" "$prog" "$REGISTRY" > "$tmp" && mv "$tmp" "$REGISTRY"
}

# Lowest-numbered free slot name, or empty.
first_free_slot() {
  jq -r '[.slots | to_entries[] | select(.value.state=="free") | .key] | sort | .[0] // empty' "$REGISTRY"
}

# Next unused _pool-N index.
next_slot_name() {
  local n=1
  while jq -e --arg s "_pool-$n" '.slots[$s]' "$REGISTRY" >/dev/null 2>&1 \
        || [[ -e "$WT_DIR/_pool-$n" ]]; do n=$((n+1)); done
  echo "_pool-$n"
}

slot_count() { jq -r '.slots | length' "$REGISTRY"; }
free_count()  { jq -r '[.slots[] | select(.state=="free")] | length' "$REGISTRY"; }

sha1_of() { [[ -f "$1" ]] && (sha1sum "$1" 2>/dev/null || shasum "$1") | awk '{print $1}'; }

# --- provision: create a warm parked slot ------------------------------------
# Creates `_pool-N` as a detached worktree at base, wires env (which kicks off
# the background npm install), records lockfile hash baseline, marks it free.
do_provision_one() {
  reg_init
  local slot; slot="$(next_slot_name)"
  local dir="$WT_DIR/$slot"
  [[ "$(slot_count)" -lt "$POOL_MAX" ]] || { log "pool_max=$POOL_MAX reached — not provisioning"; return 1; }

  log "provisioning $slot (detached at $DEFAULT_BASE)"
  git -C "$REPO" worktree add --detach "$dir" "$DEFAULT_BASE" >&2
  "$LINK_ENV" "$dir" >&2 || true    # kicks off background npm install

  local lf; lf="$(sha1_of "$dir/package-lock.json" || true)"
  [[ -n "${lf:-}" ]] && printf '%s\n' "$lf" > "$dir/.npm-install.lock-hash"

  reg_edit '.slots[$s] = {state:"free", branch:null}' --arg s "$slot"
  log "$slot parked (installing in background)"
}

cmd_provision() {
  local n="${1:-1}"
  for ((i=0; i<n; i++)); do
    ( flock 9; do_provision_one ) 9>"$LOCK" || true
  done
}

# --- claim the first free slot for a branch, atomically. Prints slot or "". --
claim_free_slot() {
  local branch="$1"
  flock 9
  reg_init
  local s; s="$(first_free_slot)"
  [[ -z "$s" ]] && return 0
  jq --arg s "$s" --arg b "$branch" \
    '.slots[$s] = {state:"leased", branch:$b}' "$REGISTRY" > "$REGISTRY.tmp" \
    && mv "$REGISTRY.tmp" "$REGISTRY"
  printf '%s' "$s"
} 9>"$LOCK"

# --- lease: warm slot → branch-named live tree, launch window ----------------
cmd_lease() {
  local branch="${1:-}"; local base="${2:-$DEFAULT_BASE}"
  [[ -n "$branch" ]] || die "usage: wt-pool.sh lease <branch> [base]"
  reg_init

  [[ -e "$WT_DIR/$branch" ]] && die "worktree '$branch' already exists"

  # --- claim a slot; provision on demand if the pool is dry ---
  local slot; slot="$(claim_free_slot "$branch")"
  if [[ -z "$slot" ]]; then
    log "no free slot — provisioning one on demand (pays install this time)"
    ( flock 9; do_provision_one ) 9>"$LOCK"
    slot="$(claim_free_slot "$branch")"
    [[ -n "$slot" ]] || die "could not obtain a slot"
  fi

  local live="$WT_DIR/$branch"
  log "leasing $slot → $branch"

  # 1. move warm slot into branch-named identity (same-fs rename, carries deps)
  git -C "$REPO" worktree move "$WT_DIR/$slot" "$live"

  # 2. rebind git state; clean only untracked non-ignored cruft (NO -x)
  git -C "$live" fetch --quiet || true
  git -C "$live" checkout -B "$branch" "$base"
  git -C "$live" reset --hard
  git -C "$live" clean -fd

  # 3. dependency-drift gate: reinstall ONLY if the lockfile changed
  local new old
  new="$(sha1_of "$live/package-lock.json" || true)"
  old="$(cat "$live/.npm-install.lock-hash" 2>/dev/null || true)"
  if [[ -n "${new:-}" && "$new" != "${old:-}" ]]; then
    log "lockfile changed — forcing reinstall for $branch"
    rm -f "$live/.npm-install.ok"
  fi

  # 4. clear stale local R2 (miniflare) SQLite locks; keep the data files
  find "$live" -path '*/.wrangler/state/*' \
    \( -name '*.sqlite-shm' -o -name '*.sqlite-wal' \) -delete 2>/dev/null || true

  # 5. re-wire env (same persisted offset; install auto-skips unless step 3 cleared it)
  "$LINK_ENV" "$live" >&2
  [[ -n "${new:-}" ]] && printf '%s\n' "$new" > "$live/.npm-install.lock-hash"

  # 6. build/attach the tmux window via the existing launcher (window==branch)
  "$LAUNCHER" --add "$branch" < /dev/null || true

  # 7. keep the pool warm
  top_up_headroom

  log "leased: $branch ready (attach: tmux -L wt attach -t wt)"
}

# --- retire: reset + park the slot back --------------------------------------
cmd_retire() {
  local branch="${1:-}"
  [[ -n "$branch" ]] || die "usage: wt-pool.sh retire <branch>"
  reg_init
  local live="$WT_DIR/$branch"
  [[ -d "$live" ]] || die "no live worktree '$branch'"

  # which slot backs this branch?
  local slot
  slot="$(jq -r --arg b "$branch" '[.slots|to_entries[]|select(.value.branch==$b)|.key][0] // empty' "$REGISTRY")"
  [[ -n "$slot" ]] || die "no registry slot maps to '$branch' (was it leased via wt-pool?)"

  # --- dirty guard (mirrors fleet teardown): refuse to lose work ---
  if [[ -n "$(git -C "$live" status --porcelain)" ]]; then
    ( flock 9; reg_edit '.slots[$s].state="dirty"' --arg s "$slot" ) 9>"$LOCK"
    die "'$branch' has uncommitted changes — commit/stash first (slot marked dirty)"
  fi
  # unlanded = has commits not reachable from base and not on any remote-tracking ref
  local unlanded
  unlanded="$(git -C "$live" rev-list "$branch" --not "$DEFAULT_BASE" --remotes 2>/dev/null | head -1)"
  if [[ -n "$unlanded" ]]; then
    ( flock 9; reg_edit '.slots[$s].state="dirty"' --arg s "$slot" ) 9>"$LOCK"
    die "'$branch' has unlanded commits (not on $DEFAULT_BASE or any remote) — merge/push first (slot marked dirty)"
  fi

  log "retiring $branch → $slot"
  tmux -L "${TMUX_WT_SOCKET:-wt}" kill-window -t "${TMUX_SESSION:-wt}:$branch" 2>/dev/null || true

  git -C "$live" checkout "$DEFAULT_BASE"
  git -C "$live" reset --hard
  git -C "$live" clean -fd
  git -C "$REPO" worktree move "$live" "$WT_DIR/$slot"

  ( flock 9; reg_edit '.slots[$s]={state:"free", branch:null}' --arg s "$slot" ) 9>"$LOCK"
  log "parked: $slot free (warm)"
}

# --- headroom: keep K free warm slots ready ----------------------------------
top_up_headroom() {
  local free total; free="$(free_count)"; total="$(slot_count)"
  while [[ "$free" -lt "$HEADROOM" && "$total" -lt "$POOL_MAX" ]]; do
    ( flock 9; do_provision_one ) 9>"$LOCK" || break
    free="$(free_count)"; total="$(slot_count)"
  done
}

cmd_status() {
  reg_init
  echo "pool: $(slot_count) slots, $(free_count) free (headroom target K=$HEADROOM, max=$POOL_MAX)"
  jq -r '.slots | to_entries[] | "  \(.key)\t\(.value.state)\t\(.value.branch // "-")"' "$REGISTRY" | column -t -s $'\t'
}

# --- dispatch ----------------------------------------------------------------
case "${1:-}" in
  provision) shift; cmd_provision "$@" ;;
  lease)     shift; cmd_lease "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  status)    shift; cmd_status ;;
  *) cat >&2 <<EOF
usage: wt-pool.sh <command>
  provision [n]          create n warm parked slots (default 1)
  lease <branch> [base]  grab a warm slot, rebind to branch, launch window
  retire <branch>        reset + park the slot back (refuses unlanded work)
  status                 show the pool registry
EOF
    exit 1 ;;
esac
