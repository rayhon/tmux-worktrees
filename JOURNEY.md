# How I Stopped Fighting My Coding Agent and Started Cloning It

*An eight-stage journey from one terminal, one bug, one agent — to a tmux-managed swarm of Claude sessions, each in its own git worktree, each with its own dev stack, each isolated and reproducible. And the dead-ends along the way.*

---

If you've ever paired with an AI coding agent and thought *"this would go three times faster if I had three of these,"* you already know where this story starts. This is the road from that thought to a working setup, including all the ditches I drove into along the way.

## Stage 1 — Two Terminals, One Repo, Mutual Destruction

It begins innocently. You open a Claude Code session, you give it a task, it works, you accept the diff. Productive day. So far so good.

Then a second idea comes in. *"While Claude finishes the auth refactor, I'll have it audit the migration scripts in another terminal."* You open Terminal #2, fire up another agent, point it at the same repo, and start typing.

About four minutes in, you discover the law of conservation of source code: two agents editing the same working tree will, eventually, scribble over each other. One renames a function in `auth.ts`. The other refactors that same file from a different angle. By the time you look up, neither change makes sense, your linter is screaming, and Claude #1 is calmly explaining what it did, blissfully unaware that Claude #2 just removed every line it edited.

You try mitigations. "Only let one agent touch the API folder, the other does the UI." But the agents don't read the rule, you forget to enforce it, and once they reach for something shared — a types file, a shared util, the package.json — collisions resume.

**The lesson:** parallel agents need parallel **worlds**, not just parallel terminals. They cannot safely share one working tree any more than two writers can safely share one Google Doc with no track changes.

## Stage 2 — Discovering Git Worktrees (and Port Hell)

The fix sounds obvious in retrospect: git worktrees. One repository, many checked-out branches, each in its own folder. Agent A works in `worktrees/feature-auth/`, Agent B in `worktrees/migration-audit/`. They cannot touch each other's files because they literally don't exist in the same folder.

```bash
git worktree add ../worktrees/feature-auth -b feature-auth
git worktree add ../worktrees/migration-audit -b migration-audit
```

Beautiful. For a monorepo, also a complete disaster the moment you try to actually **run** the apps.

My monorepo has three services that need to be up together to function: an MCP hub on port 8787, an agent-hub on 51957, and a Next.js web app on 3000. The whole thing only makes sense when all three are live and talking to each other. Now multiply that by N worktrees. Worktree #1 takes 8787, 51957, 3000. Worktree #2 starts up and… port already in use. Dies. So you bump every port by hand: 8788, 51958, 3001. And every cross-service env var: `MCP_HUB_URL=http://localhost:8788`, `AGENT_HUB_URL=http://localhost:51958`, on and on.

Now your worktrees aren't symmetric anymore. Worktree #2 has different `.env.local` files than the main repo. If you create worktree #3, you have to remember which ports are taken and pick fresh ones. You start keeping a sticky note. The sticky note is wrong. You restart the wrong worktree's wrangler, kill the wrong dev server, and lose your place.

**The lesson:** worktrees fix the *file* collision but introduce a *port* collision in any non-trivial app. You need a deterministic way to assign ports per worktree, ideally one that doesn't require thinking.

## Stage 3 — `claude --worktree` and the Phantom State

Around this point I discovered Claude Code has a `--worktree <name>` flag. It creates a worktree for you and drops you into a Claude session inside it. Lovely. You can also wire it to a `WorktreeCreate` hook to run setup scripts. Great, problem solved.

Except…

The first time I spun up a worktree this way, every service exploded.

- `wrangler dev` complained about missing `.dev.vars` (env file).
- The Next.js web app couldn't reach the auth provider because `.env.local` wasn't there.
- And — the subtle killer — the local R2 cache at `.wrangler/state/v3/r2` was empty. So all the API calls that used to be served from cached fixtures were now hitting the live network or returning nothing. Tests that depended on local cached blobs failed in ways that looked like backend bugs.

The reason: `git worktree add` checks out *tracked* files only. Your `.env.local`, `.dev.vars`, and `.wrangler/state` are all gitignored. They live only in the main checkout. The new worktree is a pristine working tree with a missing nervous system.

