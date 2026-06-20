#!/usr/bin/env bash
# test_sail_run_review.sh — issue #41: `sail run --diff` wires gates + blocking LLM
# review into one pass (the drop-in /ship replacement). Hermetic: mocks the LLM
# backend via SAIL_REVIEW_CMD and uses throwaway git targets. Never calls a real CLI.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
# #51: restrict the deterministic gate registry to the fast checkers this suite needs as
# background — only T4 asserts a gate (ruff). Skips semgrep/pip-audit/bandit/mypy (~11s/pass,
# run twice per --diff call) which test nothing about the LLM-review arm under test here.
export SAIL_CHECKERS=ruff,pytest
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

# ── #42: resume-safety — `sail run --diff` must not blindly re-run the review on resume ──
# Call-sentinel mock: touches $CALLED when invoked, so a test can assert whether the
# backend was re-run. "Resume" = a second `sail run --diff --run-dir RD` against the same RD
# (run-state.json already present → the runner treats it as a resume).
MOCK2="$WORK/mock_llm_sentinel.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' '[ -n "${CALLED:-}" ] && touch "$CALLED"' 'printf "%s" "${MOCK_OUT:-}"' 'exit ${MOCK_RC:-0}' > "$MOCK2"
chmod +x "$MOCK2"

# --- T10: prior review COMPLETED + clean → resume reuses it, does NOT re-invoke the backend ---
RD10="$WORK/rd10"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD10" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || fail "T10 setup: run1 clean review should exit 0, got $rc"
python3 -c "import json,sys;d=json.load(open('$RD10/review.json'));sys.exit(0 if d.get('status')=='completed' else 1)" || fail "T10 setup: run1 review.json not completed"
fmarkers_before=$(grep -c "findings (" "$RD10/decision-log.md" || true)
CALLED10="$WORK/called10"
set +e; SAIL_REVIEW_CMD="bash $MOCK2" CALLED="$CALLED10" MOCK_OUT="$HIGH_JSON" python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD10" >/dev/null 2>&1; rc=$?; set -e
[ ! -f "$CALLED10" ] || fail "T10: resume of a completed review must NOT re-invoke the backend"
[ "$rc" = "0" ] || fail "T10: resume of a clean completed review should exit 0, got $rc"
python3 -c "import json,sys;d=json.load(open('$RD10/review.json'));sys.exit(0 if d.get('status')=='completed' and not any(f.get('severity')=='HIGH' for f in d.get('findings',[])) else 1)" || fail "T10: review.json must be unchanged (still clean completed)"
fmarkers_after=$(grep -c "findings (" "$RD10/decision-log.md" || true)
[ "$fmarkers_before" = "$fmarkers_after" ] || fail "T10: resume duplicated the review findings marker ($fmarkers_before -> $fmarkers_after)"
grep -qi "reused prior completed review" "$RD10/decision-log.md" || fail "T10: resume must record a distinct reused-review marker"
echo "PASS T10: resume of a completed clean review reuses it (no backend re-call, no duplicate marker)"

# --- T11: prior review ERRORED → resume RE-RUNS it (never reuse a non-result) ---
RD11="$WORK/rd11"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="not json" python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD11" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "1" ] || fail "T11 setup: run1 unparseable review should exit 1, got $rc"
python3 -c "import json,sys;d=json.load(open('$RD11/review.json'));sys.exit(0 if d.get('status')=='error' else 1)" || fail "T11 setup: run1 review.json not error"
CALLED11="$WORK/called11"
set +e; SAIL_REVIEW_CMD="bash $MOCK2" CALLED="$CALLED11" MOCK_OUT="$CLEAN_JSON" python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD11" >/dev/null 2>&1; rc=$?; set -e
[ -f "$CALLED11" ] || fail "T11: resume of an ERRORED review MUST re-invoke the backend"
[ "$rc" = "0" ] || fail "T11: re-run clean review should exit 0, got $rc"
python3 -c "import json,sys;d=json.load(open('$RD11/review.json'));sys.exit(0 if d.get('status')=='completed' else 1)" || fail "T11: review.json should now be completed after re-run"
echo "PASS T11: resume of an errored review re-runs the backend (never-mask preserved)"

# --- T12: prior review COMPLETED + blocking → resume still exits 1 without re-invoking (backend gone) ---
RD12="$WORK/rd12"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$HIGH_JSON" python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD12" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "1" ] || fail "T12 setup: run1 blocking review should exit 1, got $rc"
set +e; SAIL_REVIEW_CMD="/nonexistent/llm-xyz" python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD12" 2>"$WORK/t12.err"; rc=$?; set -e
[ "$rc" = "1" ] || fail "T12: resume of a blocking completed review must still exit 1, got $rc"
if grep -qi "Traceback" "$WORK/t12.err"; then fail "T12: reuse path must not crash"; fi
if grep -qi "backend unavailable" "$RD12/decision-log.md"; then fail "T12: reuse path must not emit a fail-closed marker (review was reused, not re-attempted)"; fi
echo "PASS T12: resume preserves a prior blocking review's exit code without re-invoking the backend"

