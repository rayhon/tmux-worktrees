# tmux-worktrees

A Claude Code skill that manages a tmux dev session for git worktrees. Each worktree gets its own tmux window with panes for every service defined in a `tmux-worktree.yaml` file at the repo root.

## Overall View
<img width="2694" height="1480" alt="Screenshot 2026-05-22 at 1 18 43 PM" src="https://github.com/user-attachments/assets/3e12d2b4-1065-40b0-bcb1-beec47cef162" />
* **Top**: worktree selector
* **Bottom**: agent and services quick view

## Worktree View
<img width="2578" height="1546" alt="Screenshot 2026-05-22 at 2 31 46 AM" src="https://github.com/user-attachments/assets/f053cd9a-771d-46ca-aee9-66af355bea44" />
* **Bottom left**: worktrees (shift + left/right) to navigate
* **Bottom right**: agent and services (click at the label change view)

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rayhon/tmux-worktrees/main/install.sh)
```

Downloads the skill to `~/.claude/skills/tmux-worktrees/` and wires the global `WorktreeCreate` hook in `~/.claude/settings.json`. Run once per machine.

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
/tmux-worktrees                 # prepares the tmux session
```

`/tmux-worktrees` (invoked from inside Claude Code) sets up the tmux session in the background. Claude Code can't attach a TTY itself, so attach from your terminal:

```bash
tmux -L wt attach -t wt
```

You only need to attach once — re-running `/tmux-worktrees` after adding worktrees just refreshes the session you're already attached to.

## Navigation

| Action | Keys / Mouse |
|---|---|
| Switch pane within a worktree | `Alt + ←/→/↑/↓` (stays zoomed) |
| Switch between worktrees | `Shift + ←/→` |
| Jump to pane fullscreen | Click the label in the status bar (CLAUDE / API / WEB / …) |
| Pane picker | `Alt + m` |

## How it works

- **Port assignment** is positional and stateless — worktrees sorted alphabetically get offset +10, +20, +30… added to each service's base port. Same name = same ports every time.
- **`{PORT}`** in the cmd is replaced with the actual assigned port.
- **`{LABEL_URL}`** gives you another service's URL (e.g. `{API_URL}`).

## Requires

- tmux
- yq (`brew install yq` — auto-installed if missing)
