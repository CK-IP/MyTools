#!/usr/bin/env bash
# test_sail_95_build_backend.sh — #95: SAIL_BUILD_CMD pluggable build backend (hermetic, mock backend).
# Step 1 covers the sail/build.py module contract: resolution, clean-degrade-to-inline,
# delegated dispatch, fail-closed (backend error / TDD marker / fix-mode review.json),
# and the wrapper-aware same-family advisory guard.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# Hermetic (.ship/domain.md #102): a real shell exports SAIL_* codex knobs (settings.json);
# clear them so each subtest controls its own backend (subtests set theirs via command prefix).
unset "${!SAIL_@}"
export SAIL_STATE_DIR="$WORK/sail-state"   # isolate the #107 codex-down latch to this test's throwaway dir
cd "$REPO_ROOT"

fail() { echo "FAIL: $*"; exit 1; }

# A runnable backend named "codex" on PATH (shadows the real one inside this test only),
# so family detection has a real basename to resolve. Ignores stdin; exits $MOCK_RC.
BIN="$WORK/bin"; mkdir -p "$BIN"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'exit ${MOCK_RC:-0}' > "$BIN/codex"
chmod +x "$BIN/codex"
export PATH="$BIN:$PATH"

# run_build(target, run_dir, mode, round) at the module level (Step 2 adds the CLI).
run_build() {  # args: target run_dir mode round
  python3 - "$@" <<'PY'
import sys
from sail.build import run_build
t, rd, mode, rnd = sys.argv[1:5]
raise SystemExit(run_build(t, rd, mode=mode, round=int(rnd)))
PY
}
status() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$1"; }
warn()   { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("same_family_warning") or "")' "$1"; }
reason() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("reason") or "")' "$1"; }  # #120: inline cause
mark_red() { mkdir -p "$1/.sail"; : > "$1/.sail/last-test-failed"; }  # the failing-test marker

TGT="$WORK/tgt"; mkdir -p "$TGT"

# T1: SAIL_BUILD_CMD unset → inline status, exit 0 (clean degrade)
RD="$WORK/rd1"; mark_red "$TGT"
set +e; ( unset SAIL_BUILD_CMD; run_build "$TGT" "$RD" build 1 ) >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "T1: unset backend should exit 0, got $rc"
[ "$(status "$RD/build.json")" = inline ] || fail "T1: status should be inline when unset"
echo "PASS T1: unset SAIL_BUILD_CMD → inline, exit 0"

# T2: unrunnable backend → inline, exit 0
RD="$WORK/rd2"; mark_red "$TGT"
set +e; SAIL_BUILD_CMD="/nonexistent/backend-xyz" run_build "$TGT" "$RD" build 1 >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "T2: unrunnable backend should exit 0, got $rc"
[ "$(status "$RD/build.json")" = inline ] || fail "T2: status should be inline when unrunnable"
echo "PASS T2: unrunnable backend → inline, exit 0"

# T3: runnable backend rc=0 + marker present → delegated, exit 0
RD="$WORK/rd3"; mark_red "$TGT"
set +e; SAIL_BUILD_CMD="codex" MOCK_RC=0 run_build "$TGT" "$RD" build 1 >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "T3: delegated build should exit 0, got $rc"
[ "$(status "$RD/build.json")" = delegated ] || fail "T3: status should be delegated"
echo "PASS T3: runnable backend + marker → delegated, exit 0"

# T4: backend rc!=0 → error, exit 1 (fail closed)
RD="$WORK/rd4"; mark_red "$TGT"
set +e; SAIL_BUILD_CMD="codex" MOCK_RC=3 run_build "$TGT" "$RD" build 1 >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 1 ] || fail "T4: backend error should exit 1, got $rc"
[ "$(status "$RD/build.json")" = error ] || fail "T4: status should be error on backend rc!=0"
echo "PASS T4: backend error → error, exit 1"

# T5: build-mode, NO failing-test marker → error exit 1, backend NOT invoked (TDD precondition, RT-1)
RD="$WORK/rd5"; TGT5="$WORK/tgt5"; mkdir -p "$TGT5"   # no .sail/last-test-failed
set +e; SAIL_BUILD_CMD="codex" MOCK_RC=0 run_build "$TGT5" "$RD" build 1 >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 1 ] || fail "T5: build with no failing-test marker should exit 1, got $rc"
[ "$(status "$RD/build.json")" = error ] || fail "T5: status should be error with no marker"
echo "PASS T5: build-mode without failing-test marker → error, exit 1 (RT-1)"

