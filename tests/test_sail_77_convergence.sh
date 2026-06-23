#!/usr/bin/env bash
# test_sail_77_convergence.sh
# Issue #77 — codify autonomous-mode convergence discipline (rules + code enforcement).
#   Gap 1: a plan risk the driver marks "self-mitigated" (with a rationale) must not block the
#          plan gate; without a rationale it MUST still block (no laundering).
#   Gap 2: a deterministic convergence oracle (`sail converge`) the autonomous driver consults —
#          rc 0 => proceed (stop at green; LOWs never chased), rc!=0 under cap => revise,
#          rc!=0 at the 3-round cap => park.
# Hermetic: no live backend; pure-function imports + a mock plan backend.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
LOG_FILE="$TMP_ROOT/python.log"
SAIL_MD="$REPO_ROOT/commands/sail.md"
SURF_MD="$REPO_ROOT/commands/surf.md"

cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  [ -s "$LOG_FILE" ] && { echo "---- python output ----" >&2; sed 's/^/  /' "$LOG_FILE" >&2; echo "-----------------------" >&2; }
  exit 1
}

cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# T1 — `sail converge` oracle: rc + round -> proceed | revise | park
# ---------------------------------------------------------------------------
converge() { python3 -m sail converge "$@" 2>"$LOG_FILE"; }

out=$(converge --rc 0 --round 1) || fail "converge --rc 0 --round 1 exited non-zero"
[ "$out" = "proceed" ] || fail "rc 0 should be 'proceed', got '$out'"

out=$(converge --rc 1 --round 1) || fail "converge --rc 1 --round 1 exited non-zero"
[ "$out" = "revise" ] || fail "rc 1 round 1 should be 'revise', got '$out'"

out=$(converge --rc 1 --round 3) || fail "converge --rc 1 --round 3 exited non-zero"
[ "$out" = "park" ] || fail "rc 1 round 3 (default cap 3) should be 'park', got '$out'"

# LOW-only review keeps the gate green (rc 0) -> the oracle never asks for another round.
out=$(converge --rc 0 --round 2) || fail "converge rc 0 round 2 exited non-zero"
[ "$out" = "proceed" ] || fail "green light at round 2 must still 'proceed' (LOWs not chased), got '$out'"

# --max-rounds override: a higher cap keeps revising past round 3.
out=$(converge --rc 1 --round 4 --max-rounds 5) || fail "converge --max-rounds 5 exited non-zero"
[ "$out" = "revise" ] || fail "rc 1 round 4 with cap 5 should be 'revise', got '$out'"
out=$(converge --rc 1 --round 5 --max-rounds 5) || fail "converge --max-rounds 5 at cap exited non-zero"
[ "$out" = "park" ] || fail "rc 1 round 5 with cap 5 should be 'park', got '$out'"

# Any non-zero rc (not just 1) is "not green".
out=$(converge --rc 127 --round 1) || fail "converge --rc 127 exited non-zero"
[ "$out" = "revise" ] || fail "rc 127 round 1 should be treated as not-green ('revise'), got '$out'"

# ---------------------------------------------------------------------------
# T2 — effective_blocking_risks pure function (sail.plan)
# ---------------------------------------------------------------------------
if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
from sail.plan import effective_blocking_risks

# A HIGH risk validly marked self-mitigated (disposition + non-empty rationale) is defused.
defused = effective_blocking_risks([
    {"severity": "HIGH", "issue": "isolation check defeated by re-augmentation",
     "disposition": "self-mitigated", "rationale": "plan's code-seam remedy already delivers the escape hatch"},
])
assert defused == [], f"validly self-mitigated HIGH should not block, got {defused!r}"

# Fail-safe: self-mitigated tag WITHOUT a rationale still blocks (no laundering).
blocked = effective_blocking_risks([
    {"severity": "HIGH", "issue": "x", "disposition": "self-mitigated", "rationale": ""},
])
assert len(blocked) == 1, f"self-mitigated without rationale must still block, got {blocked!r}"

# Fail-safe: missing rationale key entirely still blocks.
blocked = effective_blocking_risks([
    {"severity": "CRITICAL", "issue": "y", "disposition": "self-mitigated"},
])
assert len(blocked) == 1, f"self-mitigated without rationale key must still block, got {blocked!r}"

# An undispositioned HIGH/CRITICAL still blocks.
blocked = effective_blocking_risks([
    {"severity": "HIGH", "issue": "z"},
    {"severity": "CRITICAL", "issue": "w"},
])
assert len(blocked) == 2, f"undispositioned HIGH+CRITICAL must block, got {blocked!r}"

# LOW/MEDIUM never appear in blocking, dispositioned or not.
assert effective_blocking_risks([
    {"severity": "LOW", "issue": "a"}, {"severity": "MEDIUM", "issue": "b"},
]) == [], "LOW/MEDIUM must never block"

