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

# rc is environment-dependent (a gate may fail when its tool is installed); the
# orchestration writes its full audit trail regardless. Orchestration COMPLETENESS
# (six terminal gates + audit trail) is asserted below, not the exit code.
python3 -m sail run --target "$TARGET" --run-dir "$RUN" >"$LOG_FILE" 2>&1 || true

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

import shutil

terminal_statuses = {"passed", "failed", "skipped"}
# The gate's tool name matches its registry name for all six checkers.
for gate in gates:
    name = gate.get("name")
    status = gate.get("status")
    if status not in terminal_statuses:
        print(
            f"FAIL: gate {name!r} has non-terminal status {status!r}",
            file=sys.stderr,
        )
        raise SystemExit(1)
    available = shutil.which(name) is not None
    if available:
        # Tool installed -> the gate actually ran: terminal pass/fail with rc recorded,
        # never a clean skip.
        if status == "skipped":
            print(
                f"FAIL: gate {name!r} tool is installed but the gate was skipped",
                file=sys.stderr,
            )
            raise SystemExit(1)
        if gate.get("rc") is None:
            print(f"FAIL: gate {name!r} ran but rc is None", file=sys.stderr)
            raise SystemExit(1)
    else:
        # Tool absent -> availability-gated clean skip with a tool-unavailable reason.
        if status != "skipped":
            print(
                f"FAIL: gate {name!r} tool absent but status {status!r} != 'skipped'",
                file=sys.stderr,
            )
            raise SystemExit(1)
        if "tool-unavailable" not in (gate.get("reason") or ""):
            print(
                f"FAIL: gate {name!r} skip reason missing 'tool-unavailable'",
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
