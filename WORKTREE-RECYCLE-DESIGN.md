# Worktree Recycling — Design

Status: draft for review. Not implemented yet.

## Goal

Two things at once:

1. **Task-identifiable trees.** Every live tree shows *which task* it holds, and each task maps to a branch name.
2. **No upfront wait.** Reuse already-provisioned worktrees instead of create-then-`npm install` on every new task. A new task pays ~1s of re-wiring, not a full install, as long as a warm slot is free.

## Why this is cheap to add

The expensive step is already idempotent. `link-worktree-env.sh` starts `npm install` only when `node_modules` **or** `.npm-install.ok` is missing:

```
if [[ ! -d node_modules ]] || [[ ! -f .npm-install.ok ]]; then  # install
else  echo "node_modules + install sentinel present — skipping npm install"
```

And ports are already stable per **dir**, not per name: the offset is persisted once in `.wt-port-offset` and "claims the lowest free multiple of 10 not already taken by a sibling," so add/remove never shifts a running tree's ports.

So a worktree whose dir survives keeps `node_modules`, `.npm-install.ok`, `.wt-port-offset`, its copied+rewritten env, and its symlinks — and re-wiring it skips install. **The only reason we pay install today is that removal deletes the dir.** Recycling = keep the dir, rebind the branch.

## Model: warm parked slot, `git worktree move` into identity

The launcher's whole world keys on one invariant: **window name == dir basename == the identity you see**. Prune (`[[ -d .claude/worktrees/$wname ]]`), offset (`.wt-port-offset` per dir), and `jump-pane.sh` (`@role`) all rely on it. So instead of breaking that invariant with a registry+rename, we *preserve* it and recycle underneath it with `git worktree move`.

| Concept | Value | Lifetime |
|---|---|---|
| **Parked slot** (warm dir) | `.claude/worktrees/_pool-1`, `_pool-2`, … (leading `_`) | Persists; holds warm `node_modules` + `.npm-install.ok` + `.wt-port-offset` + env |
| **Live tree** (task identity) | `.claude/worktrees/<branch>` — same dir, moved & renamed | One lease |

- **Lease** = `git worktree move _pool-N <branch>`. The warm dir *becomes* the branch-named live tree — an instant same-filesystem rename that carries `node_modules`, env, and the offset marker along. The launcher then sees an ordinary branch-named worktree and builds its window exactly as today. **Zero launcher changes for identity, ports, or jump.**
- **Retire** = move it back: `git worktree move <branch> _pool-N`. Warm assets stay; the slot is free again.
- "Which tree is for what task" reads off the window name = branch, unchanged from today.

Only one small launcher touch is needed: **skip `_`-prefixed parked dirs** in the worktree scan and in prune, so a parked slot doesn't get a window built or get reaped. One guard line in each of two loops.

A lightweight **registry** (`.wt-pool.json`) still tracks each slot's `free | leased→branch | dirty` state and drives headroom, but it is *not* on the identity/port/window path — those are handled entirely by the move.

## State machine

```
        provision (npm install, once)
  ∅  ────────────────────────────────▶  free (warm: node_modules + sentinel + offset)
                                          │
                              lease task/x │
                                          ▼
                                       leased  (window="task/x", servers up)
                                          │
                    ┌─────────────────────┼─────────────────────┐
             work clean                dirty tree            branch unlanded
                    │                     │                       │
             retire │                     │ (blocked — see guard) │
                    ▼                     ▼                       ▼
                  reset ───────────────▶ free                 stays leased
```

## Registry

One file at the repo root, e.g. `.wt-pool.json` (gitignored):

```json
{
  "slots": {
    "pool-1": { "state": "leased", "branch": "task/frame-cache", "since": "2026-07-15T18:00:00Z" },
    "pool-2": { "state": "free",   "branch": null },
    "pool-3": { "state": "dirty",  "branch": "task/old-thing" }
  }
}
```

`state ∈ {free, leased, dirty}`. Source of truth for what's warm and what a slot currently holds. The launcher and lease/retire commands read+write it.

## Lease recipe

