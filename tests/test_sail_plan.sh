#!/usr/bin/env bash
# test_sail_plan.sh — issue #46: `sail plan` front-door stage (hermetic, mock LLM CLI).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"

fail() { echo "FAIL: $*"; exit 1; }

# Mock LLM CLI: ignores stdin, echoes $MOCK_OUT. Pointed at via SAIL_PLAN_CMD.
MOCK="$WORK/mock_llm.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "%s" "${MOCK_OUT:-}"' 'exit ${MOCK_RC:-0}' > "$MOCK"
chmod +x "$MOCK"

TARGET="."
SPEC='Write a short, concrete plan for the issue in stdin.'
EMPTY_SPEC='   '

# Full-shape plan JSON so the future parser can validate the documented artifact contract.
CLEAN_JSON='{"status":"completed","approach":"outline","simpler_alternative":"none","acceptance_criteria":["a"],"test_plan":["b"],"risks":[{"severity":"LOW","area":"scope","issue":"minor","mitigation":"watch"}],"scope":{"in":["x"],"out":["y"]},"summary":"clean"}'
HIGH_JSON='{"status":"completed","approach":"outline","simpler_alternative":"none","acceptance_criteria":["a"],"test_plan":["b"],"risks":[{"severity":"HIGH","area":"scope","issue":"blocking concern","mitigation":"mitigate"}],"scope":{"in":["x"],"out":["y"]},"summary":"blocking"}'

run_plan() {
  local spec="$1"
  local run_dir="$2"
  shift 2
  printf '%s' "$spec" | python3 -m sail plan --target "$TARGET" --run-dir "$run_dir" "$@"
}

assert_plan_status() {
  local path="$1"
  local expected="$2"
  python3 - "$path" "$expected" <<'PY'
import json
import sys

path, expected = sys.argv[1:3]
d = json.load(open(path))
if d.get("status") != expected:
    raise SystemExit(1)
PY
}

assert_no_blocking_risks() {
  local path="$1"
  python3 - "$path" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))
risks = d.get("risks", [])
if not isinstance(risks, list):
    raise SystemExit(1)
if any(isinstance(r, dict) and r.get("severity") in {"CRITICAL", "HIGH"} for r in risks):
    raise SystemExit(1)
PY
}

assert_has_high_risk() {
  local path="$1"
  python3 - "$path" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))
risks = d.get("risks", [])
if not isinstance(risks, list):
    raise SystemExit(1)
if not any(isinstance(r, dict) and r.get("severity") == "HIGH" for r in risks):
    raise SystemExit(1)
PY
}

# --- T1: `python3 -m sail plan` is a real subcommand; clean backend JSON + spec on stdin → exit 0 ---
RD1="$WORK/rd1"
set +e; SAIL_PLAN_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" run_plan "$SPEC" "$RD1" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || fail "T1: clean plan should exit 0, got $rc"
[ -f "$RD1/plan.json" ] || fail "T1: plan.json not written into the run-dir"
assert_plan_status "$RD1/plan.json" completed || fail "T1: plan.json status should be completed"
assert_no_blocking_risks "$RD1/plan.json" || fail "T1: clean plan must not contain HIGH/CRITICAL risks"
echo "PASS T1: clean plan → exit 0, plan.json recorded"

# --- T2: backend emits a HIGH risk → exit 1 ---
RD2="$WORK/rd2"
set +e; SAIL_PLAN_CMD="bash $MOCK" MOCK_OUT="$HIGH_JSON" run_plan "$SPEC" "$RD2" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "1" ] || fail "T2: HIGH-risk plan should exit 1, got $rc"
[ -f "$RD2/plan.json" ] || fail "T2: plan.json not written for HIGH-risk plan"
assert_has_high_risk "$RD2/plan.json" || fail "T2: HIGH risk not present in plan.json"
echo "PASS T2: HIGH-risk plan → exit 1"

# --- T3: same HIGH-risk backend + --advisory → exit 0 ---
RD3="$WORK/rd3"
set +e; SAIL_PLAN_CMD="bash $MOCK" MOCK_OUT="$HIGH_JSON" run_plan "$SPEC" "$RD3" --advisory >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || fail "T3: --advisory should suppress the blocking HIGH-risk exit, got $rc"
[ -f "$RD3/plan.json" ] || fail "T3: advisory run must still write plan.json"
assert_has_high_risk "$RD3/plan.json" || fail "T3: advisory plan.json should still record the HIGH risk"
echo "PASS T3: HIGH-risk plan + --advisory → exit 0"

