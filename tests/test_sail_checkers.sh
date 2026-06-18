#!/usr/bin/env bash
# test_sail_checkers.sh
# Verifies the sail.checkers registry contract for the availability-gated adapters.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_FILE="$(mktemp)"

cleanup() {
  rm -f "$LOG_FILE"
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

cd "$REPO_ROOT"

if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
import shutil
import sail.checkers as checkers

expected_names = ["ruff", "mypy", "pytest", "bandit", "semgrep", "pip-audit"]
expected_artifacts = {
    "ruff": "ruff.sarif",
    "mypy": "mypy.junit.xml",
    "pytest": "junit.xml",
    "bandit": "bandit.sarif",
    "semgrep": "semgrep.sarif",
    "pip-audit": "pip-audit.json",
}

registry = checkers.build_registry()
names = [checker.name for checker in registry]
if names != expected_names:
    raise SystemExit(f"FAIL: expected registry order {expected_names!r}, got {names!r}")

for checker in registry:
    if checker.artifact != expected_artifacts[checker.name]:
        raise SystemExit(
            "FAIL: "
            f"{checker.name} artifact {checker.artifact!r} != {expected_artifacts[checker.name]!r}"
        )
    expected_available = shutil.which(checker.tool) is not None
    if checker.available() != expected_available:
        raise SystemExit(
            "FAIL: "
            f"expected {checker.name}.available() to equal {expected_available!r}, "
            f"got {checker.available()!r}"
        )
    if checker.classify(0) != "passed":
        raise SystemExit(f"FAIL: expected {checker.name}.classify(0) to return 'passed'")
    if checker.classify(1) != "failed":
        raise SystemExit(f"FAIL: expected {checker.name}.classify(1) to return 'failed'")

print("PASS: sail.checkers registry contract verified")
PY
then
  fail "sail.checkers registry contract failed (expected until sail/checkers.py exists)"
fi

echo "PASS: sail.checkers registry contract verified"
