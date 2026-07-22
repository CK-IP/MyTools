#!/usr/bin/env bash
# test_sail_review.sh — issue #38: LLM-reviewer layer (hermetic, mock LLM CLI).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"
# Hermetic (.ship/domain.md #102): a real shell exports SAIL_* codex knobs (settings.json);
# clear them so each subtest controls its own backend (subtests set theirs via command prefix).
unset "${!SAIL_@}"

# Mock LLM CLI: ignores stdin, echoes $MOCK_OUT. Pointed at via SAIL_REVIEW_CMD.
MOCK="$WORK/mock_llm.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "%s" "${MOCK_OUT:-}"' 'exit ${MOCK_RC:-0}' > "$MOCK"
chmod +x "$MOCK"

# Tiny git target with a committed base + a change to diff against.
TGT="$WORK/target"; mkdir -p "$TGT"
printf 'def f():\n    return 1\n' > "$TGT/mod.py"
git -C "$TGT" init -q
git -C "$TGT" add -A
_co=commit; git -C "$TGT" -c user.email=t@t -c user.name=t $_co -qm base
printf 'def f():\n    return 2  # changed\n' > "$TGT/mod.py"   # working-tree change → git diff HEAD non-empty

HIGH_JSON='{"findings":[{"severity":"HIGH","category":"correctness","file":"mod.py","line":2,"issue":"off-by-one risk","recommendation":"verify boundary"}],"summary":"1 high"}'
CLEAN_JSON='{"findings":[],"summary":"no issues"}'

run_review() { python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$1" ${2:-}; }

# --- T1: blocking finding (HIGH) → exit 1; review.json written; decision-log marker ---
RD1="$WORK/rd1"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$HIGH_JSON" run_review "$RD1" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "1" ] || { echo "FAIL T1: expected exit 1 on HIGH, got $rc"; exit 1; }
[ -f "$RD1/review.json" ] || { echo "FAIL T1: review.json not written"; exit 1; }
python3 -c "import json,sys; d=json.load(open('$RD1/review.json')); sys.exit(0 if any(f.get('severity')=='HIGH' for f in d.get('findings',[])) else 1)" || { echo "FAIL T1: HIGH finding not in review.json"; exit 1; }
grep -qi "review" "$RD1/decision-log.md" || { echo "FAIL T1: decision-log missing review marker"; exit 1; }
echo "PASS T1: blocking HIGH → exit 1, review.json + decision-log recorded"

# --- T2: --advisory → exit 0, findings still recorded ---
RD2="$WORK/rd2"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$HIGH_JSON" run_review "$RD2" --advisory >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || { echo "FAIL T2: --advisory should exit 0, got $rc"; exit 1; }
[ -f "$RD2/review.json" ] || { echo "FAIL T2: advisory must still record review.json"; exit 1; }
echo "PASS T2: --advisory → exit 0, findings recorded"

# --- T3: backend unavailable → skips cleanly (exit 0) ---
RD3="$WORK/rd3"
set +e; SAIL_REVIEW_CMD="/nonexistent/llm-xyz" run_review "$RD3" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || { echo "FAIL T3: unavailable backend should skip (exit 0), got $rc"; exit 1; }
echo "PASS T3: unavailable backend skips cleanly"

# --- T4: clean review (no findings) → exit 0 ---
RD4="$WORK/rd4"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" run_review "$RD4" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || { echo "FAIL T4: clean review should exit 0, got $rc"; exit 1; }
echo "PASS T4: clean review → exit 0"

# --- T5: unparseable backend output with a non-empty diff → exit 1 (never-mask), exit 0 if advisory ---
RD5="$WORK/rd5"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="this is not json" run_review "$RD5" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "1" ] || { echo "FAIL T5: unparseable output must not silently pass (expected 1), got $rc"; exit 1; }
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="this is not json" run_review "$WORK/rd5b" --advisory >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || { echo "FAIL T5: unparseable + advisory should exit 0, got $rc"; exit 1; }
echo "PASS T5: unparseable output never-masks (exit 1; advisory exit 0)"

