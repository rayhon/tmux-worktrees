# tmux-worktrees

A Claude Code skill that gives every git worktree its own live dev stack — one pane per service defined in a `tmux-worktree.yaml` at the repo root — so you can work several branches in parallel and glance across them.

It ships **two flows** that read the **same** `tmux-worktree.yaml`. There's no auto-switch; you pick by the command you run.

## Two flows — which one?

| | [**Pooled — treehouse + herdr**](docs/herdr.md) · *recommended* | [**Classic — tmux**](docs/tmux.md) |
|---|---|---|
| Worktrees | A reusable **pool** leased by [treehouse](https://github.com/kunchenguid/treehouse) off your clone | Claude Code's `WorktreeCreate` hook, under `.claude/worktrees/` |
| View | [herdr](https://herdr.dev): one server, a **branch-labeled tab** per worktree | one tmux session, a **window** per worktree |
| Best when | juggling many branches; want warm slots + no re-`npm install` | you already live in tmux; no extra tooling |
| Command | `scripts/wt-up.sh <branch>` | `claude --worktree <name>` + `/tmux-worktrees` |
| Full guide | **[docs/herdr.md](docs/herdr.md)** | **[docs/tmux.md](docs/tmux.md)** |

**Visual explainer (both flows, why + how):** open [`docs/architecture.html`](docs/architecture.html) in a browser.

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rayhon/tmux-worktrees/main/install.sh)
```

Downloads the skill to `~/.claude/skills/tmux-worktrees/`, wires the global `WorktreeCreate` hook (tmux flow), installs the pooled-worktree scripts (`wt-up.sh` / `wt-down.sh` / `herdr-worktrees.sh`), and — if [treehouse](https://github.com/kunchenguid/treehouse) is on your `PATH` — registers the treehouse `post_create` hook so pooled worktrees auto-wire. Run once per machine.

## Per-repo setup

Drop a `tmux-worktree.yaml` at your repo root (or run `/tmux-worktrees` in Claude Code and let it propose a draft from a scan of your repo):

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

- **`{PORT}`** in a cmd is replaced with the worktree's actual assigned port.
- **`{LABEL_URL}`** / **`{LABEL_PORT}`** give another service's URL/port (e.g. `{API_URL}`) so panes reach each other.
- The **pooled flow** also reads root-level `symlinks:` / `mirror_with_sqlite_copies:` for shared state — see [docs/herdr.md](docs/herdr.md).

> **Heads up on `--dangerously-skip-permissions`:** auto-approves every tool call Claude makes (writes, deletes, shell commands). Each worktree is in its own isolated folder so the blast radius is contained, but you're giving up the per-call prompt. Use `cmd: claude` if you'd rather keep the prompts.

## `.wt-env.json` — the manifest agents read

Wiring a worktree writes `.wt-env.json` at its root: this worktree's **resolved** ports, commands, env and on-disk outcome. `tmux-worktree.yaml` is intent shared by every worktree; the manifest is what this one actually got.

```sh
jq -r '.services[0].port' .wt-env.json   # 8810 — the offset port, not the 8790 base
jq -r '.services[]|.cmd'  .wt-env.json   # placeholders already substituted, runnable as-is
```

Anything automated — Claude Code, an agent working in the worktree, CI — should read this rather than parse the yaml and redo the offset arithmetic. `state_landed` also records whether `.wrangler/state` ended up a symlink, a copy or absent, which the yaml cannot tell you.

A repo with **no** `tmux-worktree.yaml` still gets one, as `"mode": "minimal"` — offset plus copied env files, empty `services`. The manifest is always there to read, so adopting the yaml is an upgrade rather than a prerequisite.

Offsets come from one **machine-wide** registry (`~/.config/wt-ports/registry.json`, managed by `scripts/wt-offset.sh`), so two repos can never hand out the same offset to worktrees whose base ports overlap. `wt-offset.sh list` shows every allocation on the machine.

## Config gotcha — per-worktree URLs

Worktrees run on **offset ports**, but env files are shared from the main clone, where values were written for the original port. When an app reads its **own** URL from env, you get a mismatch — the dev server listens on `:3010` but thinks it's `:3000`. Symptoms range from broken auth callbacks to silently-wrong API targets.

**Rule of thumb: any env var that encodes a port or base URL must be re-derived per worktree, not shared.** Set them in `cmd:` using `{LABEL_URL}` / `{LABEL_PORT}` so each worktree gets its own values.

| App / library | Variable | Failure mode |
|---|---|---|
| Better Auth | `APP_URL`, `AUTH_TRUSTED_ORIGINS` | `Invalid origin: http://localhost:3010` on every sign-in |
| NextAuth | `NEXTAUTH_URL` | OAuth callback returns to main's port, session fails to set |
| Next.js public URLs | `NEXT_PUBLIC_APP_URL`, `NEXT_PUBLIC_API_URL` | Client-side fetches go to main's port instead of the worktree's |
| OAuth providers (Google/GitHub) | redirect URI in provider dashboard | `redirect_uri_mismatch` — add `localhost:3010`/3020/3030 to allowed callbacks |
| CORS allowlists | server-side allowed origins | Request from `localhost:3010` rejected by the server it's calling |
| Cross-service URLs | `MCP_HUB_URL`, `API_URL`, etc. | Worktree's web app calls *main's* API/MCP instead of its own |

Example — Better Auth + cross-service URLs, made self-consistent per worktree:

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

> **Tip:** if you see *"Invalid origin"*, *"redirect_uri_mismatch"*, or *"Cross-Origin Request Blocked"* on a fresh worktree, it's almost always a missing `{LABEL_URL}` in your `cmd:` line.

## Requires

- yq (`brew install yq` — auto-installed if missing)
- **tmux flow:** tmux
- **pooled flow:** [treehouse](https://github.com/kunchenguid/treehouse) + [herdr](https://herdr.dev) on your `PATH`
