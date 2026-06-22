#!/usr/bin/env bash
# test_sail_80_code_health.sh — issue #80: code-health (simplicity + efficiency) check with
# marginal-value TIERED enforcement. Upgrades the #63 advisory tidiness lens so EGREGIOUS
# code-health defects can BLOCK, but only when justified:
#   Gear 1 (generation): the tidiness lens tags each finding by tier (block|advisory).
#   Gear 2 (verification): a block-tier finding gets teeth ONLY if an independent cross-family
#                          (Codex) lens confirms it.
#   Gear 3 (fix-and-recheck): confirmed block-tier findings enter the blocking exit-code path.
# Efficiency FP guardrail: a block-tier efficiency finding must state (a) current complexity,
#   (b) concrete cheaper alternative, (c) why path is hot/reachable — else demoted to advisory.
# Degrades cleanly: no verify backend / empty diff / size-gated → advisory, never a blocked run.
# Lens separation: code-health stays its OWN lens (the tidiness block), never folded into the
#   correctness `findings`/`counts`.
# Hermetic per #64: mocks every backend (SAIL_REVIEW_CMD / SAIL_TIDINESS_CMD / SAIL_TIDINESS_VERIFY_CMD)
# and uses throwaway git targets. Never calls a real CLI; never asserts against live git state.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
export SAIL_CHECKERS=ruff,pytest
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"

fail() { echo "FAIL: $*"; exit 1; }

# Mock LLM: discards stdin, emits $MOCK_OUT (named by $2), exits ${RC:-0}.
mk_mock() { # $1=path $2=outvar-env-name
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' "printf '%s' \"\${$2:-}\"" 'exit ${RC:-0}' > "$1"
  chmod +x "$1"
}
REVIEW_MOCK="$WORK/review_mock.sh"; mk_mock "$REVIEW_MOCK" REVIEW_OUT
TIDY_MOCK="$WORK/tidy_mock.sh";     mk_mock "$TIDY_MOCK"   TIDY_OUT

# Cross-family verifier mock (Gear 2): reads the prompt on stdin, echoes back a verdict for EVERY
# candidate id it sees, confirmed=${CONFIRM:-true}. This exercises the real content-derived id
# round-trip (production matches verdicts to findings by id) without hard-coding a hash.
VERIFY_MOCK="$WORK/verify_mock.sh"
cat > "$VERIFY_MOCK" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
in="$(cat)"
IN="$in" python3 - <<'PY'
import os, re, json
text = os.environ["IN"]
ids = re.findall(r'"id":\s*"([^"]+)"', text)
conf = os.environ.get("CONFIRM", "true") == "true"
print(json.dumps({"verdicts": [{"id": i, "confirmed": conf, "reason": "mock"} for i in ids]}))
PY
EOF
chmod +x "$VERIFY_MOCK"

# Clean git target with a multi-line working-tree change (gates pass; diff non-empty).
new_target() { # $1=dir
  mkdir -p "$1"
  printf 'def f():\n    return 1\n' > "$1/mod.py"
  git -C "$1" init -q
  git -C "$1" add -A
  git -C "$1" -c user.email=t@t -c user.name=t commit -qm base
  printf 'def f():\n    x = 1\n    y = 2\n    return x + y  # changed\n' > "$1/mod.py"
}

CLEAN='{"findings":[],"summary":"no issues"}'
TIDY_TIDY='{"findings":[],"summary":"tidy"}'

# Block-tier EASY WIN (dead code) — no efficiency justification needed.
BLOCK_DEADCODE='{"findings":[{"severity":"LOW","tier":"block","category":"simplification","file":"mod.py","line":2,"issue":"dead local x/y never used after inline","recommendation":"return 1+2"}],"summary":"1"}'
# Block-tier EFFICIENCY WITH the 3-part justification (block-eligible).
EFF_BLOCK_OK='{"findings":[{"severity":"LOW","tier":"block","category":"efficiency","file":"mod.py","line":2,"issue":"re-sorts the list on every call","recommendation":"sort once before the loop","current_complexity":"O(n^2) over the request list","cheaper_alternative":"sort once before the loop (O(n log n))","hot_path_reason":"runs per-request on the API hot path"}],"summary":"1"}'
# Block-tier EFFICIENCY MISSING the 3-part justification (must be demoted by the guardrail).
EFF_BLOCK_BAD='{"findings":[{"severity":"LOW","tier":"block","category":"efficiency","file":"mod.py","line":2,"issue":"feels slow","recommendation":"make it faster"}],"summary":"1"}'
# Advisory-tier finding (diminishing-returns polish) — must NEVER block.
ADVISORY='{"findings":[{"severity":"MEDIUM","tier":"advisory","category":"naming","file":"mod.py","line":2,"issue":"x/y could be named better","recommendation":"rename"}],"summary":"1"}'