# T6: fix-mode, NO marker → error exit 1 (shared precondition, RT-4)
RD="$WORK/rd6"; TGT6="$WORK/tgt6"; mkdir -p "$TGT6"
mkdir -p "$RD"; printf '%s' '{"status":"completed","findings":[]}' > "$RD/review.json"
set +e; SAIL_BUILD_CMD="codex" MOCK_RC=0 run_build "$TGT6" "$RD" fix 2 >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 1 ] || fail "T6: fix with no failing-test marker should exit 1, got $rc"
[ "$(status "$RD/build.json")" = error ] || fail "T6: status should be error (fix, no marker)"
echo "PASS T6: fix-mode without failing-test marker → error, exit 1 (RT-4)"

# T7: fix-mode, marker present, review.json MISSING → error exit 1 (RT-2)
RD="$WORK/rd7"; mark_red "$TGT"   # RD has no review.json
set +e; SAIL_BUILD_CMD="codex" MOCK_RC=0 run_build "$TGT" "$RD" fix 2 >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 1 ] || fail "T7: fix with missing review.json should exit 1, got $rc"
[ "$(status "$RD/build.json")" = error ] || fail "T7: status should be error (fix, no review.json)"
echo "PASS T7: fix-mode without review.json → error, exit 1 (RT-2)"

# T8: fix-mode, review.json present but status != completed → error exit 1 (RT-6 kernel)
RD="$WORK/rd8"; mark_red "$TGT"; mkdir -p "$RD"; printf '%s' '{"status":"error"}' > "$RD/review.json"
set +e; SAIL_BUILD_CMD="codex" MOCK_RC=0 run_build "$TGT" "$RD" fix 2 >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 1 ] || fail "T8: fix with review.json not status:completed should exit 1, got $rc"
echo "PASS T8: fix-mode review.json not completed → error, exit 1 (RT-6 kernel)"

# T9: fix-mode, review.json status:completed, marker present, NO decision-log → delegated exit 0 (RT-6: absent log OK)
RD="$WORK/rd9"; mark_red "$TGT"; mkdir -p "$RD"
printf '%s' '{"status":"completed","findings":[{"id":"R1","severity":"HIGH","issue":"x"}]}' > "$RD/review.json"
set +e; SAIL_BUILD_CMD="codex" MOCK_RC=0 run_build "$TGT" "$RD" fix 2 >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "T9: fix with valid review + absent decision-log should exit 0, got $rc"
[ "$(status "$RD/build.json")" = delegated ] || fail "T9: status should be delegated"
echo "PASS T9: fix-mode valid review + absent decision-log → delegated, exit 0 (RT-6)"

# T10: fix-mode, decision-log present but undecodable → error exit 1 (RT-6)
RD="$WORK/rd10"; mark_red "$TGT"; mkdir -p "$RD"
printf '%s' '{"status":"completed","findings":[]}' > "$RD/review.json"
printf '\xff\xfe\x00\x80bad' > "$RD/decision-log.md"   # invalid UTF-8 → undecodable
set +e; SAIL_BUILD_CMD="codex" MOCK_RC=0 run_build "$TGT" "$RD" fix 2 >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 1 ] || fail "T10: fix with undecodable decision-log should exit 1, got $rc"
[ "$(status "$RD/build.json")" = error ] || fail "T10: status should be error (undecodable decision-log)"
echo "PASS T10: fix-mode undecodable decision-log → error, exit 1 (RT-6)"

# T11: same-family — SAIL_BUILD_CMD and SAIL_REVIEW_CMD2 both resolve to "codex" → warning set
RD="$WORK/rd11"; mark_red "$TGT"
set +e; SAIL_BUILD_CMD="codex" SAIL_REVIEW_CMD2="codex review" MOCK_RC=0 run_build "$TGT" "$RD" build 1 >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "T11: same-family build should still exit 0 (advisory, non-blocking), got $rc"
[ -n "$(warn "$RD/build.json")" ] || fail "T11: same_family_warning should be set when build & review2 share a family"
echo "PASS T11: same-family (codex/codex) → advisory same_family_warning set, exit 0 (RT-3)"

