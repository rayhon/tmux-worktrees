#!/usr/bin/env bash
# herdr-worktrees.sh — pane creation per git worktree, over herdr.
#
# Distilled from tmux-worktrees.sh: keeps the valuable port/env/install-gating
# logic, drops the tmux plumbing (status bar, keybindings, layout/base-index
# quirks, the .claude/worktrees mtime scan + stale-tab prune). herdr targets
# tabs/panes by explicit dir and by the ids it returns, so none of that is
# needed here.
#
# For each worktree it opens ONE herdr tab (in a persistent per-repo workspace)
# with a MAIN pane (claude/shell) plus one pane per service from
# tmux-worktree.yaml. Panes open in the right dir (worktree root, or
# worktree/<cwd> for a service), get per-worktree offset ports as env exports,
# and each service cmd is gated behind the background npm install.
#
# Config: the SAME tmux-worktree.yaml (main.label/cmd, services[].label/cwd/
# port/inspector_port/cmd/env, top-level env). Requires herdr + jq + yq.
#
# Usage:
#   ./herdr-worktrees.sh <worktree-dir> [<worktree-dir> ...]
#   # e.g. treehouse slots:  ./herdr-worktrees.sh ~/.treehouse/<hash>/<slot>/agent-board
#   # e.g. classic layout:   ./herdr-worktrees.sh "$REPO"/.claude/worktrees/feature-x
# The tab is labeled after the dir's basename. Re-running skips a tab that
# already exists (idempotent).
#
# Port offset per worktree: the durable `.wt-port-offset` marker is the single
# source of truth; falls back to an env-file PORT, then a fixed +10.
#
# SAFETY: every herdr call goes through H(), which pins BOTH HERDR_SESSION and a
# trailing `--session` flag — the env var alone is NOT safe once another herdr
# server is bound (firstmate's 2026-07-02 cleanup bug). This script never runs
# server/session stop|delete|kill-server and never targets `default` for
# teardown; it only creates/closes the workspace, tabs, and panes it owns.

set -euo pipefail

REPO=$(git rev-parse --show-toplevel)
YAML="$REPO/tmux-worktree.yaml"
SESSION=${HERDR_WT_SESSION:-${HERDR_SESSION:-default}}
WS_LABEL=${HERDR_WT_WORKSPACE:-wt-$(basename "$REPO")}

