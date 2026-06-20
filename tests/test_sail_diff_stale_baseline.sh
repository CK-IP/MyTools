#!/usr/bin/env bash
# test_sail_diff_stale_baseline.sh — issue #49: stale/nested .sail/runs/*/baseline-src
# must not leak into the bandit current scan during `sail run --diff` (false block).
#
# Repro: bandit -r ignores .gitignore, so the diff-mode current-tree scan recurses into
# any .sail/runs/*/baseline-src checkout left by an interrupted prior diff run. Those
# files are absent from the clean baseline (checked out at --diff <ref>) → register as
# "new" → spurious block. The fix sweeps stale baseline-src dirs before the current scan.
#
# Hermetic end-to-end (real `sail run --diff`, not a synthetic direct scan). Bandit-guarded:
# skips cleanly where bandit is absent (AC: end-to-end coverage of the stale-baseline case).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
cd "$REPO_ROOT"

if ! command -v bandit >/dev/null 2>&1; then
  echo "SKIP: bandit not installed — #49 stale-baseline-src end-to-end check skipped"
  exit 0
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

gate_field() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));g=[x for x in d['gates'] if x['name']==sys.argv[2]][0];print(g.get(sys.argv[3]))" "$1" "$2" "$3"; }

# --- Tiny git target: one clean committed file (no bandit finding), then a real
#     working-tree edit so the diff against <ref> is non-empty. ---
TGT="$WORK/target"; mkdir -p "$TGT/sail"
printf 'def f():\n    return 1\n' > "$TGT/sail/ok.py"
git -C "$TGT" init -q
git -C "$TGT" config user.email t@t.t
git -C "$TGT" config user.name t
git -C "$TGT" add -A
git -C "$TGT" commit -qm init
BASE="$(git -C "$TGT" rev-parse HEAD)"
printf 'def f():\n    return 2\n' > "$TGT/sail/ok.py"   # working-tree change → real diff

# --- Plant a STALE baseline-src remnant (as if a prior diff run was interrupted before
#     its _remove_worktree fired). Contains a bandit-flaggable finding (B101 assert) that
#     does NOT exist at BASE, so without the fix it leaks into the current scan as "new". ---
mkdir -p "$TGT/.sail/runs/STALE-OLD/baseline-src/sail"
printf 'def bad():\n    assert True  # B101 — bandit flags asserts\n' \
  > "$TGT/.sail/runs/STALE-OLD/baseline-src/sail/stale_bad.py"

# --- Run diff-mode gates only (no review backend dependency). ---
RD="$WORK/rd"
python3 -m sail run --target "$TGT" --diff "$BASE" --run-dir "$RD" --no-review >/dev/null 2>&1 || true
[ -f "$RD/run-state.json" ] || { echo "FAIL: no run-state for diff run"; exit 1; }

# --- T1 (AC1): bandit reports 0 spurious "new" findings from the stale baseline-src. ---
b_mode=$(gate_field "$RD/run-state.json" bandit mode)
b_new=$(gate_field "$RD/run-state.json" bandit new_findings_count)
b_status=$(gate_field "$RD/run-state.json" bandit status)
[ "$b_mode" = "diff" ] || { echo "FAIL T1: bandit mode=$b_mode, expected diff"; exit 1; }
[ "$b_new" = "0" ] || { echo "FAIL T1: bandit new_findings_count=$b_new, expected 0 (stale baseline-src must not leak)"; exit 1; }
[ "$b_status" = "passed" ] || { echo "FAIL T1: bandit status=$b_status, expected passed (no real new findings)"; exit 1; }
echo "PASS T1: stale .sail/runs/*/baseline-src does not leak into bandit current scan (new=0)"

# --- T2 (AC2 / RT-1 guard): the diff baseline scan still produced a non-empty artifact. ---
[ -s "$RD/baseline/bandit.sarif" ] || { echo "FAIL T2: baseline bandit artifact empty/missing (RT-1 regression)"; exit 1; }
echo "PASS T2: diff baseline bandit artifact still produced (no RT-1 regression)"

echo "PASS: sail diff stale-baseline-src leak guard (#49) verified"