# A disposition value other than self-mitigated does NOT defuse a HIGH.
blocked = effective_blocking_risks([
    {"severity": "HIGH", "issue": "c", "disposition": "deferred", "rationale": "later"},
])
assert len(blocked) == 1, f"non-self-mitigated disposition must still block, got {blocked!r}"
print("ok")
PY
then
  fail "sail.plan.effective_blocking_risks not implemented / failed assertions"
fi
grep -q '^ok$' "$LOG_FILE" || fail "effective_blocking_risks test did not reach 'ok'"

# ---------------------------------------------------------------------------
# T3 — run_plan integration: a driver-set self-mitigated HIGH no longer blocks the gate
# ---------------------------------------------------------------------------
MOCK="$TMP_ROOT/mock_backend.sh"
cat > "$MOCK" <<'MOCK_EOF'
#!/usr/bin/env bash
cat >/dev/null   # discard stdin (the spec)
printf '%s' "$MOCK_OUT"
MOCK_EOF
chmod +x "$MOCK"

SPEC="Add a feature with a tricky isolation property."

# Plan whose ONLY blocking risk carries a driver-set self-mitigation disposition -> gate passes (exit 0).
MITIGATED_JSON='{"approach":"do the thing via a code seam","acceptance_criteria":["works"],"test_plan":["t"],"risks":[{"severity":"HIGH","issue":"isolation defeated by re-augmentation","disposition":"self-mitigated","rationale":"the code-seam remedy in the approach already delivers the escape hatch"}],"scope":{"in":[],"out":[]},"summary":"s"}'
RD1="$TMP_ROOT/rd1"
set +e
printf '%s' "$SPEC" | SAIL_PLAN_CMD="bash $MOCK" MOCK_OUT="$MITIGATED_JSON" \
  python3 -m sail plan --target "$REPO_ROOT" --run-dir "$RD1" >"$LOG_FILE" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "run_plan with a self-mitigated-only blocking risk should exit 0, got rc=$rc"
# Disposition is recorded for audit (payload + decision log).
python3 - "$RD1/plan.json" <<'PY' >>"$LOG_FILE" 2>&1 || fail "self_mitigated not recorded in plan.json payload"
import json, sys
data = json.load(open(sys.argv[1]))
sm = data.get("self_mitigated") or []
assert len(sm) == 1, f"expected 1 self_mitigated risk recorded, got {sm!r}"
PY
grep -q 'self-mitigated' "$RD1/decision-log.md" || fail "decision-log.md should record the self-mitigated disposition"

# Control: the SAME risk WITHOUT a disposition still blocks (exit 1) — proves the gate is real.
UNMITIGATED_JSON='{"approach":"do the thing","acceptance_criteria":["works"],"test_plan":["t"],"risks":[{"severity":"HIGH","issue":"isolation defeated by re-augmentation"}],"scope":{"in":[],"out":[]},"summary":"s"}'
RD2="$TMP_ROOT/rd2"
set +e
printf '%s' "$SPEC" | SAIL_PLAN_CMD="bash $MOCK" MOCK_OUT="$UNMITIGATED_JSON" \
  python3 -m sail plan --target "$REPO_ROOT" --run-dir "$RD2" >>"$LOG_FILE" 2>&1
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "run_plan with an undispositioned HIGH should still exit 1, got rc=$rc"

# ---------------------------------------------------------------------------
# T4 — commands/sail.md documents the autonomous-mode convergence rubric
# ---------------------------------------------------------------------------
assert_md() { grep -qiE "$1" "$2" || fail "$3"; }
assert_md 'autonomous.{0,40}convergence|convergence.{0,40}rubric' "$SAIL_MD" "sail.md missing the autonomous-mode convergence rubric heading"
assert_md 'self-mitigat' "$SAIL_MD" "sail.md rubric missing the self-mitigated-risk rule"
assert_md 'exit 0|exit code 0|green' "$SAIL_MD" "sail.md rubric missing the exit-0/green stop signal"
assert_md 'sail converge' "$SAIL_MD" "sail.md rubric must reference the sail converge oracle"
assert_md '3[ -]round|three[ -]round|round cap' "$SAIL_MD" "sail.md rubric missing the 3-round cap"
assert_md 'park' "$SAIL_MD" "sail.md rubric missing the PARK backstop"

# ---------------------------------------------------------------------------
# T5 — commands/surf.md points the autonomous driver at the rubric
# ---------------------------------------------------------------------------
assert_md 'convergence|sail converge' "$SURF_MD" "surf.md missing a pointer to the convergence rubric"

echo "PASS: test_sail_77_convergence.sh"
