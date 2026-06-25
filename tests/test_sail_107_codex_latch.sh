#!/usr/bin/env bash
# test_sail_107_codex_latch.sh
# #107: session-level codex-availability latch + reset-aware expiry.
# Hermetic — controls SAIL_STATE_DIR, SAIL_SESSION_ID, a frozen `now`, and uses
# temp executable stubs so it never depends on this machine's codex/claude install
# (the inherited SAIL_* env + out-of-credits codex is exactly why test_sail_plan/66
# are flaky on this host — these assertions must not be).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Hermetic (.ship/domain.md #102): a real shell exports SAIL_* codex knobs (settings.json);
# clear them so each subtest controls its own backend (subtests set theirs via command prefix).
unset "${!SAIL_@}"
TMP_ROOT="$(mktemp -d)"
LOG_FILE="$TMP_ROOT/python.log"

cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  if [ -s "$LOG_FILE" ]; then
    echo "---- python output ----" >&2; sed 's/^/  /' "$LOG_FILE" >&2 || true; echo "-----------------------" >&2
  fi
  exit 1
}

# Hermetic state dir + session token; isolate from the host's SAIL_* / CLAUDE_CODE_SESSION_ID.
export SAIL_STATE_DIR="$TMP_ROOT/state"
export SAIL_SESSION_ID="sess-A"
unset CLAUDE_CODE_SESSION_ID || true
# codex/claude executable stubs (basename drives is_codex_family; never invoked here).
mkdir -p "$TMP_ROOT/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP_ROOT/bin/codex"; chmod +x "$TMP_ROOT/bin/codex"
printf '#!/bin/sh\nexit 0\n' > "$TMP_ROOT/bin/claude"; chmod +x "$TMP_ROOT/bin/claude"
CODEX="$TMP_ROOT/bin/codex"
CLAUDE="$TMP_ROOT/bin/claude"

cd "$REPO_ROOT"

if ! SAIL_STATE_DIR="$SAIL_STATE_DIR" SAIL_SESSION_ID="$SAIL_SESSION_ID" \
     CODEX="$CODEX" CLAUDE="$CLAUDE" python3 - <<'PY' >"$LOG_FILE" 2>&1
import os
import sail.codexlatch as L

codex = os.environ["CODEX"]
claude = os.environ["CLAUDE"]
NOW = 1_000_000  # frozen epoch for deterministic expiry tests

def reset():
    L.clear_latch()
    assert not L.latch_active(now=NOW), "latch should be inactive after clear"

# ---- is_codex_family: wrapper peeling (detection) ----
assert L.is_codex_family(["codex", "exec"]) is True
assert L.is_codex_family(["env", "K=V", "codex", "exec"]) is True
assert L.is_codex_family(["bash", "-lc", "codex exec -m gpt-5.4-mini"]) is True
assert L.is_codex_family(["python", "-m", "codex"]) is True
assert L.is_codex_family(["claude", "-p"]) is False
assert L.is_codex_family([]) is False

# ---- AC1: first availability failure trips the latch (writes the marker) ----
reset()
tripped = L.observe([codex, "exec"], rc=1,
                    stderr="Error: usage limit reached; resets at 2099-01-01T00:00:00Z",
                    now=NOW)
assert tripped is True, "availability failure must trip"
assert os.path.isfile(L.marker_path()), "AC1: marker must be written"
assert L.latch_active(now=NOW) is True, "AC1: latch active after trip"

# ---- AC3: a non-availability failure (malformed JSON) does NOT trip ----
reset()
tripped = L.observe([codex, "exec"], rc=0, stderr="", now=NOW)  # rc=0 garbage output
assert tripped is False, "rc=0 content failure must not trip"
assert not L.latch_active(now=NOW)
tripped = L.observe([codex, "exec"], rc=1,
                    stderr="SyntaxError: Unexpected token } in JSON at position 42", now=NOW)
assert tripped is False, "AC3: malformed-JSON failure must not trip the latch"
assert not L.latch_active(now=NOW), "AC3: latch must stay inactive on content failure"

# ---- AC3: a Claude/non-codex failure never trips the codex latch ----
reset()
tripped = L.observe([claude, "-p"], rc=1, stderr="rate limit exceeded", now=NOW)
assert tripped is False, "non-codex backend must never trip the codex latch"
assert not L.latch_active(now=NOW)

# ---- AC5: parsed reset time expires the latch; unparseable stays latched ----
reset()
L.trip_latch("usage limit", reset_epoch=NOW + 100)
assert L.latch_active(now=NOW) is True, "active before reset"
assert L.latch_active(now=NOW + 100) is False, "AC5: expired at reset_epoch"
assert not os.path.isfile(L.marker_path()), "AC5: expired marker removed"
reset()
L.trip_latch("usage limit", reset_epoch=None)  # unparseable reset
assert L.latch_active(now=NOW) is True
assert L.latch_active(now=NOW + 10_000_000) is True, "AC5: no reset → latched all session"

# ---- AC5: reset parsing from stderr ----
assert L.parse_reset_epoch("try again in 30 seconds", now=NOW) == NOW + 30
assert L.parse_reset_epoch("try again in 5 minutes", now=NOW) == NOW + 300
assert L.parse_reset_epoch("resets at 2099-01-01T00:00:00Z", now=NOW) > NOW
assert L.parse_reset_epoch("no time mentioned here", now=NOW) is None

# ---- AC6: session mismatch → stale → inactive + cleaned (no leak to new session) ----
reset()
L.trip_latch("usage limit", reset_epoch=None)
assert L.latch_active(now=NOW) is True
os.environ["SAIL_SESSION_ID"] = "sess-B"  # a different session
assert L.latch_active(now=NOW) is False, "AC6: a new session must not see the old latch"
assert not os.path.isfile(L.marker_path()), "AC6: stale marker cleaned up"
os.environ["SAIL_SESSION_ID"] = "sess-A"