# T12: same-family detected THROUGH a wrapper — SAIL_REVIEW_CMD2='env A=1 codex' → still flagged (RT-5)
RD="$WORK/rd12"; mark_red "$TGT"
set +e; SAIL_BUILD_CMD="codex" SAIL_REVIEW_CMD2="env A=1 codex" MOCK_RC=0 run_build "$TGT" "$RD" build 1 >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "T12: wrapper same-family should exit 0, got $rc"
[ -n "$(warn "$RD/build.json")" ] || fail "T12: same_family_warning should see past an env wrapper (RT-5)"
echo "PASS T12: same-family through env wrapper → warning set (RT-5)"

# T13: different family — SAIL_REVIEW_CMD2='claude -p' (need not be runnable) → NO warning
RD="$WORK/rd13"; mark_red "$TGT"
set +e; SAIL_BUILD_CMD="codex" SAIL_REVIEW_CMD2="claude -p" MOCK_RC=0 run_build "$TGT" "$RD" build 1 >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "T13: cross-family build should exit 0, got $rc"
[ -z "$(warn "$RD/build.json")" ] || fail "T13: cross-family must NOT set same_family_warning"
echo "PASS T13: cross-family (codex/claude) → no warning (RT-3)"

# T14 (S1.R1.1): malformed SAIL_BUILD_CMD (unbalanced quote) -> inline, exit 0 (no crash)
RD="$WORK/rd14"; mark_red "$TGT"
set +e; SAIL_BUILD_CMD='codex "unbalanced' run_build "$TGT" "$RD" build 1 >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "T14: malformed SAIL_BUILD_CMD should degrade to inline (exit 0), got $rc"
[ "$(status "$RD/build.json")" = inline ] || fail "T14: status should be inline for unparseable backend command"
echo "PASS T14: malformed SAIL_BUILD_CMD -> inline, exit 0 (S1.R1.1)"

# T15 (S1.R1.2): backend emits non-UTF8 bytes on stdout, rc=0 -> delegated, exit 0 (no decode crash)
RD="$WORK/rd15"; mark_red "$TGT"
BYTES="$BIN/codex-bytes"; printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "\xff\xfe\x80"' 'exit 0' > "$BYTES"; chmod +x "$BYTES"
set +e; SAIL_BUILD_CMD="$BYTES" run_build "$TGT" "$RD" build 1 >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "T15: non-UTF8 backend stdout should not crash the dispatcher (exit 0 delegated), got $rc"
[ "$(status "$RD/build.json")" = delegated ] || fail "T15: status should be delegated despite non-UTF8 output"
echo "PASS T15: non-UTF8 backend output -> delegated, exit 0 (S1.R1.2)"

# ===== #120: inline `reason` distinguishes backend-unset from backend-not-runnable =====
# So Stage-2 prose can classify the #112 INFO/ALERT tone off the artifact, not by re-reading $SAIL_BUILD_CMD.

# T19 (#120): SAIL_BUILD_CMD unset → inline, reason "backend-unset" (expected degrade → INFO)
RD="$WORK/rd19"; mark_red "$TGT"
set +e; ( unset SAIL_BUILD_CMD; run_build "$TGT" "$RD" build 1 ) >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "T19: unset backend should exit 0, got $rc"
[ "$(status "$RD/build.json")" = inline ] || fail "T19: status should be inline when unset"
[ "$(reason "$RD/build.json")" = backend-unset ] || fail "T19: reason should be backend-unset when SAIL_BUILD_CMD unset, got '$(reason "$RD/build.json")'"
echo "PASS T19: unset SAIL_BUILD_CMD → inline reason=backend-unset (#120)"

# T20 (#120): SAIL_BUILD_CMD set but unrunnable → inline, reason "backend-not-runnable" (unexpected fallback → ALERT)
RD="$WORK/rd20"; mark_red "$TGT"
set +e; SAIL_BUILD_CMD="/nonexistent/backend-xyz" run_build "$TGT" "$RD" build 1 >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "T20: unrunnable backend should exit 0, got $rc"
[ "$(status "$RD/build.json")" = inline ] || fail "T20: status should be inline when unrunnable"
[ "$(reason "$RD/build.json")" = backend-not-runnable ] || fail "T20: reason should be backend-not-runnable when set-but-unrunnable, got '$(reason "$RD/build.json")'"
echo "PASS T20: set-but-unrunnable SAIL_BUILD_CMD → inline reason=backend-not-runnable (#120)"

