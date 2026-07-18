# tmux-worktrees

A Claude Code skill that manages a tmux dev session for git worktrees. Each worktree gets its own tmux window with panes for every service defined in a `tmux-worktree.yaml` file at the repo root.

> **New: pooled worktrees over [treehouse](https://github.com/kunchenguid/treehouse) + [herdr](https://herdr.dev).** One command per branch leases a warm worktree and launches its whole dev stack, viewed as a labeled tab per worktree. See the visual explainer: **[`docs/architecture.html`](docs/architecture.html)** (open in a browser) — why a multiplexer, what treehouse does, the `tmux-worktree.yaml` field guide, and how to drive it from Claude Code.

## Overall View
<img width="2694" height="1480" alt="Screenshot 2026-05-22 at 1 18 43 PM" src="https://github.com/user-attachments/assets/3e12d2b4-1065-40b0-bcb1-beec47cef162" />

* **Top**: worktree selector
* **Bottom**: agent and services quick view

## Worktree View
<img width="2578" height="1546" alt="Screenshot 2026-05-22 at 2 31 46 AM" src="https://github.com/user-attachments/assets/f053cd9a-771d-46ca-aee9-66af355bea44" />

* **Bottom left**: worktrees — `Shift + ←/→` to navigate between them
* **Bottom right**: agent + service labels — `Alt + ←/→` cycles through the panes, active one highlights yellow

<br/>

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rayhon/tmux-worktrees/main/install.sh)
```

Downloads the skill to `~/.claude/skills/tmux-worktrees/` and wires the global `WorktreeCreate` hook in `~/.claude/settings.json`. It also installs the pooled-worktree scripts (`wt-up.sh` / `wt-down.sh` / `herdr-worktrees.sh`) and — if [treehouse](https://github.com/kunchenguid/treehouse) is on your `PATH` — registers the treehouse `post_create` hook so pooled worktrees auto-wire. Run once per machine.

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

## Pooled worktrees (treehouse + herdr) — recommended

The section above is the classic **tmux** flow. The recommended alternative is a **managed pool** of worktrees over [treehouse](https://github.com/kunchenguid/treehouse) (leases/returns reusable worktrees off your clone) viewed in [herdr](https://herdr.dev) (one persistent local server, a labeled tab per worktree). There's **no auto-switch** — you pick by the command you run. The same `tmux-worktree.yaml` drives both, so switching costs nothing.

**Why prefer it:** warm reusable slots (no re-clone / re-`npm install` per branch), branch-labeled tabs that track the current branch, and a return that never kills your session.

```bash
scripts/wt-up.sh <branch> [<session-name>]   # lease a slot, put it on <branch>, launch the stack
herdr --session <session-name>               # attach; one tab per worktree (session defaults to fmwt)
scripts/wt-down.sh <slot-path>               # save context, return the slot to the pool (herdr stays up)
```

You can also just **tell Claude Code** *"spin up a worktree on `<branch>`"* or *"release that worktree"* — it runs `wt-up.sh` / `wt-down.sh` for you. (Install and attach must be run by you in a terminal; Claude can't bind your terminal.)

For a shared-state repo, declare paths to share **once at the yaml root** — read by `link-worktree-env.sh` when a slot is wired:

```yaml
symlinks: [src/data]              # plain symlink from your clone
mirror_with_sqlite_copies:        # hybrid: blob dirs symlinked, SQLite copied per-slot
  - .wrangler/state
