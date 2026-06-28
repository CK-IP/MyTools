#!/usr/bin/env bash
# test_sail_88_isolation_hard_dep.sh
# Hermetic red test for /sail Stage 0.5 (#88): isolation infra must be a HARD dependency.
# A missing/unsourced lib must HALT, never silently run in-place.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; SKILL="$REPO_ROOT/commands/sail.md"
# Hermetic (.ship/domain.md #102): a real shell exports SAIL_* codex knobs (settings.json);
# clear them so each subtest controls its own backend (subtests set theirs via command prefix).
unset "${!SAIL_@}"
PASS=0; fail(){ echo "FAIL: $1" >&2; exit 1; }; ok(){ PASS=$((PASS+1)); }
TMP_ROOT="$(mktemp -d)"; trap 'rm -rf "$TMP_ROOT"' EXIT

[ -f "$SKILL" ] || fail "commands/sail.md exists"

extract_block(){ awk -v b="$1" -v e="$2" 'index($0,b){f=1;next} index($0,e){f=0} f{print}' "$SKILL"; }
PREFLIGHT="$(extract_block 'SAIL-ISOLATION-PREFLIGHT-BEGIN' 'SAIL-ISOLATION-PREFLIGHT-END')"
ISOLATE_RAW="$(extract_block 'SAIL-ISOLATION-ISOLATE-BEGIN' 'SAIL-ISOLATION-ISOLATE-END')"
ISOLATE="${ISOLATE_RAW//<issue>/88}"
[ -n "$PREFLIGHT" ] || fail "preflight block missing (SAIL-ISOLATION-PREFLIGHT markers)"
[ -n "$ISOLATE_RAW" ] || fail "isolate block missing (SAIL-ISOLATION-ISOLATE markers)"

make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" -c user.email=t@t -c user.name=t commit --allow-empty -qm "init"
}

run_isolate() {
  local stubdefs="$1"
  local repo="$2"
  bash -c 'MODE=isolate; REPO_ROOT="'"$repo"'"; WORK_DIR="$REPO_ROOT"; COMMIT="yes"; '"$stubdefs"' '"$ISOLATE"'; printf "WORK_DIR=%s;COMMIT=%s\n" "$WORK_DIR" "$COMMIT"'
}

# T1 preflight infra UNDEFINED -> HALT.
out="$(bash -c "$PREFLIGHT" 2>&1)" && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "T1: preflight should halt when infra is undefined"
printf '%s' "$out" | grep -qiE 'sail-git-lifecycle|ship-resume-safety|isolation infra' \
  || fail "T1: preflight stderr should mention the hard-dependency guard"
ok

# T2 preflight all-3 stubbed -> exit 0.
out="$(bash -c 'sail_setup_isolation(){ :; }; sail_concurrent_run(){ :; }; ship_safe_cleanup_orphan_dir(){ :; }; '"$PREFLIGHT" 2>&1)" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "T2: preflight with all three stubs should succeed"
ok

# T6 preflight only first two stubbed (ship_safe_cleanup_orphan_dir undefined) -> HALT.
out="$(bash -c 'sail_setup_isolation(){ :; }; sail_concurrent_run(){ :; }; '"$PREFLIGHT" 2>&1)" && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "T6: preflight must halt when ship_safe_cleanup_orphan_dir is undefined"
ok

# T3a collision (rc=3) -> in-place. The lib now emits a collision-specific rc=3 (#92), so the
# driver switches on the return code and no longer re-derives the collision from git-worktree
# internals — the assertion deliberately carries NO collision worktree setup.
make_repo "$TMP_ROOT/collide"
out="$(run_isolate 'sail_setup_isolation(){ return 3; };' "$TMP_ROOT/collide")" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "T3a: collision (rc=3) should fall back cleanly to in-place"
printf '%s' "$out" | grep -q "WORK_DIR=$TMP_ROOT/collide;COMMIT=no" \
  || fail "T3a: collision fallback should set WORK_DIR to repo root and COMMIT=no"