# T20b (#120): SAIL_BUILD_CMD set but malformed (unparseable) → inline, reason "backend-not-runnable" (it WAS configured)
RD="$WORK/rd20b"; mark_red "$TGT"
set +e; SAIL_BUILD_CMD='codex "unbalanced' run_build "$TGT" "$RD" build 1 >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "T20b: malformed backend should exit 0, got $rc"
[ "$(status "$RD/build.json")" = inline ] || fail "T20b: status should be inline when malformed"
[ "$(reason "$RD/build.json")" = backend-not-runnable ] || fail "T20b: malformed (but set) backend reason should be backend-not-runnable, got '$(reason "$RD/build.json")'"
echo "PASS T20b: malformed (set) SAIL_BUILD_CMD → inline reason=backend-not-runnable (#120)"

# T21 (#120): delegated path carries NO reason field (reason is inline-only — additive, no spurious key)
RD="$WORK/rd21"; mark_red "$TGT"
set +e; SAIL_BUILD_CMD="codex" MOCK_RC=0 run_build "$TGT" "$RD" build 1 >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "T21: delegated should exit 0, got $rc"
[ "$(status "$RD/build.json")" = delegated ] || fail "T21: status should be delegated"
[ -z "$(reason "$RD/build.json")" ] || fail "T21: delegated build.json must NOT carry a reason field, got '$(reason "$RD/build.json")'"
echo "PASS T21: delegated → no reason field (#120)"

echo "PASS: sail build backend contract verified (Step 1)"

# ============ Step 2: `sail build` subcommand (CLI wiring, #95) ============
# T16: `python3 -m sail build` is a real subcommand; unset backend → inline, exit 0, build.json written
RD="$WORK/rd16"; mark_red "$TGT"
set +e; ( unset SAIL_BUILD_CMD; python3 -m sail build --target "$TGT" --run-dir "$RD" >/dev/null 2>&1 ); rc=$?; set -e
[ "$rc" = 0 ] || fail "T16: sail build subcommand (unset backend) should exit 0, got $rc"
[ "$(status "$RD/build.json")" = inline ] || fail "T16: build.json status should be inline via CLI"
echo "PASS T16: python3 -m sail build subcommand → inline, exit 0 (S2)"

# T17: --mode fix honored — marker present, NO review.json → fix-mode errors (exit 1), proving mode reaches run_build
RD="$WORK/rd17"; mark_red "$TGT"
set +e; SAIL_BUILD_CMD="codex" MOCK_RC=0 python3 -m sail build --target "$TGT" --run-dir "$RD" --mode fix --round 2 >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 1 ] || fail "T17: --mode fix (marker, no review.json) should exit 1 via CLI, got $rc"
[ "$(status "$RD/build.json")" = error ] || fail "T17: fix-mode CLI error status"
echo "PASS T17: sail build --mode fix plumbed through CLI (S2)"

# T17b: default mode=build via CLI — marker present + backend → delegated exit 0 (contrasts T17, proves --mode plumbing)
RD="$WORK/rd17b"; mark_red "$TGT"
set +e; SAIL_BUILD_CMD="codex" MOCK_RC=0 python3 -m sail build --target "$TGT" --run-dir "$RD" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "T17b: default build mode via CLI should exit 0 delegated, got $rc"
[ "$(status "$RD/build.json")" = delegated ] || fail "T17b: default build should be delegated via CLI"
echo "PASS T17b: sail build default mode → delegated via CLI (S2)"

# T18 (S2.R1.1): `sail build` with NO --run-dir defaults run_dir under cwd/.sail/runs and does not crash
RD_CWD="$WORK/nrd"; mkdir -p "$RD_CWD"; mark_red "$TGT"
set +e; ( cd "$RD_CWD" && unset SAIL_BUILD_CMD; PYTHONPATH="$REPO_ROOT" python3 -m sail build --target "$TGT" >/dev/null 2>&1 ); rc=$?; set -e
[ "$rc" = 0 ] || fail "T18: sail build with no --run-dir should exit 0 (default run-dir), got $rc"
find "$RD_CWD/.sail/runs" -name build.json | grep -q . || fail "T18: default run-dir build.json not created under cwd/.sail/runs"
echo "PASS T18: sail build defaults run-dir when --run-dir omitted (S2.R1.1)"

echo "PASS: sail build subcommand wiring verified (Step 2)"