```

**Full visual explainer — why a multiplexer, what each piece does, the yaml field guide, and the exact create-a-worktree call flow:** open [`docs/architecture.html`](docs/architecture.html) in a browser.

## Navigation

Mouse mode is **on by default** — the scroll wheel scrolls pane/Claude history and a drag-select copies to your system clipboard. Everything is also keyboard-driven:

| Action | Keys |
|---|---|
| Cycle through panes within a worktree | `Alt + ←/→` (or `↑/↓`) — wraps around CLAUDE → MCP → AGENT → WEB |
| Switch between worktrees | `Shift + ←/→` |
| Worktree picker (with live preview) | `Alt + w` |
| Pane picker | `Alt + m` |
| Toggle mouse mode | `Ctrl+b m` — turn off briefly for clean native terminal selection |

The active pane shows up two ways: a **bright pane** (others dim gray) and the **matching label highlighted in yellow** in the top status bar.

### Copy/paste

With the default `mouse on`, **hold your terminal's bypass modifier and drag** — on iTerm2/Terminal.app that's **⌥ Option + drag**. Your terminal's native selection takes over, highlight stays, ⌘C copies, ⌘V pastes. No tmux highlight, no OSC 52, no clipboard wipes.

(A plain drag without the modifier is captured by tmux's mouse mode and piped to the system clipboard via `pbcopy` / `wl-copy` / `xclip` — that also works, but Option+drag gives the cleaner native selection.)

Hold the per-terminal bypass key while dragging:

| Terminal | Hold while dragging (mouse mode ON) |
|---|---|
| iTerm2, Terminal.app | **⌥ Option** |
| Alacritty, Ghostty, WezTerm | **⇧ Shift** |
| Kitty | **Ctrl+Shift** |

### Scrolling Claude's history

With the default `mouse on`, the scroll wheel enters tmux copy-mode and scrolls the pane's history (including Claude's chat) directly — no extra setup. If you've toggled mouse OFF via `Ctrl+b m`, the wheel falls back to your terminal's own scrollback instead; in that case use the keyboard:

| Approach | How |
|---|---|
| **Wheel (default, mouse ON)** | Just scroll — tmux copy-mode shows the pane history. Press `q` to exit copy-mode. |
| **Keyboard (works everywhere)** | `fn + shift + ↑` / `fn + shift + ↓` on a Mac laptop (= Shift+PageUp/PageDown). iTerm sends these to the alt-screen app directly. |

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

## tmux model — why windows, not sessions

tmux always nests four layers: **server → session → window → pane**. You can't skip one — a pane lives in a window, a window in a session, a session in a server. This skill maps worktrees onto that hierarchy like so:

```
SOCKET "wt"   (-L wt)            ← one tmux server, isolated from your default tmux
└── SESSION "wt"                 ← one session = the whole dashboard
    ├── WINDOW "feature-xyz"     ← one window per WORKTREE
    │   ├── pane CLAUDE  (left, large)
    │   ├── pane API
    │   └── pane WEB             ← one pane per SERVICE
    ├── WINDOW "bugfix-abc"      ← next worktree
    └── WINDOW "main"
```

| tmux layer | maps to | count |
|---|---|---|
| socket (`-L wt`) | this skill's whole tmux server | 1 |
| session (`wt`) | the dashboard | 1 |
| **window** | **one worktree** | N worktrees |
| pane | one service in that worktree | one per `services:` entry (+ CLAUDE) |

So worktrees are separated by **windows**, not by sessions or sockets.

### Why one session with many windows (not a session per worktree)

The goal is *glance across every worktree from a single attached client*. Windows deliver that; separate sessions don't:

- **One attach sees everything.** `tmux -L wt attach -t wt` drops you into all worktrees at once — flip between them with `Shift + ←/→`. Session-per-worktree would need a separate attach (or a session-picker hop) for each.
- **One status bar lists them all.** Window tabs across the top *are* the worktree selector. A session only shows its own windows in the bar.
- **Adding a worktree is just `new-window`.** The `WorktreeCreate` hook appends a window to the live session — no re-attach. `new-session` would spawn a detached session you'd have to find and attach separately.
- **Same nesting depth either way.** Session-per-worktree isn't "less nested" — it's N sessions each holding one window, vs. 1 session holding N windows. Same number of layers; the single-session layout just keeps worktrees as siblings under one roof so the combined view works.

Session-per-worktree *would* win if you wanted each worktree fully isolated (detach one without seeing the others), or multiple people attaching to different worktrees independently. That's not this use case — here it's **one dev, one screen, many worktrees, flip fast**.

### Why a dedicated socket (`-L wt`)

Separate concern from worktree layout. The `-L wt` socket runs this dashboard as its **own tmux server**, distinct from your normal `default` tmux. So:

- A stray `tmux kill-server` (or `tmux -L wt kill-server` to rebuild) only hits this dashboard — never your unrelated tmux work.
- No session/window name clashes with whatever else you run.
- `tmux -L wt ls` shows only this skill's sessions; plain `tmux ls` shows your default server — two servers, blind to each other.

Every command targeting the dashboard repeats `-L wt`; without it you're talking to the `default` server, which won't have a `wt` session. Handy alias:

```bash
alias wt='tmux -L wt'   # then: wt attach -t wt   ·   wt ls   ·   wt kill-server
```

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

- yq (`brew install yq` — auto-installed if missing)
- **tmux flow:** tmux
- **pooled flow:** [treehouse](https://github.com/kunchenguid/treehouse) + [herdr](https://herdr.dev) on your `PATH`
