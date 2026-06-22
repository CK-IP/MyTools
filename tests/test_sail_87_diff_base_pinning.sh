#!/usr/bin/env bash
# test_sail_87_diff_base_pinning.sh — issue #87: sail run --diff pins the diff base to
# a concrete SHA (merge-base) at run-start so concurrent main movement cannot pollute
# the review diff mid-run.
#
# Repro shape: the #86 A/B failure — a /sail run was isolated on a worktree branched
# from main at BASE; midway through, main advanced to MAIN_ADV; `sail run --diff main`
# then resolved "main" to MAIN_ADV, rendering the new commit's content as a phantom
# deletion → spurious blocking HIGH → park. The fix pins `diff_ref` to
# `git merge-base <diff_ref> HEAD` at run-start.
#
# Hermetic: a real `sail run --no-review` against a tiny scratch git repo. No review
# backend dependency. Verifies (a) the stored diff_ref is the merge-base SHA and
# (b) the diff text computed from it does NOT contain the phantom file.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
cd "$REPO_ROOT"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Build a tiny git repo that reproduces the #86 A/B scenario
# ---------------------------------------------------------------------------
TGT="$WORK/target"
mkdir -p "$TGT"

git -C "$TGT" init -q -b main
git -C "$TGT" config user.email t@t.t
git -C "$TGT" config user.name t

# Commit 1 (BASE): the point in time when the /sail run was isolated
printf 'def f():\n    return 1\n' > "$TGT/ok.py"
git -C "$TGT" add -A
git -C "$TGT" commit -qm "init"
BASE="$(git -C "$TGT" rev-parse HEAD)"

# Create a feature branch at BASE (simulating sail/<issue> worktree isolation)
git -C "$TGT" checkout -qb "sail/test-87"

# Advance main to MAIN_ADV to simulate a concurrent /sail merge landing mid-run.
# The new commit adds phantom.py — content that should NOT appear in the review diff.
git -C "$TGT" checkout -q main
printf 'x = 1\n' > "$TGT/phantom.py"
git -C "$TGT" add phantom.py
git -C "$TGT" commit -qm "phantom commit (simulates concurrent main movement)"
MAIN_ADV="$(git -C "$TGT" rev-parse HEAD)"

# Back to the feature branch: make the real working-tree change this run owns
git -C "$TGT" checkout -q "sail/test-87"
printf 'def f():\n    return 2\n' > "$TGT/ok.py"  # working-tree change, not committed

# ---------------------------------------------------------------------------
# Run sail with --diff main (no review — gates-only, hermetic)
# ---------------------------------------------------------------------------
RD="$WORK/rd"
python3 -m sail run --target "$TGT" --diff main --run-dir "$RD" --no-review \
  >/dev/null 2>&1 || true

[ -f "$RD/run-state.json" ] || { echo "FAIL: no run-state.json produced"; exit 1; }

stored_diff_ref="$(python3 -c \
  "import json,sys; print(json.load(open(sys.argv[1]))['diff_ref'])" \
  "$RD/run-state.json")"

# ---------------------------------------------------------------------------
# T1: stored diff_ref must be the pinned SHA (merge-base = BASE), not the
#     mutable branch name "main" and not the advanced tip MAIN_ADV.
# ---------------------------------------------------------------------------
if [ "$stored_diff_ref" = "main" ]; then
  echo "FAIL T1: diff_ref stored as branch name 'main' — not pinned (pre-fix behavior)"
  echo "  BASE=$BASE  MAIN_ADV=$MAIN_ADV"
  exit 1
fi
if [ "$stored_diff_ref" = "$MAIN_ADV" ]; then
  echo "FAIL T1: diff_ref stored as MAIN_ADV ($MAIN_ADV) — resolves to moved tip, not branch-point"
  echo "  BASE=$BASE"
  exit 1
fi
if [ "$stored_diff_ref" != "$BASE" ]; then
  echo "FAIL T1: diff_ref=$stored_diff_ref expected BASE=$BASE"
  exit 1
fi
echo "PASS T1: diff_ref pinned to merge-base SHA (BASE=$BASE, not MAIN_ADV=$MAIN_ADV)"

# ---------------------------------------------------------------------------
# T2: the diff computed from the pinned base must NOT mention phantom.py —
#     the file added by the concurrent main movement must not appear.
# ---------------------------------------------------------------------------
diff_text="$(git -C "$TGT" diff "$stored_diff_ref" 2>/dev/null)"
if echo "$diff_text" | grep -q "phantom"; then
  echo "FAIL T2: diff against pinned base mentions phantom.py — main contamination leaked in"
  echo "  stored_diff_ref=$stored_diff_ref"
  exit 1
fi
echo "PASS T2: diff against pinned base does not mention phantom.py (main movement isolated)"

# ---------------------------------------------------------------------------
# T3: verify sail's OWN codepath used the pinned base. The decision-log
#     records the exact SHA sail passed to _generate_baseline via
#     `mode_marker(mode, diff_ref)`: "- mode: diff (base=<SHA>)". This is
#     a durable sail-internal output — it is written by sail's own run path,
#     not computed by the test script. The decision-log MUST exist after
#     sail run --diff; if absent or if the recorded SHA ≠ BASE, it fails.
# ---------------------------------------------------------------------------
dlog="$RD/decision-log.md"
[ -f "$dlog" ] || { echo "FAIL T3: no decision-log.md — sail's diff mode_marker not written"; exit 1; }
logged_base="$(grep -o 'base=[0-9a-f]*' "$dlog" | head -1 | cut -d= -f2)"
[ -n "$logged_base" ] || { echo "FAIL T3: decision-log has no 'base=<sha>' entry — diff mode not recorded"; exit 1; }
[ "$logged_base" = "$BASE" ] || {
  echo "FAIL T3: decision-log recorded base=$logged_base, expected BASE=$BASE"
  echo "  sail used the wrong diff_ref internally (MAIN_ADV=$MAIN_ADV)"
  exit 1
}
echo "PASS T3: sail's decision-log recorded base=$logged_base = BASE (sail used pinned SHA in its own diff path)"

echo "PASS: sail diff base pinning (#87) verified"
