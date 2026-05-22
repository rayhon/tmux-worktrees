#!/usr/bin/env bash
# jump-pane.sh — select the pane in the current tmux window whose @role
# user option matches the given label, then zoom it to fullscreen.
#
# Usage: jump-pane.sh <role>           e.g. jump-pane.sh CLAUDE
#
# Always runs against the dedicated -L wt server (so it works even if the
# user has another tmux server going).
set -euo pipefail

SOCKET=${TMUX_WT_SOCKET:-wt}
LABEL=$(printf '%s' "${1-}" | tr '[:lower:]' '[:upper:]')
[[ -z "$LABEL" ]] && exit 0

PANE=$(tmux -L "$SOCKET" list-panes -F "#{pane_id} #{@role}" 2>/dev/null \
  | awk -v lbl="$LABEL" '$2==lbl {print $1; exit}')
[[ -z "$PANE" ]] && exit 0

tmux -L "$SOCKET" select-pane -t "$PANE"
zoomed=$(tmux -L "$SOCKET" display-message -p -t "$PANE" '#{window_zoomed_flag}')
[[ "$zoomed" != "1" ]] && tmux -L "$SOCKET" resize-pane -Z -t "$PANE"
