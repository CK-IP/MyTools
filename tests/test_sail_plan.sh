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

# --- T10 (#58 AC#1): the plan prompt requires a consistency self-check — for every
# user-facing instruction/remediation the change adds, name the exact action that fulfills it ---
python3 - <<'PY' || fail "T10: plan prompt missing the consistency self-check"
from sail.plan import build_prompt
p = build_prompt("some spec").lower()
# the prompt must demand promise->action consistency (the broken promise->action failure class)
ok = (
    ("instruction" in p or "remediation" in p)
    and "action" in p
    and "consistency" in p
)
raise SystemExit(0 if ok else 1)
PY
echo "PASS T10: plan prompt includes consistency self-check (AC#1)"

# --- T11 (#58 AC#2): the escalation heuristic flags a plan-risky spec
# (user-facing remediation / reconciling multiple files+lists) as risky ---
python3 - <<'PY' || fail "T11: risky spec not detected by is_plan_risky"
from sail.plan import is_plan_risky
risky = (
    "doctor.sh tells the user to Run ./install.sh to remediate, but install.sh "
    "cannot install one tool counted in the tool list — reconcile the two files."
)
raise SystemExit(0 if is_plan_risky(risky) else 1)
PY
echo "PASS T11: is_plan_risky flags a remediation/reconciliation spec (AC#2)"

# --- T12 (#58 AC#4): non-risky specs are NOT flagged risky → stay single-pass. Includes
# specs that mention BROAD terms in isolation (a single remediation OR reconcile signal, or
# common prose like "run the tests" / "error message" / "consistent with") — these must NOT
# escalate, or AC#4 ("no uniform weight") is nullified (review R1 HIGH, both lenses). ---
python3 - <<'PY' || fail "T12: a non-risky spec was wrongly flagged risky"
from sail.plan import is_plan_risky
non_risky = [
    "Rename the variable foo to bar in helper.py and update its docstring.",
    "Run the test suite after the refactor and improve the error message.",
    "Keep the README consistent with the code style.",
    "Add a remediation message telling the user what went wrong.",  # single remediation signal
    "Reconcile the rounding in the price calculation.",             # single reconcile signal
]
bad = [s for s in non_risky if is_plan_risky(s)]
if bad:
    print("wrongly flagged risky:", bad)
    raise SystemExit(1)
PY
echo "PASS T12: is_plan_risky leaves ordinary/single-signal specs single-pass (AC#4)"

# --- T12b (#58 AC#2): the heuristic fires only on CO-OCCURRENCE (a remediation signal AND a
# reconcile signal) or an unambiguous failure phrase — the #55 "unresolvable loop" shape ---
python3 - <<'PY' || fail "T12b: co-occurrence/unambiguous heuristic regressed"
from sail.plan import is_plan_risky
co_occurrence = "doctor.sh tells the user to run ./install.sh to remediate, but it cannot reconcile the two files."
unambiguous = "There is an unresolvable loop between the doctor message and what install delivers."
if not is_plan_risky(co_occurrence):
    print("co-occurrence spec should be risky"); raise SystemExit(1)
if not is_plan_risky(unambiguous):
    print("unambiguous-phrase spec should be risky"); raise SystemExit(1)
PY
echo "PASS T12b: is_plan_risky fires on co-occurrence + unambiguous shapes (AC#2)"

# --- T13 (#58 AC#2): risky spec + --plan-adversary + a second backend that returns a
# blocking adversarial risk → escalates, unions the adversary risk, blocks (exit 1) ---
RD13="$WORK/rd13"
# Adversary mock: emits a HIGH-risk plan critique; first (author) backend emits clean plan.
# The mock body must contain LITERAL ${ADV_OUT}/${ADV_RC} (expanded at mock-runtime, not now),
# so the single quotes are intentional — same pattern as the $MOCK author backend above.
ADV_MOCK="$WORK/adv_mock.sh"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "%s" "${ADV_OUT:-}"' 'exit ${ADV_RC:-0}' > "$ADV_MOCK"
chmod +x "$ADV_MOCK"
RISKY_SPEC='doctor.sh says "Run ./install.sh" to remediate a missing tool, but install.sh cannot install that tool — reconcile the tool list across both files.'
# The adversary emits the REDUCED documented shape {"risks":[...],"summary":...} (build_adversary_prompt),
# not the full author schema — pin that actual contract here (review R1 LOW lens1).
ADV_HIGH='{"risks":[{"severity":"HIGH","area":"design","issue":"unresolvable loop: doctor promises install.sh fixes a tool it cannot install","mitigation":"reconcile both files"}],"summary":"broken promise"}'
ADV_CLEAN='{"risks":[],"summary":"no adversarial findings"}'
set +e
printf '%s' "$RISKY_SPEC" | SAIL_PLAN_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" \
  SAIL_PLAN_CMD2="bash $ADV_MOCK" ADV_OUT="$ADV_HIGH" \
  python3 -m sail plan --target "$TARGET" --run-dir "$RD13" --plan-adversary >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "1" ] || fail "T13: --plan-adversary with a blocking adversarial risk must exit 1, got $rc"