# --- T6: parse_findings unit (fenced, bare, garbage) ---
python3 - << 'PY'
import sail.review as r
fenced = "```json\n{\"findings\":[{\"severity\":\"high\",\"issue\":\"x\"}],\"summary\":\"s\"}\n```"
bare = "{\"findings\":[{\"severity\":\"LOW\",\"issue\":\"y\"}]}"
f1 = r.parse_findings(fenced); assert f1 is not None and len(f1)==1 and f1[0]["severity"]=="HIGH", f"fenced+normalize: {f1}"
f2 = r.parse_findings(bare); assert f2 is not None and len(f2)==1, f"bare: {f2}"
assert r.parse_findings("totally not json") is None, "garbage → None"
assert r.parse_findings('{"nope":1}') is None, "missing findings key → None"
print("parse_findings unit OK")
PY
echo "PASS T6: parse_findings unit verified"
# --- T6b: strict parsing rejects smuggling (two objects / prose around content) ---
python3 - << 'PY2'
import sail.review as r
# pure object OK
assert r.parse_findings('{"findings":[{"severity":"HIGH","issue":"x"}]}') is not None
# single clean fence OK
assert r.parse_findings('```json\n{"findings":[{"severity":"LOW","issue":"y"}]}\n```') is not None
# two findings-objects → None (fail closed; the concrete smuggle vector)
assert r.parse_findings('{"findings":[]}\n{"findings":[{"severity":"HIGH","issue":"real"}]}') is None
# one findings-object wrapped in prose → parses (real backends wrap JSON in prose)
assert r.parse_findings('Here is my review:\n{"findings":[{"severity":"HIGH","issue":"x"}]}\nDone.') is not None
print("balanced parse (usable + anti-smuggle) OK")
PY2
echo "PASS T6b: strict parsing rejects smuggling"

# --- T7: backend exits non-zero (crash) with clean JSON + non-empty diff → exit 1 (never-mask) ---
RD7="$WORK/rd7"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" MOCK_RC=3 run_review "$RD7" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "1" ] || { echo "FAIL T7: backend rc!=0 must fail closed (expected 1), got $rc"; exit 1; }
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" MOCK_RC=3 run_review "$WORK/rd7b" --advisory >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || { echo "FAIL T7: backend rc!=0 + advisory should exit 0, got $rc"; exit 1; }
echo "PASS T7: backend non-zero rc fails closed (exit 1; advisory exit 0)"

# --- T8: unknown/injected severity must NOT silently downgrade — fail closed (blocks) ---
RD8="$WORK/rd8"
UNK_JSON='{"findings":[{"severity":"BLOCKER","category":"x","issue":"weird severity"}],"summary":"s"}'
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$UNK_JSON" run_review "$RD8" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "1" ] || { echo "FAIL T8: unknown severity must fail closed (expected 1), got $rc"; exit 1; }
python3 -c "import sail.review as r; f=r.parse_findings('{\"findings\":[{\"severity\":\"BLOCKER\",\"issue\":\"x\"}]}'); assert f and r.has_blocking(f), 'unknown severity must be blocking'; print('unknown-sev fail-closed OK')"
echo "PASS T8: unknown severity fails closed (blocks)"

# ============================================================================
# #47 Step 1 — plan->review traceability spine (verify against plan.json)
# ============================================================================
# Helper: write a plan.json into a run-dir before running review there.
write_plan() { mkdir -p "$1"; printf '%s' "$2" > "$1/plan.json"; }