# --- T4: backend unavailable → skips cleanly (exit 0) with plan.json status skipped ---
RD4="$WORK/rd4"
set +e; SAIL_PLAN_CMD="/nonexistent/backend-xyz" run_plan "$SPEC" "$RD4" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || fail "T4: unavailable backend should skip cleanly (exit 0), got $rc"
[ -f "$RD4/plan.json" ] || fail "T4: skipped plan should still write plan.json"
assert_plan_status "$RD4/plan.json" skipped || fail "T4: plan.json status should be skipped when the backend is absent"
echo "PASS T4: unavailable backend skips cleanly"

# --- T5: empty / whitespace-only spec on stdin → hard error, never a skip (exit 1) ---
RD5="$WORK/rd5"
set +e; SAIL_PLAN_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" run_plan "$EMPTY_SPEC" "$RD5" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "1" ] || fail "T5: whitespace-only spec must fail hard (exit 1), got $rc"
[ -f "$RD5/plan.json" ] || fail "T5: hard error should still write plan.json"
assert_plan_status "$RD5/plan.json" error || fail "T5: plan.json status should be error for whitespace-only stdin"
echo "PASS T5: whitespace-only stdin → exit 1, status error"

# --- T6: clean run writes the documented plan.json artifact and decision-log marker ---
RD6="$WORK/rd6"
mkdir -p "$RD6"
: > "$RD6/decision-log.md"
set +e; SAIL_PLAN_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" run_plan "$SPEC" "$RD6" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || fail "T6: clean plan should exit 0, got $rc"
[ -f "$RD6/plan.json" ] || fail "T6: plan.json not written into the run-dir"
python3 -c 'import json,sys
path = sys.argv[1]
required = {"status","approach","simpler_alternative","acceptance_criteria","test_plan","risks","scope","summary"}
d = json.load(open(path))
missing = sorted(required.difference(d))
if missing or d.get("status") != "completed":
    raise SystemExit(1)
' "$RD6/plan.json" || fail "T6: plan.json must include the full documented artifact contract"
[ -f "$RD6/decision-log.md" ] || fail "T6: decision-log.md not written into the run-dir"
grep -q -- '^- plan:' "$RD6/decision-log.md" || fail "T6: decision-log.md must include a plan marker"
echo "PASS T6: clean run writes plan.json and decision-log plan marker"

# --- T7: unparseable backend output + --advisory → hard error (exit 1) with plan.json status error ---
RD7="$WORK/rd7"
set +e; SAIL_PLAN_CMD="bash $MOCK" MOCK_OUT='not json at all' run_plan "$SPEC" "$RD7" --advisory >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "1" ] || fail "T7: unparseable backend output must fail hard even under --advisory, got $rc"
[ -f "$RD7/plan.json" ] || fail "T7: plan.json not written for unparseable backend output"
assert_plan_status "$RD7/plan.json" error || fail "T7: plan.json status should be error for unparseable backend output"
echo "PASS T7: unparseable backend output + --advisory → exit 1, status error"

# --- T8: valid JSON with empty risks but no approach → hard error (exit 1) with plan.json status error ---
RD8="$WORK/rd8"
set +e; SAIL_PLAN_CMD="bash $MOCK" MOCK_OUT='{"risks":[]}' run_plan "$SPEC" "$RD8" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "1" ] || fail "T8: plan missing approach must fail hard, got $rc"
[ -f "$RD8/plan.json" ] || fail "T8: plan.json not written for missing-approach response"
assert_plan_status "$RD8/plan.json" error || fail "T8: plan.json status should be error for missing approach"
echo "PASS T8: valid JSON without approach → exit 1, status error"

# --- T9: null approach is also unusable → hard error (exit 1) with plan.json status error ---
RD9="$WORK/rd9"
set +e; SAIL_PLAN_CMD="bash $MOCK" MOCK_OUT='{"risks":[],"approach":null}' run_plan "$SPEC" "$RD9" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "1" ] || fail "T9: null approach must fail hard, got $rc"
[ -f "$RD9/plan.json" ] || fail "T9: plan.json not written for null-approach response"
assert_plan_status "$RD9/plan.json" error || fail "T9: plan.json status should be error for null approach"
echo "PASS T9: null approach → exit 1, status error"

echo "PASS: sail plan contract verified"