ok

# T3b rc=1 -> HALT, unconditionally. rc=1 is now a GENERIC git/worktree failure (a collision is
# rc=3), so the driver HALTs on it regardless of git state — prove it halts EVEN with a real
# sail/88 collision worktree present (the driver trusts the return code, never re-greps).
make_repo "$TMP_ROOT/nocollide"
git -C "$TMP_ROOT/nocollide" branch sail/88
git -C "$TMP_ROOT/nocollide" worktree add -q "$TMP_ROOT/wt88" sail/88
if run_isolate 'sail_setup_isolation(){ return 1; };' "$TMP_ROOT/nocollide" >/dev/null 2>&1; then
  fail "T3b: rc=1 (generic failure) must halt even when a sail/88 worktree exists"
fi
ok

# T3c undefined (rc127) -> HALT.
if run_isolate ':;' "$TMP_ROOT/nocollide" >/dev/null 2>&1; then
  fail "T3c: undefined sail_setup_isolation must halt"
fi
ok

# T3d rc=2 -> HALT.
if run_isolate 'sail_setup_isolation(){ return 2; };' "$TMP_ROOT/nocollide" >/dev/null 2>&1; then
  fail "T3d: rc=2 must halt"
fi
ok

# T3e rc=0 -> WORK_DIR is printed path.
mkdir -p "$TMP_ROOT/iso"
out="$(run_isolate 'sail_setup_isolation(){ printf "%s\n" "'"$TMP_ROOT"'/iso"; return 0; };' "$TMP_ROOT/nocollide")" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "T3e: rc=0 should succeed"
printf '%s' "$out" | grep -q "WORK_DIR=$TMP_ROOT/iso;COMMIT=yes" \
  || fail "T3e: rc=0 should preserve the returned WORK_DIR and COMMIT=yes"
ok

# T4 anchors: markers and hard-dependency lines.
grep -q 'SAIL-ISOLATION-PREFLIGHT-BEGIN' "$SKILL" || fail "T4: missing SAIL-ISOLATION-PREFLIGHT-BEGIN marker"
grep -q 'SAIL-ISOLATION-PREFLIGHT-END' "$SKILL" || fail "T4: missing SAIL-ISOLATION-PREFLIGHT-END marker"
grep -q 'SAIL-ISOLATION-ISOLATE-BEGIN' "$SKILL" || fail "T4: missing SAIL-ISOLATION-ISOLATE-BEGIN marker"
grep -q 'SAIL-ISOLATION-ISOLATE-END' "$SKILL" || fail "T4: missing SAIL-ISOLATION-ISOLATE-END marker"
printf '%s\n' "$PREFLIGHT" | grep -Fq 'command -v sail_setup_isolation' \
  || fail "T4: preflight must hard-check sail_setup_isolation"
printf '%s\n' "$PREFLIGHT" | grep -Fq 'command -v sail_concurrent_run' \
  || fail "T4: preflight must hard-check sail_concurrent_run"
printf '%s\n' "$PREFLIGHT" | grep -Fq 'command -v ship_safe_cleanup_orphan_dir' \
  || fail "T4: preflight must hard-check ship_safe_cleanup_orphan_dir"
ok

# T5 ordering: preflight before concurrent-run detection.
pf_line="$(grep -n 'SAIL-ISOLATION-PREFLIGHT-BEGIN' "$SKILL" | head -1 | cut -d: -f1)"
cr_line="$(grep -n 'sail_concurrent_run "$REPO_ROOT"' "$SKILL" | head -1 | cut -d: -f1)"
[ -n "$pf_line" ] || fail "T5: missing preflight anchor"
[ -n "$cr_line" ] || fail "T5: missing sail_concurrent_run call"
[ "$pf_line" -lt "$cr_line" ] || fail "T5: preflight must appear before concurrent-run detection"
ok

echo "PASS: sail #88 isolation hard-dependency guard verified ($PASS checks)"
