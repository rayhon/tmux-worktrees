---
name: tmux-worktrees
description: Give each git worktree its own live dev stack for the current repo. Default flow is a pooled worktree over treehouse + herdr (scripts/wt-up.sh <branch>); a classic tmux dashboard (/tmux-worktrees) is the alternative. Reads tmux-worktree.yaml at repo root.
type: flexible
---

# tmux-worktrees

Give each git worktree its own live dev stack (one pane per service from `tmux-worktree.yaml`). Two flows, both reading the same yaml.

## Decide the flow FIRST

**When the user asks to create / spin up / make a worktree on a branch, DEFAULT to the pooled flow — do NOT use Claude Code's native worktree tool (`EnterWorktree` / `claude --worktree`), which is the tmux flow.**

### Pooled flow — treehouse + herdr (DEFAULT)

Run, from the repo root (leases from the current repo's pool):

```bash
bash ~/.claude/skills/tmux-worktrees/scripts/wt-up.sh <branch> [<session-name>]
```

This leases a reusable worktree from a treehouse pool, checks out `<branch>`, wires it (offset ports, env, symlinks), and launches its stack in herdr. Then tell the user to attach in their own terminal (you can't bind their TTY):

```bash
herdr --session <session-name>      # session-name defaults to fmwt
```

Release later with `bash scripts/wt-down.sh <slot-path>`. Requires `treehouse` + `herdr` on `PATH`; if either is missing, say so and offer the tmux flow. Full guide: [docs/herdr.md](../../docs/herdr.md).

### tmux dashboard flow

Use **only** when the user explicitly wants tmux, or treehouse/herdr aren't available. This is the `/tmux-worktrees` flow documented below (Claude Code's `WorktreeCreate` hook + `tmux-worktrees.sh`). Full guide: [docs/tmux.md](../../docs/tmux.md).

---

## tmux dashboard flow — when invoked as `/tmux-worktrees`

### Step 0 — First-run install check

Check if the WorktreeCreate hook is wired:
```bash
grep -q "tmux-worktrees" ~/.claude/settings.json 2>/dev/null && echo "installed" || echo "not installed"
```

If not installed, tell the user to re-run the install command:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rayhon/tmux-worktrees/main/install.sh)
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

## Pooled worktrees over treehouse + herdr (recommended for teams)

