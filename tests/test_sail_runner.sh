#!/usr/bin/env bash
# test_sail_runner.sh
# Red test for the Step 4 orchestration command.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
TARGET="$(mktemp -d "$TMP_ROOT/target.XXXXXX")"
RUN="$(mktemp -d "$TMP_ROOT/run.XXXXXX")"
LOG_FILE="$TMP_ROOT/sail-run.log"
STATE_FILE="$RUN/run-state.json"
DECISION_LOG="$RUN/decision-log.md"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  if [ -s "$LOG_FILE" ]; then
    echo "---- sail output ----" >&2
    sed 's/^/  /' "$LOG_FILE" >&2 || true
    echo "---------------------" >&2
  fi
  exit 1
}

cat >"$TARGET/trivial.py" <<'PY'
print("hello")
PY

cd "$REPO_ROOT"

if python3 -m sail run --target "$TARGET" --run-dir "$RUN" >"$LOG_FILE" 2>&1; then
  RC=0
else
  RC=$?
fi

if [ "$RC" -ne 0 ]; then
  fail "python3 -m sail run --target \"$TARGET\" --run-dir \"$RUN\" exited $RC; expected 0 and a completed six-gate orchestration"
fi

[ -f "$STATE_FILE" ] || fail "run-state.json was not created at $STATE_FILE"
[ -f "$DECISION_LOG" ] || fail "decision-log.md was not created at $DECISION_LOG"

python3 - "$STATE_FILE" "$DECISION_LOG" <<'PY' || exit 1
import json
import sys

state_path = sys.argv[1]
log_path = sys.argv[2]
expected_names = ["ruff", "mypy", "pytest", "bandit", "semgrep", "pip-audit"]

with open(state_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

gates = data.get("gates")
if not isinstance(gates, list):
    print("FAIL: run-state.json field 'gates' must be a list", file=sys.stderr)
    raise SystemExit(1)

if [gate.get("name") for gate in gates] != expected_names:
    print(
        "FAIL: gate order/names mismatch: "
        f"expected {expected_names!r}, got {[gate.get('name') for gate in gates]!r}",
        file=sys.stderr,
    )
    raise SystemExit(1)

terminal_statuses = {"passed", "failed", "skipped"}
for gate in gates:
    status = gate.get("status")
    if status not in terminal_statuses:
        print(
            f"FAIL: gate {gate.get('name')!r} has non-terminal status {status!r}",
            file=sys.stderr,
        )
        raise SystemExit(1)
    if status != "skipped":
        print(
            f"FAIL: gate {gate.get('name')!r} has status {status!r}, expected 'skipped' in this environment",
            file=sys.stderr,
        )
        raise SystemExit(1)
    reason = gate.get("reason") or ""
    if "tool-unavailable" not in reason:
        print(
            f"FAIL: gate {gate.get('name')!r} reason {reason!r} does not contain 'tool-unavailable'",
            file=sys.stderr,
        )
        raise SystemExit(1)

with open(log_path, "r", encoding="utf-8") as fh:
    lines = fh.read().splitlines()

header_lines = [line for line in lines if line == "# /sail decision log"]
if len(header_lines) != 1:
    print(
        f"FAIL: decision-log.md header count expected 1, got {len(header_lines)}",
        file=sys.stderr,
    )
    raise SystemExit(1)

seq_lines = [line for line in lines if "seq=" in line]
if len(seq_lines) != 6:
    print(
        f"FAIL: decision-log.md expected 6 outcome lines with seq=, got {len(seq_lines)}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY

echo "PASS: sail orchestration runs all gates"
