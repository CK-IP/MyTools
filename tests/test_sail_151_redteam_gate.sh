#!/usr/bin/env bash
# test_sail_151_redteam_gate.sh — issue #151: /surf's merge-gate degradation compensation must
# cover the RED-TEAM lens (previously lens2-only) — fail-closed.
#
# The detection markers (redteam_requested / redteam_ran / redteam_configured / redteam_latched)
# already exist in review.json (#116). This pins:
#   (AC1/AC2) sail.review.redteam_status(review, backend_available=...) — a classifier mirroring
#             dual_lens_status(), split into compensable vs degraded by whether a red-team backend
#             is available NOW (configured-ness basis, NOT the review.json latch marker):
#               - "single-by-design" : not gated for red-team, OR gated but no backend configured
#                                      (operator's expected setup — proceed, not a park).
#               - "ok"               : gated for AND the red-team pass genuinely ran.
#               - "compensable"      : gated for, configured, did NOT run, backend available now
#                                      → supervisor re-runs it before merge.
#               - "degraded"         : gated for, configured, did NOT run, backend down now
#                                      → park, never merge (the fail-closed case #151 closes).
#   (AC6)     sail.review.redteam_gate_report(outcome[, sha]) — distinct operator labels for a
#             COMPENSATED pass vs a still-DEGRADED (parked) one.
# Hermetic: mock LLM CLI, real `python3 -m sail review`. Mirrors test_sail_74_dual_lens_signal.sh.
# shellcheck disable=SC2016
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"
# Clear inherited backends so each case controls its own (mirrors #74 round-3 hermeticity fix).
unset "${!SAIL_@}" 2>/dev/null || true

# Mock LLM CLI: ignores stdin, echoes a clean (no-findings) review, exit 0.
MOCK="$WORK/mock_llm.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "%s" "${MOCK_OUT:-}"' 'exit ${MOCK_RC:-0}' > "$MOCK"
chmod +x "$MOCK"

# Tiny git target with a committed base + a working-tree change to diff against.
TGT="$WORK/target"; mkdir -p "$TGT"
printf 'def f():\n    return 1\n' > "$TGT/mod.py"
git -C "$TGT" init -q
git -C "$TGT" add -A
git -C "$TGT" -c user.email=t@t -c user.name=t commit -qm base
printf 'def f():\n    return 2  # changed\n' > "$TGT/mod.py"

CLEAN_JSON='{"findings":[],"summary":"no issues"}'
field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$1" "$2"; }

# --- T1: gated for red-team AND it ran (backend runnable) → redteam_status == "ok". -------------
RD1="$WORK/rd1"
set +e; SAIL_REVIEW_CMD="bash $MOCK" SAIL_REDTEAM_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD1" --red-team >/dev/null 2>&1; set -e
[ "$(field "$RD1/review.json" redteam_requested)" = "True" ] || { echo "FAIL T1: redteam_requested != True"; exit 1; }
[ "$(field "$RD1/review.json" redteam_ran)" = "True" ]       || { echo "FAIL T1: redteam_ran != True"; exit 1; }
python3 - "$RD1/review.json" <<'PY'
import json, sys
from sail.review import redteam_status
r = json.load(open(sys.argv[1]))
assert redteam_status(r, backend_available=True)  == "ok", redteam_status(r, backend_available=True)
assert redteam_status(r, backend_available=False) == "ok", "a run that RAN is 'ok' regardless of live availability"
print("PASS T1: gated + ran → ok")
PY

# --- T2: gated + configured but DID NOT run, backend UP now → "compensable". --------------------
RD2="$WORK/rd2"
set +e; SAIL_REVIEW_CMD="bash $MOCK" SAIL_REDTEAM_CMD="/nonexistent/rt-xyz" MOCK_OUT="$CLEAN_JSON" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD2" --red-team >/dev/null 2>&1; set -e
[ "$(field "$RD2/review.json" redteam_requested)" = "True" ]  || { echo "FAIL T2: redteam_requested != True"; exit 1; }
[ "$(field "$RD2/review.json" redteam_ran)" = "False" ]       || { echo "FAIL T2: redteam_ran != False"; exit 1; }
[ "$(field "$RD2/review.json" redteam_configured)" = "True" ] || { echo "FAIL T2: redteam_configured != True"; exit 1; }
python3 - "$RD2/review.json" <<'PY'
import json, sys
from sail.review import redteam_status
r = json.load(open(sys.argv[1]))
assert redteam_status(r, backend_available=True)  == "compensable", redteam_status(r, backend_available=True)
assert redteam_status(r, backend_available=False) == "degraded",    redteam_status(r, backend_available=False)
print("PASS T2: gated+configured+absent → compensable (up) / degraded (down)")
PY

