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

<br/>

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
  # -c resumes the last session in this worktree; falls back to a fresh
  # session on first launch. --dangerously-skip-permissions auto-approves
  # all tool calls so you don't have to babysit every worktree.
  cmd: claude -c --dangerously-skip-permissions || claude --dangerously-skip-permissions

# Global env vars exported into every service pane (per-service `env:` overrides)
env:
  API_URL: "{API_URL}"
  NEXT_PUBLIC_API_URL: "{API_URL}"

services:
  - label: API
    cwd: backend
    port: 3100
    cmd: PORT={PORT} npm run dev

  - label: WEB
    cwd: frontend
    port: 3000
    env:                             # per-service additions/overrides
      AUTH_TRUSTED_ORIGINS: "{WEB_URL}"
      APP_URL: "{WEB_URL}"
    cmd: PORT={PORT} npm run dev
```

That's it. The hook is already active globally.

> **Heads up on `--dangerously-skip-permissions`:** auto-approves every tool call Claude makes (writes, deletes, shell commands). Each worktree is in its own isolated folder so the blast radius is contained, but you're giving up the per-call prompt. Use `cmd: claude` if you'd rather keep the prompts.

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

Mouse mode is **off by default** — it causes clipboard wipes and copy-mode traps inside VS Code/iTerm2. Everything is keyboard-driven:

| Action | Keys |
|---|---|
| Cycle through panes within a worktree | `Alt + ←/→` (or `↑/↓`) — wraps around CLAUDE → MCP → AGENT → WEB |
| Switch between worktrees | `Shift + ←/→` |
| Worktree picker (with live preview) | `Alt + w` |
| Pane picker | `Alt + m` |
| Toggle mouse mode | `Ctrl+b m` — turn on briefly when you need clickable status / scroll-wheel |

The active pane shows up two ways: a **bright pane** (others dim gray) and the **matching label highlighted in yellow** in the top status bar.

### Copy/paste

Use your **terminal's own selection** — never tmux's. Hold the bypass key while dragging:

| Terminal | Hold while dragging |
|---|---|
| iTerm2, Terminal.app | **⌥ Option** |
| Alacritty, Ghostty, WezTerm | **⇧ Shift** |
| Kitty | **Ctrl+Shift** |
| VS Code terminal | (with mouse off in tmux) just drag normally |

That gives you native selection — highlight stays, ⌘C copies, ⌘V pastes into the active pane. No tmux mouse mode, no OSC 52, no clipboard wipes.

### macOS Option+arrow inside VS Code

VS Code intercepts Option+arrow for editor word-nav before tmux sees it. To make pane cycling work, add this to your VS Code `keybindings.json`:

```json
{ "key": "alt+left",  "command": "workbench.action.terminal.sendSequence",
  "args": { "text": "[1;3D" }, "when": "terminalFocus" },
{ "key": "alt+right", "command": "workbench.action.terminal.sendSequence",
  "args": { "text": "[1;3C" }, "when": "terminalFocus" },
{ "key": "alt+up",    "command": "workbench.action.terminal.sendSequence",
  "args": { "text": "[1;3A" }, "when": "terminalFocus" },
{ "key": "alt+down",  "command": "workbench.action.terminal.sendSequence",
  "args": { "text": "[1;3B" }, "when": "terminalFocus" }
```

In iTerm2/Terminal.app, just enable Option-as-Meta in profile settings.

## How it works

- **Port assignment** is by worktree creation time — first worktree gets offset +10, next +20, next +30… Existing worktrees keep their ports forever; new worktrees always get the next unused offset, so adding one never collides with running dev servers.
- **`{PORT}`** in the cmd is replaced with the actual assigned port.
- **`{LABEL_URL}`** gives you another service's URL (e.g. `{API_URL}`).

## Common pitfalls

Worktrees run on offset ports (worktree #1 → +10, #2 → +20, …), but every env file in the worktree is symlinked from main, where the values were written for the original port (3000, 8787, etc). When an app reads its **own** URL from env, you get a mismatch — the dev server listens on `:3010` but thinks it's still `:3000`. Symptoms range from broken auth callbacks to silently-wrong API targets.

**Rule of thumb: any env var that encodes a port or base URL must be re-derived per worktree, not symlinked.** Set them in `cmd:` using the `{LABEL_URL}` / `{LABEL_PORT}` placeholders so each worktree gets its own values.

The usual suspects:

| App / library | Variable | Failure mode |
|---|---|---|
| Better Auth | `APP_URL`, `AUTH_TRUSTED_ORIGINS` | `Invalid origin: http://localhost:3010` on every sign-in |
| NextAuth | `NEXTAUTH_URL` | OAuth callback returns to main's port, session fails to set |
| Next.js public URLs | `NEXT_PUBLIC_APP_URL`, `NEXT_PUBLIC_API_URL` | Client-side fetches go to main's port instead of the worktree's |
| OAuth providers (Google/GitHub) | redirect URI registered in provider dashboard | `redirect_uri_mismatch` — provider only knows about main's port. Add `localhost:3010`/3020/3030 to allowed callbacks |
| CORS allowlists | server-side allowed origins | Request from `localhost:3010` rejected by the server it's calling |
| Cross-service URLs | `MCP_HUB_URL`, `API_URL`, etc. | Worktree's web app calls *main's* API/MCP instead of its own worktree copy |

Use `{LABEL_URL}` placeholders to fix them at the worktree boundary. Example for Better Auth + cross-service URLs:

```yaml
- label: WEB
  cwd: apps/web
  port: 3000
  cmd: |
    APP_URL={WEB_URL} NEXT_PUBLIC_APP_URL={WEB_URL}
    AUTH_TRUSTED_ORIGINS={WEB_URL}
    MCP_HUB_URL={MCP_URL} NEXT_PUBLIC_MCP_HUB_URL={MCP_URL}
    AGENT_HUB_URL={AGENT_URL}
    PORT={PORT} npm run dev
```

Now the worktree on port 3010 launches as a self-consistent `http://localhost:3010` — auth, fetch, and CORS all agree.

> **Tip:** if you see *"Invalid origin"*, *"redirect_uri_mismatch"*, or *"Cross-Origin Request Blocked"* anywhere on a fresh worktree, the answer is almost always a missing `{LABEL_URL}` in your `cmd:` line.

## Requires

- tmux
- yq (`brew install yq` — auto-installed if missing)