[[ -f "$YAML" ]] || { echo "missing $YAML — run /tmux-worktrees to set up" >&2; exit 1; }
command -v herdr >/dev/null 2>&1 || { echo "herdr not found — https://herdr.dev" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found (brew install jq)" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "→ yq not found, installing via brew..." >&2; brew install yq; }

# --sync-labels: relabel every existing tab in this repo's workspace to its
# worktree's CURRENT branch (no dirs needed). Wire it to a git post-checkout
# hook to keep tab names tracking the active branch automatically.
SYNC_ONLY=""
if [[ "${1:-}" == "--sync-labels" ]]; then SYNC_ONLY=1; shift; fi

[[ -n "$SYNC_ONLY" || $# -gt 0 ]] || { echo "usage: $0 [--sync-labels] <worktree-dir[=name]> ..." >&2; exit 1; }

H() { HERDR_SESSION="$SESSION" herdr "$@" --session "$SESSION"; }

# --- Parse YAML --------------------------------------------------------------
MAIN_LABEL=$(yq '.main.label' "$YAML")
MAIN_CMD=$(yq   '.main.cmd'   "$YAML")
# Optional shared layout block (drives BOTH launchers). Absent → built-in
# defaults, so a yaml without `layout:` behaves exactly as before.
#   layout:
#     main_ratio: 0.70   # fraction of width the MAIN (CLAUDE) pane keeps
#     zoom_main: false   # open zoomed on the main pane
YAML_MAIN_RATIO=$(yq -r '.layout.main_ratio // ""' "$YAML" 2>/dev/null)
YAML_ZOOM_MAIN=$(yq -r '.layout.zoom_main // ""' "$YAML" 2>/dev/null)
[[ "$YAML_ZOOM_MAIN" == "true" ]] && YAML_ZOOM_MAIN=1 || YAML_ZOOM_MAIN=""
SVC_COUNT=$(yq '.services | length' "$YAML")
SVC_LABELS=(); SVC_CWDS=(); SVC_BASE_PORTS=(); SVC_BASE_INSP=(); SVC_CMDS=()
for ((i=0; i<SVC_COUNT; i++)); do
  SVC_LABELS+=(   "$(yq ".services[$i].label"                   "$YAML")")
  SVC_CWDS+=(     "$(yq ".services[$i].cwd // \".\""            "$YAML")")
  SVC_BASE_PORTS+=("$(yq ".services[$i].port"                   "$YAML")")
  SVC_BASE_INSP+=( "$(yq ".services[$i].inspector_port // 0"    "$YAML")")
  SVC_CMDS+=(     "$(yq ".services[$i].cmd"                     "$YAML")")
done

# Per-worktree `export <LABEL>_PORT/_URL=` for every service — so each pane sees
# this worktree's sibling ports. Per-pane shell exports, never workspace/tab env
# (which would be shared across worktrees).
build_shared_port_exports() {
  local offset="$1" out="" i u p
  for ((i=0; i<SVC_COUNT; i++)); do
    u=$(printf '%s' "${SVC_LABELS[$i]}" | tr '[:lower:]' '[:upper:]')
    p=$((SVC_BASE_PORTS[i] + offset))
    out+="export ${u}_PORT=$p; export ${u}_URL=http://localhost:$p; "
  done
  printf '%s' "$out"
}

# Global `.env` + per-service `.services[i].env`, placeholders expanded, per-svc
# overrides global. Shell-safe export string.
build_env_prefix() {
  local svc_idx="$1" offset="$2" prefix="" k v expanded
  while IFS=$'\t' read -r k v; do
    [[ -z "$k" || "$k" == "null" ]] && continue
    expanded=$(expand_placeholders "$v" "$svc_idx" "$offset")
    prefix+="export $k=\"${expanded//\"/\\\"}\"; "
  done < <(yq -r '.env // {} | to_entries | .[] | [.key, .value] | @tsv' "$YAML" 2>/dev/null)
  while IFS=$'\t' read -r k v; do
    [[ -z "$k" || "$k" == "null" ]] && continue
    expanded=$(expand_placeholders "$v" "$svc_idx" "$offset")
    prefix+="export $k=\"${expanded//\"/\\\"}\"; "
  done < <(yq -r ".services[$svc_idx].env // {} | to_entries | .[] | [.key, .value] | @tsv" "$YAML" 2>/dev/null)
  printf '%s' "$prefix"
}

# {PORT} {INSPECTOR_PORT} {LABEL_PORT} {LABEL_URL} → this worktree's real ports.
expand_placeholders() {
  local str="$1" idx="$2" offset="$3"
  str="${str//\{PORT\}/$((SVC_BASE_PORTS[idx] + offset))}"
  local ib="${SVC_BASE_INSP[$idx]}"
  [[ "$ib" != "0" ]] && str="${str//\{INSPECTOR_PORT\}/$((ib + offset))}"
  for ((k=0; k<SVC_COUNT; k++)); do
    local uk; uk=$(printf '%s' "${SVC_LABELS[$k]}" | tr '[:lower:]' '[:upper:]')
    local ap=$((SVC_BASE_PORTS[k] + offset))
    str="${str//\{${uk}_PORT\}/$ap}"; str="${str//\{${uk}_URL\}/http://localhost:$ap}"
  done
  printf '%s' "$str"
}

# Offset: durable marker (single source of truth) → env-file PORT → +10.
resolve_offset() {
  local dir="$1" fallback="$2" off=0 i base cwd envf port
  if [[ -f "$dir/.wt-port-offset" ]]; then off=$(tr -dc '0-9' < "$dir/.wt-port-offset"); fi
  if [[ -z "$off" || "$off" -le 0 ]]; then
    for ((i=0; i<SVC_COUNT; i++)); do
      base="${SVC_BASE_PORTS[$i]}"; cwd="${SVC_CWDS[$i]}"
      for envf in "$dir/$cwd/.env.local" "$dir/$cwd/.dev.vars"; do
        [[ -f "$envf" ]] || continue
        port=$(grep -E '^PORT=' "$envf" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]' || true)
        [[ -n "$port" ]] || continue
        off=$(( port - base )); break 2
      done
    done
  fi
  [[ -z "$off" || "$off" -le 0 ]] && off=$(( fallback ))
  printf '%s' "$off"
}

# Tab label for a worktree: explicit override → current branch → <basename>-<slot>.
# Reads the branch LIVE so it reflects the worktree's current checkout.
label_for_dir() {
  local dir="$1" override="${2:-}" w slot
  if [[ -n "$override" ]]; then
    w="$override"
  else
    w=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null || true)
    if [[ -z "$w" ]]; then
      # Detached HEAD = no branch = a free/released worktree. Show it as free
      # (never a bare commit sha), keyed to its treehouse slot when there is one.
      slot=$(printf '%s\n' "$dir" | sed -nE 's#.*/\.treehouse/[^/]+/([0-9]+)(/|$).*#\1#p')
      w="free${slot:+-$slot}"
    fi
  fi
  printf '%s' "${w//\//-}"
}

# --- herdr server + workspace ------------------------------------------------
server_ensure() {
  local running i
  running=$(H status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
  [[ "$running" == "true" ]] && return 0
  ( H server >/dev/null 2>&1 & ) || return 1
  for i in $(seq 1 20); do
    running=$(H status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
    [[ "$running" == "true" ]] && return 0
    sleep 0.5
  done
  echo "herdr server for '$SESSION' did not start within 10s" >&2; return 1
}

# Persistent per-repo workspace; when we create it, herdr seeds one default tab
# (label "1") we prune once a real tab exists (closing a workspace's last tab
# deletes the workspace — verified). Communicates via GLOBALS (WSID,
# SEEDED_TAB_ID), never stdout: it MUST be called as a plain statement, not
# through $(...) — a command-substitution subshell would discard the globals
# (the exact pitfall firstmate's herdr adapter documents).
WSID=""
SEEDED_TAB_ID=""
workspace_ensure() {
  local out
  WSID=$(H workspace list 2>/dev/null | jq -r --arg want "$WS_LABEL" \
    '.result.workspaces[]? | select(.label == $want) | .workspace_id' 2>/dev/null | head -1)
  [[ -n "$WSID" ]] && return 0
  out=$(H workspace create --cwd "$REPO" --label "$WS_LABEL" --no-focus 2>/dev/null) || return 1
  WSID=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  [[ -n "$WSID" ]] || return 1
  SEEDED_TAB_ID=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  return 0
}

prune_seeded_default_tab() {
  local wsid="$1" tab_id="$2" tabs count label
  [[ -n "$tab_id" ]] || return 0
  tabs=$(H tab list --workspace "$wsid" 2>/dev/null) || return 0
  count=$(printf '%s' "$tabs" | jq -r '.result.tabs? // [] | length' 2>/dev/null)
  case "$count" in ''|*[!0-9]*|0|1) return 0 ;; esac
  label=$(printf '%s' "$tabs" | jq -r --arg t "$tab_id" '.result.tabs[]? | select(.tab_id==$t) | .label' 2>/dev/null)
  [[ "$label" == "1" ]] || return 0
  H tab close "$tab_id" >/dev/null 2>&1 || true
}

# --- Main --------------------------------------------------------------------
server_ensure || exit 1

# --sync-labels: relabel existing tabs to their worktree's current branch, then
# exit. Does NOT create a workspace — nothing to sync if none exists yet.
if [[ -n "$SYNC_ONLY" ]]; then
  WSID=$(H workspace list 2>/dev/null | jq -r --arg want "$WS_LABEL" \
    '.result.workspaces[]? | select(.label==$want) | .workspace_id' 2>/dev/null | head -1)
  [[ -n "$WSID" ]] || { echo "no herdr workspace '$WS_LABEL' to sync" >&2; exit 0; }
  synced=0
  while IFS=$'\t' read -r tab_id cwd; do
    [[ -n "$cwd" && -d "$cwd" ]] || continue
    want=$(label_for_dir "$cwd" "")
    cur=$(H tab list --workspace "$WSID" 2>/dev/null | jq -r --arg t "$tab_id" \
      '.result.tabs[]? | select(.tab_id==$t) | .label' 2>/dev/null)
    if [[ -n "$want" && "$want" != "$cur" ]]; then
      H tab rename "$tab_id" "$want" >/dev/null 2>&1 && { echo "↻ '$cur' → '$want'" >&2; synced=$((synced+1)); }
    fi
  done < <(H pane list --workspace "$WSID" 2>/dev/null | jq -r --arg m "$MAIN_LABEL" \
    '.result.panes[]? | select(.label==$m) | "\(.tab_id)\t\(.cwd)"' 2>/dev/null)
  echo "✓ synced $synced tab label(s) to current branch" >&2
  exit 0
fi

workspace_ensure || { echo "failed to ensure herdr workspace '$WS_LABEL'" >&2; exit 1; }

pos=0
for arg in "$@"; do
  # Each arg is a worktree dir, optionally with an EXPLICIT tab name after '=':
  #   <dir>              → auto-name (branch, else <basename>-<slot>)
  #   <dir>=<name>       → tab named exactly <name> (branch/purpose/agent id)
  # The explicit form is the reliable "way to tell which worktree is which" when
  # a treehouse slot is at detached HEAD (no branch to read).
  # <dir>          → auto-name (current branch, else <basename>-<slot>)
  # <dir>=<name>   → CREATE/switch branch <name> in the worktree, then name the
  #                  tab <name>. So the branch exists before work starts and the
  #                  tab, git, and Claude's statusline all show it from launch.
  DIR="$arg"; LBL=""
  [[ "$arg" == *=* ]] && { DIR="${arg%%=*}"; LBL="${arg#*=}"; }
  [[ -d "$DIR" ]] || { echo "⚠ worktree dir '$DIR' not found — skipping" >&2; continue; }
  DIR=$(cd "$DIR" && pwd -P)   # physical path: match herdr's resolved pane cwd
  pos=$((pos + 1))
  # Explicit name = the branch this worktree is for: create it (or switch if it
  # already exists) BEFORE launching, so nothing ever shows a detached sha.
  if [[ -n "$LBL" ]]; then
    if git -C "$DIR" show-ref --verify --quiet "refs/heads/$LBL"; then
      git -C "$DIR" checkout -q "$LBL" 2>/dev/null || echo "⚠ '$LBL' may be checked out in another worktree — skipping checkout" >&2
    else
      git -C "$DIR" checkout -q -b "$LBL" 2>/dev/null || echo "⚠ could not create branch '$LBL'" >&2
    fi
  fi
  w=$(label_for_dir "$DIR" "$LBL")

  # Idempotent, keyed on the WORKTREE DIR (a pane's cwd), not the label — so a
  # tab that already exists for this worktree is RE-LABELED to the current name
  # (branch may have changed since it was created; a detached slot later checked
  # out onto a branch should now show that branch). Re-running the launcher thus
  # syncs every tab's label to its worktree's current branch.
  # Match by realpath, not raw string: herdr may report a pane cwd via a symlink
  # form (macOS /var vs /private/var) that won't string-equal our resolved DIR.
  existing_tab=""
  while IFS=$'\t' read -r _tid _tcwd; do
    [[ -n "$_tcwd" ]] || continue
    _rp=$(cd "$_tcwd" 2>/dev/null && pwd -P) || continue
    if [[ "$_rp" == "$DIR" ]]; then existing_tab="$_tid"; break; fi
  done < <(H pane list --workspace "$WSID" 2>/dev/null | jq -r --arg m "$MAIN_LABEL" \
    '.result.panes[]? | select(.label==$m) | "\(.tab_id)\t\(.cwd)"' 2>/dev/null)
  if [[ -n "$existing_tab" ]]; then
    cur=$(H tab list --workspace "$WSID" 2>/dev/null | jq -r --arg t "$existing_tab" \
      '.result.tabs[]? | select(.tab_id==$t) | .label' 2>/dev/null)
    if [[ "$cur" != "$w" ]]; then
      H tab rename "$existing_tab" "$w" >/dev/null 2>&1 && echo "↻ relabeled '$cur' → '$w'" >&2
    else
      echo "· tab '$w' already current — skipping" >&2
    fi
    continue
  fi

  OFFSET=$(resolve_offset "$DIR" $(( pos * 10 )))
  SHARED_EXPORTS=$(build_shared_port_exports "$OFFSET")

  # Tab + main pane in the worktree root.
  TAB_OUT=$(H tab create --workspace "$WSID" --cwd "$DIR" --label "$w" --no-focus 2>/dev/null) \
    || { echo "⚠ tab create failed for '$w' — skipping" >&2; continue; }
  MAIN_PANE=$(printf '%s' "$TAB_OUT" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  [[ -n "$MAIN_PANE" ]] || { echo "⚠ no pane id for '$w' — skipping" >&2; continue; }
  prune_seeded_default_tab "$WSID" "$SEEDED_TAB_ID"; SEEDED_TAB_ID=""

  # `pane rename` is herdr's native per-pane label (analogue of tmux @role) —
  # it shows on the pane and is the cheapest native "tab status" herdr offers.
  H pane rename "$MAIN_PANE" "$MAIN_LABEL" >/dev/null 2>&1 || true
  H pane run "$MAIN_PANE" "${SHARED_EXPORTS}clear; $MAIN_CMD" >/dev/null 2>&1 || true

  # Service panes: first splits right off main, rest stack downward.
  PREV_PANE=""
  for ((i=0; i<SVC_COUNT; i++)); do
    lbl="${SVC_LABELS[$i]}"
    svc_dir="$DIR"; [[ "${SVC_CWDS[$i]}" != "." ]] && svc_dir="$DIR/${SVC_CWDS[$i]}"
    cmd=$(expand_placeholders "${SVC_CMDS[$i]}" "$i" "$OFFSET")
    env_prefix=$(build_env_prefix "$i" "$OFFSET")
    local_port=$((SVC_BASE_PORTS[i] + OFFSET))
    inspector_export=""
    [[ "${SVC_BASE_INSP[$i]}" != "0" ]] && inspector_export="export INSPECTOR_PORT=$((SVC_BASE_INSP[$i] + OFFSET)); "
    env_prefix="${SHARED_EXPORTS}export PORT=$local_port; ${inspector_export}${env_prefix}"

    # Install gate: same sidecar as the tmux path.
    wait_cmd="bash ~/.claude/skills/tmux-worktrees/scripts/wait-for-install.sh '$DIR'"
    gated_cmd="${env_prefix}${wait_cmd}; $cmd"

    if [[ $i -eq 0 ]]; then
      # herdr --ratio sizes the ORIGINAL (left/main) pane, opposite of tmux's
      # `-l 28%` which sizes the NEW pane. 0.60 keeps CLAUDE the larger pane
      # while leaving the service column wide enough to read dev-server logs.
      # Override with HERDR_WT_MAIN_RATIO.
      SPLIT_OUT=$(H pane split "$MAIN_PANE" --direction right --ratio "${HERDR_WT_MAIN_RATIO:-${YAML_MAIN_RATIO:-0.70}}" --cwd "$svc_dir" --no-focus 2>/dev/null) || SPLIT_OUT=""
    else
      SPLIT_OUT=$(H pane split "$PREV_PANE"  --direction down             --cwd "$svc_dir" --no-focus 2>/dev/null) || SPLIT_OUT=""
    fi
    PREV_PANE=$(printf '%s' "$SPLIT_OUT" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
    [[ -n "$PREV_PANE" ]] || { echo "⚠ split failed for service '$lbl' in '$w'" >&2; continue; }

    H pane rename "$PREV_PANE" "$lbl" >/dev/null 2>&1 || true
    H pane run "$PREV_PANE" "$gated_cmd" >/dev/null 2>&1 || true
  done

  # Leave the tab UNZOOMED so all panes (CLAUDE + services) are visible on open
  # — the captain's standard. (Zooming main hid the service column.) Set
  # HERDR_WT_ZOOM_MAIN=1 to open focused/zoomed on the CLAUDE pane instead.
  [[ "${HERDR_WT_ZOOM_MAIN:-${YAML_ZOOM_MAIN:-0}}" == "1" ]] && H pane zoom "$MAIN_PANE" --on >/dev/null 2>&1 || true
  echo "✓ '$w' → offset $OFFSET (main + $SVC_COUNT service pane(s))" >&2
done

echo "" >&2
echo "✓ herdr workspace '$WS_LABEL' ready (session: $SESSION)." >&2
echo "  Attach:  herdr --session $SESSION" >&2

# --- What was DROPPED from the tmux launcher (intentional, no herdr analogue) -
# * Dynamic status-right highlight / @active_role / focus hooks — herdr owns its
#   own tab-bar UI; pane roles are set with `herdr pane rename` (its cheapest
#   native label), but there is no status-bar templating or click-to-jump
#   (jump-pane.sh) and no highlight of the active role.
# * `prefix R` re-run of a pane's @start_cmd — herdr has no per-pane user-option
#   to stash a launch command, so re-running a dev server means re-issuing it.
# * All tmux-worktree.conf keybindings (pane/window cycling, tree pickers,
#   mouse-copy, mouse toggle) — tmux keytable bindings with no herdr CLI surface.
# * The .claude/worktrees mtime scan + stale-tab prune — herdr targets by
#   explicit dir/ids, so the caller passes worktree dirs directly (treehouse
#   slots included) instead of the launcher guessing from a fixed layout.
