#!/usr/bin/env bash
# test_sail_resume.sh
# Red test for Step 5 crash-safe resume/reconciliation behavior.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
R="$(mktemp -d "$TMP_ROOT/run.XXXXXX")"
TGT="$(mktemp -d "$TMP_ROOT/target.XXXXXX")"
LOG_FILE="$TMP_ROOT/sail-resume.log"
STATE_FILE="$R/run-state.json"
DECISION_LOG="$R/decision-log.md"
G0_FILE="$TMP_ROOT/g0.txt"
COUNT_FILE="$TMP_ROOT/gate-count.txt"

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

mkdir -p "$TGT"
cat >"$TGT/trivial.py" <<'PY'
print("hello")
PY

cd "$REPO_ROOT"
# Hermetic (.ship/domain.md #102): a real shell exports SAIL_* codex knobs (settings.json);
# clear them so each subtest controls its own backend (subtests set theirs via command prefix).
unset "${!SAIL_@}"

# rc is environment-dependent; run-state + decision-log are written regardless.
python3 -m sail run --run-dir "$R" --target "$TGT" >"$LOG_FILE" 2>&1 || true

[ -f "$STATE_FILE" ] || fail "run-state.json was not created at $STATE_FILE"
[ -f "$DECISION_LOG" ] || fail "decision-log.md was not created at $DECISION_LOG"

python3 - "$STATE_FILE" "$G0_FILE" "$COUNT_FILE" <<'PY' || exit 1
import json
import sys

state_path, g0_path, count_path = sys.argv[1:4]

with open(state_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

gates = data.get("gates")
if not isinstance(gates, list):
    print("FAIL: run-state.json field 'gates' must be a list", file=sys.stderr)
    raise SystemExit(1)
if len(gates) != 10:
    print(f"FAIL: expected 10 gates in run-state.json, got {len(gates)}", file=sys.stderr)
    raise SystemExit(1)

gates[0]["status"] = "passed"
gates[0]["rc"] = 0
gates[0]["artifact"] = "SENTINEL.txt"
gates[0]["reason"] = None
gates[0]["finished_at"] = "2026-01-01T00:00:00Z"

gates[2]["status"] = "pending"
gates[2]["rc"] = None
gates[2]["finished_at"] = None

gates[3]["status"] = "running"
gates[3]["rc"] = None
gates[3]["finished_at"] = None

with open(state_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")

with open(g0_path, "w", encoding="utf-8") as fh:
    fh.write(gates[0]["name"] + "\n")

with open(count_path, "w", encoding="utf-8") as fh:
    fh.write(str(len(gates)) + "\n")
PY

G0="$(tr -d '\n' < "$G0_FILE")"
GATE_COUNT="$(tr -d '\n' < "$COUNT_FILE")"

python3 - "$DECISION_LOG" "$G0" <<'PY' || exit 1
import sys

log_path, gate_name = sys.argv[1:3]
key = f"[gate={gate_name} seq="

with open(log_path, "r", encoding="utf-8") as fh:
    lines = fh.read().splitlines()

updated = [line for line in lines if key not in line]
if len(updated) == len(lines):
    print(f"FAIL: could not find decision-log line for gate {gate_name!r}", file=sys.stderr)
    raise SystemExit(1)

with open(log_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(updated) + "\n")
PY

# rc is environment-dependent; the resume reconciliation is asserted below.
python3 -m sail run --run-dir "$R" --target "$TGT" >"$LOG_FILE" 2>&1 || true

python3 - "$STATE_FILE" "$DECISION_LOG" "$G0" "$GATE_COUNT" <<'PY' || exit 1
import json
import sys

state_path, log_path, gate_name, expected_count = sys.argv[1:5]
expected_count = int(expected_count)

with open(state_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

gates = data.get("gates")
if not isinstance(gates, list):
    print("FAIL: run-state.json field 'gates' must be a list after resume", file=sys.stderr)
    raise SystemExit(1)
if len(gates) != expected_count:
    print(
        f"FAIL: expected {expected_count} gates after resume, got {len(gates)}",
        file=sys.stderr,
    )
    raise SystemExit(1)

g0 = gates[0]
if g0.get("status") != "passed" or g0.get("rc") != 0 or g0.get("artifact") != "SENTINEL.txt":
    print(
        "FAIL: gate[0] was not preserved across resume "
        f"(got status={g0.get('status')!r} rc={g0.get('rc')!r} artifact={g0.get('artifact')!r})",
        file=sys.stderr,
    )
    raise SystemExit(1)

terminal_statuses = {"passed", "failed", "skipped"}
non_terminal = [gate.get("name") for gate in gates if gate.get("status") not in terminal_statuses]
if non_terminal:
    print(f"FAIL: non-terminal gates remain after resume: {non_terminal!r}", file=sys.stderr)
    raise SystemExit(1)

with open(log_path, "r", encoding="utf-8") as fh:
    lines = fh.read().splitlines()

if not any("↺ resume" in line for line in lines):
    print("FAIL: decision-log.md is missing the ↺ resume marker after resume", file=sys.stderr)
    raise SystemExit(1)

gate_lines = [line for line in lines if f"[gate={gate_name} seq=" in line]
if len(gate_lines) != 1:
    print(
        f"FAIL: expected exactly one decision-log line for gate {gate_name!r}, got {len(gate_lines)}",
        file=sys.stderr,
    )
    raise SystemExit(1)

seen = {}
for line in lines:
    if not line.startswith("[gate="):
        continue
    key = line.split("] ", 1)[0]
    seen[key] = seen.get(key, 0) + 1

duplicates = sorted(key for key, count in seen.items() if count != 1)
if duplicates:
    print(f"FAIL: duplicate or missing outcome lines detected: {duplicates!r}", file=sys.stderr)
    raise SystemExit(1)
PY

echo "PASS: sail resume preserved terminal gates and reconciled the decision log"
