# How I Stopped Fighting My Coding Agent and Started Cloning It

*A six-stage journey from pair-programming with one agent to running a tmux-managed swarm of Claude sessions, each in its own git worktree, each with its own dev stack, each isolated and reproducible.*

---

If you've ever paired with an AI coding agent and thought *"this would go three times faster if I had three of these,"* you know where this story starts. Here's the road from that thought to a working setup.

## Stage 1 — Pair Programming, One Agent at a Time

Open a Claude Code session, give it a task, accept the diff, repeat. This is the productive default and most days it's enough. The problem only appears the moment you have *two* good ideas going in parallel.

## Stage 2 — Two Agents, One Repo, Mutual Destruction

The natural next move is more terminals. Open Terminal #2, start another agent, point it at the same repo, and start typing.

About four minutes in you discover the law of conservation of source code: two agents editing the same working tree will, eventually, scribble over each other. One renames a function in `auth.ts`. The other refactors that same file from a different angle. By the time you look up, neither change makes sense, your linter is screaming, and Claude #1 is calmly explaining what it did, blissfully unaware that Claude #2 just removed every line it edited.

"Just keep them in different folders" doesn't survive contact with shared utils, types files, or `package.json`.

**The lesson:** parallel agents need parallel **worlds**, not just parallel terminals. They cannot safely share one working tree any more than two writers can safely share one Google Doc with no track changes.

## Stage 3 — Worktrees, and Everything That Quietly Breaks

The fix sounds obvious: git worktrees. One repository, many branches checked out into separate folders. Agent A works in `worktrees/feature-auth/`, Agent B in `worktrees/migration-audit/`. File collisions become physically impossible.

```bash
git worktree add ../worktrees/feature-auth -b feature-auth
```

Beautiful. For any non-trivial app, also a disaster the moment you try to *run* it. Three things break in quick succession:

**Port collisions.** My monorepo runs three services together — mcp-hub on 8787, agent-hub on 51957, web on 3000. Worktree #1 binds them. Worktree #2 starts up and dies on every port. So you bump every port by hand, then every cross-service env var pointing at those ports, then keep a sticky note of which worktree owns which port. The sticky note is wrong.

**Missing env files.** `.env.local`, `.dev.vars`, OAuth credentials — all gitignored, all only in the main checkout. New worktree boots with a missing nervous system: auth dies, secrets are undefined, half the app 500s.

**Missing local cache.** My setup has a local R2 fixture cache at `.wrangler/state/v3/r2` that tests and dev runs depend on. Also gitignored. So calls that used to hit cached fixtures now hit the live network or return empty, and you spend an hour debugging "backend bugs" that are really empty caches.

**The lesson:** a worktree is not a working dev environment. The dev environment includes a graveyard of gitignored state — env files, local caches, build artifacts — that `git worktree add` deliberately won't copy. You have to bring it back, deterministically, every time.

## Stage 4 — The Right Layer for Setup

I wrote a setup script: symlink the env files, symlink `.wrangler/state` so the worktree shares the parent's R2 cache, kick off `npm install` in the background. Told the agent: "run this script before working in a worktree."

The agent ran it. Sometimes. Forgot. Sometimes. Waited 90 seconds for npm install to finish and then ran out of patience. Sometimes. Ran a slightly different command it invented and wrote 200 lines against a half-configured environment.

The problem wasn't the agent's competence — I was asking the wrong layer to enforce a thing that needs to be enforced by the system. The right place is *the moment the worktree is created*, before any agent touches it. Claude Code has a `WorktreeCreate` hook for exactly this:

```jsonc
"WorktreeCreate": [{
  "hooks": [{
    "type": "command",
    "command": "bash -c '... git worktree add ...; symlink env files; npm install &; echo $DIR'"
  }]
}]
```

With the setup wired to the hook, the agent literally cannot create a worktree without the symlinks, install, and port wiring being in place. State is correct by construction.

Port assignment got the same treatment: instead of remembering or typing, it's derived. Each worktree's offset is `(position * 10)`, where position is the creation-order rank — `+10`, `+20`, `+30` — so `MCP_PORT = 8700 + offset`, `WEB_PORT = 3000 + offset`, etc. Cross-service URLs (`MCP_HUB_URL`, `APP_URL`, …) are injected per-worktree at launch so every service sees the right neighbors.

The same principle solves one more failure mode: the agent **inside** a worktree session occasionally edits the wrong copy of a file. Bash tool calls start fresh in the parent repo's cwd, not the worktree's. The agent gets an absolute path from Grep or autocompletion that resolves to the parent. The edit succeeds in the wrong branch, no error fires, and you only notice when your worktree's behavior doesn't change.

A `PreToolUse` hook closes the gap. It intercepts `Edit`, `Write`, `MultiEdit`, `NotebookEdit` and rejects any path that falls inside the parent repo while the session's cwd is inside a worktree. Exit code 2 returns the rejection to the model with a suggested correct path, so the agent retries with the right file and the bug self-corrects within the same turn:

```bash
# pseudocode
if cwd matches "<repo>/.claude/worktrees/<branch>/...":
  if file_path under "<repo>/" but NOT under the worktree:
    exit 2: "blocked — that path is the parent repo; use $worktree_root/$relative instead"
```