py_tidiness() { # $1=review.json — print compact tidiness block facts
  python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
t = d.get("tidiness") or {}
print("status=%s nfind=%d nblock=%d" % (
    t.get("status"), len(t.get("findings", [])), len(t.get("blocking", []))))
# code-health must NEVER pollute the correctness lens (strict lens-separation).
assert d.get("findings") == [], "code-health leaked into blocking correctness findings"
assert d["counts"]["HIGH"] == 0 and d["counts"]["CRITICAL"] == 0, "code-health leaked into counts"
PY
}

run_sail() { # env vars pre-set by caller; $1=target $2=run-dir ; returns rc in global RC_OUT
  set +e
  python3 -m sail run --target "$1" --diff HEAD --run-dir "$2" --tidiness >/dev/null 2>&1
  RC_OUT=$?
  set -e
}

# --- T1: confirmed block-tier EASY WIN blocks (Gear 1 tags block, Gear 2 confirms, Gear 3 blocks). ---
TGT="$WORK/t1"; new_target "$TGT"; RD="$WORK/rd1"
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="bash $TIDY_MOCK" TIDY_OUT="$BLOCK_DEADCODE" \
SAIL_TIDINESS_VERIFY_CMD="bash $VERIFY_MOCK" CONFIRM=true \
  run_sail "$TGT" "$RD"
[ "$RC_OUT" = "1" ] || fail "T1: confirmed block-tier code-health finding must block (expected 1), got $RC_OUT"
facts=$(py_tidiness "$RD/review.json") || fail "T1: lens-separation violated"
echo "$facts" | grep -q "nblock=1" || fail "T1: expected 1 blocking code-health finding ($facts)"
echo "PASS T1: confirmed block-tier easy-win blocks the run (3-gear path)"

# --- T2: block-tier candidate that the cross-family verifier does NOT confirm → demoted, no block. ---
TGT="$WORK/t2"; new_target "$TGT"; RD="$WORK/rd2"
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="bash $TIDY_MOCK" TIDY_OUT="$BLOCK_DEADCODE" \
SAIL_TIDINESS_VERIFY_CMD="bash $VERIFY_MOCK" CONFIRM=false \
  run_sail "$TGT" "$RD"
[ "$RC_OUT" = "0" ] || fail "T2: an UNCONFIRMED block-tier finding must NOT block (expected 0), got $RC_OUT"
echo "$(py_tidiness "$RD/review.json")" | grep -q "nblock=0" || fail "T2: unconfirmed finding still recorded as blocking"
echo "PASS T2: Gear-2 cross-family non-confirmation demotes to advisory (no false-positive block)"

# --- T3: block-tier EFFICIENCY missing the 3-part justification → guardrail demotes (no block,
#         verifier never consulted). ---
TGT="$WORK/t3"; new_target "$TGT"; RD="$WORK/rd3"
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="bash $TIDY_MOCK" TIDY_OUT="$EFF_BLOCK_BAD" \
SAIL_TIDINESS_VERIFY_CMD="bash $VERIFY_MOCK" CONFIRM=true \
  run_sail "$TGT" "$RD"
[ "$RC_OUT" = "0" ] || fail "T3: unjustified efficiency block must be DEMOTED, not block (expected 0), got $RC_OUT"
python3 - "$RD/review.json" <<'PY' || fail "T3: guardrail did not demote the unjustified efficiency finding"
import json, sys
t = json.load(open(sys.argv[1]))["tidiness"]
assert not t.get("blocking"), "unjustified efficiency finding blocked"
f = t["findings"][0]
assert f.get("tier") == "advisory", f"expected demotion to advisory, got tier={f.get('tier')}"
assert "demoted" in f, "demotion not recorded on the finding"
PY
echo "PASS T3: efficiency guardrail demotes a block finding missing complexity/alternative/hot-path"

# --- T4: block-tier EFFICIENCY WITH full 3-part justification + verifier confirms → blocks. ---
TGT="$WORK/t4"; new_target "$TGT"; RD="$WORK/rd4"
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="bash $TIDY_MOCK" TIDY_OUT="$EFF_BLOCK_OK" \
SAIL_TIDINESS_VERIFY_CMD="bash $VERIFY_MOCK" CONFIRM=true \
  run_sail "$TGT" "$RD"
[ "$RC_OUT" = "1" ] || fail "T4: a justified+confirmed efficiency block must block (expected 1), got $RC_OUT"
echo "$(py_tidiness "$RD/review.json")" | grep -q "nblock=1" || fail "T4: justified efficiency block not recorded"
echo "PASS T4: justified + confirmed egregious efficiency defect blocks the run"

# --- T5: block-tier candidate but NO cross-family verify backend → degrades to advisory (clean). ---
TGT="$WORK/t5"; new_target "$TGT"; RD="$WORK/rd5"
# Neither SAIL_TIDINESS_VERIFY_CMD nor SAIL_REVIEW_CMD2 set → no verifier available.
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="bash $TIDY_MOCK" TIDY_OUT="$BLOCK_DEADCODE" \
  run_sail "$TGT" "$RD"
