#!/usr/bin/env bash
# test_sail_156_converge_gate_audit.sh
# Issue #156 — `sail converge` must not report `proceed` on rc=0 when the run-state gate audit
# is red. Green run-state fixtures still proceed, and the existing green hardening terminus must
# stay unchanged.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
LOG_FILE="$TMP_ROOT/stderr.log"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  [ -s "$LOG_FILE" ] && { echo "---- stderr ----" >&2; sed 's/^/  /' "$LOG_FILE" >&2; echo "----------------" >&2; }
  exit 1
}

converge() {
  python3 -m sail converge "$@" 2>"$LOG_FILE"
}

cd "$REPO_ROOT"
# Hermetic (.ship/domain.md #102): a real shell exports SAIL_* codex knobs; clear them so this
# test controls its own backend and only the fixtures below matter.
unset "${!SAIL_@}"
export PYTHONPATH="$REPO_ROOT${PYTHONPATH:+:$PYTHONPATH}"

FAILED_RUN="$TMP_ROOT/failed-gate"
mkdir -p "$FAILED_RUN"
cat >"$FAILED_RUN/run-state.json" <<'JSON'
{"gates":[{"name":"ruff","status":"failed"}]}
JSON

GREEN_RUN="$TMP_ROOT/green-gate"
mkdir -p "$GREEN_RUN"
cat >"$GREEN_RUN/run-state.json" <<'JSON'
{"gates":[{"name":"ruff","status":"passed","new_failures":0},{"name":"mypy","status":"skipped","new_findings_count":0}]}
JSON

# AC1: rc=0 + red run-state gate falls through to the normal loop path and revises, not proceeds.
out=$(converge --rc 0 --round 1 --run-dir "$FAILED_RUN") || fail "rc0 red-gate converge exited non-zero"
[ "$out" = "revise" ] || fail "rc 0 with a red gate should revise, got '$out'"
grep -q 'gate-not-green' "$LOG_FILE" || fail "red-gate stderr reason missing gate-not-green"
grep -q 'rc=0' "$LOG_FILE" || fail "red-gate stderr reason missing rc=0"
grep -q 'not passed/skipped' "$LOG_FILE" || fail "red-gate stderr reason missing not-passed/skipped phrasing"

# AC2: rc=0 + green run-state gate still proceeds.
out=$(converge --rc 0 --round 1 --run-dir "$GREEN_RUN") || fail "rc0 green-gate converge exited non-zero"
[ "$out" = "proceed" ] || fail "rc 0 with a green gate should proceed, got '$out'"
if grep -q 'gate-not-green' "$LOG_FILE"; then
  fail "green-gate stderr should not report gate-not-green"
fi

# AC3: the red-gate fall-through is bounded by the existing round ceiling.
out=$(converge --rc 0 --round 10 --run-dir "$FAILED_RUN") || fail "rc0 red-gate at cap exited non-zero"
[ "$out" = "park" ] || fail "rc 0 with a red gate at the round cap should park, got '$out'"

# AC4: no --run-dir keeps the legacy rc=0 fast-path intact.
out=$(converge --rc 0 --round 1) || fail "rc0 without run-dir exited non-zero"
[ "$out" = "proceed" ] || fail "rc 0 without run-dir should still proceed, got '$out'"

# AC6 (#156 review MEDIUM): a run-dir with NO run-state.json (the PLAN stage shares $SESSION_DIR
# but never writes run-state.json) must NOT be treated as a red gate — rc=0 there still proceeds.
# The guard fires only when run-state.json EXISTS and is red, never on its absence.
NO_STATE_RUN="$TMP_ROOT/no-run-state"
mkdir -p "$NO_STATE_RUN"
out=$(converge --rc 0 --round 1 --run-dir "$NO_STATE_RUN") || fail "rc0 absent-run-state converge exited non-zero"
[ "$out" = "proceed" ] || fail "rc 0 with a run-dir but NO run-state.json should proceed (plan stage), got '$out'"
if grep -q 'gate-not-green' "$LOG_FILE"; then
  fail "absent-run-state should not report gate-not-green (nothing to audit)"
fi

# AC5: the existing green hardening terminus stays unchanged.
TARGET="$TMP_ROOT/target"
mkdir -p "$TARGET"
cd "$TARGET"
git init -q
git config user.email "codex@example.com"
git config user.name "Codex"

cat > core.py <<'PY'
line1
line2
line3
PY

git add core.py
git commit -q -m "base"
BASE="$(git rev-parse HEAD)"

python3 - "$TARGET/core.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
lines[1] = "line2-changed"
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

DH="$(TARGET="$TARGET" BASE="$BASE" python3 - <<'PY'
import os
from sail import review

print(review.diff_fingerprint(os.environ["TARGET"], os.environ["BASE"]))
PY
)"

HARDEN_RUN="$TMP_ROOT/hardening-run"
mkdir -p "$HARDEN_RUN"
cat >"$HARDEN_RUN/run-state.json" <<'JSON'
{"gates":[{"name":"ruff","status":"passed","new_failures":0},{"name":"mypy","status":"skipped","new_findings_count":0}]}
JSON

python3 - "$TARGET" "$BASE" "$DH" "$HARDEN_RUN" <<'PY'
import json
import os
from pathlib import Path
import sys

from sail import review as review_mod
from sail.decisionlog import DecisionLog

target = Path(sys.argv[1])
base = sys.argv[2]
dh = sys.argv[3]
run_dir = Path(sys.argv[4])

(run_dir / "decision-log.md").write_text("# /sail decision log\n", encoding="utf-8")
(run_dir / "plan.json").write_text(
    json.dumps({
        "status": "completed",
        "acceptance_criteria": [{"criterion": "one", "status": "met", "evidence": "ok"}],
    }),
    encoding="utf-8",
)
review_payload = {
    "status": "completed",
    "target": str(target),
    "diff_ref": base,
    "diff_hash": dh,
    "plan_hash": review_mod.plan_fingerprint(str(run_dir)),
    "round": 2,
    "findings": [
        {
            "id": "RT-156",
            "severity": "HIGH",
            "file": "core.py",
            "line": 2,
        }
    ],
    "plan_verification": {
        "acceptance_criteria": [
            {"criterion": "one", "status": "met", "evidence": "ok"},
        ]
    },
    "tidiness": {"blocking": []},
}
(run_dir / "review.json").write_text(json.dumps(review_payload), encoding="utf-8")
DecisionLog(str(run_dir)).finding_resolution("RT-156", "deferred", "x", round=2)
PY

STUB="$TMP_ROOT/materiality-false.sh"
cat >"$STUB" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' '{"material":false}'
SH
chmod +x "$STUB"

export SAIL_MATERIALITY_CMD="$STUB"
cd "$REPO_ROOT"
out=$(converge --rc 1 --round 2 --run-dir "$HARDEN_RUN" --target "$TARGET") || fail "green hardening converge exited non-zero"
[ "$out" = "proceed-hardening" ] || fail "green hardening path should still proceed-hardening, got '$out'"
grep -q 'materiality-floor' "$LOG_FILE" || fail "hardening stderr reason missing materiality-floor"
grep -q 'RT-156' "$LOG_FILE" || fail "hardening stderr reason missing finding id"

echo "PASS: test_sail_156_converge_gate_audit.sh"