assert_has_high_risk "$RD13/plan.json" || fail "T13: adversarial HIGH risk must be unioned into plan.json"
echo "PASS T13: --plan-adversary unions a blocking adversarial risk → exit 1 (AC#2)"

# --- T14 (#58 AC#4): a CLEAN author plan + a CLEAN adversary still passes (exit 0) — the
# adversary runs but adds nothing blocking when there is nothing to find ---
RD14="$WORK/rd14"
set +e
printf '%s' "$RISKY_SPEC" | SAIL_PLAN_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" \
  SAIL_PLAN_CMD2="bash $ADV_MOCK" ADV_OUT="$ADV_CLEAN" \
  python3 -m sail plan --target "$TARGET" --run-dir "$RD14" --plan-adversary >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] || fail "T14: clean author + clean adversary should exit 0, got $rc"
echo "PASS T14: clean author + clean adversary → exit 0 (AC#4)"

# --- T15 (#58 AC#4): --plan-adversary requested but NO second backend → degrades cleanly
# to a single author pass (logged, not a hard error) on a clean plan → exit 0 ---
RD15="$WORK/rd15"
set +e
printf '%s' "$RISKY_SPEC" | SAIL_PLAN_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" \
  python3 -m sail plan --target "$TARGET" --run-dir "$RD15" --plan-adversary >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] || fail "T15: missing adversary backend should degrade to single-pass (exit 0), got $rc"
grep -q -- 'plan-adversary' "$RD15/decision-log.md" || fail "T15: degraded adversary path must be logged"
echo "PASS T15: --plan-adversary with no second backend degrades cleanly (AC#4)"

# --- T16 (#58 review R1 HIGH lens2): an adversary BACKEND error fails closed AND the on-disk
# plan.json status must be "error" (not "completed") so a downstream reuse can't treat a
# failed-closed plan run as valid ---
RD16="$WORK/rd16"
set +e
printf '%s' "$RISKY_SPEC" | SAIL_PLAN_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" \
  SAIL_PLAN_CMD2="bash $ADV_MOCK" ADV_RC=1 ADV_OUT="" \
  python3 -m sail plan --target "$TARGET" --run-dir "$RD16" --plan-adversary >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "1" ] || fail "T16: adversary backend error must fail closed (exit 1), got $rc"
assert_plan_status "$RD16/plan.json" error || fail "T16: plan.json status must be 'error' on adversary backend error (must match exit code)"
echo "PASS T16: adversary backend error → exit 1 AND plan.json status=error (R1 HIGH lens2)"

# --- T17 (#58 review R1 MEDIUM lens1): an adversary risk with a typo'd/missing severity must
# NOT be promoted to a blocking HIGH (no default-to-HIGH on the adversary union). A clean
# author plan + an adversary whose only "risk" has a garbage severity stays exit 0 ---
RD17="$WORK/rd17"
ADV_BADSEV='{"risks":[{"severity":"meduim","area":"design","issue":"typo sev","mitigation":"x"}],"summary":"sloppy"}'
set +e
printf '%s' "$RISKY_SPEC" | SAIL_PLAN_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" \
  SAIL_PLAN_CMD2="bash $ADV_MOCK" ADV_OUT="$ADV_BADSEV" \
  python3 -m sail plan --target "$TARGET" --run-dir "$RD17" --plan-adversary >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] || fail "T17: a non-explicit adversary severity must not block (exit 0), got $rc"
echo "PASS T17: adversary risk with garbage severity does not spuriously block (R1 MED lens1)"