PLAN_JSON='{"status":"completed","approach":"x","acceptance_criteria":["AC one","AC two"],"risks":[],"scope":{"in":[],"out":[]},"summary":"s"}'
# Backend returns clean findings + ac_results: one met, one unmet.
AC_MET_UNMET='{"findings":[],"summary":"ok","ac_results":[{"criterion":"AC one","status":"met","evidence":"impl present"},{"criterion":"AC two","status":"unmet","evidence":"missing"}]}'
AC_ALL_MET='{"findings":[],"summary":"ok","ac_results":[{"criterion":"AC one","status":"met","evidence":"a"},{"criterion":"AC two","status":"met","evidence":"b"}]}'

# --- T9: plan present, an unmet AC → exit 1 (spine has teeth); plan_verification recorded ---
RD9="$WORK/rd9"; write_plan "$RD9" "$PLAN_JSON"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$AC_MET_UNMET" run_review "$RD9" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "1" ] || { echo "FAIL T9: unmet AC must block (expected 1), got $rc"; exit 1; }
python3 -c "import json,sys; d=json.load(open('$RD9/review.json')); pv=d.get('plan_verification',{}); sys.exit(0 if pv.get('status')=='verified' and any(a['status']=='unmet' for a in pv.get('acceptance_criteria',[])) else 1)" || { echo "FAIL T9: plan_verification not recorded with unmet AC"; exit 1; }
grep -qi "unmet AC" "$RD9/decision-log.md" || { echo "FAIL T9: decision-log missing unmet-AC marker"; exit 1; }
echo "PASS T9: unmet AC blocks + plan_verification recorded"

# --- T9b: plan present, all ACs met, no findings → exit 0 ---
RD9b="$WORK/rd9b"; write_plan "$RD9b" "$PLAN_JSON"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$AC_ALL_MET" run_review "$RD9b" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || { echo "FAIL T9b: all ACs met + clean → exit 0, got $rc"; exit 1; }
echo "PASS T9b: all ACs met → exit 0"

# --- T10: malformed plan.json present → fail closed (exit 1, plan_verification.status=error) ---
RD10="$WORK/rd10"; write_plan "$RD10" '{"status":"completed","acceptance_criteria":[trunc'
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" run_review "$RD10" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "1" ] || { echo "FAIL T10: malformed plan.json must fail closed (expected 1), got $rc"; exit 1; }
python3 -c "import json,sys; d=json.load(open('$RD10/review.json')); sys.exit(0 if d.get('plan_verification',{}).get('status')=='error' else 1)" || { echo "FAIL T10: malformed plan not recorded as error"; exit 1; }
echo "PASS T10: malformed plan.json fails closed"

# --- T10b: NO plan.json → no-plan, non-blocking (exit 0 on clean diff) ---
RD10b="$WORK/rd10b"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" run_review "$RD10b" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || { echo "FAIL T10b: absent plan must be non-blocking (expected 0), got $rc"; exit 1; }
python3 -c "import json,sys; d=json.load(open('$RD10b/review.json')); sys.exit(0 if d.get('plan_verification',{}).get('status')=='no-plan' else 1)" || { echo "FAIL T10b: absent plan not recorded as no-plan"; exit 1; }
echo "PASS T10b: absent plan → no-plan, non-blocking"

# --- T10c: load_plan_acs unit (absent / malformed / ok-completed / skipped) ---
python3 - "$WORK" << 'PY'
import os, sys
import sail.review as r
work = sys.argv[1]
d_absent = os.path.join(work, "pa_absent"); os.makedirs(d_absent, exist_ok=True)
assert r.load_plan_acs(d_absent) == (None, "absent"), "absent"
d_mal = os.path.join(work, "pa_mal"); os.makedirs(d_mal, exist_ok=True)
open(os.path.join(d_mal, "plan.json"), "w").write("{not json")
assert r.load_plan_acs(d_mal) == (None, "malformed"), "malformed"
d_ok = os.path.join(work, "pa_ok"); os.makedirs(d_ok, exist_ok=True)
open(os.path.join(d_ok, "plan.json"), "w").write('{"status":"completed","acceptance_criteria":["x","y"]}')
acs, st = r.load_plan_acs(d_ok); assert acs == ["x", "y"] and st == "ok", (acs, st)
d_skip = os.path.join(work, "pa_skip"); os.makedirs(d_skip, exist_ok=True)
open(os.path.join(d_skip, "plan.json"), "w").write('{"status":"skipped"}')
assert r.load_plan_acs(d_skip) == (None, "ok"), "skipped→ok/no-acs"
print("load_plan_acs unit OK")
PY
echo "PASS T10c: load_plan_acs unit verified"