`wt-pool.sh lease <branch> [base]` (base defaults to the repo's default branch HEAD):

1. Pick a slot: first `free` `_pool-N` in the registry. If none free → **provision** a fresh one (pays install once, backgrounded) or wait — governed by headroom K below.
2. Move the warm slot into the branch-named identity (instant same-fs rename, carries deps/env/offset):
   ```bash
   git worktree move ".claude/worktrees/_pool-N" ".claude/worktrees/<branch>"
   ```
3. Rebind git state to the task branch, clear only untracked cruft:
   ```bash
   git -C "<live-dir>" fetch --quiet
   git -C "<live-dir>" checkout -B "<branch>" "<base>"
   git -C "<live-dir>" reset --hard
   git -C "<live-dir>" clean -fd            # NO -x: keeps gitignored node_modules + .env.local + .wrangler + sentinel
   ```
4. Dependency-drift gate + stale-lock clear, then re-wire env (same offset, install skips unless deps changed):
   ```bash
   new=$(sha1 package-lock.json); old=$(cat .npm-install.lock-hash 2>/dev/null)
   [[ "$new" != "$old" ]] && rm -f .npm-install.ok          # only then does link-env reinstall
   find "<live-dir>" -path '*/.wrangler/state/*' \( -name '*.sqlite-shm' -o -name '*.sqlite-wal' \) -delete
   ~/.claude/skills/tmux-worktrees/scripts/link-worktree-env.sh "<live-dir>"
   printf '%s\n' "$new" > "<live-dir>/.npm-install.lock-hash"
   ```
5. Build/attach the window via the existing launcher — `tmux-worktrees.sh --add <branch>` names the window `<branch>` and starts servers exactly as today.
6. Registry: slot → `{ leased, branch }`; top up headroom.

Wall cost when deps unchanged: worktree-move + git ops + env re-copy ≈ 1s. No `npm install`.

### Why `git clean -fd` (no `-x`) is correct

Verified against agent-board `.gitignore`: `node_modules/`, `.env.*`, `.wrangler/`, `.npm-install.ok` are all gitignored. `git clean -fd` removes **untracked but non-ignored** cruft (stray build files, scratch) while leaving every warm asset intact. `-x` would wipe them and defeat the whole design — never add it.

## Retire recipe

`wt-pool.sh retire <branch>`:

1. **Dirty guard** (mirrors the fleet teardown rule): refuse if the tree has uncommitted changes **or** the branch holds commits not reachable from the default branch / any remote. A retire that would lose work stops and reports; it never force-cleans. Mark the slot `dirty` in the registry so it's excluded from lease until resolved.
2. Kill the tmux window, then reset and move the dir back to a parked slot:
   ```bash
   tmux -L wt kill-window -t "wt:<branch>"
   git -C "<live-dir>" checkout <base> && git -C "<live-dir>" reset --hard && git -C "<live-dir>" clean -fd
   git worktree move ".claude/worktrees/<branch>" ".claude/worktrees/_pool-N"
   ```
3. Registry → `free`.

The dir, deps, offset, env, and lockfile-hash stay — that's the point.

## Headroom K

Keep **K** free warm slots ready at all times.

- After any lease, if `free < K`, background-provision a new `pool-N` (install runs detached, exactly like today's first-run install, so it's ready before the next task).
- K is a config knob (`headroom: 2` in `tmux-worktree.yaml`). K=0 means "provision on demand" (pay install per new task); K≥1 means "always one warm" (typical).
- Cap total slots (`pool_max`) so a burst doesn't spawn unbounded trees.

This is the "headroom" — spare warm capacity so a lease is instant.

## Reconcile coexistence

Today the launcher builds one window per dir under `.claude/worktrees/`, and kills any window whose dir no longer exists (`--prune`). The move model needs exactly **one guard**: parked `_pool-N` dirs must be **skipped** by both the worktree scan and prune.

- **Scan skip:** in the launcher's NAMES population, `continue` on a basename starting with `_`. So a parked slot never gets a window built.
- **Prune skip:** `prune_stale_windows` keys on `[[ -d .claude/worktrees/$wname ]]`; window names never start with `_` (they're branch names), so parked dirs don't map to any window and prune is already inert toward them. No change strictly needed, but add an explicit `_`-skip comment for clarity.
- A leased tree is an ordinary branch-named dir → launcher and prune treat it exactly like a hand-made worktree today. **Nothing else changes.**

## Data topology — why recycling is state-safe

A recycled slot must never serve stale or wrong data. Given this project's topology, it doesn't:

- **Neon (Postgres, cloud) = auth only.** Shared by every worktree through the `DATABASE_URL` env var. There is **no per-worktree local database** — so nothing to warm, nothing to drift on recycle. A recycled slot inherits the same cloud URL. Auth-schema changes are cloud-side migrations, applied once and shared; they are not per-slot state.
- **R2 = the real data.** In dev that is `.wrangler/state` — miniflare's local R2 emulation. The hybrid mirror **symlinks the blob dirs from parent** (shared, immutable, always current) and **copies only the SQLite lock files per-worktree**. So a recycled slot always sees current R2 blobs with zero refresh, and the only per-slot state is the SQLite locks.

Net: there is no local DB to go stale, so no `--fresh-db` / migration-refresh path is needed. The only two things that can be wrong on re-lease are dependency drift and stale SQLite locks — both handled automatically below.

## Automatic on re-lease (resolved behavior, not open risks)

- **Dependency drift → hash-gated reinstall.** Store the installed lockfile's hash beside the sentinel (`.npm-install.lock-hash`). On lease, hash the new branch's `package-lock.json` and compare. Unchanged → keep warm `node_modules`, skip install. Changed → `rm .npm-install.ok` so `link-worktree-env.sh` reinstalls **only that time**. No manual step.
- **Stale SQLite locks → targeted rm.** On the lease reset, `rm -f **/*.sqlite-shm **/*.sqlite-wal` under `.wrangler/state` to clear stale miniflare/workerd locks, while **keeping** the `.sqlite` data files. Not a blanket clean.
- **Running servers during retire.** Stop on retire, restart on lease via each pane's `@start_cmd` (fast). A free slot holds no running dev servers, so it ties up no ports.
- **Two sessions leasing at once.** The registry write takes a `flock` on `.wt-pool.json` so concurrent leases can't grab the same slot.

## Implementation surface

Small and mostly additive:

- **`wt-pool.sh`** (new) — owns `provision` / `lease` / `retire` / `status`, the `.wt-pool.json` registry with `flock`, the worktree-move recycling, the lockfile-hash drift gate, the SQLite-lock clear, and headroom top-up. Reuses `link-worktree-env.sh` and `tmux-worktrees.sh --add` rather than reimplementing them.
- `tmux-worktrees.sh` (2-line touch) — skip `_`-prefixed parked dirs in the worktree scan; explicit `_`-skip note in prune.
- `link-worktree-env.sh` (tiny) — write `.npm-install.lock-hash` alongside `.npm-install.ok` after a successful install so the lease drift-gate has a baseline.
- `tmux-worktree.yaml` — new keys: `headroom: <K>`, `pool_max: <N>`.
- `.wt-pool.json` — new registry (gitignored).

## Open decisions (defaults chosen, flag to change)

1. **Recycling mechanism:** `git worktree move` a warm `_pool-N` into the branch-named dir. *(Chosen — preserves the launcher's window==dir invariant, so ports/prune/jump need no rework.)*
2. **`git clean -fd` no `-x`:** confirmed safe against agent-board `.gitignore`. *(Chosen.)*
3. **Parked slots are window-less** (leading `_`, skipped by the launcher scan). No placeholder window. *(Chosen — a free slot ties up no window/port.)*
4. **Servers on retire:** stop (kill window). Lease restarts them via the launcher. *(Chosen.)*
5. **K (headroom) and `pool_max`:** defaults `K=2`, `pool_max=6`. *(Tune to machine.)*
6. **`git worktree move` while checked-out:** git allows moving a worktree that has a branch checked out; contents are a same-fs rename so `node_modules`/env travel intact. Verify once on your git version before trusting in anger. *(Assumed valid — smoke-test in the build.)*

## Data-safety note (topology-specific)

Recycling is safe because auth data lives in **cloud Neon** (shared via env, no local copy) and real data lives in **R2**, whose dev blobs are **symlinked from parent** (always current). The only per-slot local state is SQLite lock files, cleared on every lease. If that topology changes — e.g. a real per-worktree local database is introduced — revisit this section before trusting recycled state.