**The lesson:** if correctness depends on a setup step, don't ask the agent to do it. Put it in the platform. Hooks for both **creation** (`WorktreeCreate` for symlinks + npm install) and **isolation** (`PreToolUse` for write guards), scripts for port assignment, env injection at launch — anything that runs without human or model judgment.

## Stage 5 — Tmux to Actually See Them All

By now I had a one-command worktree spinner that produced a fully-wired dev environment per branch. The next problem: *where do I look at all of them?*

A handful of separate Terminal.app windows is unmanageable. Two die silently. Three are running stale env from yesterday. You don't notice wrangler in worktree #2 is throwing 500s until you happen to alt-tab there.

The Unix-native answer is tmux. One tmux session, one window per worktree, four panes per window: one for Claude, one for each of the three dev servers. Now you can see everything at once.

But raw tmux is brutal — `Ctrl+b` for everything, no friendly labels, easy to lose track of which pane is active. The configuration that makes it usable:

- `Alt + ←/→` cycles through panes within a worktree
- `Shift + ←/→` switches between worktrees
- `Alt + w` opens a picker with live preview of every worktree
- Active pane is brightened; inactive panes are dimmed gray
- Top status bar shows `CLAUDE / MCP / AGENT / WEB`; the active pane's label highlights yellow via a `pane-focus-in` hook
- Mouse mode defaults to **off** — inside VS Code/iTerm2's terminal emulators, tmux mouse mode causes clipboard wipes and copy-mode traps. `Ctrl+b m` toggles it on for the rare case you want scroll-wheel or click-to-focus

Two dead-ends were worth ruling out: a custom "dashboard" window mirroring every worktree's Claude pane via `pipe-pane` (read-only and flickery, since tmux can't share a pane between windows); declaring the WorktreeCreate hook in the skill's `SKILL.md` frontmatter (skill-scoped hooks don't fire for `claude --worktree` because that runs from outside any active skill session). Both verified empirically; both reverted.

**The lesson:** dev work across N worktrees is unmanageable if you can't see them all. tmux is ugly but solves the visibility problem for free. The platform has good reasons for its boundaries — lean on what it already does well, plus a small `.conf` to teach it your workflow.

## Stage 6 — Skill-ifying for Any Repo

By this point the setup worked, but only for my specific repo. Every script was full of hardcoded service paths, ports, and command lines. Useless for anyone else, including future-me on a different project.

So I generalized. The repo-specific bits — service paths, ports, commands, which folders to symlink — moved into a single YAML at the repo root:

```yaml
main:
  label: CLAUDE
  cmd: claude -c --dangerously-skip-permissions || claude --dangerously-skip-permissions

env:                              # shared across every service pane
  APP_URL: "{WEB_URL}"
  NEXT_PUBLIC_APP_URL: "{WEB_URL}"
  MCP_HUB_URL: "{MCP_URL}"
  AGENT_HUB_URL: "{AGENT_URL}"

services:
  - label: MCP
    cwd: apps/mcp/mcp-hub
    port: 8700
    cmd: npm run dev -- --port {PORT}
    symlinks: [.wrangler/state]
  - label: AGENT
    cwd: apps/agentic/agent-hub
    port: 51900
    cmd: PORT={PORT} npm run dev
    symlinks: [.wrangler/state]
  - label: WEB
    cwd: apps/web
    port: 3000
    cmd: PORT={PORT} npm run dev
    symlinks: [.wrangler/state]
```

The launcher reads it, assigns deterministic per-worktree port offsets, expands `{PORT}` / `{LABEL_URL}` placeholders, and runs each service's `cmd`. The generic logic — tmux config, env symlinking, hook wiring — lives in a Claude Code skill at `~/.claude/skills/tmux-worktrees/`.

Installation is one command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rayhon/tmux-worktrees/main/install.sh)
```

That copies the skill in and registers the global `WorktreeCreate` hook. For any new repo, drop a `tmux-worktree.yaml` at the root, then type `/tmux-worktrees`. Two-minute setup, then `claude --worktree feature-x` from any terminal spins up a fully isolated workspace and adds a tmux window to your running session.

Source: **[github.com/rayhon/tmux-worktrees](https://github.com/rayhon/tmux-worktrees)**

## What I Carry Forward

- **Parallel agents need parallel worlds.** One repo = one agent unless you isolate. Git worktrees are the cheapest isolation that actually works.
- **A worktree isn't a dev environment.** Bring the gitignored state — env files, local caches, install artifacts — explicitly. Plan for it.
- **If correctness depends on a setup step, don't put it in the agent's prompt.** Put it in the platform. Hooks, install scripts, anything that runs without human or model judgment.
- **Make multiple sessions visible.** Long-running dev work with N worktrees is unworkable if you can't see them all. tmux is ugly but solves it for free.
- **Build for one project, generalize ruthlessly the second time you need it.** YAML config at the repo root, generic scripts in a skill — every monorepo can have the same UX with different services.

No clever insight here, just a stack of small "oh, that's why" moments, each one trimming a stupid loss off the next day's work. If you've been quietly losing hours to one of these same problems, hopefully this saves you a few.

Now go give your one agent some siblings.
