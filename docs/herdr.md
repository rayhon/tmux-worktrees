# Pooled worktrees — treehouse + herdr (recommended)

A **managed pool** of worktrees over [treehouse](https://github.com/kunchenguid/treehouse) (leases and returns reusable worktrees off your clone) viewed in [herdr](https://herdr.dev) (one persistent local server, a labeled tab per worktree). This is the recommended flow.

> Prefer the classic single-session tmux dashboard instead? See the [tmux flow](tmux.md). There's **no auto-switch** — you pick by the command you run, and the same `tmux-worktree.yaml` drives both.

**Why prefer it**

- **Warm, reusable slots** — treehouse hands back an already-provisioned worktree, so there's no re-clone or re-`npm install` per branch.
- **Branch-labeled tabs** — each herdr tab shows its branch and tracks it on later `git checkout` / rebase (a released slot reads `free-<slot>`).
- **Safe return** — the herdr server runs from `$HOME`, so returning a slot to the pool never kills your session.
- **Your real data, isolated** — worktrees share your clone's `.git` and the blob dirs you declare, while keeping per-slot state (see the yaml keys below).

## Prerequisites

- [treehouse](https://github.com/kunchenguid/treehouse) and [herdr](https://herdr.dev) on your `PATH`.
- The one-time `install.sh` (see the [README](../README.md)) registers the treehouse `post_create` hook so leased slots auto-wire (offset ports, env, symlinks). If you install treehouse *after* running the installer, just re-run it.

## Daily use — one command per branch

```bash
scripts/wt-up.sh <branch> [<session-name>]   # lease a slot, put it on <branch>, launch the stack
herdr --session <session-name>               # attach; one tab per worktree
scripts/wt-down.sh <slot-path>               # save context, return the slot to the pool (herdr stays up)
```

- **`wt-up.sh <branch> [<session-name>]`** — leases a free slot, checks out `<branch>` (fetches or creates it), restores that branch's saved Claude session (or starts fresh — a reused slot never leaks the previous occupant's conversation), and launches the herdr stack. `<session-name>` is the herdr session the tab lands in; it **defaults to `fmwt`**.
- **`herdr --session <session-name>`** — attach to see one tab per worktree, each with its live main + service panes. Use the same name you gave `wt-up`.
- **`wt-down.sh <slot-path>`** — archives the branch's Claude context, detaches the branch, and returns the slot to the pool for reassignment. herdr stays up; the tab relabels to `free-<slot>`.

You can also just **tell Claude Code** *"spin up a worktree on `<branch>`"* or *"release that worktree"* — it runs `wt-up.sh` / `wt-down.sh` for you. **Install and attach must be run by you in a terminal** — Claude can't bind your terminal.

## Sharing state — root-level yaml keys

The pooled flow reads two extra keys from `tmux-worktree.yaml`, declared **once at the root** (not per service) and applied to every service's `cwd`. `link-worktree-env.sh` uses them when a slot is wired:

```yaml
symlinks: [src/data]              # plain symlink from your clone (static shared dirs)
mirror_with_sqlite_copies:        # hybrid: blob dirs symlinked, SQLite copied per-slot
  - .wrangler/state
```

- **`symlinks`** — plain symlinks from the parent clone into each worktree, for read-only/static shared dirs.
- **`mirror_with_sqlite_copies`** — hybrid handling for stateful dirs: large immutable blob subtrees are **symlinked** (so every worktree sees the same real data) while SQLite files are **copied per-slot** (so each worktree owns its own locks and dev servers can run in parallel).

## Visual explainer

For the full picture — why a multiplexer, what each piece does, the `tmux-worktree.yaml` field guide, and the exact create-a-worktree call flow (which script does what) — open [`architecture.html`](architecture.html) in a browser.
