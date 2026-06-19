#!/usr/bin/env bash
# test_sail_run_review.sh — issue #41: `sail run --diff` wires gates + blocking LLM
# review into one pass (the drop-in /ship replacement). Hermetic: mocks the LLM
# backend via SAIL_REVIEW_CMD and uses throwaway git targets. Never calls a real CLI.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"

fail() { echo "FAIL: $*"; exit 1; }

# Mock LLM CLI: discards stdin, emits $MOCK_OUT, exits $MOCK_RC. Pointed at via SAIL_REVIEW_CMD.
MOCK="$WORK/mock_llm.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "%s" "${MOCK_OUT:-}"' 'exit ${MOCK_RC:-0}' > "$MOCK"
chmod +x "$MOCK"

# Clean git target: committed base + a working-tree change that introduces NO new findings,
# so `git diff HEAD` is non-empty but the deterministic gates pass — isolating the review arm.
TGT="$WORK/target"; mkdir -p "$TGT"
printf 'def f():\n    return 1\n' > "$TGT/mod.py"
git -C "$TGT" init -q
git -C "$TGT" add -A
git -C "$TGT" -c user.email=t@t -c user.name=t commit -qm base
printf 'def f():\n    return 2  # changed\n' > "$TGT/mod.py"

HIGH_JSON='{"findings":[{"severity":"HIGH","category":"correctness","file":"mod.py","line":2,"issue":"x","recommendation":"y"}],"summary":"1 high"}'
CLEAN_JSON='{"findings":[],"summary":"no issues"}'

# --- T1: --diff + blocking review (HIGH) → exit 1 even though gates pass; review.json in run-dir ---
RD1="$WORK/rd1"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$HIGH_JSON" python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD1" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "1" ] || fail "T1: blocking review must fail the run (expected 1), got $rc"
[ -f "$RD1/review.json" ] || fail "T1: review.json not written into the run-dir"
grep -qi "review" "$RD1/decision-log.md" || fail "T1: decision-log missing review marker"
echo "PASS T1: --diff gates+review one pass — blocking review → exit 1, review.json recorded"

# --- T2: --diff + clean review → exit 0 (gates clean + review clean); review.json present ---
RD2="$WORK/rd2"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD2" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || fail "T2: gates clean + review clean should exit 0, got $rc"
[ -f "$RD2/review.json" ] || fail "T2: review.json not written"
echo "PASS T2: --diff clean gates + clean review → exit 0"

# --- T3: --no-review opts out → review never runs (no review.json), gates-only exit ---
RD3="$WORK/rd3"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$HIGH_JSON" python3 -m sail run --target "$TGT" --diff HEAD --no-review --run-dir "$RD3" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || fail "T3: --no-review should exit on gates only (expected 0), got $rc"
[ ! -f "$RD3/review.json" ] || fail "T3: --no-review must not write review.json"
echo "PASS T3: --no-review opts out of review (gates-only)"

# --- T4: gates fail + review clean → still exit 1 (gate-blocking not masked). Guarded on ruff. ---
if command -v ruff >/dev/null 2>&1; then
  TGT4="$WORK/target4"; mkdir -p "$TGT4"
  printf 'def g():\n    return 1\n' > "$TGT4/mod.py"
  git -C "$TGT4" init -q
  git -C "$TGT4" add -A
  git -C "$TGT4" -c user.email=t@t -c user.name=t commit -qm base
  printf 'import os\ndef g():\n    return 1\n' > "$TGT4/mod.py"   # NEW F401 → ruff fails in diff mode
  RD4="$WORK/rd4"
  set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" python3 -m sail run --target "$TGT4" --diff HEAD --run-dir "$RD4" >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" = "1" ] || fail "T4: gates-fail + review-clean should still exit 1, got $rc"
  python3 -c "import json,sys;d=json.load(open('$RD4/run-state.json'));g=[x for x in d['gates'] if x['name']=='ruff'][0];sys.exit(0 if g['status']=='failed' else 1)" \
    || fail "T4: expected ruff gate failed (the blocking arm)"
  echo "PASS T4: gates-fail + review-clean → exit 1 (gate blocking preserved)"
else
  echo "SKIP T4: ruff not installed (gate-blocking arm covered by test_sail_runner.sh)"
