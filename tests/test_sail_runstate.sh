#!/usr/bin/env bash
# test_sail_runstate.sh
# Verifies that `python3 -m sail run --run-dir ...` writes a valid run-state.json
# with required top-level metadata and the expected gate schema/order.

set -euo pipefail
# Hermetic (.ship/domain.md #102): a real shell exports SAIL_* codex knobs (settings.json);
# clear them so each subtest controls its own backend (subtests set theirs via command prefix).
unset "${!SAIL_@}"

TMP_ROOT="$(mktemp -d)"
RUN_DIR="$TMP_ROOT/myrun"
LOG_FILE="$TMP_ROOT/sail-run.log"
STATE_FILE="$RUN_DIR/run-state.json"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  if [ -f "$LOG_FILE" ]; then
    echo "---- sail output ----" >&2
    sed 's/^/  /' "$LOG_FILE" >&2 || true
    echo "---------------------" >&2
  fi
  exit 1
}

mkdir -p "$RUN_DIR"

# rc is environment-dependent (a gate may fail when its tool is installed); the run-state
# is written regardless. Only require that the run-state was initialized + valid below.
python3 -m sail run --run-dir "$RUN_DIR" >"$LOG_FILE" 2>&1 || true

[ -f "$STATE_FILE" ] || fail "run-state.json was not created at $STATE_FILE"

python3 - "$STATE_FILE" <<'PY' || exit 1
import json
import sys

path = sys.argv[1]
expected_gates = ["ruff", "mypy", "pytest", "bandit", "semgrep", "pip-audit", "shellcheck", "gitleaks", "npm-audit", "diff-coverage"]
valid_statuses = {"pending", "running", "passed", "failed", "skipped"}

try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception as exc:  # pragma: no cover - shell test handles exit status
    print(f"FAIL: run-state.json is not valid JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)

missing = [key for key in ("run_id", "started_at", "schema_version") if key not in data]
if missing:
    print(f"FAIL: run-state.json is missing required top-level fields: {', '.join(missing)}", file=sys.stderr)
    raise SystemExit(1)

gates = data.get("gates")
if not isinstance(gates, list):
    print("FAIL: run-state.json field 'gates' must be a list", file=sys.stderr)
    raise SystemExit(1)

names = []
for idx, gate in enumerate(gates):
    if not isinstance(gate, dict):
        print(f"FAIL: gate {idx} is not an object", file=sys.stderr)
        raise SystemExit(1)
    if "name" not in gate:
        print(f"FAIL: gate {idx} is missing field 'name'", file=sys.stderr)
        raise SystemExit(1)
    status = gate.get("status")
    if status not in valid_statuses:
        print(
            f"FAIL: gate {gate.get('name', idx)!r} has invalid status {status!r}",
            file=sys.stderr,
        )
        raise SystemExit(1)
    names.append(gate["name"])

if names != expected_gates:
    print(
        "FAIL: gate order/names mismatch: "
        f"expected {expected_gates!r}, got {names!r}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY

echo "PASS: run-state.json has valid schema and gate ordering"