[ "$RC_OUT" = "0" ] || fail "T5: no verify backend must degrade cleanly (advisory), got $RC_OUT"
python3 - "$RD/review.json" <<'PY' || fail "T5: missing verifier did not degrade to advisory"
import json, sys
t = json.load(open(sys.argv[1]))["tidiness"]
assert not t.get("blocking"), "blocked with no cross-family verifier available"
assert t["findings"][0].get("tier") == "advisory", "candidate not demoted without a verifier"
PY
echo "PASS T5: a block candidate with no cross-family verifier degrades to advisory (never blocks)"

# --- T6: advisory-tier finding NEVER blocks and NEVER triggers verification (regression guard). ---
TGT="$WORK/t6"; new_target "$TGT"; RD="$WORK/rd6"
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="bash $TIDY_MOCK" TIDY_OUT="$ADVISORY" \
SAIL_TIDINESS_VERIFY_CMD="bash $VERIFY_MOCK" CONFIRM=true \
  run_sail "$TGT" "$RD"
[ "$RC_OUT" = "0" ] || fail "T6: advisory-tier finding must never block (expected 0), got $RC_OUT"
echo "$(py_tidiness "$RD/review.json")" | grep -q "nfind=1 nblock=0" || fail "T6: advisory finding recorded wrong"
echo "PASS T6: advisory-tier polish never touches the exit code (existing behavior preserved)"

# --- T7: a clean/tidy diff → no blocking, NO verification cost, exit 0. ---
TGT="$WORK/t7"; new_target "$TGT"; RD="$WORK/rd7"
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="bash $TIDY_MOCK" TIDY_OUT="$TIDY_TIDY" \
SAIL_TIDINESS_VERIFY_CMD="bash $VERIFY_MOCK" CONFIRM=true \
  run_sail "$TGT" "$RD"
[ "$RC_OUT" = "0" ] || fail "T7: a clean diff must not block (expected 0), got $RC_OUT"
python3 - "$RD/review.json" <<'PY' || fail "T7: clean diff produced a blocking/verification artifact"
import json, sys
t = json.load(open(sys.argv[1]))["tidiness"]
assert not t.get("blocking"), "clean diff blocked"
assert "verification" not in t, "clean diff paid verification cost (Gear-2 should not fire)"
PY
echo "PASS T7: clean diff → no extra round, no verification cost, no block"

# --- T8: resume re-block — a cached review.json with tidiness.blocking must STILL block on reuse
#         (the runner recompute path must honor code-health blocking, not just findings/ACs). ---
TGT="$WORK/t8"; new_target "$TGT"; RD="$WORK/rd8"
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="bash $TIDY_MOCK" TIDY_OUT="$BLOCK_DEADCODE" \
SAIL_TIDINESS_VERIFY_CMD="bash $VERIFY_MOCK" CONFIRM=true \
  run_sail "$TGT" "$RD"
[ "$RC_OUT" = "1" ] || fail "T8: first run must block, got $RC_OUT"
# Resume the SAME scope WITH --tidiness (reuse path). No backends needed — reuse recomputes.
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="bash $TIDY_MOCK" TIDY_OUT="$BLOCK_DEADCODE" \
SAIL_TIDINESS_VERIFY_CMD="bash $VERIFY_MOCK" CONFIRM=true \
  run_sail "$TGT" "$RD"
[ "$RC_OUT" = "1" ] || fail "T8: resumed run reused the cache but DROPPED the code-health block, got $RC_OUT"
echo "PASS T8: a cached code-health block still blocks on resume (recompute honors it)"

# --- T9 (plan-time, shift-left): build_prompt carries a code-health item in the plan self-check. ---
python3 - <<'PY' || fail "T9: plan self-check is missing the code-health item"
from sail.plan import build_prompt
p = build_prompt("Some spec").lower()
assert "code-health" in p or "code health" in p, "no code-health item in the plan self-check"
# It must speak to BOTH simplicity (materially-simpler shape) and efficiency (worse algorithm).
assert "algorithm" in p or "data-structure" in p or "data structure" in p, "no algorithm/data-structure probe"
assert "simpler" in p, "no materially-simpler-shape probe"
PY
echo "PASS T9: plan self-check (#58) gains a code-health item (no new plan lens)"

# --- T10: code-health blocking is gated on --tidiness — a run WITHOUT --tidiness never blocks
#          on code health (and writes no tidiness block). ---
TGT="$WORK/t10"; new_target "$TGT"; RD="$WORK/rd10"
set +e
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="bash $TIDY_MOCK" TIDY_OUT="$BLOCK_DEADCODE" \
SAIL_TIDINESS_VERIFY_CMD="bash $VERIFY_MOCK" CONFIRM=true \
  python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] || fail "T10: without --tidiness the run must not block on code health, got $rc"
python3 -c "import json,sys; sys.exit(0 if json.load(open('$RD/review.json')).get('tidiness') is None else 1)" \
  || fail "T10: tidiness block present without --tidiness"
echo "PASS T10: code-health enforcement is opt-in via --tidiness (absent by default)"

echo "ALL PASS: test_sail_80_code_health.sh"