# --- T18 (#62): the adversary now RUNS on plan-risky work EVEN WHEN the author plan is already
# blocking (reversing #58 review R1 LOW's skip-when-already-red). Its job is design BREADTH: a
# HIGH author plan + an adversary that finds its OWN blocking design risk must run, exit 1, and
# union the adversary's risk (tagged lens=adversary) into plan.json ON TOP OF the author HIGH —
# so the second design perspective is recorded for the reviewer regardless of the already-red gate. ---
RD18="$WORK/rd18"
set +e
printf '%s' "$RISKY_SPEC" | SAIL_PLAN_CMD="bash $MOCK" MOCK_OUT="$HIGH_JSON" \
  SAIL_PLAN_CMD2="bash $ADV_MOCK" ADV_OUT="$ADV_HIGH" \
  python3 -m sail plan --target "$TARGET" --run-dir "$RD18" --plan-adversary >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "1" ] || fail "T18: already-blocking author plan + adversary should exit 1, got $rc"
grep -q 'plan-adversary: ran' "$RD18/decision-log.md" || fail "T18: adversary must RUN (not skip) when the author plan already blocks"
python3 - "$RD18/plan.json" <<'PY' || fail "T18: adversary risk must be unioned (tagged lens=adversary) on top of the author HIGH"
import json, sys
d = json.load(open(sys.argv[1]))
risks = d.get("risks", [])
# the author HIGH is present AND the adversary's risk is appended and tagged lens=adversary
author = [r for r in risks if isinstance(r, dict) and r.get("lens") != "adversary"]
adv = [r for r in risks if isinstance(r, dict) and r.get("lens") == "adversary"]
if not any(r.get("severity") == "HIGH" for r in author):
    raise SystemExit(1)
if not any(r.get("severity") == "HIGH" for r in adv):
    raise SystemExit(1)
PY
echo "PASS T18: adversary RUNS on already-blocking plan and unions its design finding (#62)"

# --- T18b (#62, mirrors #58 review R1 HIGH lens2): with the skip removed, an adversary BACKEND
# error on an ALREADY-BLOCKING author plan must fail closed UNIFORMLY — status=error (not the old
# "stays completed"), exit 1. The artifact status must match a failed-closed run regardless of
# whether the author plan was independently blocking. ---
RD18B="$WORK/rd18b"
set +e
printf '%s' "$RISKY_SPEC" | SAIL_PLAN_CMD="bash $MOCK" MOCK_OUT="$HIGH_JSON" \
  SAIL_PLAN_CMD2="bash $ADV_MOCK" ADV_RC=1 ADV_OUT="" \
  python3 -m sail plan --target "$TARGET" --run-dir "$RD18B" --plan-adversary >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "1" ] || fail "T18b: adversary error on an already-blocking plan must exit 1, got $rc"
assert_plan_status "$RD18B/plan.json" error || fail "T18b: adversary backend error must set status=error even when author plan already blocks"
grep -q 'plan-adversary: backend error' "$RD18B/decision-log.md" || fail "T18b: adversary backend error must be logged"
echo "PASS T18b: adversary error on already-blocking plan fails closed (status=error, exit 1) (#62)"

# --- T18c (#62): the adversary prompt is explicitly DESIGN-FOCUSED — it directs the reviewer to
# surface design breadth (design choices / a simpler approach a single author pass misses), so the
# pass earns its keep on an already-blocking plan beyond merely adding to the blocking count. ---
python3 - <<'PY' || fail "T18c: adversary prompt missing the design-breadth directive"
from sail.plan import build_adversary_prompt
p = build_adversary_prompt("some spec").lower()
ok = "design" in p and ("breadth" in p or "simpler" in p or "alternativ" in p)
raise SystemExit(0 if ok else 1)
PY
echo "PASS T18c: adversary prompt is design-focused (surfaces design breadth) (#62)"

# --- T19 (#61 AC#1): the plan prompt instructs the planner to surface key design
# ALTERNATIVES, a recommended choice, and the trade-off — gated on a genuine
# no-single-right-answer design choice (the #55 N=8-vs-N=9 miss the consistency
# self-check cannot catch). It must also tell trivial specs to leave it empty. ---
python3 - <<'PY' || fail "T19: plan prompt missing the design-alternatives directive"
from sail.plan import build_prompt
p = build_prompt("some spec").lower()
ok = (
    "alternativ" in p          # surface alternatives
    and "recommend" in p       # a recommended choice
    and "trade" in p           # the trade-off
    and "design_alternatives" in p  # the structured field is named in the schema
    # conditional: do not force trivial specs to invent alternatives (AC against MEDIUM risk)
    and ("empty" in p or "no " in p)
)
raise SystemExit(0 if ok else 1)
PY
echo "PASS T19: plan prompt includes the design-alternatives directive (#61 AC#1)"