# ============================================================================
# #47 Step 2 — per-finding stable ids + disposition passthrough in review.json
# ============================================================================
# --- T11: findings in review.json carry a content-derived stable id (lens-prefixed),
#          stable across reordering; backend-supplied disposition/rationale pass through ---
RD11="$WORK/rd11"
DISP_JSON='{"findings":[{"severity":"HIGH","category":"correctness","file":"mod.py","issue":"bug A","recommendation":"fix A","disposition":"deferred","rationale":"tracked separately"}],"summary":"1 high"}'
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$DISP_JSON" run_review "$RD11" >/dev/null 2>&1; set -e
python3 -c "
import json,sys
d=json.load(open('$RD11/review.json'))
f=d['findings'][0]
assert isinstance(f.get('id'),str) and f['id'].startswith('lens1-') and len(f['id'])>6, f.get('id')
assert f.get('disposition')=='deferred' and f.get('rationale')=='tracked separately', f
print('id+disposition OK:', f['id'])
" || { echo "FAIL T11: finding id / disposition passthrough"; exit 1; }
echo "PASS T11: stable content-derived finding id + disposition passthrough"

# --- T11b: _finding_id is content-stable, order-independent, and line/category-disambiguated ---
python3 - << 'PY'
import sail.review as r
a={"issue":"bug A","file":"x.py","line":1,"severity":"HIGH","category":"correctness"}
b={"issue":"bug B","file":"y.py","line":2,"severity":"LOW","category":"design"}
# same content → same id regardless of dict construction order
a2={"category":"correctness","severity":"HIGH","line":1,"file":"x.py","issue":"bug A"}
assert r._finding_id(a)==r._finding_id(a2), "id not content-stable"
assert r._finding_id(a)!=r._finding_id(b), "distinct findings collided"
# lens prefix disambiguates the dual-lens union
assert r._finding_id(a,"lens1")!=r._finding_id(a,"lens2"), "lens not in id"
# Gate F MED-2: findings differing ONLY in line/category must NOT collide
c1={"issue":"same","file":"f.py","line":10,"severity":"HIGH","category":"correctness"}
c2={"issue":"same","file":"f.py","line":99,"severity":"HIGH","category":"correctness"}
c3={"issue":"same","file":"f.py","line":10,"severity":"HIGH","category":"design"}
assert len({r._finding_id(c1),r._finding_id(c2),r._finding_id(c3)})==3, "line/category collision"
print("finding-id stability unit OK")
PY
echo "PASS T11b: finding-id content-stable + lens-disambiguated + line/category-distinct"

# --- T11c: Gate F MED-1 — a backend-supplied id/lens MUST be overwritten (not attacker-controlled) ---
RD11c="$WORK/rd11c"
ATTACK_JSON='{"findings":[{"severity":"HIGH","file":"m.py","issue":"x","id":"ATTACKER","lens":"evil"}],"summary":"s"}'
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$ATTACK_JSON" run_review "$RD11c" >/dev/null 2>&1; set -e
python3 -c "
import json,sys
f=json.load(open('$RD11c/review.json'))['findings'][0]
assert f['id']!='ATTACKER' and f['id'].startswith('lens1-'), f.get('id')
assert f['lens']=='lens1', f.get('lens')
print('id/lens overwrite OK')
" || { echo "FAIL T11c: backend-supplied id/lens not overwritten"; exit 1; }
echo "PASS T11c: backend-supplied id/lens overwritten (Gate F MED-1)"

