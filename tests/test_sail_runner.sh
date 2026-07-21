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
# Hermetic (.ship/domain.md #102): a real shell exports SAIL_* codex knobs (settings.json);
# clear them so each subtest controls its own backend (subtests set theirs via command prefix).
unset "${!SAIL_@}"

# rc is environment-dependent (a gate may fail when its tool is installed); the
# orchestration writes its full audit trail regardless. Orchestration COMPLETENESS
# (eight terminal gates + audit trail) is asserted below, not the exit code.
python3 -m sail run --target "$TARGET" --run-dir "$RUN" >"$LOG_FILE" 2>&1 || true

[ -f "$STATE_FILE" ] || fail "run-state.json was not created at $STATE_FILE"
[ -f "$DECISION_LOG" ] || fail "decision-log.md was not created at $DECISION_LOG"

python3 - "$STATE_FILE" "$DECISION_LOG" <<'PY' || exit 1
import json
import sys

state_path = sys.argv[1]
log_path = sys.argv[2]
expected_names = ["ruff", "mypy", "pytest", "bandit", "semgrep", "pip-audit", "shellcheck", "gitleaks", "npm-audit", "diff-coverage", "shell-runtime"]

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
import sail.checkers as _checkers

# Most checkers' tool binary == their registry name, but #52 adds npm-audit (tool=npm) and
# diff-coverage (tool=diff-cover) where they differ — resolve availability via the real tool.
_tool_by_name = {c.name: c.tool for c in _checkers.build_registry()}

terminal_statuses = {"passed", "failed", "skipped"}
# pytest is the one checker that legitimately skips while installed: on a target
# with no tests it exits rc=5 ("no tests collected"), and checkers.Checker.classify
# maps rc 2/5 -> "skipped" (non-blocking, per #33/#35). So "installed tool never
# skips" is false for pytest on this no-test target. Allow ONLY the exact
# (rc, reason) pairs that Checker.reason() emits for that legitimate case — a
# whitelist, not a blanket exemption, so a genuine "installed tool silently
# skipped for no reason" regression (wrong rc, or rc 2/5 with an unexpected /
# tool-unavailable reason) is still caught. This keeps the test hermetic: pytest
# being on PATH or not no longer changes the verdict.
legit_pytest_skips = {
    (5, "no tests collected (rc=5)"),
    (2, "collection/config error (rc=2) — not a test failure"),
}
# The gate's tool name matches its registry name for all eight checkers.
for gate in gates:
    name = gate.get("name")
    status = gate.get("status")
    if status not in terminal_statuses:
        print(
            f"FAIL: gate {name!r} has non-terminal status {status!r}",
            file=sys.stderr,
        )
        raise SystemExit(1)
    # Diff-only gates are skipped in whole-repo mode with a "diff-only gate" reason.
    # diff-coverage is a DIFF-ONLY gate (#52): in this whole-repo run it is always skipped with
    # a "diff-only gate" reason — regardless of whether diff-cover is installed. Accept that
    # legitimate skip explicitly (mirrors the pytest legit-skip whitelist) before the
    # tool-availability invariant below.
    if name in ("diff-coverage", "shell-runtime"):
        if status != "skipped":
            print(f"FAIL: {name} must be skipped in whole-repo mode, got {status!r}", file=sys.stderr)
            raise SystemExit(1)
        if "diff-only" not in (gate.get("reason") or ""):
            print(f"FAIL: {name} whole-repo skip must record a diff-only reason, got {gate.get('reason')!r}", file=sys.stderr)
            raise SystemExit(1)
        continue
    available = shutil.which(_tool_by_name.get(name, name)) is not None
    if available:
        # Tool installed -> the gate actually ran: terminal pass/fail with rc recorded,
        # never a clean skip -- EXCEPT pytest's legitimate no-tests/collection skip.
        if status == "skipped":
            if name == "pytest" and (gate.get("rc"), gate.get("reason")) in legit_pytest_skips:
                # Legitimate pytest no-tests/collection skip on the no-test target.
                # rc is recorded by construction (it is part of the whitelisted pair).
                continue
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
if len(seq_lines) != 11:
    print(
        f"FAIL: decision-log.md expected 11 outcome lines with seq=, got {len(seq_lines)}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY

echo "PASS: sail orchestration runs all gates"

# --- #48 Step 1: gate-reconciliation on resume ---
# A run-state.json that predates a registry change (its gates array OMITS some registry
# checkers) must NOT KeyError at the gates_by_name index sites. run() backfills the missing
# gates (in registry order) before the per-checker loop; afterwards every registry checker has
# a gate, and seq values are monotonic and gap-free. Hermetic: SAIL_CHECKERS pins a two-checker
# registry (ruff,pytest) while the crafted state seeds only ruff — pytest must be backfilled.
RECON_TARGET="$(mktemp -d "$TMP_ROOT/recon-target.XXXXXX")"
RECON_RUN="$(mktemp -d "$TMP_ROOT/recon-run.XXXXXX")"
RECON_STATE="$RECON_RUN/run-state.json"
RECON_LOG="$TMP_ROOT/recon.log"

cat >"$RECON_TARGET/trivial.py" <<'PY'
print("hi")
PY

# Seed a resumable state whose gates array contains ONLY ruff (omits pytest). Give ruff a
# terminal status with seq=1 so it is skipped by the loop and pytest is the only backfilled gate.
cat >"$RECON_STATE" <<'JSON'
{
  "run_id": "recon",
  "started_at": "2026-01-01T00:00:00Z",
  "schema_version": 1,
  "gates": [
    {
      "name": "ruff",
      "status": "passed",
      "artifact": "ruff.sarif",
      "rc": 0,
      "reason": null,
      "seq": 1,
      "started_at": "2026-01-01T00:00:00Z",
      "finished_at": "2026-01-01T00:00:01Z"
    }
  ]
}
JSON

SAIL_CHECKERS="ruff,pytest" python3 -m sail run --target "$RECON_TARGET" --run-dir "$RECON_RUN" --no-review >"$RECON_LOG" 2>&1 || true

[ -f "$RECON_STATE" ] || fail "reconciliation: run-state.json missing after resume"

python3 - "$RECON_STATE" <<'PY' || { echo "---- recon output ----" >&2; sed 's/^/  /' "$TMP_ROOT/recon.log" >&2 || true; echo "----------------------" >&2; exit 1; }
import json, sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
gates = data["gates"]
names = [g["name"] for g in gates]

# Both registry checkers must now have a gate (pytest backfilled), in registry order.
if names != ["ruff", "pytest"]:
    raise SystemExit(f"FAIL: reconciliation must backfill missing gates in registry order, got {names!r}")

# seq must be monotonic and gap-free across all gates that ran/were seeded.
seqs = sorted(g["seq"] for g in gates if g.get("seq") is not None)
if seqs != list(range(1, len(seqs) + 1)):
    raise SystemExit(f"FAIL: seq must be monotonic gap-free starting at 1, got {seqs!r}")

# The backfilled pytest gate reached a terminal status (no KeyError / crash).
pytest_gate = next(g for g in gates if g["name"] == "pytest")
if pytest_gate["status"] not in {"passed", "failed", "skipped"}:
    raise SystemExit(f"FAIL: backfilled pytest gate not terminal: {pytest_gate['status']!r}")

print("PASS: gate-reconciliation backfills missing registry gates on resume (#48 Step 1)")
PY

echo "PASS: gate-reconciliation backfills missing registry gates on resume (#48 Step 1)"
