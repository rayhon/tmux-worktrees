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

### Step 1 — If `tmux-worktree.yaml` is missing, scan the repo and propose one

**Don't ask the user blind.** Inspect the repo first, then present a draft yaml the user can accept or tweak.

Things to look for:

| Signal | Implies |
|---|---|
| `apps/*/package.json` (or `packages/*`, `services/*`) | Monorepo — one service per matching dir |
| Root `package.json` with a `dev` / `start` script | Single-service repo at root |
| `wrangler.toml` / `wrangler.jsonc` in a service dir | Cloudflare Worker — needs `--port {PORT}` in cmd, add `.wrangler/state` symlink |
| `next.config.{js,ts,mjs}` | Next.js — `npm run dev` works as-is (Next reads `PORT`) |
| `vite.config.{js,ts}` | Vite — `npm run dev` works as-is (Vite reads `PORT`) |
| `package.json` `dev` containing `wrangler` | Same as wrangler.toml — needs `--port {PORT}` |
| `package.json` `dev` containing `next` / `vite` / `node` / `tsx` / `nodemon` | Reads `PORT` env — no script change needed |
| Default port hint | scan `next.config.*` / `wrangler.jsonc` / `vite.config.*` / `.env*` for explicit port |

Then write a draft to the repo root:

```yaml
main:
  label: CLAUDE
  cmd: claude

services:
  - label: <LABEL>             # short, uppercase (WEB, API, WORKER, …)
    cwd: <relative-path>       # e.g. apps/web  (use "." for single-service repo)
    port: <base>               # see "Port base convention" below
    cmd: <start-command>       # see "Cmd patterns" below
    # Optional:
    # inspector_port: <base>   # for wrangler --inspector-port
    # symlinks:                # paths under cwd to symlink from main (e.g. .wrangler/state)
    #   - .wrangler/state
    # env:                     # extra exports for the pane
    #   FOO_URL: "{API_URL}"
```

**Cmd patterns** (this is the part users get wrong most often):

| Framework | Yaml `cmd` | Why |
|---|---|---|
| Next.js | `npm run dev` | Next reads `process.env.PORT` automatically |
| Vite | `npm run dev` | Vite reads `process.env.PORT` automatically |
| Express / Fastify / plain Node | `npm run dev` | Reads `process.env.PORT` |
| Wrangler (Worker) | `npx wrangler dev --port {PORT}` | Wrangler ignores `PORT`; needs explicit flag |
| Other framework that doesn't read PORT | `<cmd> --port {PORT}` or equivalent | Same as wrangler |

The skill exports `PORT=<resolved port>` into each service pane, so any framework that respects the standard `PORT` env var just works without touching the project's `package.json`. Only frameworks that ignore `PORT` (notably wrangler) need an explicit `--port {PORT}` substitution in the yaml cmd.

**Cross-service URLs** — use `{LABEL_URL}` (e.g. `{API_URL}`) in any pane's `cmd` or `env`. The skill substitutes the resolved `http://localhost:<port>`.

**Port base convention**: round each service's default down to the nearest 100 (8787→8700, 51957→51900, 3000→3000). Worktree offsets (+10, +20, …) are added on top.

### Step 2 — Show the draft, ask to confirm

Print the proposed yaml. Tell the user:
> "I scanned `apps/`, `wrangler.*`, `next.config.*`. Here's the draft. Sound right? Hit ok to write it, or tell me what to change."

Write on confirm. Don't write without confirmation.

### Step 3 — Launch

```bash
~/.claude/skills/tmux-worktrees/scripts/tmux-worktrees.sh
```

---

## Key facts

- **Per-pane PORT:** each service pane has `PORT=<its own offset port>` exported. Framework-aware frameworks (Next, Vite, Express, …) need no `--port` flag.
- **Named env vars:** every pane also sees `<LABEL>_PORT` and `<LABEL>_URL` for every service, so a WEB pane can reach `$API_URL`.
- **Navigation:** Alt+arrow moves panes (stays zoomed). Shift+arrow switches worktrees.
- **Pane jump:** click labels in the status bar, or Alt+m for a picker menu.
- **Restart:** `tmux -L wt kill-server` then re-run the launcher.
- **Add a worktree:** `claude --worktree <name>` — hook fires automatically, symlinks env, npm installs, adds tmux window.
- **Remove a worktree:** there is no WorktreeRemove hook (Claude Code doesn't emit one, and a raw `git worktree remove` couldn't fire it anyway). Instead the launcher **reconciles on every run**: any window whose worktree dir no longer exists is killed. So a stale window self-cleans on the next `/tmux-worktrees` launch or the next `claude --worktree` (which calls `--add`). To clean immediately without a full launch: `~/.claude/skills/tmux-worktrees/scripts/tmux-worktrees.sh --prune`. Pruning is keyed on dir existence, so passing an explicit subset of worktrees to the launcher never kills the others.
- **Port assignment:** alphabetical by worktree name, deterministic — 1st→+10, 2nd→+20, 3rd→+30.
