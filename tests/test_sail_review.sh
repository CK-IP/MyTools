#!/usr/bin/env bash
# test_sail_review.sh — issue #38: LLM-reviewer layer (hermetic, mock LLM CLI).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"

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

echo "PASS: sail LLM-reviewer (#38) verified"