**The lesson:** "create a worktree" is not the same as "create a working development environment." The dev environment includes a graveyard of untracked-but-essential state — env files, local caches, build artifacts — that the worktree mechanism deliberately won't copy. You have to put it back, or symlink to it, deliberately.

## Stage 4 — Automation, and the Agent Who Wouldn't Run the Script

So I wrote a script. `setup-worktree.sh`. It symlinked the env files, symlinked `.wrangler/state` to share the local R2 cache with the main repo, and kicked off `npm install` in the background so I wouldn't have to wait for it to finish before the agent could start work.

Then I told the agent: *"Before working in a worktree, run `./scripts/setup-worktree.sh`."*

The agent ran it. Sometimes. The agent forgot to run it. Sometimes. The agent ran it but waited for npm install to finish (so much for backgrounding) and then ran out of patience and aborted. Sometimes. The agent ran a slightly different command it invented, missed an env file, and wrote 200 lines of code against an env that was missing the OAuth credentials.

I tried being more emphatic in the prompt. I tried `CLAUDE.md`. I tried hooks. The problem wasn't the agent's competence — it was that I was asking the wrong layer to enforce a thing that needed to be enforced by the system itself.

The right place to do worktree setup is *the moment the worktree is created*, before any agent touches it. That's exactly what Claude Code's `WorktreeCreate` hook is for. So I moved the script into the hook.

```jsonc
"WorktreeCreate": [{
  "hooks": [{
    "type": "command",
    "command": "bash -c '... git worktree add ...; symlink env files; npm install &; echo $DIR'"
  }]
}]
```

Now the agent literally cannot create a worktree without the setup running. The state is correct by construction.

**The lesson:** if a setup step is required for correctness, **don't ask the agent to do it**. Let the system do it. Agents are good at writing code; they are not your CI pipeline. Build the right rails and they will stay on them.

## Stage 5 — I Have Worktrees, but I Cannot See Them

By now I had a one-command worktree spinner that gave each branch its own env, its own local R2 cache, its own deterministic port range. The next problem appeared: *where do I look at them all?*

A handful of Terminal.app windows in macOS is unmanageable. You alt-tab to one, you lose your place in another. Two of them die silently because the dev server crashed. Three are running stale env vars from yesterday. You don't notice the wrangler in worktree #2 is throwing 500s until you happen to switch to it.

The Unix-native answer for "I have many terminals and I want to see them on one screen" is tmux. So I gave each worktree a tmux window, and each window a grid of panes — one for Claude, one for the wrangler MCP service, one for the agent-hub, one for the web app. Now I could see everything at once.

But raw tmux is brutal:

- The default `Ctrl+b` prefix for everything makes "switch pane" a four-keystroke affair.
- macOS terminals don't pass `Option`/`Alt` to tmux unless you flip a setting that's hidden three menus deep.
- Status bar shows window numbers, not friendly worktree names.
- Pane titles get overwritten the moment you start Claude (because Claude renames its terminal title), so the labels you set up vanish.

I customized:

- **`Alt+arrow`** to move between panes, staying zoomed (so you focus one pane fullscreen and "tab" through them).
- **`Shift+arrow`** to jump between worktrees.
- **`Alt+w`** to open a worktree picker — a tmux `choose-tree` view with live previews of each worktree's CLAUDE pane. Pick one, press Enter, drop into it fully interactive.
- **Status-bar labels** (CLAUDE / MCP / AGENT / WEB) on the top bar that follow the active pane — a `pane-focus-in` hook stores the active pane's `@role` in a session-level option, and the bar highlights the matching label in yellow.
- A `@role` tmux pane variable that *doesn't* get overwritten by Claude's title shenanigans, so my labels stay correct.

Along the way I went down two dead-ends worth mentioning:

1. **A custom "dashboard" window** showing all worktree Claude conversations side-by-side, mirrored via `pipe-pane` to log files and re-rendered with `tail -f`. It flickered, it was read-only, and tmux doesn't actually let you share a pane between two windows. After an hour I realized I was reimplementing a worse version of `choose-tree`. Killed it.
2. **Declaring the `WorktreeCreate` hook in the skill's `SKILL.md` frontmatter** instead of `settings.json`. Spec says you can. Reality: skill-scoped hooks don't fire for `claude --worktree` because that runs from outside any active skill session. Verified empirically with a "did the hook fire?" log file. Reverted.

