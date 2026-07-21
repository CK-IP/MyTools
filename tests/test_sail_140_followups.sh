#!/usr/bin/env bash
# test_sail_140_followups.sh — #136 follow-ups (#140), items 1 & 2.
#
# Item 1 — orphan-resume worktree reuse is ALREADY collision-free. /surf's orphan-resume just
# relaunches a fresh `/sail` worker; /sail's Stage 0.5 isolate calls sail_setup_isolation, which is
# idempotent (#65/#92/#115): an existing `.claude/worktrees/sail-<n>` on an unmerged `sail/<n>`
# branch is REUSED (rc=0, same path), never re-created into a collision. This pins that property so
# it cannot regress (the follow-up's real deliverable is the regression lock, not new orchestration).
#
# Item 2 — the /surf resolver ↔ /sail run-dir naming CONTRACT. surf_worker_resolve_run_dir
# deliberately validates every run-dir suffix against `[0-9]{8}T[0-9]{6}Z` (a #136 forged-suffix
# guard). That couples it to /sail's documented run-dir format (sail.md Stage 0). If /sail ever
# changes that format the resolver would silently find nothing → false-park. This test locks the
# contract: the format documented in sail.md is accepted by the live resolver, and a non-conforming
# suffix is still rejected (the guard stays intact).
#
# Hermetic: every assertion runs against a THROWAWAY temp repo, never the live tree (mirrors
# test_sail_82_land_lifecycle.sh / test_surf_worker.sh idiom).

set -euo pipefail

# Neutralize inherited SAIL_* knobs (hermeticity rule, #97/#102).
unset "${!SAIL_@}" 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIFECYCLE="$REPO_ROOT/home/lib/sail-git-lifecycle.sh"
RESUME_SAFETY="$HOME/.claude/lib/ship-resume-safety.sh"
WORKER="$REPO_ROOT/config/surf-worker.sh"
SAILMD="$REPO_ROOT/commands/sail.md"

TMP_ROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); }

[ -f "$LIFECYCLE" ] || fail "sail-git-lifecycle.sh exists at $LIFECYCLE"
[ -f "$WORKER" ] || fail "surf-worker.sh exists at $WORKER"
[ -f "$SAILMD" ] || fail "sail.md exists at $SAILMD"

# ship_safe_cleanup_orphan_dir is an EXTERNAL cc-dotfiles dep sail_setup_isolation needs in scope.
# shellcheck disable=SC1090
[ -f "$RESUME_SAFETY" ] && . "$RESUME_SAFETY"
# shellcheck disable=SC1090
. "$LIFECYCLE"
command -v sail_setup_isolation >/dev/null 2>&1 || fail "sail_setup_isolation is defined"

make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.io
  git -C "$dir" config user.name tester
  echo base > "$dir/base.txt"
  git -C "$dir" add -A && git -C "$dir" commit -qm "base"
}

# --- ITEM 1, T1: sail_setup_isolation is idempotent — orphan-resume reuse is collision-free ---
if command -v ship_safe_cleanup_orphan_dir >/dev/null 2>&1; then
  R1="$TMP_ROOT/r1"; make_repo "$R1"
  WT_A="$(sail_setup_isolation "$R1" 140)" || fail "T1: first isolate failed"
  # Simulate a parked/orphaned run: the worktree is left intact, on an UNMERGED sail/140 branch,
  # and /sail's run-dir was written INSIDE the worktree (untracked, gitignored .sail/).
  mkdir -p "$WT_A/.sail/runs/sail-140-20260101T000000Z"
  printf '{}' > "$WT_A/.sail/runs/sail-140-20260101T000000Z/run-state.json"
  # Orphan-resume relaunches a fresh /sail worker → Stage 0.5 calls sail_setup_isolation AGAIN.
  WT_B="$(sail_setup_isolation "$R1" 140)"; rc=$?
  [ "$rc" -eq 0 ] || fail "T1: second isolate (orphan-resume) must rc=0 (reuse), got rc=$rc"
  [ "$WT_A" = "$WT_B" ] || fail "T1: orphan-resume did not REUSE the same worktree (A=$WT_A B=$WT_B) — collision path"
  # The worktree still exists on the branch, and the parked run-dir was preserved (not clobbered).
  git -C "$R1" worktree list --porcelain | grep -qx "branch refs/heads/sail/140" \
    || fail "T1: sail/140 no longer checked out in a worktree after reuse"
  [ -f "$WT_B/.sail/runs/sail-140-20260101T000000Z/run-state.json" ] \
    || fail "T1: reuse clobbered the parked run-dir inside the worktree (data loss)"
  ok; echo "PASS T1 (item 1): orphan-resume reuse is collision-free (idempotent sail_setup_isolation, parked work preserved)"
else
  echo "SKIP T1 (item 1): ship_safe_cleanup_orphan_dir unavailable (external cc-dotfiles dep) — sourced from $RESUME_SAFETY"
fi

# --- ITEM 2, T2: the resolver's timestamp regex is coupled to /sail's DOCUMENTED run-dir format ---
# (a) sail.md Stage 0 documents the exact suffix format token — the source of the contract.
grep -qF 'date -u +%Y%m%dT%H%M%SZ' "$SAILMD" \
  || fail "T2a: sail.md no longer documents the 'date -u +%Y%m%dT%H%M%SZ' run-dir suffix (contract source moved)"
ok; echo "PASS T2a (item 2): sail.md documents the run-dir suffix format token"

# (b) a sample produced by that EXACT documented format is accepted by the live resolver.
# shellcheck disable=SC1090
. "$WORKER"
command -v surf_worker_resolve_run_dir >/dev/null 2>&1 || fail "surf_worker_resolve_run_dir is defined"
TS="$(date -u +%Y%m%dT%H%M%SZ)"   # the SAME invocation sail.md:16 documents
RR="$TMP_ROOT/resolve"; mkdir -p "$RR/.sail/runs/sail-9-$TS"
printf '{}' > "$RR/.sail/runs/sail-9-$TS/run-state.json"
printf '{}' > "$RR/.sail/runs/sail-9-$TS/review.json"
GOT="$(surf_worker_resolve_run_dir 9 "$RR" 2>/dev/null || true)"
case "$GOT" in
  */.sail/runs/sail-9-"$TS") ok; echo "PASS T2b (item 2): resolver accepts /sail's documented '$TS' run-dir format" ;;
  *) fail "T2b: resolver did NOT accept a run-dir named with /sail's documented format ('$TS'); got: '$GOT' — naming CONTRACT BROKEN (resolver would false-park every real run)" ;;
esac

# (c) the forged-suffix guard is INTACT — a non-conforming suffix is still rejected (not force-picked
# by any fallback). Pins that the item-2 fix is a contract LOCK, never a guard-weakening fallback.
NC="$TMP_ROOT/resolve-nonconforming"; mkdir -p "$NC/.sail/runs/sail-9-NOTATIMESTAMP"
printf '{}' > "$NC/.sail/runs/sail-9-NOTATIMESTAMP/run-state.json"
printf '{}' > "$NC/.sail/runs/sail-9-NOTATIMESTAMP/review.json"
if surf_worker_resolve_run_dir 9 "$NC" >/dev/null 2>&1; then
  fail "T2c: resolver accepted a NON-conforming suffix ('sail-9-NOTATIMESTAMP') — #136 forged-suffix guard regressed"
fi
ok; echo "PASS T2c (item 2): non-conforming suffix still rejected (forged-suffix guard intact)"

echo "ALL PASS ($PASS assertions)"
