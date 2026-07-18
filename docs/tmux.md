# tmux flow

The classic flow: each worktree becomes a **tmux window** with one pane per service, all under a single attached session. Created via Claude Code's `WorktreeCreate` hook (`claude --worktree`) and laid out by `tmux-worktrees.sh`.

> Prefer a managed, reusable pool with a richer view? See the [pooled treehouse + herdr flow](herdr.md). Both read the same `tmux-worktree.yaml`.

## Overall View
<img width="2694" height="1480" alt="Screenshot 2026-05-22 at 1 18 43 PM" src="https://github.com/user-attachments/assets/3e12d2b4-1065-40b0-bcb1-beec47cef162" />

* **Top**: worktree selector
* **Bottom**: agent and services quick view

## Worktree View
<img width="2578" height="1546" alt="Screenshot 2026-05-22 at 2 31 46 AM" src="https://github.com/user-attachments/assets/f053cd9a-771d-46ca-aee9-66af355bea44" />

* **Bottom left**: worktrees — `Shift + ←/→` to navigate between them
* **Bottom right**: agent + service labels — `Alt + ←/→` cycles through the panes, active one highlights yellow

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
  "args": { "text": "[1;3D" }, "when": "terminalFocus" },
{ "key": "alt+right", "command": "workbench.action.terminal.sendSequence",
  "args": { "text": "[1;3C" }, "when": "terminalFocus" },
{ "key": "alt+up",    "command": "workbench.action.terminal.sendSequence",
  "args": { "text": "[1;3A" }, "when": "terminalFocus" },
{ "key": "alt+down",  "command": "workbench.action.terminal.sendSequence",
  "args": { "text": "[1;3B" }, "when": "terminalFocus" }
```

In iTerm2/Terminal.app, just enable Option-as-Meta in profile settings.

## Port assignment

Ports are assigned by worktree **creation time** — first worktree gets offset +10, next +20, next +30… Existing worktrees keep their ports forever; new worktrees always get the next unused offset, so adding one never collides with running dev servers.

(The pooled flow uses a different, slot-derived offset — see [herdr.md](herdr.md).)

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