**The lesson:** every time I tried to be too clever — share a pane, lazy-install hooks via the skill — I learned that the platform has good reasons for its boundaries. The shortest path is usually to lean on what tmux already does well, plus a small `.conf` to teach it your workflow.

## Stage 6 — The Worktree Bleed

By now I had visible worktrees, predictable ports, working dev stacks. And yet I kept losing time to one specific failure that took me embarrassingly long to name.

I'd be working in a worktree session. I'd ask the agent to fix something in `apps/web/lib/auth.ts`. It would say "done." I'd reload the app — no change. I'd diff the worktree — clean. I'd diff the **parent repo** — and there it was: my supposedly-isolated change, sitting in the main checkout, mixing with whatever else was uncommitted there.

The agent had edited the wrong copy of the file.

Why? Several footguns, all silent:

- The `Bash` tool starts each command in the parent repo's cwd, even when the rest of the session is "in" the worktree. So a `cd .claude/worktrees/foo && do-thing` works for that one call but `do-other-thing` in the next call starts back at the parent.
- The agent uses an absolute path like `/Users/me/projects/repo/apps/web/lib/auth.ts` (because that's what Grep returned, or what the file mention rendered as) — and that path resolves to the parent, not the worktree.
- A long-running dev server was already running from the parent path, so the agent "helpfully" edited the file it knew that server was loading from.

In all three cases, no error fires. The edit succeeds, in the wrong file, in the wrong branch. You only notice when your worktree's behavior doesn't change, or when `git status` in the parent shows mystery edits hours later.

I tried CLAUDE.md instructions ("always use the worktree path"). I tried memory entries. I tried being more careful. None of it worked, because we'd already established the lesson back in Stage 4: **if correctness depends on it, don't ask the agent.**

The right fix is a `PreToolUse` hook that intercepts `Edit`, `Write`, `MultiEdit`, `NotebookEdit` and refuses any write whose path falls inside the parent repo *while the session's cwd is inside a worktree*. The hook is short — maybe 40 lines of bash. The pseudocode:

```bash
if cwd matches "<repo>/.claude/worktrees/<branch>/...":
  if file_path under "<repo>/" but NOT under "<repo>/.claude/worktrees/<branch>/":
    exit 2 with error: "blocked — that path is the parent repo; use $worktree_root/$relative instead"
```

Exit code 2 means the write is rejected *and* the error message is returned to the model. So the next thing Claude sees is *"blocked — that path is the parent repo; use `.claude/worktrees/foo/apps/web/lib/auth.ts` instead"*. It retries with the right path. Problem self-corrects within the same turn, no user intervention.

This single hook eliminated a class of bug I'd been losing 20–30 minutes to per occurrence, several times a week.

**The lesson:** worktree isolation is only as strong as your weakest path resolution. The agent will, eventually, get an absolute path that points at the wrong copy of the file — through Grep results, file mentions, autocompletion, or just shell muscle memory. Don't trust the agent to never make this mistake; trust the platform to refuse the write.

## Stage 7 — Skill-ifying the Whole Thing

By this point everything worked but only for *my* repo. The scripts were full of hardcoded paths to `apps/web`, `apps/mcp/mcp-hub`, port 8787, etc. Useless for anyone else, including future-me on a different project.

So I generalized. The repo-specific bits — service paths, ports, commands, which folders to symlink — all moved into a single YAML at the repo root:

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

The launcher reads it, assigns ports by worktree directory creation time (oldest gets +10, next +20, etc.), and substitutes `{PORT}` and `{API_URL}` placeholders. The generic logic — tmux config, env symlinking, hook wiring — went into a Claude Code skill at `~/.claude/skills/tmux-worktrees/`.

The whole installation is now one command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rayhon/tmux-worktrees/main/install.sh)
```

That script copies the skill into place and registers the global `WorktreeCreate` hook. Then for any repo you want to use it in, you drop a `tmux-worktree.yaml` at the root and type `/tmux-worktrees`. Done.

Source: **[github.com/rayhon/tmux-worktrees](https://github.com/rayhon/tmux-worktrees)**

## Stage 8 — The Polish That Matters

The first version "worked." Living with it for a week surfaced the small papercuts that drive you to give up on tools. Each one had a one-line fix; finding the *right* one line was the work.

**Clipboard wipes on paste.** Copy a URL in the browser, switch to a tmux pane, ⌘V → nothing pasted, clipboard now empty. Two culprits, both ours:
- `set -g set-clipboard on` was forwarding OSC 52 from any process inside the pane out to the system clipboard. Some inner TUI was emitting an empty OSC 52 on focus, wiping the clipboard. **Fix:** `set -g set-clipboard off`. Inner processes can no longer overwrite the host clipboard.
- The mouse-drag-to-copy binding piped to `pbcopy` unconditionally. A click registered as a zero-pixel drag fired `pbcopy < /dev/null`, which clears the clipboard. **Fix:** `sh -c 'b=$(cat); [ -n "$b" ] && printf %s "$b" | pbcopy'` — guard against empty input.

**Mouse mode is the source of most pain.** Inside VS Code's xterm.js + tmux, mouse-on routes clicks through layers that can wipe clipboard, trap you in copy mode, or emit `^[[A^[[B` literals when a TUI app handles scroll wheel. **Fix:** default `set -g mouse off`. Bind `Ctrl+b m` to toggle it on for the rare cases you want clickable status / drag-resize. You lose click-to-switch-pane; you gain a terminal that doesn't fight you.

**Option+arrow ate by VS Code, not tmux.** With macOptionIsMeta on, you'd expect `Option+←` to send `ESC[1;3D` to tmux. VS Code intercepts it anyway for editor word-nav. **Fix:** `keybindings.json` override that forces VS Code to send the literal escape sequence to the terminal when terminal is focused:
```json
{ "key": "alt+left",  "command": "workbench.action.terminal.sendSequence",
  "args": { "text": "[1;3D" }, "when": "terminalFocus" }
```
…and the same for the other three arrows.

**Where am I?** Four panes look identical when you're tab-cycling through them with the keyboard. Two cheap signals: (1) `window-style fg=colour244` dims inactive panes, leaving the active one at full brightness; (2) a `pane-focus-in` hook stores the active pane's `@role` in a session-level `@active_role`, and the top status bar dynamically highlights the matching label in yellow. Now you can glance at either the pane or the status bar and instantly know which one is live.

**The status bar kept disappearing.** The dynamic status-right was only being set when the session was *created*. Any `source-file` reload or `--add` invocation left the default `  %H:%M ` in place. **Fix:** apply status-right at the end of every launcher run, unconditionally.

**The lesson:** the gap between "works in a demo" and "I trust it daily" is a stack of these one-liners. None of them are interesting individually. All of them together is the difference between a tool you reach for and a tool you avoid.

## What I Carry Forward

If you take nothing else from this story:

- **Parallel agents need parallel worlds.** One repo = one agent unless you isolate. Git worktrees are the cheapest isolation that actually works.
- **A "worktree" isn't a "dev environment."** You have to bring the gitignored state — env files, local caches, install artifacts — explicitly. Plan for this.
- **If correctness depends on a setup step, don't put it in the agent's prompt.** Put it in the platform. Hooks, install scripts, anything that runs without human or model judgment.
- **Make multiple sessions visible.** A long-running dev workflow with N worktrees is unworkable if you can't see them all. tmux is ugly but solves this for free.
- **Worktree isolation needs a guard.** Even with worktrees, the agent will eventually edit the wrong copy of a file via an absolute path. Use a `PreToolUse` hook to refuse writes that escape the worktree boundary.
- **Build for one project, generalize ruthlessly the second time you need it.** YAML config at the repo root, generic scripts in a skill — every monorepo can have the same UX with different services.

There's no clever insight here, really. Just a stack of small "oh, that's why" moments, each one trimming a stupid loss off the next day's work. If you've been quietly losing hours to one of these same problems, hopefully this saves you a few.

Now go give your one agent some siblings.