# ============ Step 3: commands/sail.md prose (#95) ============
SAILMD="$REPO_ROOT/commands/sail.md"
pin() { grep -qiE "$1" "$SAILMD" 2>/dev/null || fail "S3: sail.md missing pin ($2): $1"; }
pin 'python3 -m sail build' "Stage-2 sail build call"
pin 'SAIL_BUILD_CMD' "SAIL_BUILD_CMD env backend documented"
pin 'delegated' "build.json status=delegated branch"
pin 'status.*inline|inline.*degrade|inline.*build' "inline degrade branch"
pin '[-][-]mode fix' "per-round fix delegation"
pin 'sonnet 4\.6' "Sonnet 4.6 backend option"
pin '#83|same.family|same_family' "#83 same-family interaction"
pin 'last-test-failed|failing.test.*first|test-first|TDD.*enforc' "enforced TDD-first note"
echo "PASS S3: commands/sail.md documents SAIL_BUILD_CMD build delegation"

# ============ Step 4: docs (#95) ============
README="$REPO_ROOT/sail/README.md"; INSTALL_MD="$REPO_ROOT/INSTALL.md"
grep -q 'SAIL_BUILD_CMD' "$README"     || fail "S4: sail/README.md missing SAIL_BUILD_CMD docs"
grep -q 'SAIL_BUILD_CMD' "$INSTALL_MD" || fail "S4: INSTALL.md missing SAIL_BUILD_CMD docs"
echo "PASS S4: SAIL_BUILD_CMD documented in sail/README.md + INSTALL.md"

# ============ #133: prose/spec-heavy classification + cross-family-preserving build routing ============
# Doc-dominated changes route to SAIL_BUILD_CMD_PROSE (a capable cross-family builder), preserving
# the #83 invariant (implementer family ≠ reviewer family). When the selected prose builder collides
# with the active reviewer family, build.json records the collapse (cross_family:lost + ALERT) but
# still proceeds. Code-class routing is unchanged.

# Logging mocks (the #95 mocks above don't record which backend ran). Each appends its name to RAN_LOG.
# shellcheck disable=SC2016  # '${MOCK_RC:-0}' is single-quoted on purpose: the literal is written into
# the generated mock so each mock reads MOCK_RC from its own runtime env, not expanded at printf time.
for name in pcodex pclaude prosebot; do
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' "echo $name >> \"\$RAN_LOG\"" 'exit ${MOCK_RC:-0}' > "$BIN/$name"
  chmod +x "$BIN/$name"
done
xfam()   { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("cross_family") or "")' "$1"; }
crouted(){ python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("change_class") or "")' "$1"; }
classify(){ python3 -c 'import json,sys; from sail.build import classify_change; print(classify_change(json.loads(sys.argv[1])))' "$1"; }

# P1: deterministic classify_change (all-doc→prose, any-code→code, empty→code)
[ "$(classify '["commands/surf.md","README.md"]')" = prose ] || fail "P1: all-doc set should classify prose"
[ "$(classify '["commands/surf.md","sail/build.py"]')" = code ] || fail "P1: any .py should classify code"
[ "$(classify '["docs/x.rst"]')" = prose ] || fail "P1: lone .rst should classify prose"
[ "$(classify '[]')" = code ] || fail "P1: empty set should default to code (safe)"
echo "PASS P1 (#133): classify_change deterministic — T-prose-classify / T-code-classify"

# P2: prose class routes to SAIL_BUILD_CMD_PROSE over SAIL_BUILD_CMD
RD="$WORK/rdp2"; mark_red "$TGT"; export RAN_LOG="$WORK/ranp2"; : > "$RAN_LOG"
set +e; SAIL_BUILD_CMD="pcodex" SAIL_BUILD_CMD_PROSE="prosebot" MOCK_RC=0 \
  python3 -m sail build --target "$TGT" --run-dir "$RD" --change-class prose >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "P2: prose route should exit 0, got $rc"
[ "$(status "$RD/build.json")" = delegated ] || fail "P2: prose route status should be delegated"
grep -q '^prosebot$' "$RAN_LOG" || fail "P2: prose backend should have run"
grep -q '^pcodex$' "$RAN_LOG" && fail "P2: default backend must NOT run on prose route"
echo "PASS P2 (#133): prose class → SAIL_BUILD_CMD_PROSE used (not SAIL_BUILD_CMD)"

