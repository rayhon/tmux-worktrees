#!/usr/bin/env bash
# tmux-worktrees.sh — generic tmux session launcher for git worktrees.
# All repo-specific config lives in scripts/tmux-worktree.yaml.
# Requires: yq (brew install yq)
#
# Port assignment is purely positional (alphabetical order, no stored state):
#   1st worktree → offset 10, 2nd → 20, 3rd → 30, …
#
# Usage:
#   ./scripts/tmux-worktrees.sh              # all worktrees
#   ./scripts/tmux-worktrees.sh name1 name2  # specific worktrees
#
# Re-running attaches to the existing session.
# Fresh start: tmux -L wt kill-server

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO=$(git rev-parse --show-toplevel)
SESSION=${TMUX_SESSION:-wt}
SOCKET=${TMUX_WT_SOCKET:-wt}
YAML="$REPO/tmux-worktree.yaml"

# Prefer repo-local copies of conf/jump so teams can customise them;
# fall back to the skill bundle so repos don't need to carry these files.
CONF="$REPO/scripts/tmux-worktree.conf"
[[ -f "$CONF" ]] || CONF="$SKILL_DIR/tmux-worktree.conf"
JUMP="$REPO/scripts/jump-pane.sh"
[[ -x "$JUMP" ]] || JUMP="$SKILL_DIR/jump-pane.sh"

[[ -f "$YAML" ]] || { echo "missing $YAML — run /tmux-worktrees to set up" >&2; exit 1; }
if ! command -v yq >/dev/null 2>&1; then
  echo "→ yq not found, installing via brew..." >&2
  brew install yq
fi
[[ -x "$JUMP" ]] || chmod +x "$JUMP"

# --- Parse YAML --------------------------------------------------------------
MAIN_LABEL=$(yq '.main.label' "$YAML")
MAIN_CMD=$(yq   '.main.cmd'   "$YAML")

SVC_COUNT=$(yq '.services | length' "$YAML")
SVC_LABELS=()
SVC_CWDS=()
SVC_BASE_PORTS=()
SVC_BASE_INSP=()
SVC_CMDS=()

