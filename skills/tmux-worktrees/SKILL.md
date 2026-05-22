---
name: tmux-worktrees
description: Launch a tmux dev session for the current repo's git worktrees. Reads tmux-worktree.yaml at repo root.
type: flexible
---

# tmux-worktrees

Launches (or re-attaches to) the tmux dev session for this repo.

## When invoked: `/tmux-worktrees`

### Step 0 — First-run install check

Check if the WorktreeCreate hook is wired:
```bash
grep -q "tmux-worktrees" ~/.claude/settings.json 2>/dev/null && echo "installed" || echo "not installed"
```

If not installed, tell the user to re-run the install command:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/contextforce/tmux-worktrees/main/install.sh)
```

### Step 1 — If `tmux-worktree.yaml` is missing at the repo root

Ask the user about their services:

> "What services does this repo need? For each one:
> - A short label (e.g. API, WEB, WORKER)
> - Directory to run from (relative to repo root)
> - Start command (e.g. `npm run dev`, `npx wrangler dev`)
> - Default port"

Then generate `tmux-worktree.yaml` at the repo root:

```yaml
main:
  label: CLAUDE
  cmd: claude

services:
  - label: <LABEL>
    cwd: <relative-path>
    port: <base-port-rounded-down-to-nearest-100>
    cmd: <start-command> --port {PORT}

  # Cross-service URLs: {LABEL_URL} e.g. {API_URL}
  # Wrangler services also add:
  #   inspector_port: 9200
  #   cmd: npx wrangler dev --port {PORT} --inspector-port {INSPECTOR_PORT}
  #   symlinks:
  #     - .wrangler/state
```

Port base convention: round default down to nearest 100 (8787→8700, 51957→51900, 3000→3000).

### Then launch

```bash
~/.claude/skills/tmux-worktrees/scripts/tmux-worktrees.sh
```

---

## Key facts

- **Navigation:** Alt+arrow moves panes (stays zoomed). Shift+arrow switches worktrees.
- **Pane jump:** click labels in the status bar, or Alt+m for a picker menu.
- **Restart:** `tmux -L wt kill-server` then re-run the launcher.
- **Add a worktree:** `claude --worktree <name>` — hook fires automatically, symlinks env, npm installs, adds tmux window.
- **Port assignment:** alphabetical order, deterministic — 1st→+10, 2nd→+20, 3rd→+30.