# P3: prose class, SAIL_BUILD_CMD_PROSE unset → fall back to SAIL_BUILD_CMD (clean degrade)
RD="$WORK/rdp3"; mark_red "$TGT"; export RAN_LOG="$WORK/ranp3"; : > "$RAN_LOG"
set +e; SAIL_BUILD_CMD="pcodex" MOCK_RC=0 python3 -m sail build --target "$TGT" --run-dir "$RD" --change-class prose >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "P3: prose fallback should exit 0, got $rc"
grep -q '^pcodex$' "$RAN_LOG" || fail "P3: with PROSE unset, SAIL_BUILD_CMD should run"
echo "PASS P3 (#133): prose + PROSE unset → falls back to SAIL_BUILD_CMD"

# P4: cross-family PRESERVED — prose builder (codex-ish) ≠ reviewer (claude lens1); lens2 UNSET
RD="$WORK/rdp4"; mark_red "$TGT"; export RAN_LOG="$WORK/ranp4"; : > "$RAN_LOG"
set +e; SAIL_BUILD_CMD="pclaude" SAIL_BUILD_CMD_PROSE="pcodex" SAIL_REVIEW_CMD="pclaude -p" MOCK_RC=0 \
  python3 -m sail build --target "$TGT" --run-dir "$RD" --change-class prose >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "P4: cross-family prose route should exit 0, got $rc"
[ "$(xfam "$RD/build.json")" != lost ] || fail "P4: cross-family preserved must NOT record cross_family:lost"
[ -z "$(warn "$RD/build.json")" ] || fail "P4: cross-family preserved must NOT set same_family_warning"
echo "PASS P4 (#133): T-prose-cross-family-ok — prose builder ≠ reviewer family → no loss"

# P5: same-family ALERT — prose builder == active reviewer lens1 (lens2 UNSET, the live allocation)
RD="$WORK/rdp5"; mark_red "$TGT"; export RAN_LOG="$WORK/ranp5"; : > "$RAN_LOG"
set +e; SAIL_BUILD_CMD="pcodex" SAIL_BUILD_CMD_PROSE="pclaude -p --model opus" SAIL_REVIEW_CMD="pclaude -p --model sonnet" MOCK_RC=0 \
  python3 -m sail build --target "$TGT" --run-dir "$RD" --change-class prose >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "P5: same-family prose route should STILL exit 0 (proceeds), got $rc"
[ "$(status "$RD/build.json")" = delegated ] || fail "P5: same-family route status should be delegated"
[ "$(xfam "$RD/build.json")" = lost ] || fail "P5: same-family must record cross_family:lost"
W="$(warn "$RD/build.json")"; [ -n "$W" ] || fail "P5: same-family must set same_family_warning"
printf '%s' "$W" | grep -q 'SAIL_BUILD_CMD_PROSE' || fail "P5: warning must name the SAIL_BUILD_CMD_PROSE remediation"
echo "PASS P5 (#133): T-prose-same-family-ALERT — collision vs lens1 (lens2 unset) → cross_family:lost + ALERT, still delegated"

# P5b (#133 review MEDIUM lens1-ba28ed0e9017): cross_family:lost fires on the SAIL_BUILD_CMD FALLBACK
# collision too — not only when the backend came from SAIL_BUILD_CMD_PROSE. PROSE unset, prose class,
# SAIL_BUILD_CMD collides with the claude reviewer → the loss must still be recorded.
RD="$WORK/rdp5b"; mark_red "$TGT"; export RAN_LOG="$WORK/ranp5b"; : > "$RAN_LOG"
set +e; SAIL_BUILD_CMD="pclaude -p" SAIL_REVIEW_CMD="pclaude -p --model sonnet" MOCK_RC=0 \
  python3 -m sail build --target "$TGT" --run-dir "$RD" --change-class prose >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "P5b: prose-fallback-collision should exit 0, got $rc"
[ "$(xfam "$RD/build.json")" = lost ] || fail "P5b: prose class + SAIL_BUILD_CMD fallback collision must record cross_family:lost"
printf '%s' "$(warn "$RD/build.json")" | grep -q 'SAIL_BUILD_CMD_PROSE' || fail "P5b: fallback-collision warning must still name SAIL_BUILD_CMD_PROSE remediation"
echo "PASS P5b (#133): cross_family:lost on the SAIL_BUILD_CMD fallback collision (class-gated, not env-gated)"

