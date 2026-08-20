#!/usr/bin/env bash
# wt-offset.sh — allocate a MACHINE-WIDE unique port offset for a worktree.
#
# WHY THIS EXISTS. Offsets used to be claimed per repo, by scanning
# `$MAIN_ROOT/.claude/worktrees/*/.wt-port-offset` for the lowest free multiple
# of ten. Two problems, both real:
#
#   1. CROSS-REPO COLLISION. Every repo restarted at +10, so worktree A of
#      project X and worktree A of project Y both got +10 — and if their base
#      ports overlap (plenty of dev servers default to 8787 or 3000) their
#      ABSOLUTE ports collided. The offset was unique only within one repo.
#   2. INVISIBLE SIBLINGS. The scan only looked in `.claude/worktrees`, so
#      treehouse pool worktrees under `~/.treehouse/<hash>/<slot>/` were
#      invisible to it and every pool slot would have claimed +10. That is why
#      th-postcreate had to pre-seed `100 + slot*10` as a workaround.
#
# One allocator, one registry, no directory conventions:
#
#     ~/.config/wt-ports/registry.json   { "<worktree-abs-path>": <offset>, ... }
#
# The registry is the ALLOCATOR; `.wt-port-offset` in the worktree stays the
# per-worktree cache that consumers read, so nothing downstream changes.
#
# Self-healing: entries whose path no longer exists are pruned on every claim,
# so a worktree deleted with `rm -rf` (no `release`) does not leak its offset.
#
# Usage:
#   wt-offset.sh claim   <worktree-dir>       # print the offset, allocating if new
#   wt-offset.sh get     <worktree-dir>       # print the offset, or nothing
#   wt-offset.sh move    <old-dir> <new-dir>  # carry an offset across a rename
#   wt-offset.sh release <worktree-dir>       # free it (worktree destroyed)
#   wt-offset.sh list                         # every allocation, machine-wide
#
# `release` is for a worktree that is GONE, not for a pooled slot being freed:
# a parked slot keeps its path and its offset so its ports are stable across
# leases. Nothing calls release on the pool path for that reason, and a worktree
# deleted with `rm -rf` needs no call at all — claim prunes dead paths.
set -euo pipefail

REG_DIR="${WT_PORTS_DIR:-$HOME/.config/wt-ports}"
REG="$REG_DIR/registry.json"
LOCK="$REG_DIR/.lock"
STEP="${WT_OFFSET_STEP:-10}"
FLOOR="${WT_OFFSET_FLOOR:-10}"

mkdir -p "$REG_DIR"
[[ -f "$REG" ]] || printf '{}\n' > "$REG"

# mkdir is atomic on every filesystem we care about, and needs no flock (absent
# on stock macOS). Two concurrent worktree creations are common — treehouse can
# provision a pool in parallel — so the read-modify-write MUST be serialised or
# both would claim the same offset.
lock() {
  local tries=0
  until mkdir "$LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    # A crashed holder would otherwise wedge every future claim.
    if [[ $tries -gt 100 ]]; then
      echo "wt-offset: stale lock at $LOCK — removing" >&2
      rm -rf "$LOCK"
      continue
    fi
    sleep 0.1
  done
  trap 'rm -rf "$LOCK"' EXIT
}

abs() { (cd "$1" 2>/dev/null && pwd) || printf '%s' "$1"; }

# python3 rather than jq: jq is not guaranteed present, python3 ships with macOS,
# and this needs real JSON writing, not string surgery.
py() { python3 - "$@"; }

cmd=${1:-}; shift || true

case "$cmd" in
  claim)
    WT="$(abs "${1:?usage: wt-offset.sh claim <worktree-dir>}")"
    lock
    py "$REG" "$WT" "$STEP" "$FLOOR" <<'PY'
import json, os, sys
reg_path, wt, step, floor = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
try:
    reg = json.load(open(reg_path))
except Exception:
    reg = {}
# Prune allocations whose worktree is gone, so a deleted worktree frees its slot.
reg = {p: o for p, o in reg.items() if os.path.isdir(p)}
if wt in reg:
    print(reg[wt])
else:
    used = set(int(o) for o in reg.values())
    off = floor
    while off in used:
        off += step
    reg[wt] = off
    tmp = reg_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(reg, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, reg_path)          # atomic, never a half-written registry
    print(off)
PY
    ;;
  move)
    # RE-KEY an allocation when the worktree's PATH changes but its identity does
    # not. `git worktree move` is what makes this necessary: wt-pool renames a
    # slot into a branch on lease (_pool-3 → my-branch) and back on retire, so a
    # path-keyed registry would drop the association at every move. The old entry
    # is then pruned as "gone", a fresh offset is claimed for the new path, and
    # the slot's ports change on every lease — contradicting the pool's own
    # same-persisted-offset contract. Re-keying keeps the number with the slot.
    #
    # `move` deliberately does NOT allocate: if the old path was never registered
    # there is nothing to carry, and the caller's normal claim (link-worktree-env)
    # will allocate for the new path a moment later. Printing nothing says so.
    OLD="$(abs "${1:?usage: wt-offset.sh move <old-dir> <new-dir>}")"
    NEW="$(abs "${2:?usage: wt-offset.sh move <old-dir> <new-dir>}")"
    lock
    py "$REG" "$OLD" "$NEW" <<'PY'
import json, os, sys
reg_path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    reg = json.load(open(reg_path))
except Exception:
    reg = {}
off = reg.pop(old, None)
if off is not None:
    reg[new] = off
# Prune only AFTER the re-key: the old path is already gone by the time a caller
# runs this (the move happened), so pruning first would delete the very entry
# being carried over.
reg = {p: o for p, o in reg.items() if os.path.isdir(p)}
tmp = reg_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(reg, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, reg_path)
if off is not None:
    print(off)
PY
    ;;
  get)
    WT="$(abs "${1:?usage: wt-offset.sh get <worktree-dir>}")"
    py "$REG" "$WT" <<'PY'
import json, sys
try:
    reg = json.load(open(sys.argv[1]))
except Exception:
    reg = {}
v = reg.get(sys.argv[2])
if v is not None:
    print(v)
PY
    ;;
  release)
    WT="$(abs "${1:?usage: wt-offset.sh release <worktree-dir>}")"
    lock
    py "$REG" "$WT" <<'PY'
import json, os, sys
reg_path, wt = sys.argv[1], sys.argv[2]
try:
    reg = json.load(open(reg_path))
except Exception:
    reg = {}
freed = reg.pop(wt, None)
reg = {p: o for p, o in reg.items() if os.path.isdir(p)}
tmp = reg_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(reg, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, reg_path)
# nothing freed prints NOTHING (not a blank line), so `release` is safe in
# `off="$(wt-offset.sh release "$d")"; [[ -n "$off" ]]` — but a real offset gets
# its newline, or the caller's next echo runs onto the same line.
if freed is not None:
    print(freed)
PY
    ;;
  list)
    py "$REG" <<'PY'
import json, os, sys
try:
    reg = json.load(open(sys.argv[1]))
except Exception:
    reg = {}
for p, o in sorted(reg.items(), key=lambda kv: kv[1]):
    print(f"+{o:<5} {p}{'' if os.path.isdir(p) else '   (missing)'}")
PY
    ;;
  *)
    echo "usage: wt-offset.sh {claim|get|release|list} [worktree-dir]" >&2
    exit 2
    ;;
esac