Instead of the tmux + Claude-Code-worktree-hook flow above, a repo can use a
**managed pool** of worktrees via [treehouse](https://github.com/kunchenguid/treehouse)
and view each one's dev panes in [herdr](https://herdr.dev). This is the
zero-hand-holding path: a dev with plain Claude Code runs one command per branch
and gets a fully wired stack, no manual setup, no asking anyone.

**treehouse manages the worktree; herdr just creates the panes and attaches.**
treehouse keeps a small pool of reusable git worktrees off *your* clone (they
share `.git` and, via the `.wrangler` mirror, your real local data). herdr shows
each worktree's dev servers (main + services) in a labeled tab.

### One-time setup (done by `install.sh`)

`install.sh` (step 4) registers the treehouse `post_create` hook in
`~/.config/treehouse/config.toml` pointing at
`scripts/th-postcreate.sh`. That hook auto-wires every pooled worktree with
offset ports, env, symlinks, and the `.wrangler` mirror. **treehouse ignores
repo-level hooks for safety — the hook must be user-level, which is why the
installer writes it there.** Prereqs the dev installs themselves: `treehouse`
and `herdr` on `PATH` (the installer skips the hook with a note if treehouse is
absent).

Uses the same `tmux-worktree.yaml` at the repo root as the tmux flow — layout
(`main.ratio`, `zoom_main`), services, ports, and symlinks are all read from it.
No project-specific values live in the scripts.

### Daily use — one command per branch

```bash
# from a checkout of the repo whose pool you want (default: current dir):
scripts/wt-up.sh <branch>            # lease a slot, put it on <branch>, launch herdr stack
herdr --session fmwt                 # attach; the tab is named after the branch
# ... work in the CLAUDE pane; MCP/WEB/etc panes run the dev servers ...
scripts/wt-down.sh <slot-path>       # save context, release slot back to pool (herdr stays up)
```

- `wt-up.sh <branch> [session] [repo-dir]` — leases a free treehouse slot,
  checks out `<branch>` (fetches or creates it), restores that branch's saved
  Claude context if any (else starts fresh — a reused slot never leaks the
  previous occupant's conversation), and launches the herdr stack. Also installs
  `post-checkout` + `post-rewrite` + `reference-transaction` hooks so the tab label
  always tracks the branch — including a `git branch -m` rename (which the checkout
  hooks never see, since HEAD doesn't move; `reference-transaction` catches it).
- `wt-down.sh <slot-path> [session]` — archives the branch's Claude context,
  detaches the branch, returns the slot to the pool for reassignment, and
  relabels the now-free tab. **Does NOT kill herdr** (the server runs from `$HOME`
  so returning a slot can't take the session down).
- Tab labels reflect status automatically: an active worktree shows its branch;
  a released (detached) one shows `free-<slot>`.

### Gotchas

- **Real data:** the pool is keyed to whichever clone you run `wt-up.sh` from.
  Run it from the clone whose local data (`.wrangler`, populated sqlite) you want
  the worktree to share — a fresh/empty clone mirrors empty data.
- **herdr server cwd:** `wt-up.sh` starts the herdr server from `$HOME`, never a
  slot, so `treehouse return` (which kills processes by cwd) can't kill the
  session. Don't start `herdr server` yourself from inside a slot.
- **Same branch, two worktrees:** git forbids it — a branch can be checked out in
  only one worktree at a time.

---

## Creating a worktree — two paths (tmux flow)

**A. You, from a terminal:** `claude --worktree <name>` — fires the WorktreeCreate hook (wires env, offset ports, npm install) AND opens a fresh interactive Claude session + tmux window you're attached to.

**B. The agent, in-session (no terminal needed from you):** the assistant can do everything except bind your terminal:
1. `EnterWorktree <name>` tool — fires the **same** WorktreeCreate hook (env + offset ports), switches the session into the worktree.
2. Run the launcher **headless** to build the tmux session + start every dev server in its pane:
   ```bash
   ~/.claude/skills/tmux-worktrees/scripts/tmux-worktrees.sh <name> < /dev/null
   ```
   With no TTY it builds + starts servers, then prints the attach line instead of attaching.
3. **You run the one universal command to watch the panes:**
   ```bash
   tmux -L wt attach -t wt
   ```

Split the work this way: **agent = create + wire + launch + servers; you = `tmux -L wt attach`.** The launcher's machinery stays hidden behind the agent; you only ever type the attach command everyone already knows.

**Gotchas (macOS):**
- **No `timeout`** — never wrap the launcher in `timeout` (it's GNU-only; exits 127). Background it instead.
- **mcp-hub offsets from its own base 8787** → +20 = 8807, etc. (web 3000→3020, agent 51957→51977). Don't assume a single 87xx base.
- The WorktreeCreate hook branches new worktrees from **local `HEAD`** (not `origin/HEAD`) — so they carry your local-only commits. `git pull` first if you also want the remote's latest.

---

## Key facts

- **Per-pane PORT:** each service pane has `PORT=<its own offset port>` exported. Framework-aware frameworks (Next, Vite, Express, …) need no `--port` flag.
- **Named env vars:** every pane also sees `<LABEL>_PORT` and `<LABEL>_URL` for every service, so a WEB pane can reach `$API_URL`.
- **Navigation:** Alt+arrow moves panes (stays zoomed). Shift+arrow switches worktrees.
- **Pane jump:** click labels in the status bar, or Alt+m for a picker menu.
- **Restart:** `tmux -L wt kill-server` then re-run the launcher.
- **Add a worktree:** `claude --worktree <name>` (you, terminal) OR `EnterWorktree <name>` + headless launcher (the agent, in-session) — see "Creating a worktree" above. Hook fires either way: symlinks env, offset ports, npm installs, adds tmux window.
- **Remove a worktree:** there is no WorktreeRemove hook (Claude Code doesn't emit one, and a raw `git worktree remove` couldn't fire it anyway). Instead the launcher **reconciles on every run**: any window whose worktree dir no longer exists is killed. So a stale window self-cleans on the next `/tmux-worktrees` launch or the next `claude --worktree` (which calls `--add`). To clean immediately without a full launch: `~/.claude/skills/tmux-worktrees/scripts/tmux-worktrees.sh --prune`. Pruning is keyed on dir existence, so passing an explicit subset of worktrees to the launcher never kills the others.
- **Port assignment:** the lowest free multiple of ten, allocated **machine-wide** by `scripts/wt-offset.sh` against `~/.config/wt-ports/registry.json`. Not per repo and not alphabetical: offsets used to restart at +10 in every repo, so worktree A of one project and worktree A of another both took +10 and collided whenever their base ports matched (8787 and 3000 are everybody's defaults). One registry means a pool slot, a `.claude/worktrees` checkout and an unrelated repo can never share an offset. `.wt-port-offset` in the worktree stays the cache consumers read.
  - `wt-offset.sh list` shows every allocation on the machine — the fastest way to answer "what is on 8810?".
  - A worktree deleted with `rm -rf` needs no cleanup; dead paths are pruned on the next claim. `release` is for a worktree that is gone, **not** for a pooled slot being freed — a parked slot keeps its offset so its ports are stable across leases.
  - `git worktree move` changes the registry key, so `wt-pool.sh` calls `wt-offset.sh move` on both lease and retire. Without that a slot draws a fresh offset every lease.

---

## `.wt-env.json` — what an agent should read

Every wired worktree carries `.wt-env.json` at its root. **This is the file to read**, not `tmux-worktree.yaml`: the yaml is *intent* shared by every worktree (base ports, policy), the manifest is *outcome* for this one — resolved ports, resolved commands, resolved env, and what actually landed on disk.

```sh
jq -r '.services[0].port'  .wt-env.json   # 8810, not the 8790 base
jq -r '.services[]|.cmd'   .wt-env.json   # runnable as-is, placeholders resolved
jq -r '.offset'            .wt-env.json   # this worktree's port offset
```

Without it a consumer has to find the yaml, have `yq`, know `port:` is a base rather than a port, read `.wt-port-offset` separately, and do the arithmetic — five steps and a convention it must be told.

- `cmd` and `env` have `{PORT}`, `{INSPECTOR_PORT}`, `{LABEL_PORT}` and `{LABEL_URL}` already substituted, so a service starts without knowing tmux, herdr or treehouse exist.
- `state_landed` reports what `.wrangler/state` actually is — `symlink`, `copy` or `absent` — which the yaml's `wrangler_state:` request cannot tell you.
- **Minimal mode:** a repo with no `tmux-worktree.yaml` still gets a manifest, with `"mode": "minimal"`, the offset, copied env files and an empty `services` list. Adopting the yaml is an upgrade, not an entry fee, so an agent can rely on the manifest existing in any wired worktree.

**Never bind a base port.** Take the port from the manifest, or add `.offset` to the project's base yourself.