# ---- classify_failure direct table ----
assert L.classify_failure(1, "Error: rate limit exceeded (429)") is True
assert L.classify_failure(1, "401 Unauthorized") is True
assert L.classify_failure(1, "connection refused") is True
assert L.classify_failure(1, "insufficient credit balance") is True
assert L.classify_failure(1, "some ordinary stack trace ValueError") is False
assert L.classify_failure(0, "anything") is False

print("ok-core")
PY
then
  fail "sail.codexlatch core contract failed (expected ModuleNotFoundError until implemented)"
fi
grep -q 'ok-core' "$LOG_FILE" || fail "core test did not reach ok-core"

# ---- AC2: latched codex backends are skipped by _argv_runnable across modules ----
if ! SAIL_STATE_DIR="$SAIL_STATE_DIR" SAIL_SESSION_ID="$SAIL_SESSION_ID" \
     CODEX="$CODEX" CLAUDE="$CLAUDE" python3 - <<'PY' >"$LOG_FILE" 2>&1
import os
import sail.codexlatch as L
from sail.build import _argv_runnable as build_runnable
from sail.plan import _argv_runnable as plan_runnable
from sail.review import _argv_runnable as review_runnable

codex = os.environ["CODEX"]; claude = os.environ["CLAUDE"]
L.clear_latch()
# Not latched: codex backend is runnable (stub is an executable file).
for r in (build_runnable, plan_runnable, review_runnable):
    assert r([codex, "exec"]) is True, "codex runnable when not latched"
    assert r([claude, "-p"]) is True, "claude runnable"
# Latched: codex suppressed everywhere, claude untouched (AC2).
L.trip_latch("usage limit", reset_epoch=None)
for r in (build_runnable, plan_runnable, review_runnable):
    assert r([codex, "exec"]) is False, "AC2: latched codex must be skipped"
    assert r([claude, "-p"]) is True, "AC2: claude must NOT be suppressed by the codex latch"
L.clear_latch()
print("ok-wiring")
PY
then
  fail "AC2 wiring: _argv_runnable does not yet consult the codex latch"
fi
grep -q 'ok-wiring' "$LOG_FILE" || fail "wiring test did not reach ok-wiring"

# ---- AC4: observe() writes a visible decision-log line on trip; never raises ----
if ! SAIL_STATE_DIR="$SAIL_STATE_DIR" SAIL_SESSION_ID="$SAIL_SESSION_ID" \
     CODEX="$CODEX" RUN_DIR="$TMP_ROOT/run" python3 - <<'PY' >"$LOG_FILE" 2>&1
import os
import sail.codexlatch as L
from sail.decisionlog import DecisionLog

codex = os.environ["CODEX"]; run_dir = os.environ["RUN_DIR"]; NOW = 1_000_000
os.makedirs(run_dir, exist_ok=True)
L.clear_latch()
log = DecisionLog(run_dir)
tripped = L.observe([codex, "exec"], rc=1, stderr="usage limit reached; try again in 60 seconds",
                    decision_log=log, now=NOW)
assert tripped is True
body = open(os.path.join(run_dir, "decision-log.md"), encoding="utf-8").read()
assert "codex" in body.lower(), "AC4: a visible codex line must be logged"
L.clear_latch()
print("ok-log")
PY
then
  fail "AC4 visible logging: observe() did not emit a decision-log line"
fi
grep -q 'ok-log' "$LOG_FILE" || fail "log test did not reach ok-log"

# ---- AC4 (production path): trip/skip are VISIBLE on stderr with NO decision_log passed ----
# Every live /sail call site passes decision_log=None — the always-on stderr notice is the
# only channel /sail surfaces. Capture sys.stderr and assert the notices appear there.
if ! SAIL_STATE_DIR="$SAIL_STATE_DIR" SAIL_SESSION_ID="$SAIL_SESSION_ID" \
     CODEX="$CODEX" python3 - <<'PY' >"$LOG_FILE" 2>&1
import contextlib
import io
import os
import sail.codexlatch as L

codex = os.environ["CODEX"]; NOW = 1_000_000
L.clear_latch()

# Trip with NO decision_log (production path) — must still be visible on stderr.
L._TRIP_NOTICED = False
L._SKIP_NOTICED = False
buf = io.StringIO()
with contextlib.redirect_stderr(buf):
    tripped = L.observe([codex, "exec"], rc=1,
                        stderr="usage limit reached; try again in 60 seconds", now=NOW)
assert tripped is True
trip_err = buf.getvalue()
assert "codex" in trip_err.lower(), f"AC4: trip must print a codex notice to stderr, got: {trip_err!r}"

# Skip with NO decision_log (production path) — latch is active now.
L._TRIP_NOTICED = False
L._SKIP_NOTICED = False
buf = io.StringIO()
with contextlib.redirect_stderr(buf):
    runnable = L.runnable([codex, "exec"], now=NOW)
assert runnable is False, "latched codex must be suppressed"
skip_err = buf.getvalue()
assert "codex" in skip_err.lower() and "skip" in skip_err.lower(), \
    f"AC4: skip must print a codex skip notice to stderr, got: {skip_err!r}"

L.clear_latch()
print("ok-stderr")
PY
then
  fail "AC4 stderr visibility: trip/skip notices are not emitted to stderr on the no-decision_log production path"
fi
grep -q 'ok-stderr' "$LOG_FILE" || fail "stderr test did not reach ok-stderr"

echo "PASS: #107 codex-availability latch — core + detection + AC2/AC4 wiring verified"
