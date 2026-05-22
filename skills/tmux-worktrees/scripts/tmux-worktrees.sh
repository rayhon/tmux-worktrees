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

# --- Worktree list (sorted alphabetically → stable port assignment) ----------
if [[ $# -gt 0 ]]; then
  NAMES=("$@")
else
  NAMES=()
  for d in "$REPO/.claude/worktrees"/*/; do
    [[ -d "$d" ]] || continue
    NAMES+=("$(basename "$d")")
  done
fi

[[ ${#NAMES[@]} -eq 0 ]] && {
  echo "No worktrees found under .claude/worktrees/" >&2
  echo "Create one with: claude --worktree <name>" >&2
  exit 1
}

# Sort for stable positional offsets
IFS=$'\n' NAMES=($(printf '%s\n' "${NAMES[@]}" | sort)) unset IFS

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

# --add NAME: called from WorktreeCreate hook — adds one window to a running
# session without attaching. Falls through to full launch if no session yet.
ADD_NAME=""
if [[ "${1:-}" == "--add" ]]; then
  ADD_NAME="${2:-}"
  shift 2 2>/dev/null || true
fi

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

  if $first; then
    T -f "$CONF" new-session -d -s "$SESSION" -c "$DIR" -n "$w"
    T set -g status-right        "$STATUS_RIGHT"
    T set -g status-right-length 200
    first=false
  else
    T new-window -t "$SESSION" -c "$DIR" -n "$w"
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

  # Service panes (left column, stacked)
  PREV_PANE=""
  for ((i=0; i<SVC_COUNT; i++)); do
    lbl="${SVC_LABELS[$i]}"
    svc_dir="$DIR"
    [[ "${SVC_CWDS[$i]}" != "." ]] && svc_dir="$DIR/${SVC_CWDS[$i]}"

    cmd=$(expand_placeholders "${SVC_CMDS[$i]}" "$i" "$OFFSET")

    if [[ $i -eq 0 ]]; then
      T split-window -hb -l "28%" -t "$MAIN_PANE" -c "$svc_dir"
    else
      T split-window -v -t "$PREV_PANE" -c "$svc_dir"
    fi

    PREV_PANE=$(T display-message -p -t "$TARGET" '#{pane_id}')
    T set -pt "$PREV_PANE" @role "$lbl"
    T send-keys -t "$PREV_PANE" "$cmd" C-m
  done

  T select-layout -t "$TARGET" -E
  T select-pane  -t "$MAIN_PANE"
  T resize-pane -Z -t "$MAIN_PANE"
done

# --add mode: called from hook in background — just switch to the new window, don't attach
if [[ -n "$ADD_NAME" ]]; then
  T select-window -t "$SESSION:$ADD_NAME" 2>/dev/null || true
else
  attach_or_instruct
fi