# --- T13: a "completed" review.json with a missing/garbled findings list must re-run on resume,
# not reuse/crash (RT-1 regression — never reuse a non-result; findings is the required field). ---
RD13="$WORK/rd13"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD13" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || fail "T13 setup: run1 clean review should exit 0, got $rc"
# Corrupt the artifact: keep status "completed" but drop the findings list (garbled shape).
python3 -c "import json;p='$RD13/review.json';d=json.load(open(p));d.pop('findings',None);json.dump(d,open(p,'w'))"
CALLED13="$WORK/called13"
set +e; SAIL_REVIEW_CMD="bash $MOCK2" CALLED="$CALLED13" MOCK_OUT="$CLEAN_JSON" python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD13" 2>"$WORK/t13.err"; rc=$?; set -e
[ -f "$CALLED13" ] || fail "T13: a completed review with no findings list MUST re-run (not reuse)"
if grep -qi "Traceback" "$WORK/t13.err"; then fail "T13: malformed artifact must not crash the run"; fi
echo "PASS T13: malformed completed-review artifact re-runs cleanly on resume (RT-1 regression)"

# --- T14: a resume that CHANGED --diff must re-review, not reuse the prior-scope review
# (RT-2 regression — reuse is gated on matching target+diff). ---
TGT14="$WORK/target14"; mkdir -p "$TGT14"
printf 'def h():\n    return 0\n' > "$TGT14/mod.py"
git -C "$TGT14" init -q
git -C "$TGT14" add -A
git -C "$TGT14" -c user.email=t@t -c user.name=t commit -qm c1
printf 'def h():\n    return 1\n' > "$TGT14/mod.py"; git -C "$TGT14" add -A
git -C "$TGT14" -c user.email=t@t -c user.name=t commit -qm c2
printf 'def h():\n    return 2  # wt\n' > "$TGT14/mod.py"   # working-tree change
RD14="$WORK/rd14"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" python3 -m sail run --target "$TGT14" --diff HEAD --run-dir "$RD14" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || fail "T14 setup: run1 (--diff HEAD) should exit 0, got $rc"
CALLED14="$WORK/called14"
set +e; SAIL_REVIEW_CMD="bash $MOCK2" CALLED="$CALLED14" MOCK_OUT="$CLEAN_JSON" python3 -m sail run --target "$TGT14" --diff HEAD~1 --run-dir "$RD14" >/dev/null 2>&1; rc=$?; set -e
[ -f "$CALLED14" ] || fail "T14: a resume with a CHANGED --diff must re-review, not reuse a stale-scope review"
echo "PASS T14: changed-diff resume re-reviews instead of reusing a stale-scope review (RT-2 regression)"

# --- T15: blocking is recomputed from findings, not the counts cache. A completed artifact with
# clean (zeroed) counts but a real HIGH finding must still BLOCK on resume — counts can't mask it
# (RT-3/RT-4 regression). Backend is gone to prove the reuse path (not a re-run) blocks. ---
RD15="$WORK/rd15"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD15" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || fail "T15 setup: run1 clean review should exit 0, got $rc"
# Inconsistent artifact: counts say clean, but findings carries a real HIGH (e.g. hand-edited).
python3 -c "import json;p='$RD15/review.json';d=json.load(open(p));d['findings']=[{'severity':'HIGH','issue':'x'}];d['counts']={'CRITICAL':0,'HIGH':0,'MEDIUM':0,'LOW':0};json.dump(d,open(p,'w'))"
set +e; SAIL_REVIEW_CMD="/nonexistent/llm-xyz" python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD15" 2>"$WORK/t15.err"; rc=$?; set -e
[ "$rc" = "1" ] || fail "T15: a reused review with a HIGH finding must still block (expected 1), got $rc"
if grep -qi "Traceback" "$WORK/t15.err"; then fail "T15: reuse path must not crash"; fi
if grep -qi "backend unavailable" "$RD15/decision-log.md"; then fail "T15: must reuse (not re-attempt) — no fail-closed marker"; fi
echo "PASS T15: blocking is recomputed from findings on reuse; zeroed counts cannot mask a HIGH (RT-3/RT-4 regression)"

