# tmux-worktrees

A Claude Code skill that manages a tmux dev session for git worktrees. Each worktree gets its own tmux window with panes for every service defined in a `tmux-worktree.yaml` file at the repo root.

## Install

```bash
npx skills add https://github.com/rayhon1014/tmux-worktrees --skill tmux-worktrees
bash ~/.claude/skills/tmux-worktrees/install.sh
```

`install.sh` runs once to wire the global `WorktreeCreate` hook and register the `/tmux-worktrees` slash command.

## Per-repo setup

Drop a `tmux-worktree.yaml` at your repo root:

```yaml
main:
  label: CLAUDE
  cmd: claude

services:
  - label: API
    cwd: backend
    port: 3100
    cmd: npm run dev --port {PORT}

  - label: WEB
    cwd: frontend
    port: 3000
    cmd: API_URL={API_URL} npm run dev --port {PORT}
```

That's it. The hook is already active globally.

## Usage

```bash
claude --worktree feature-xyz   # creates worktree + symlinks env + npm install + adds tmux window
/tmux-worktrees                 # opens the tmux session
```

## How it works

- **Port assignment** is positional and stateless — worktrees sorted alphabetically get offset +10, +20, +30… added to each service's base port. Same name = same ports every time.
- **`{PORT}`** in the cmd is replaced with the actual assigned port.
- **`{LABEL_URL}`** gives you another service's URL (e.g. `{API_URL}`).
- **Navigation:** Alt+arrow moves between panes (stays zoomed). Shift+arrow switches worktrees. Click service labels in the status bar to jump fullscreen.

## Requires

- tmux
- yq (`brew install yq` — auto-installed if missing)