# --- T20 (#61 AC#2): a backend that emits a non-empty design_alternatives value must
# have it ROUND-TRIP into the written plan.json — proving run_plan's explicit-key payload
# rebuild does not drop the field (closes the plan's HIGH consistency risk). ---
RD20="$WORK/rd20"
DA_JSON='{"status":"completed","approach":"outline","simpler_alternative":"none","design_alternatives":[{"option":"N=8 exclude per-project pytest","tradeoff":"simpler honest count","recommended":true},{"option":"N=9 include + split remediation","tradeoff":"complete but messier","recommended":false}],"acceptance_criteria":["a"],"test_plan":["b"],"risks":[{"severity":"LOW","area":"scope","issue":"minor","mitigation":"watch"}],"scope":{"in":["x"],"out":["y"]},"summary":"clean"}'
set +e; SAIL_PLAN_CMD="bash $MOCK" MOCK_OUT="$DA_JSON" run_plan "$SPEC" "$RD20" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || fail "T20: clean plan with design_alternatives should exit 0, got $rc"
python3 - "$RD20/plan.json" <<'PY' || fail "T20: design_alternatives did not round-trip into plan.json"
import json, sys
d = json.load(open(sys.argv[1]))
da = d.get("design_alternatives")
if not isinstance(da, list) or len(da) != 2:
    raise SystemExit(1)
if da[0].get("option") != "N=8 exclude per-project pytest" or da[0].get("recommended") is not True:
    raise SystemExit(1)
if "tradeoff" not in da[1]:
    raise SystemExit(1)
PY
echo "PASS T20: design_alternatives round-trips into plan.json (#61 AC#2)"

# --- T21 (#61 AC#2 default): a planner that OMITS design_alternatives is not a hard
# error — plan.json carries the field as the documented default (empty list), exit 0. ---
RD21="$WORK/rd21"
set +e; SAIL_PLAN_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" run_plan "$SPEC" "$RD21" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || fail "T21: clean plan without design_alternatives should exit 0, got $rc"
python3 - "$RD21/plan.json" <<'PY' || fail "T21: omitted design_alternatives should default to an empty list"
import json, sys
d = json.load(open(sys.argv[1]))
if d.get("design_alternatives") != []:
    raise SystemExit(1)
PY
echo "PASS T21: omitted design_alternatives defaults to [] (#61 AC#2)"

# --- T22 (#90): the plan prompt front-loads a CONDITIONAL failure-class checklist so the
# single author pass proactively addresses the three robustness properties /ship's heavier
# red-team caught on #86 — (1) queue ORDERING (a later-discovered item violating a required
# parent-before-dependent order; name the reordering rule), (2) HYDRATION-before-decision
# (a filter/classify acting on data a cheap list call does not carry; require the hydrate
# step first), and (3) PERSISTENCE/RESUME (a terminal/partial cap-hit/interrupted state whose
# leftover work must be durably recorded + reconciled on resume; require the artifact + reader).
# It must be CONDITIONAL — naming the work-queue / multi-pass-loop / persisted-run-state surface
# AND giving a no-op escape — so trivial diffs are not forced (the #61/#80 "no uniform weight"
# lesson). Prompt-content assertion: the LLM-output variant is non-deterministic (same reason
# T19/#58/#61/#80 assert the prompt, not the model output). ---
python3 - <<'PY' || fail "T22: plan prompt missing the conditional failure-class checklist (#90)"
from sail.plan import build_prompt
p = build_prompt("some spec").lower()
ok = (
    # (1) ordering / reordering rule
    ("order" in p and "reorder" in p)
    # (2) hydration-before-decision
    and "hydrat" in p
    # (3) persistence / resume
    and "persist" in p and "resume" in p
    # conditional surface markers
    and "queue" in p and ("multi-pass" in p or "loop" in p) and "run state" in p
    # no-op escape so trivial specs are not forced (no uniform weight)
    and ("if " in p or "no " in p or "skip" in p or "not applicable" in p)
)
raise SystemExit(0 if ok else 1)
PY
echo "PASS T22: plan prompt includes the conditional failure-class checklist (#90)"

echo "PASS: sail plan contract verified"