# P6: code class routing UNCHANGED — default backend, prose backend untouched, no prose fields
RD="$WORK/rdp6"; mark_red "$TGT"; export RAN_LOG="$WORK/ranp6"; : > "$RAN_LOG"
set +e; SAIL_BUILD_CMD="pcodex" SAIL_BUILD_CMD_PROSE="prosebot" MOCK_RC=0 \
  python3 -m sail build --target "$TGT" --run-dir "$RD" --change-class code >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 0 ] || fail "P6: code route should exit 0, got $rc"
grep -q '^pcodex$' "$RAN_LOG" || fail "P6: code route must use SAIL_BUILD_CMD"
grep -q '^prosebot$' "$RAN_LOG" && fail "P6: code route must NOT use the prose backend"
[ "$(xfam "$RD/build.json")" != lost ] || fail "P6: code route must not record a prose cross_family loss"
echo "PASS P6 (#133): T-code-routing-unchanged — code class → SAIL_BUILD_CMD, prose backend untouched"

# P7: backstop — no --change-class, classify off plan.json scope (prose-dominated → prose route)
RD="$WORK/rdp7"; mark_red "$TGT"; export RAN_LOG="$WORK/ranp7"; : > "$RAN_LOG"; mkdir -p "$RD"
printf '%s' '{"status":"completed","approach":"rewrite the spec","scope":{"in":["commands/surf.md","docs/guide.rst"],"out":[]}}' > "$RD/plan.json"
set +e; SAIL_BUILD_CMD="pcodex" SAIL_BUILD_CMD_PROSE="prosebot" MOCK_RC=0 \
  python3 -m sail build --target "$TGT" --run-dir "$RD" >/dev/null 2>&1; rc=$?; set -e
[ "$(crouted "$RD/build.json")" = prose ] || fail "P7: backstop should derive change_class=prose from plan scope"
grep -q '^prosebot$' "$RAN_LOG" || fail "P7: backstop prose classification should route to prose backend"
echo "PASS P7 (#133): no --change-class → deterministic backstop classifies off plan scope (prose)"

# P8: backstop code — plan scope with a .py → code route, no prose backend
RD="$WORK/rdp8"; mark_red "$TGT"; export RAN_LOG="$WORK/ranp8"; : > "$RAN_LOG"; mkdir -p "$RD"
printf '%s' '{"status":"completed","approach":"x","scope":{"in":["commands/surf.md","sail/build.py"],"out":[]}}' > "$RD/plan.json"
set +e; SAIL_BUILD_CMD="pcodex" SAIL_BUILD_CMD_PROSE="prosebot" MOCK_RC=0 \
  python3 -m sail build --target "$TGT" --run-dir "$RD" >/dev/null 2>&1; rc=$?; set -e
[ "$(crouted "$RD/build.json")" = code ] || fail "P8: backstop with a .py in scope should derive code"
grep -q '^pcodex$' "$RAN_LOG" || fail "P8: backstop code route must use SAIL_BUILD_CMD"
echo "PASS P8 (#133): backstop code class off plan scope → SAIL_BUILD_CMD"

# P-docs: prose route documented across the prose-spec touchpoints
SAILMD="$REPO_ROOT/commands/sail.md"
grep -qiE 'SAIL_BUILD_CMD_PROSE' "$SAILMD"            || fail "P-docs: sail.md missing SAIL_BUILD_CMD_PROSE"
grep -qiE '[-][-]change-class' "$SAILMD"              || fail "P-docs: sail.md missing --change-class"
grep -qiE 'prose|spec.heavy' "$SAILMD"                || fail "P-docs: sail.md missing prose/spec classification"
grep -q 'SAIL_BUILD_CMD_PROSE' "$REPO_ROOT/home/settings.reference.json" || fail "P-docs: settings.reference.json missing SAIL_BUILD_CMD_PROSE"
grep -q 'SAIL_BUILD_CMD_PROSE' "$README"              || fail "P-docs: sail/README.md missing SAIL_BUILD_CMD_PROSE"
grep -q 'SAIL_BUILD_CMD_PROSE' "$INSTALL_MD"          || fail "P-docs: INSTALL.md missing SAIL_BUILD_CMD_PROSE"
echo "PASS P-docs (#133): prose route documented in sail.md + settings.reference.json + README + INSTALL"

echo "PASS: #133 prose-build routing contract verified"
