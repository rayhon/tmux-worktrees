#!/bin/bash
# PreToolUse hook: blocks Edit/Write/MultiEdit/NotebookEdit calls that target
# the parent repo working tree while the session is operating inside a
# `.claude/worktrees/<branch>/` worktree. Prevents the "worktree CWD trap"
# where the agent edits the parent's `apps/...` path and pollutes main.
#
# Detection: if the session's cwd is `<repo>/.claude/worktrees/<branch>/...`,
# any file_path under `<repo>/apps/...` (NOT inside the worktree) is rejected.
# The hook prints the suggested worktree path so the agent can retry correctly.
#
# Exit codes:
#   0  → allow tool to run
#   2  → block tool; stderr shown back to the assistant as a tool error

set -euo pipefail

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
case "$tool_name" in
  Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""')
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')

# Only enforce when the session is operating inside a worktree
if [[ ! "$cwd" =~ /\.claude/worktrees/([^/]+)(/|$) ]]; then
  exit 0
fi

worktree_branch="${BASH_REMATCH[1]}"
parent_repo="${cwd%%/.claude/worktrees/*}"
worktree_root="$parent_repo/.claude/worktrees/$worktree_branch"

# If file_path is outside the parent repo entirely (system paths, /tmp, ~/.claude,
# etc.), let it through — only the parent's working tree is the trap.
if [[ "$file_path" != "$parent_repo"/* ]]; then
  exit 0
fi

# Already inside the worktree — fine.
if [[ "$file_path" == "$worktree_root"/* ]]; then
  exit 0
fi

# At this point: file_path is under the parent repo but NOT under the worktree.
# Reject and suggest the correct path.
relative="${file_path#$parent_repo/}"
suggested="$worktree_root/$relative"

cat >&2 <<EOF
BLOCKED: $tool_name to parent-repo path while operating in worktree '$worktree_branch'.

  Attempted path:   $file_path
                    ↑ this is the PARENT WORKING TREE — edits here pollute main.

  Worktree root:    $worktree_root
  Suggested path:   $suggested

Retry the $tool_name with the suggested path. If you genuinely need to touch
the parent (rare — usually only for tmux-worktrees skill assets), explain why
to the user and ask them to disable this hook for the call.
EOF

exit 2
