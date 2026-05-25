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

# Build dynamic status-right from YAML labels
STATUS_RIGHT="#[range=user|${MAIN_LABEL} fg=yellow bold] ${MAIN_LABEL} #[norange default]"
for lbl in "${SVC_LABELS[@]}"; do
  STATUS_RIGHT+=" #[range=user|${lbl} fg=cyan] ${lbl} #[norange default]"
done
STATUS_RIGHT+="  %H:%M "

export TMUX_WT_JUMP="$JUMP"
export TMUX_WT_SOCKET="$SOCKET"
export TMUX_WT_CONF="$CONF"

T() { tmux -L "$SOCKET" "$@"; }

# --- Flag parsing (must happen before NAMES population) ----------------------
# --add NAME: called from WorktreeCreate hook — adds one window to a running
# session without attaching. Falls through to full launch if no session yet.
ADD_NAME=""
if [[ "${1:-}" == "--add" ]]; then
  ADD_NAME="${2:-}"
  shift 2 2>/dev/null || true
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

  OFFSET=$(( (idx + 1) * 10 ))

  if $first && ! $session_exists; then
    # No session yet — create it with the first window.
    T -f "$CONF" new-session -d -s "$SESSION" -c "$DIR" -n "$w"
    first=false
    session_exists=true
  else
    # Session already exists (either pre-existing, or we just created it
    # in a previous iteration of this loop). Add a window.
    T new-window -t "$SESSION" -c "$DIR" -n "$w"
    first=false
  fi
  TARGET="$SESSION:$w"

  # Expose all service ports + URLs as window-level env vars
  for ((i=0; i<SVC_COUNT; i++)); do
    local_upper=$(printf '%s' "${SVC_LABELS[$i]}" | tr '[:lower:]' '[:upper:]')
    T set-environment -t "$TARGET" "${local_upper}_PORT" "$((SVC_BASE_PORTS[i] + OFFSET))"
    T set-environment -t "$TARGET" "${local_upper}_URL"  "http://localhost:$((SVC_BASE_PORTS[i] + OFFSET))"
  done

  # Main pane (right, large)
  MAIN_PANE=$(T display-message -p -t "$TARGET" '#{pane_id}')
  T set -pt "$MAIN_PANE" @role "$MAIN_LABEL"
  T send-keys -t "$MAIN_PANE" "$MAIN_CMD" C-m

  # Service panes (right column, stacked) — CLAUDE stays on the left
  PREV_PANE=""
  for ((i=0; i<SVC_COUNT; i++)); do
    lbl="${SVC_LABELS[$i]}"
    svc_dir="$DIR"
    [[ "${SVC_CWDS[$i]}" != "." ]] && svc_dir="$DIR/${SVC_CWDS[$i]}"

    cmd=$(expand_placeholders "${SVC_CMDS[$i]}" "$i" "$OFFSET")
    env_prefix=$(build_env_prefix "$i" "$OFFSET")

    # Gate against the background npm install spawned by link-worktree-env.sh.
    # If install is still running, wait until its pidfile clears. No-op when
    # node_modules is already populated (subsequent launches).
    pf="$DIR/.npm-install.pid"
    wait_cmd="while [ -f '$pf' ] && p=\$(cat '$pf' 2>/dev/null) && [ -n \"\$p\" ] && kill -0 \"\$p\" 2>/dev/null; do echo '  waiting for npm install (tail $DIR/.npm-install.log)...'; sleep 3; done; rm -f '$pf' 2>/dev/null"
    gated_cmd="${env_prefix}${wait_cmd}; $cmd"

    if [[ $i -eq 0 ]]; then
      T split-window -h -l "28%" -t "$MAIN_PANE" -c "$svc_dir"
    else
      T split-window -v -t "$PREV_PANE" -c "$svc_dir"
    fi

    PREV_PANE=$(T display-message -p -t "$TARGET" '#{pane_id}')
    T set -pt "$PREV_PANE" @role "$lbl"
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
fi

# --add mode: called from hook in background — just switch to the new window, don't attach
if [[ -n "$ADD_NAME" ]]; then
  T select-window -t "$SESSION:$ADD_NAME" 2>/dev/null || true
else
  attach_or_instruct
fi