# --- T11d: review rounds log the advisory-finding count in the decision log. ---
RD11d="$WORK/rd11d"
ADVISORY_JSON='{"findings":[{"severity":"LOW","category":"design","file":"mod.py","issue":"minor nudge","recommendation":"maybe rename"},{"severity":"MEDIUM","category":"scope","file":"mod.py","issue":"could be narrower","recommendation":"consider trimming"}],"summary":"2 advisory"}'
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$ADVISORY_JSON" run_review "$RD11d" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "0" ] || { echo "FAIL T11d: advisory findings should not block, got $rc"; exit 1; }
grep -q 'advisory-findings \[round=1\]: 2' "$RD11d/decision-log.md" || { echo "FAIL T11d: advisory count not recorded in decision log"; exit 1; }
echo "PASS T11d: run_review logs the advisory-finding count for the round"

# ============================================================================
# #47 Step 3 — --dual-lens risk-gated second-lens escalation
# ============================================================================
# Second mock lens: echoes $MOCK2_OUT (separate env so the two lenses can differ).
MOCK2="$WORK/mock_llm2.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "%s" "${MOCK2_OUT:-}"' 'exit ${MOCK2_RC:-0}' > "$MOCK2"
chmod +x "$MOCK2"

# --- T12: --dual-lens, lens1 clean but lens2 finds HIGH → exit 1 (block if EITHER blocks);
#          review.json records lenses:[lens1,lens2] and the lens2 finding ---
RD12="$WORK/rd12"
LENS2_HIGH='{"findings":[{"severity":"HIGH","category":"security","file":"mod.py","issue":"lens2 caught injection","recommendation":"sanitize"}],"summary":"1 high"}'
set +e
SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" \
  SAIL_REVIEW_CMD2="env MOCK2_OUT=$(printf %q "$LENS2_HIGH") bash $MOCK2" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD12" --dual-lens >/dev/null 2>&1
rc=$?; set -e
[ "$rc" = "1" ] || { echo "FAIL T12: dual-lens must block when lens2 blocks (expected 1), got $rc"; exit 1; }
python3 -c "
import json,sys
d=json.load(open('$RD12/review.json'))
assert d.get('lenses')==['lens1','lens2'], d.get('lenses')
assert any(f.get('lens')=='lens2' and f.get('severity')=='HIGH' for f in d['findings']), d['findings']
print('dual-lens union OK')
" || { echo "FAIL T12: lenses/union not recorded"; exit 1; }
echo "PASS T12: --dual-lens unions findings, blocks if either lens blocks"