# --- T16: resume with SAME --diff HEAD but CHANGED working-tree content must re-review,
# not reuse a review keyed only on the ref string (#45). ---
TGT16="$WORK/target16"; mkdir -p "$TGT16"
printf 'def k():\n    return 0\n' > "$TGT16/mod.py"
git -C "$TGT16" init -q
git -C "$TGT16" add -A
git -C "$TGT16" -c user.email=t@t -c user.name=t commit -qm base
printf 'def k():\n    return 1  # v1\n' > "$TGT16/mod.py"   # working-tree change v1
RD16="$WORK/rd16"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" python3 -m sail run --target "$TGT16" --diff HEAD --run-dir "$RD16" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || fail "T16 setup: run1 (--diff HEAD) should exit 0, got $rc"
python3 -c "import json,sys;d=json.load(open('$RD16/review.json'));sys.exit(0 if isinstance(d.get('diff_hash'),str) and len(d['diff_hash'])==64 else 1)" || fail "T16: review.json must record a 64-char diff_hash fingerprint"
printf 'def k():\n    return 2  # v2 different\n' > "$TGT16/mod.py"   # changed content, SAME ref
CALLED16="$WORK/called16"
set +e; SAIL_REVIEW_CMD="bash $MOCK2" CALLED="$CALLED16" MOCK_OUT="$CLEAN_JSON" python3 -m sail run --target "$TGT16" --diff HEAD --run-dir "$RD16" >/dev/null 2>&1; rc=$?; set -e
[ -f "$CALLED16" ] || fail "T16: resume with same ref but changed content must re-review, not reuse a stale review"
echo "PASS T16: same-ref changed-content resume re-reviews (diff-content fingerprint, #45)"

# ── #47 HIGH-1: plan-hash reuse gate — a CHANGED plan.json must force a fresh review ──
# (mirrors the #45 diff-content reuse gate, applied to the plan->review spine.)
PLAN_AC1='{"status":"completed","approach":"x","acceptance_criteria":["AC one"],"risks":[],"scope":{"in":[],"out":[]},"summary":"s"}'
PLAN_AC2='{"status":"completed","approach":"x","acceptance_criteria":["AC one","AC two NEW"],"risks":[],"scope":{"in":[],"out":[]},"summary":"s"}'
AC1_MET='{"findings":[],"summary":"ok","ac_results":[{"criterion":"AC one","status":"met","evidence":"a"}]}'
RD17="$WORK/rd17"; mkdir -p "$RD17"; printf '%s' "$PLAN_AC1" > "$RD17/plan.json"
# First run: clean review against plan with one AC (all met) → exit 0, review.json completed.
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$AC1_MET" python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD17" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || fail "T17 setup: first plan-AC run should be clean (exit 0), got $rc"
# Change the plan's ACs in the shared run-dir, then resume: the sentinel backend MUST be re-invoked
# (stale review may have skipped the new AC).
printf '%s' "$PLAN_AC2" > "$RD17/plan.json"
CALLED17="$WORK/called17"
set +e; SAIL_REVIEW_CMD="bash $MOCK2" CALLED="$CALLED17" MOCK_OUT="$AC1_MET" python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD17" >/dev/null 2>&1; rc=$?; set -e
[ -f "$CALLED17" ] || fail "T17: changed plan.json ACs must force a fresh review (backend not re-invoked)"
grep -qi "plan acceptance criteria changed" "$RD17/decision-log.md" || fail "T17: missing plan-stale re-review marker"
echo "PASS T17: changed plan ACs force a fresh review (plan-hash reuse gate, #47 HIGH-1)"

# ── #47 HIGH-4: a plan.json that becomes MALFORMED on resume must refuse reuse (fail closed) ──
RD18="$WORK/rd18"; mkdir -p "$RD18"; printf '%s' "$PLAN_AC1" > "$RD18/plan.json"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$AC1_MET" python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD18" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || fail "T18 setup: first run should be clean, got $rc"
printf '%s' '{"status":"completed","acceptance_criteria":[trunc' > "$RD18/plan.json"   # corrupt the plan
CALLED18="$WORK/called18"
set +e; SAIL_REVIEW_CMD="bash $MOCK2" CALLED="$CALLED18" MOCK_OUT="$AC1_MET" python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD18" >/dev/null 2>&1; rc=$?; set -e
[ -f "$CALLED18" ] || fail "T18: malformed plan on resume must refuse reuse (re-review)"
[ "$rc" = "1" ] || fail "T18: malformed plan on resume must fail closed (expected 1), got $rc"
echo "PASS T18: malformed plan on resume refuses reuse + fails closed (#47 HIGH-4)"

# ── #47 HIGH-3: a --dual-lens resume must NOT reuse a single-lens cached review ──
RD19="$WORK/rd19"; mkdir -p "$RD19"; printf '%s' "$PLAN_AC1" > "$RD19/plan.json"
# First: single-lens clean run → review.json has lenses:["lens1"].
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$AC1_MET" python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD19" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || fail "T19 setup: first single-lens run should be clean, got $rc"
# Resume WITH --dual-lens → must re-invoke (lens2 was never run in the cache).
CALLED19="$WORK/called19"
set +e
SAIL_REVIEW_CMD="bash $MOCK2" CALLED="$CALLED19" MOCK_OUT="$AC1_MET" \
  SAIL_REVIEW_CMD2="bash $MOCK" \
  python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD19" --dual-lens >/dev/null 2>&1; rc=$?
set -e
[ -f "$CALLED19" ] || fail "T19: --dual-lens resume must NOT reuse a single-lens cache (re-review required)"
echo "PASS T19: --dual-lens resume re-reviews a single-lens cache (#47 HIGH-3)"

echo "PASS: sail run gates+review one-pass + resume-safety (#41, #42) + plan-hash/mode reuse (#47) verified"