for ((i=0; i<SVC_COUNT; i++)); do
  SVC_LABELS+=("$(yq ".services[$i].label"                   "$YAML")")
  SVC_CWDS+=(  "$(yq ".services[$i].cwd // \".\""            "$YAML")")
  SVC_BASE_PORTS+=("$(yq ".services[$i].port"                "$YAML")")
  SVC_BASE_INSP+=( "$(yq ".services[$i].inspector_port // 0" "$YAML")")
  SVC_CMDS+=(  "$(yq ".services[$i].cmd"                     "$YAML")")
done

# Build dynamic status-right from YAML labels.
# The active label is highlighted yellow/bold based on the @active_role
# session option (updated by pane-focus-in / after-select-pane hooks).
build_label() {
  local lbl="$1"
  printf '#[range=user|%s]#{?#{==:%s,#{@active_role}},#[fg=yellow bold],#[fg=cyan]} %s #[norange default]' \
    "$lbl" "$lbl" "$lbl"
}
STATUS_RIGHT="$(build_label "$MAIN_LABEL")"
for lbl in "${SVC_LABELS[@]}"; do
  STATUS_RIGHT+=" $(build_label "$lbl")"
done
STATUS_RIGHT+="  %H:%M "

export TMUX_WT_JUMP="$JUMP"
export TMUX_WT_SOCKET="$SOCKET"
export TMUX_WT_CONF="$CONF"

T() { tmux -L "$SOCKET" "$@"; }

# --- Prune stale windows -----------------------------------------------------
# Removing a git worktree (via `git worktree remove`, `claude` exit, or manual
# rm) does NOT touch tmux — Claude Code has no WorktreeRemove hook event, and a
# raw `git worktree remove` can't fire one anyway. So windows for deleted
# worktrees linger with panes sitting in a now-deleted directory.
#
# We reconcile on every launcher run instead (full launch AND `--add` from the
# WorktreeCreate hook): kill any session window whose worktree dir no longer
# exists. Keyed on dir existence — NOT on the NAMES arg list — so calling the
# launcher with an explicit subset of worktrees never kills the others.
prune_stale_windows() {
  T has-session -t "$SESSION" 2>/dev/null || return 0
  local wname
  while IFS= read -r wname; do
    [[ -n "$wname" ]] || continue
    # A window whose name maps to a live worktree dir stays. Anything else is a
    # window for a worktree that's been removed → kill it.
    [[ -d "$REPO/.claude/worktrees/$wname" ]] && continue
    echo "⟲ pruning stale tmux window '$wname' (worktree removed)" >&2
    T kill-window -t "$SESSION:$wname" 2>/dev/null || true
  done < <(T list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null)
}

# --- Flag parsing (must happen before NAMES population) ----------------------
# --add NAME: called from WorktreeCreate hook — adds one window to a running
# session without attaching. Falls through to full launch if no session yet.
ADD_NAME=""
if [[ "${1:-}" == "--add" ]]; then
  ADD_NAME="${2:-}"
  shift 2 2>/dev/null || true
fi

# --prune: reconcile stale windows against the live worktree set, then exit.
# Lets a worktree-removal flow (or the user) clean tmux without a full launch:
#   ~/.claude/skills/tmux-worktrees/scripts/tmux-worktrees.sh --prune
if [[ "${1:-}" == "--prune" ]]; then
  SESSION=${TMUX_SESSION:-wt}
  prune_stale_windows
  exit 0
fi

# --- Worktree list -----------------------------------------------------------
# Order matters: positional index → port offset (+10, +20, +30, ...).
# We sort by directory creation time (oldest first) so existing worktrees
# keep their offsets forever; new worktrees always land at the end and get
# a fresh offset. Alphabetical sorting would shift existing worktrees' ports
# when a new alphabetically-earlier name is added, colliding with their
# already-running dev servers.
if [[ $# -gt 0 ]]; then
  NAMES=("$@")
else
  # `stat -f %B` (macOS) prints birth time; `stat -c %W` on GNU. Use mtime
  # as a portable fallback that's close enough — the worktree dir's mtime is
  # set when `git worktree add` creates it and won't change unless touched.
  if stat -f %m . >/dev/null 2>&1; then
    STAT_FMT='stat -f %m'    # macOS / BSD
  else
    STAT_FMT='stat -c %Y'    # GNU
  fi
  NAMES=()
  while IFS= read -r line; do
    NAMES+=("${line#* }")
  done < <(
    for d in "$REPO/.claude/worktrees"/*/; do
      [[ -d "$d" ]] || continue
      ts=$($STAT_FMT "$d" 2>/dev/null || echo 0)
      printf '%s %s\n' "$ts" "$(basename "$d")"
    done | sort -n
  )
fi

[[ ${#NAMES[@]} -eq 0 ]] && {
  echo "No worktrees found under .claude/worktrees/" >&2
  echo "Create one with: claude --worktree <name>" >&2
  exit 1
}

# --- Shared port/URL exports -------------------------------------------------
# Returns `export <LABEL>_PORT=...; export <LABEL>_URL=...;` for every service,
# computed from the current worktree's OFFSET. Prepended to every pane's
# startup command so each pane's shell knows the per-worktree ports of ALL
# sibling services — without relying on `tmux set-environment`, which is
# session-scoped and gets clobbered every time a new worktree is added (each
# new window's set-environment call overwrites the prior worktree's values
# for the same key).
build_shared_port_exports() {
  local offset="$1"
  local out="" i u p
  for ((i=0; i<SVC_COUNT; i++)); do
    u=$(printf '%s' "${SVC_LABELS[$i]}" | tr '[:lower:]' '[:upper:]')
    p=$((SVC_BASE_PORTS[i] + offset))
    out+="export ${u}_PORT=$p; export ${u}_URL=http://localhost:$p; "
  done
  printf '%s' "$out"
}

# --- Env prefix construction -------------------------------------------------
# Reads `.env` at the root (global) and `.services[idx].env` (per-service).
# Returns a shell-safe `export K="V"; export K2="V2"; ` string with all
# placeholders expanded. Per-service entries override global.
build_env_prefix() {
  local svc_idx="$1"
  local offset="$2"
  local prefix=""
  local k v expanded

  # Global env first
  while IFS=$'\t' read -r k v; do
    [[ -z "$k" || "$k" == "null" ]] && continue
    expanded=$(expand_placeholders "$v" "$svc_idx" "$offset")
    prefix+="export $k=\"${expanded//\"/\\\"}\"; "
  done < <(yq -r '.env // {} | to_entries | .[] | [.key, .value] | @tsv' "$YAML" 2>/dev/null)

  # Per-service overrides
  while IFS=$'\t' read -r k v; do
    [[ -z "$k" || "$k" == "null" ]] && continue
    expanded=$(expand_placeholders "$v" "$svc_idx" "$offset")
    prefix+="export $k=\"${expanded//\"/\\\"}\"; "
  done < <(yq -r ".services[$svc_idx].env // {} | to_entries | .[] | [.key, .value] | @tsv" "$YAML" 2>/dev/null)

  printf '%s' "$prefix"
}

# --- Placeholder expansion ---------------------------------------------------
# Substitutes {PORT}, {INSPECTOR_PORT}, {LABEL_PORT}, {LABEL_URL} for a given
# service index using the actual ports computed for the current worktree.
expand_placeholders() {
  local str="$1"
  local idx="$2"
  local offset="$3"

  str="${str//\{PORT\}/$((SVC_BASE_PORTS[idx] + offset))}"

  local ib="${SVC_BASE_INSP[$idx]}"
  [[ "$ib" != "0" ]] && str="${str//\{INSPECTOR_PORT\}/$((ib + offset))}"

  for ((k=0; k<SVC_COUNT; k++)); do
    local uk
    uk=$(printf '%s' "${SVC_LABELS[$k]}" | tr '[:lower:]' '[:upper:]')
    local ap=$((SVC_BASE_PORTS[k] + offset))
    str="${str//\{${uk}_PORT\}/$ap}"
    str="${str//\{${uk}_URL\}/http://localhost:$ap}"
  done

  printf '%s' "$str"
}

# --- Session -----------------------------------------------------------------
session_exists=false
T has-session -t "$SESSION" 2>/dev/null && session_exists=true

# Reconcile FIRST: drop windows for worktrees that have since been removed, so a
# stale window can never outlive its worktree past the next launcher run. Must
# happen before the attach below (attach execs and never returns).
prune_stale_windows

attach_or_instruct() {
  if [[ -t 0 && -t 1 ]]; then
    exec tmux -L "$SOCKET" attach -t "$SESSION"
  else
    echo "" >&2
    echo "✓ tmux session '$SESSION' is ready (socket: $SOCKET)." >&2
    echo "  No TTY available — attach from your terminal with:" >&2
    echo "    tmux -L $SOCKET attach -t $SESSION" >&2
  fi
}

if $session_exists && [[ -n "$ADD_NAME" ]]; then
  # Session running and we only need to add one window — skip attach at end
  :
elif $session_exists; then
  attach_or_instruct
fi

# --- One window per worktree (idempotent: skip existing windows) -------------
first=true
for idx in "${!NAMES[@]}"; do
  w="${NAMES[$idx]}"
  DIR="$REPO/.claude/worktrees/$w"
  [[ -d "$DIR" ]] || { echo "⚠ worktree '$w' not found — skipping" >&2; continue; }

  # Skip windows that already exist in a running session
  if $session_exists && T list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$w"; then
    first=false
    continue
  fi

  # Resolve this worktree's offset from the durable `.wt-port-offset` marker
  # written by link-worktree-env.sh at creation. That marker is the SINGLE
  # source of truth, so the per-pane PORT exports below match the ports already
  # baked into the worktree's env files — no "8787 vs offset" drift. The two
  # fallbacks (env-file PORT, then positional mtime order) only cover legacy
  # worktrees created before the marker existed.
  OFFSET=0
  if [[ -f "$DIR/.wt-port-offset" ]]; then
    OFFSET=$(tr -dc '0-9' < "$DIR/.wt-port-offset")
  fi
  if [[ -z "$OFFSET" || "$OFFSET" -le 0 ]]; then
    for ((i=0; i<SVC_COUNT; i++)); do
      base="${SVC_BASE_PORTS[$i]}"
      cwd="${SVC_CWDS[$i]}"
      for envf in "$DIR/$cwd/.env.local" "$DIR/$cwd/.dev.vars"; do
        [[ -f "$envf" ]] || continue
        # `|| true` is REQUIRED: under `set -euo pipefail`, a no-match grep makes
        # this pipeline exit non-zero, the `port=$(...)` assignment inherits that
        # status, and `set -e` aborts the whole script — BEFORE the session is
        # ever created. That manifests as `tmux -L wt attach` finding no server.
        # An env file with no PORT= line (e.g. mcp-hub's .dev.vars) is normal, so
        # swallow the failure and let the `[[ -n "$port" ]]` check below skip it.
        port=$(grep -E '^PORT=' "$envf" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]' || true)
        [[ -n "$port" ]] || continue
        OFFSET=$(( port - base ))
        break 2
      done
    done
  fi
  if [[ -z "$OFFSET" || "$OFFSET" -le 0 ]]; then
    OFFSET=$(( (idx + 1) * 10 ))
  fi

  if $first && ! $session_exists; then
    # No session yet — create it with the first window.
    T -f "$CONF" new-session -d -s "$SESSION" -c "$DIR" -n "$w"
    first=false
    session_exists=true
  else
    # Session already exists (either pre-existing, or we just created it
    # in a previous iteration of this loop). Add a window. The trailing colon
    # in "$SESSION:" tells tmux to pick the next FREE index — without it,
    # `new-window -t "$SESSION"` targets the current window's index and fails
    # with "create window failed: index 1 in use" under base-index 1 when
    # adding to an already-running session (e.g. a second `--add`).
    T new-window -t "$SESSION:" -c "$DIR" -n "$w"
    first=false
  fi
  TARGET="$SESSION:$w"

  # Per-worktree shared port/URL exports. Sent into every pane's shell so each
  # pane sees this worktree's sibling ports — independent of other worktrees.
  #
  # NOTE: we deliberately do NOT use `tmux set-environment -t TARGET` here.
  # `-t` on set-environment accepts a target-session, not a target-window, so
  # the values would land at session scope and every subsequent `new-window`
  # for a different worktree would silently overwrite the same keys. The bug
  # showed up as "I created worktree A on port 8797, then worktree B on 8807,
  # and now A's mcp pane reads 8807 from MCP_PORT". Per-pane shell exports
  # are the only reliable scoping mechanism in tmux for this.
  SHARED_EXPORTS=$(build_shared_port_exports "$OFFSET")

  # Main pane (right, large)
  MAIN_PANE=$(T display-message -p -t "$TARGET" '#{pane_id}')
  T set -pt "$MAIN_PANE" @role "$MAIN_LABEL"
  T send-keys -t "$MAIN_PANE" "${SHARED_EXPORTS}clear; $MAIN_CMD" C-m

  # Service panes (right column, stacked) — CLAUDE stays on the left
  PREV_PANE=""
  for ((i=0; i<SVC_COUNT; i++)); do
    lbl="${SVC_LABELS[$i]}"
    svc_dir="$DIR"
    [[ "${SVC_CWDS[$i]}" != "." ]] && svc_dir="$DIR/${SVC_CWDS[$i]}"

    cmd=$(expand_placeholders "${SVC_CMDS[$i]}" "$i" "$OFFSET")
    env_prefix=$(build_env_prefix "$i" "$OFFSET")
    # Each service pane gets its OWN PORT so plain `npm run dev` etc. work
    # without --port flags in package.json. Frameworks that read
    # process.env.PORT (Next.js, Express, Vite, …) bind to the right port
    # automatically. Wrangler and other frameworks that ignore PORT still
    # need an explicit --port {PORT} in the yaml cmd.
    local_port=$((SVC_BASE_PORTS[i] + OFFSET))
    # Also export INSPECTOR_PORT when the service declares one in yaml.
    # Lets `npm run dev` in the pane pick up the worktree-offset inspector
    # port directly (e.g. `wrangler dev --inspector-port ${INSPECTOR_PORT:-…}`)
    # without needing a yaml-supplied CLI flag — so manual restarts after
    # Ctrl+C work without inspector-port collisions between worktrees.
    inspector_export=""
    if [[ "${SVC_BASE_INSP[$i]}" != "0" ]]; then
      inspector_export="export INSPECTOR_PORT=$((SVC_BASE_INSP[$i] + OFFSET)); "
    fi
    # Prepend sibling-service port/URL exports so cross-service lookups (e.g.
    # web pane reading MCP_PORT to call mcp-hub) work per-worktree.
    env_prefix="${SHARED_EXPORTS}export PORT=$local_port; ${inspector_export}${env_prefix}"

    # Gate against the background npm install spawned by link-worktree-env.sh.
    # Delegates to the sidecar so the pane cmd stays a one-liner and the escape
    # rules can't break going through bash → tmux send-keys → shell.
    wait_cmd="bash ~/.claude/skills/tmux-worktrees/scripts/wait-for-install.sh '$DIR'"
    gated_cmd="${env_prefix}${wait_cmd}; $cmd"

    if [[ $i -eq 0 ]]; then
      T split-window -h -l "28%" -t "$MAIN_PANE" -c "$svc_dir"
    else
      T split-window -v -t "$PREV_PANE" -c "$svc_dir"
    fi

    PREV_PANE=$(T display-message -p -t "$TARGET" '#{pane_id}')
    T set -pt "$PREV_PANE" @role "$lbl"
    # Persist the launch command on the pane so `prefix r` can re-run it
    # after the user Ctrl+C's the dev server. send-keys leaves no record
    # tmux can recover on its own, so we have to stash it ourselves.
    T set -pt "$PREV_PANE" @start_cmd "$gated_cmd"
    T send-keys -t "$PREV_PANE" "$gated_cmd" C-m
  done

  T select-layout -t "$TARGET" -E
  T select-pane  -t "$MAIN_PANE"
  T resize-pane -Z -t "$MAIN_PANE"
done

# Always re-apply the dynamic status bar after the loop.
# This survives config reloads (which would otherwise clobber it with the
# default `  %H:%M ` in tmux-worktree.conf) and runs on every launcher call
# regardless of whether windows were added or skipped.
if T has-session -t "$SESSION" 2>/dev/null; then
  T set -g status-right        "$STATUS_RIGHT"
  T set -g status-right-length 200
  # Seed the active-role tracker so the status bar shows a highlight from
  # the moment the session is created. Subsequent pane-focus-in /
  # after-select-pane hooks (in tmux-worktree.conf) keep it up to date.
  T set -g @active_role        "$MAIN_LABEL"
fi

# --add mode: called from hook in background — just switch to the new window, don't attach
if [[ -n "$ADD_NAME" ]]; then
  T select-window -t "$SESSION:$ADD_NAME" 2>/dev/null || true
else
  attach_or_instruct
fi