# --- T12b: --dual-lens with NO second backend → degrades to single-lens cleanly (exit 0 on clean) ---
RD12b="$WORK/rd12b"
set +e
( unset SAIL_REVIEW_CMD2; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD12b" --dual-lens >/dev/null 2>&1 )
rc=$?; set -e
[ "$rc" = "0" ] || { echo "FAIL T12b: dual-lens w/o 2nd backend should degrade clean (expected 0), got $rc"; exit 1; }
python3 -c "import json,sys; d=json.load(open('$RD12b/review.json')); sys.exit(0 if d.get('lenses')==['lens1'] else 1)" || { echo "FAIL T12b: should stay single-lens"; exit 1; }
echo "PASS T12b: --dual-lens with no second backend degrades to single-lens"

# --- T12c: no --dual-lens flag → byte-identical single-lens (only lens1, no lens2 even if CMD2 set) ---
RD12c="$WORK/rd12c"
set +e
SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" \
  SAIL_REVIEW_CMD2="env MOCK2_OUT=$(printf %q "$LENS2_HIGH") bash $MOCK2" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD12c" >/dev/null 2>&1
rc=$?; set -e
[ "$rc" = "0" ] || { echo "FAIL T12c: single-lens default must ignore CMD2 (expected 0), got $rc"; exit 1; }
python3 -c "import json,sys; d=json.load(open('$RD12c/review.json')); sys.exit(0 if d.get('lenses')==['lens1'] and len(d['findings'])==0 else 1)" || { echo "FAIL T12c: default ran second lens unexpectedly"; exit 1; }
echo "PASS T12c: default is single-lens (CMD2 ignored without --dual-lens)"

# --- T13: dual-lens AC reconciliation (Gate F HIGH-2) — lens1 says AC met, lens2 says unmet
#          → the unmet must propagate to plan_verification and BLOCK (either lens blocks) ---
RD13="$WORK/rd13"; write_plan "$RD13" "$PLAN_JSON"
L1_AC_MET='{"findings":[],"summary":"ok","ac_results":[{"criterion":"AC one","status":"met","evidence":"l1"},{"criterion":"AC two","status":"met","evidence":"l1"}]}'
L2_AC_UNMET='{"findings":[],"summary":"ok","ac_results":[{"criterion":"AC one","status":"met","evidence":"l2"},{"criterion":"AC two","status":"unmet","evidence":"l2 found it missing"}]}'
set +e
SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$L1_AC_MET" \
  SAIL_REVIEW_CMD2="env MOCK2_OUT=$(printf %q "$L2_AC_UNMET") bash $MOCK2" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD13" --dual-lens >/dev/null 2>&1
rc=$?; set -e
[ "$rc" = "1" ] || { echo "FAIL T13: lens2-only unmet AC must block in dual-lens (expected 1), got $rc"; exit 1; }
python3 -c "
import json,sys
d=json.load(open('$RD13/review.json'))
acs=d['plan_verification']['acceptance_criteria']
assert any(a['criterion']=='AC two' and a['status']=='unmet' for a in acs), acs
print('dual-lens AC reconciliation OK')
" || { echo "FAIL T13: lens2 unmet AC not reconciled into plan_verification"; exit 1; }
echo "PASS T13: dual-lens AC reconciliation — lens2-only unmet AC blocks (Gate F HIGH-2)"

# --- T13b: _reconcile_ac_results unit (unmet wins; met over unknown; None lenses ignored) ---
python3 - << 'PY'
import sail.review as r
acs=["A","B","C"]
l1=[{"criterion":"A","status":"met"},{"criterion":"B","status":"met"},{"criterion":"C","status":"unknown"}]
l2=[{"criterion":"A","status":"unmet"},{"criterion":"B","status":"unknown"},{"criterion":"C","status":"met"}]
out={x["criterion"]:x["status"] for x in r._reconcile_ac_results(acs,[l1,l2])}
assert out=={"A":"unmet","B":"met","C":"met"}, out
# None lenses contribute nothing
out2={x["criterion"]:x["status"] for x in r._reconcile_ac_results(["A"],[None,[{"criterion":"A","status":"met"}]])}
assert out2=={"A":"met"}, out2
print("reconcile unit OK")
PY
echo "PASS T13b: _reconcile_ac_results unit verified"

# --- T20: test-adequacy probe (#70) — REVIEW_PROMPT carries the mutation-survival probe and
#          the 'test-adequacy' category, and the no-op-on-test-free-diff instruction. ---
python3 - << 'PY'
import sail.review as r
p = r.build_prompt("--- a/x.py\n+++ b/x.py\n@@ -1 +1 @@\n-old\n+new\n", acs=["AC one"])
assert "test-adequacy" in p, "category enum must list test-adequacy"
assert "mutation" in p.lower(), "probe must name a plausible mutation"
assert "vacuous" in p.lower() and "tautological" in p.lower(), "probe must flag vacuous/tautological tests"
assert "changes no test behavior" in p, "probe must no-op on test-free diffs"
print("test-adequacy probe OK")
PY
echo "PASS T20: test-adequacy probe (#70) present in REVIEW_PROMPT"

echo "PASS: sail LLM-reviewer (#38) + plan-spine (#47 step 1) + resolution-ids (#47 step 2) + dual-lens (#47 step 3) + Gate-F fixes (HIGH-1/2) + test-adequacy probe (#70) verified"