fi

# --- T5: whole-repo (no --diff) never triggers review, even with a HIGH mock backend set.
# (Exit code is gate-driven and env-dependent here — e.g. pip-audit on a lockfile-less target —
#  so the precise claim under test is "review did not run", not a specific exit code.) ---
RD5="$WORK/rd5"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$HIGH_JSON" python3 -m sail run --target "$TGT" --run-dir "$RD5" >/dev/null 2>&1; rc=$?; set -e
[ ! -f "$RD5/review.json" ] || fail "T5: whole-repo mode must not run review"
if [ -f "$RD5/decision-log.md" ] && grep -qi "^- review:" "$RD5/decision-log.md"; then
  fail "T5: whole-repo must not emit a review marker"
fi
echo "PASS T5: whole-repo never triggers review (gate-only exit=$rc)"

# --- T6: --diff but backend unavailable → FAIL CLOSED (exit 1), marker logged, no review.json ---
RD6="$WORK/rd6"
set +e; SAIL_REVIEW_CMD="/nonexistent/llm-xyz" python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD6" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "1" ] || fail "T6: requested review with no backend must fail closed (expected 1), got $rc"
grep -qi "backend unavailable" "$RD6/decision-log.md" || fail "T6: decision-log missing fail-closed review marker"
[ ! -f "$RD6/review.json" ] || fail "T6: no review.json should be written when the backend is missing"
echo "PASS T6: missing backend fails closed (never-mask)"

# --- T7: --diff --no-review with no backend → review not attempted, gates-only exit, no marker ---
RD7="$WORK/rd7"
set +e; SAIL_REVIEW_CMD="/nonexistent/llm-xyz" python3 -m sail run --target "$TGT" --diff HEAD --no-review --run-dir "$RD7" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || fail "T7: --no-review with missing backend should exit on gates only (expected 0), got $rc"
[ ! -f "$RD7/review.json" ] || fail "T7: --no-review must not write review.json"
if [ -f "$RD7/decision-log.md" ] && grep -qi "backend unavailable" "$RD7/decision-log.md"; then
  fail "T7: --no-review must not emit the fail-closed marker"
fi
echo "PASS T7: --no-review skips review cleanly even with no backend"

# --- T8: misconfigured backend (existing but NON-executable path) + --diff → fail closed CLEANLY
# (no subprocess traceback): exit 1, fail-closed marker, no review.json. Regression for RT-1. ---
NOEXE="$WORK/not_exec.txt"; printf 'not a program\n' > "$NOEXE"   # exists, no +x bit
RD8="$WORK/rd8"
set +e; SAIL_REVIEW_CMD="$NOEXE" python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD8" 2>"$WORK/t8.err"; rc=$?; set -e
[ "$rc" = "1" ] || fail "T8: non-executable backend must fail closed (expected 1), got $rc"
grep -qi "backend unavailable" "$RD8/decision-log.md" || fail "T8: non-exec backend should hit the fail-closed marker"
[ ! -f "$RD8/review.json" ] || fail "T8: no review.json should be written for a non-runnable backend"
if grep -qi "Traceback\|PermissionError" "$WORK/t8.err"; then fail "T8: must fail closed cleanly, not crash with a traceback"; fi
echo "PASS T8: misconfigured (non-executable) backend fails closed cleanly (RT-1 regression)"

# --- T9: backend passes availability preflight (+x) but fails at EXEC time (bad shebang) + --diff
# → fail closed cleanly, no traceback. Regression for RT-2. ---
BAD="$WORK/bad.sh"; printf '#!/nonexistent/interp\necho hi\n' > "$BAD"; chmod +x "$BAD"
RD9="$WORK/rd9"
set +e; SAIL_REVIEW_CMD="$BAD" python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD9" 2>"$WORK/t9.err"; rc=$?; set -e
[ "$rc" = "1" ] || fail "T9: exec-time backend failure must fail closed (expected 1), got $rc"
if grep -qi "Traceback\|FileNotFoundError\|PermissionError" "$WORK/t9.err"; then fail "T9: exec failure must be caught, not crash with a traceback"; fi
echo "PASS T9: exec-time backend failure fails closed cleanly (RT-2 regression)"

echo "PASS: sail run gates+review one-pass (#41) verified"
