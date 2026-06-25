#!/usr/bin/env bash
# test_sail_runner_stdout.sh
# #48 Step 1: _run_checker writes captured stdout to the artifact when the checker
# declares stdout_artifact=True (shellcheck-shaped tools emit JSON to stdout, no file
# flag); when stdout_artifact=False the behavior is byte-identical to today (rc only,
# stdout discarded). Hermetic — uses `printf` as a fake checker command, no external tools.

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
# Hermetic (.ship/domain.md #102): a real shell exports SAIL_* codex knobs (settings.json);
# clear them so each subtest controls its own backend (subtests set theirs via command prefix).
unset "${!SAIL_@}"

if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
import os
import tempfile
from sail import runner
from sail.checkers import Checker


class FakeChecker(Checker):
    """A Checker whose build_command emits a fixed payload to stdout via printf."""
    def __init__(self, name, stdout_artifact, payload):
        object.__setattr__(self, "name", name)
        object.__setattr__(self, "tool", "printf")
        object.__setattr__(self, "artifact", name + ".json")
        object.__setattr__(self, "blocking", True)
        object.__setattr__(self, "stdout_artifact", stdout_artifact)
        object.__setattr__(self, "_payload", payload)

    def build_command(self, target, artifact_path):
        return ["printf", "%s", self._payload]


PAYLOAD = '[{"file":"a.sh","line":1,"code":2086,"message":"quote it"}]'

with tempfile.TemporaryDirectory() as td:
    target = os.path.join(td, "target")
    os.makedirs(target)

    # (1) stdout_artifact=True: captured stdout is written verbatim to artifact_path.
    art_true = os.path.join(td, "true", "out.json")
    os.makedirs(os.path.dirname(art_true), exist_ok=True)
    rc = runner._run_checker(FakeChecker("on", True, PAYLOAD), target, art_true)
    if rc != 0:
        raise SystemExit(f"FAIL: printf checker should rc=0, got {rc}")
    if not os.path.exists(art_true):
        raise SystemExit("FAIL: stdout_artifact=True must write the artifact file")
    with open(art_true, encoding="utf-8") as fh:
        got = fh.read()
    if got != PAYLOAD:
        raise SystemExit(f"FAIL: artifact must contain stdout verbatim, got {got!r}")

    # (2) stdout_artifact=False: stdout is NOT written to the artifact (byte-identical
    #     to today — file-based tools own their own artifact via the command).
    art_false = os.path.join(td, "false", "out.json")
    os.makedirs(os.path.dirname(art_false), exist_ok=True)
    rc = runner._run_checker(FakeChecker("off", False, PAYLOAD), target, art_false)
    if rc != 0:
        raise SystemExit(f"FAIL: printf checker should rc=0, got {rc}")
    if os.path.exists(art_false):
        raise SystemExit("FAIL: stdout_artifact=False must NOT write the artifact from stdout")

    # (3) never-mask: empty stdout under stdout_artifact=True is written verbatim (empty),
    #     NOT coerced to "[]" — a genuine empty stdout (tool crash) must fail-closed downstream.
    art_empty = os.path.join(td, "empty", "out.json")
    os.makedirs(os.path.dirname(art_empty), exist_ok=True)
    runner._run_checker(FakeChecker("empty", True, ""), target, art_empty)
    with open(art_empty, encoding="utf-8") as fh:
        body = fh.read()
    if body != "":
        raise SystemExit(f"FAIL: empty stdout must be written verbatim (not coerced), got {body!r}")

print("PASS: _run_checker stdout_artifact capture (#48 Step 1) verified")
PY
then
  fail "_run_checker stdout_artifact capture (#48 Step 1) failed"
fi

echo "PASS: _run_checker stdout_artifact capture (#48 Step 1) verified"