# --- T3: gated but NO backend configured → "single-by-design" (expected setup, not a park). -----
RD3="$WORK/rd3"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD3" --red-team >/dev/null 2>&1; set -e
[ "$(field "$RD3/review.json" redteam_requested)" = "True" ]   || { echo "FAIL T3: redteam_requested != True"; exit 1; }
[ "$(field "$RD3/review.json" redteam_ran)" = "False" ]        || { echo "FAIL T3: redteam_ran != False"; exit 1; }
[ "$(field "$RD3/review.json" redteam_configured)" = "False" ] || { echo "FAIL T3: redteam_configured != False"; exit 1; }
python3 - "$RD3/review.json" <<'PY'
import json, sys
from sail.review import redteam_status
r = json.load(open(sys.argv[1]))
# Unconfigured is the operator's expected single-lens setup — NEVER a park, regardless of live probe.
assert redteam_status(r, backend_available=False) == "single-by-design", redteam_status(r, backend_available=False)
assert redteam_status(r, backend_available=True)  == "single-by-design", redteam_status(r, backend_available=True)
print("PASS T3: gated but unconfigured → single-by-design (never a false park)")
PY

# --- T4: NOT gated for red-team (ordinary low-stakes diff) → "single-by-design". ----------------
RD4="$WORK/rd4"
set +e; SAIL_REVIEW_CMD="bash $MOCK" SAIL_REDTEAM_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD4" >/dev/null 2>&1; set -e
[ "$(field "$RD4/review.json" redteam_requested)" = "False" ] || { echo "FAIL T4: redteam_requested != False"; exit 1; }
python3 - "$RD4/review.json" <<'PY'
import json, sys
from sail.review import redteam_status
r = json.load(open(sys.argv[1]))
assert redteam_status(r, backend_available=True)  == "single-by-design", redteam_status(r, backend_available=True)
assert redteam_status(r, backend_available=False) == "single-by-design", redteam_status(r, backend_available=False)
print("PASS T4: not gated → single-by-design")
PY

# --- T5: truth table of the shipped classifier (hand-built dicts, hermetic). --------------------
python3 - <<'PY'
from sail.review import redteam_status
# not gated
assert redteam_status({"redteam_requested": False}, backend_available=True) == "single-by-design"
assert redteam_status({}, backend_available=True) == "single-by-design"
assert redteam_status(None, backend_available=True) == "single-by-design"
# ran
assert redteam_status({"redteam_requested": True, "redteam_ran": True}, backend_available=False) == "ok"
# gated, configured, absent → split on live availability
base = {"redteam_requested": True, "redteam_ran": False, "redteam_configured": True}
assert redteam_status(base, backend_available=True)  == "compensable"
assert redteam_status(base, backend_available=False) == "degraded"
# gated, UNconfigured, absent → never a park
unconf = {"redteam_requested": True, "redteam_ran": False, "redteam_configured": False}
assert redteam_status(unconf, backend_available=False) == "single-by-design"
assert redteam_status(unconf, backend_available=True)  == "single-by-design"
print("PASS T5: redteam_status truth table")
PY

# --- T6: AC6 — the reporting distinguishes 'compensated' from 'degraded' with distinct labels. --
python3 - <<'PY'
from sail.review import redteam_gate_report
tone_c, msg_c = redteam_gate_report("compensated", sha="abc1234")
tone_d, msg_d = redteam_gate_report("degraded")
assert tone_c == "INFO", tone_c
assert "compensat" in msg_c.lower(), msg_c
assert "abc1234" in msg_c, msg_c
assert tone_d == "ALERT", tone_d               # a configured-but-down lens is a real deviation (#112)
assert "degrad" in msg_d.lower() or "park" in msg_d.lower(), msg_d
assert msg_c != msg_d, "compensated and degraded must be DISTINCT labels (AC6)"
print("PASS T6: redteam_gate_report distinguishes compensated vs degraded (AC6)")
PY

echo "ALL PASS: test_sail_151_redteam_gate.sh"
