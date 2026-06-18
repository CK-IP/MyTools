#!/usr/bin/env bash
# test_sail_decisionlog.sh
# Red test for sail.decisionlog: append-only decision log with idempotent seq writes.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
RUN_DIR="$TMP_ROOT/run"
DECISION_LOG="$RUN_DIR/decision-log.md"
LOG_FILE="$TMP_ROOT/python.log"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  if [ -s "$LOG_FILE" ]; then
    echo "---- python output ----" >&2
    sed 's/^/  /' "$LOG_FILE" >&2 || true
    echo "-----------------------" >&2
  fi
  exit 1
}

mkdir -p "$RUN_DIR"

cd "$REPO_ROOT"

if ! RUN_DIR="$RUN_DIR" python3 - <<'PY' >"$LOG_FILE" 2>&1
import os

from sail.decisionlog import DecisionLog

run_dir = os.environ["RUN_DIR"]

records = [
    {"name": "ruff", "status": "passed", "rc": 0, "artifact": "ruff.sarif", "seq": 1},
    {"name": "mypy", "status": "failed", "rc": 1, "artifact": "mypy.junit.xml", "seq": 2},
    {"name": "pytest", "status": "passed", "rc": 0, "artifact": "junit.xml", "seq": 3},
]

log = DecisionLog(run_dir)
for record in records:
    log.append(record, "continue")
PY
then
  fail "sail.decisionlog is not implemented yet (expected ModuleNotFoundError)"
fi

if [ ! -f "$DECISION_LOG" ]; then
  fail "decision-log.md was not created at $DECISION_LOG"
fi

if [ "$(grep -c 'seq=' "$DECISION_LOG")" -ne 3 ]; then
  fail "expected 3 outcome lines after initial append"
fi

if [ "$(grep -c '^#' "$DECISION_LOG")" -ne 1 ]; then
  fail "expected the markdown header exactly once after initial append"
fi

if ! RUN_DIR="$RUN_DIR" python3 - <<'PY' >"$LOG_FILE" 2>&1
import os

from sail.decisionlog import DecisionLog

run_dir = os.environ["RUN_DIR"]
log = DecisionLog(run_dir)
log.append({"name": "mypy", "status": "failed", "rc": 1, "artifact": "mypy.junit.xml", "seq": 2}, "continue")
PY
then
  fail "sail.decisionlog failed when re-appending an existing seq (expected ModuleNotFoundError today)"
fi

if [ "$(grep -c 'seq=' "$DECISION_LOG")" -ne 3 ]; then
  fail "idempotent append duplicated a seq line"
fi

if [ "$(grep -c '^#' "$DECISION_LOG")" -ne 1 ]; then
  fail "idempotent append duplicated the markdown header"
fi

if ! RUN_DIR="$RUN_DIR" python3 - <<'PY' >"$LOG_FILE" 2>&1
import os

from sail.decisionlog import DecisionLog

run_dir = os.environ["RUN_DIR"]
fresh = DecisionLog(run_dir)
fresh.append({"name": "bandit", "status": "passed", "rc": 0, "artifact": "bandit.sarif", "seq": 4}, "continue")
PY
then
  fail "sail.decisionlog failed when appending via a fresh instance (expected ModuleNotFoundError today)"
fi

if [ "$(grep -c 'seq=' "$DECISION_LOG")" -ne 4 ]; then
  fail "append-only behavior truncated or skipped a record"
fi

if [ "$(grep -c '^#' "$DECISION_LOG")" -ne 1 ]; then
  fail "fresh instance duplicated the markdown header"
fi

echo "PASS: decision log append/idempotent/append-only contract verified"
