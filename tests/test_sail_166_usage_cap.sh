#!/usr/bin/env bash
# test_sail_166_usage_cap.sh — #166: proactive usage-cap avoidance via the statusline
# rate_limits feed (never hit 100%).
#
# Branch A (empirically confirmed on the issue): `statusLine.refreshInterval` re-runs the
# statusline command on a token-free timer while idle, and the payload's `.rate_limits` is
# FRESH + account-wide. So: a CK-Skills-owned statusline wrapper writes the 5h/7d
# used_percentage + resets_at to ~/.claude/usage-state.json on every fire, and the /surf
# orchestrator consults a deterministic predicate (tested sail/usage_cap.py) at each
# checkpoint — backoff at threshold, treat stale state as UNKNOWN → conservative hold.
#
# Infra-placement: decisions (threshold / staleness / wakeup-epoch) live in sail/usage_cap.py;
# the statusline wrapper is thin extraction glue; sequencing lives in surf.md.
#
# Repo is SHELL-TEST-ONLY (no pytest suite) — deterministic Python is unit-tested INLINE via
# python3 (the test_sail_146 pattern). Hermetic: fake $HOME in a tmp dir, SAIL_* cleared,
# fixed --now epochs, no live statusline/backend/git dependence.
#
# shellcheck disable=SC1091
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
unset "${!SAIL_@}" || true
cd "$REPO_ROOT"
fail() { echo "FAIL: $*"; exit 1; }

# A fixed "now" so every assertion is deterministic. resets: 5h in 1h, 7d in 3 days.
NOW=1753142400
FIVE_RESET=$((NOW + 3600))
SEVEN_RESET=$((NOW + 259200))

payload() {  # $1 = 5h pct, $2 = 7d pct  (the live-captured statusline stdin shape)
  cat <<EOF
{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42.0},
 "cost":{"total_cost_usd":1.23},
 "rate_limits":{
   "five_hour":{"used_percentage":$1,"resets_at":$FIVE_RESET},
   "seven_day":{"used_percentage":$2,"resets_at":$SEVEN_RESET}}}
EOF
}

# ============================================================================
# Part A — `sail usage-state write`: parse the statusline payload → usage-state.json
#   (5h+7d used_percentage + resets_at + written_at; atomic; rc 1 on an unusable payload)
# ============================================================================
STATE="$WORK/usage-state.json"
payload 58 41 | python3 -m sail usage-state write --out "$STATE" --now "$NOW" \
  || fail "A1: write rc on a good payload"
python3 - "$STATE" "$NOW" "$FIVE_RESET" "$SEVEN_RESET" <<'PY' || fail "A2: usage-state.json fields"
import json, sys
state = json.load(open(sys.argv[1]))
now, five_reset, seven_reset = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
assert state["written_at"] == now, state
assert state["five_hour"]["used_percentage"] == 58, state
assert state["five_hour"]["resets_at"] == five_reset, state
assert state["seven_day"]["used_percentage"] == 41, state
assert state["seven_day"]["resets_at"] == seven_reset, state
PY

# A payload with NO rate_limits (e.g. an older Claude Code) → rc 1 and no file written.
rm -f "$STATE"
echo '{"model":{"display_name":"Opus"}}' \
  | python3 -m sail usage-state write --out "$STATE" --now "$NOW" \
  && fail "A3: no-rate_limits payload must rc 1"
[ -f "$STATE" ] && fail "A4: no-rate_limits payload must not write a state file"

# Garbage stdin → rc 1, no file, no traceback spew on stdout.
echo 'not json' | python3 -m sail usage-state write --out "$STATE" --now "$NOW" \
  && fail "A5: garbage stdin must rc 1"
[ -f "$STATE" ] && fail "A6: garbage stdin must not write a state file"

# ============================================================================
# Part B — the CK-Skills statusline wrapper (home/statusline-usage-state.sh):
#   writes $HOME/.claude/usage-state.json on each fire, NEVER breaks rendering
#   (delegates to ~/.claude/statusline.sh when present; fail-open on any write problem)
# ============================================================================
WRAPPER="$REPO_ROOT/home/statusline-usage-state.sh"
[ -f "$WRAPPER" ] || fail "B0: home/statusline-usage-state.sh missing"
[ -x "$WRAPPER" ] || fail "B0b: wrapper not executable"

FAKE_HOME="$WORK/home"; mkdir -p "$FAKE_HOME/.claude"
cat > "$FAKE_HOME/.claude/statusline.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
printf 'RENDERED'
EOF
chmod +x "$FAKE_HOME/.claude/statusline.sh"

out="$(payload 58 41 | HOME="$FAKE_HOME" "$WRAPPER")" || fail "B1: wrapper rc with dispatcher present"
[ "$out" = "RENDERED" ] || fail "B2: wrapper must pass rendering through to statusline.sh (got: $out)"
[ -f "$FAKE_HOME/.claude/usage-state.json" ] || fail "B3: wrapper did not write usage-state.json"
python3 - "$FAKE_HOME/.claude/usage-state.json" <<'PY' || fail "B4: wrapper state fields"
import json, sys
state = json.load(open(sys.argv[1]))
assert state["five_hour"]["used_percentage"] == 58, state
assert state["seven_day"]["used_percentage"] == 41, state
assert isinstance(state["written_at"], int) and state["written_at"] > 0, state
PY

# No dispatcher in $HOME → still rc 0 (never crash the statusline), state still written.
FAKE_HOME2="$WORK/home2"; mkdir -p "$FAKE_HOME2/.claude"
payload 60 42 | HOME="$FAKE_HOME2" "$WRAPPER" >/dev/null || fail "B5: wrapper must rc 0 without a dispatcher"
[ -f "$FAKE_HOME2/.claude/usage-state.json" ] || fail "B6: state not written without a dispatcher"

# cwd-independence (#129 runtime class): the statusline fires from an ARBITRARY cwd (whatever
# project the session is in), so the wrapper must not depend on cwd for resolving the sail
# package. Run it from the tmp dir — the state must still be written.
FAKE_HOME4="$WORK/home4"; mkdir -p "$FAKE_HOME4/.claude"
( cd "$WORK" && payload 61 43 | HOME="$FAKE_HOME4" "$WRAPPER" >/dev/null ) \
  || fail "B10: wrapper must rc 0 from a non-repo cwd"
[ -f "$FAKE_HOME4/.claude/usage-state.json" ] || fail "B11: state not written when run from a non-repo cwd"

# A payload with no rate_limits → rendering still works, rc 0 (fail-open write), no state file.
FAKE_HOME3="$WORK/home3"; mkdir -p "$FAKE_HOME3/.claude"
cp "$FAKE_HOME/.claude/statusline.sh" "$FAKE_HOME3/.claude/statusline.sh"
out="$(echo '{"model":{"display_name":"Opus"}}' | HOME="$FAKE_HOME3" "$WRAPPER")" \
  || fail "B7: wrapper must rc 0 on a no-rate_limits payload"
[ "$out" = "RENDERED" ] || fail "B8: rendering must survive a no-rate_limits payload"
[ -f "$FAKE_HOME3/.claude/usage-state.json" ] && fail "B9: no-rate_limits payload must not write state"

# Preserve last-known-good (#166 round-1 HIGH): a transient bad payload must NOT delete a
# previously-written, still-fresh usage-state.json — the staleness guard (not eager deletion)
# is what governs trust in old data. A momentary hiccup must not force the next checkpoint
# into UNKNOWN when a fresh reading existed seconds earlier.
payload 58 41 | HOME="$FAKE_HOME3" "$WRAPPER" >/dev/null || fail "B12a: seeding good state failed"
[ -f "$FAKE_HOME3/.claude/usage-state.json" ] || fail "B12b: seed state missing"
echo '{"model":{"display_name":"Opus"}}' | HOME="$FAKE_HOME3" "$WRAPPER" >/dev/null \
  || fail "B12c: wrapper must rc 0 on a bad payload with prior state"
[ -f "$FAKE_HOME3/.claude/usage-state.json" ] || fail "B13: bad payload DELETED last-known-good state"
python3 - "$FAKE_HOME3/.claude/usage-state.json" <<'PY' || fail "B14: preserved state corrupted"
import json, sys
state = json.load(open(sys.argv[1]))
assert state["five_hour"]["used_percentage"] == 58, state
PY

# Rendering must survive a BROKEN python3 (#166 round-2 MEDIUM): the repo-root/write machinery
# exists only to support the best-effort state write — if python3 is missing/failing on the
# statusline's PATH, the wrapper must still delegate rendering (fail-open), never die under
# `set -e`. Shim a python3 that always fails ahead of the real one.
FAKE_HOME5="$WORK/home5"; mkdir -p "$FAKE_HOME5/.claude"
cp "$FAKE_HOME/.claude/statusline.sh" "$FAKE_HOME5/.claude/statusline.sh"
SHIM="$WORK/shim"; mkdir -p "$SHIM"
printf '#!/bin/sh\nexit 1\n' > "$SHIM/python3"; chmod +x "$SHIM/python3"
out="$(payload 58 41 | HOME="$FAKE_HOME5" PATH="$SHIM:$PATH" "$WRAPPER")" \
  || fail "B15: wrapper must rc 0 when python3 is broken"
[ "$out" = "RENDERED" ] || fail "B16: rendering must survive a broken python3 (got: $out)"
[ -f "$FAKE_HOME5/.claude/usage-state.json" ] && fail "B17: broken python3 must not write state"

# ============================================================================
# Part C — the decision predicate (sail.usage_cap.decide): threshold + staleness + wakeup
#   decide(state, now, threshold, cadence_secs, margin_secs) -> (decision, resume_epoch)
#   decision ∈ ok | backoff | unknown; UNKNOWN on stale/missing state (conservative).
# ============================================================================
python3 - "$NOW" "$FIVE_RESET" "$SEVEN_RESET" <<'PY' || fail "C: decide predicate"
import sys
from sail.usage_cap import decide

now, five_reset, seven_reset = (int(a) for a in sys.argv[1:4])

def state(five, seven, written_at, five_r=None, seven_r=None):
    return {
        "written_at": written_at,
        "five_hour": {"used_percentage": five, "resets_at": five_r or five_reset},
        "seven_day": {"used_percentage": seven, "resets_at": seven_r or seven_reset},
    }

# C1: fresh + both below threshold → ok, no resume epoch.
assert decide(state(58, 41, now), now, 90, 30, 120) == ("ok", None)

# C2: 5h AT the threshold → backoff (at counts), resume = 5h reset + margin.
d, resume = decide(state(90, 41, now), now, 90, 30, 120)
assert d == "backoff" and resume == five_reset + 120, (d, resume)

# C3: 5h above threshold → backoff at the 5h reset + margin.
d, resume = decide(state(95, 41, now), now, 90, 30, 120)
assert d == "backoff" and resume == five_reset + 120, (d, resume)

# C4: only the 7d window over → backoff at the SEVEN_DAY reset + margin.
d, resume = decide(state(10, 91, now), now, 90, 30, 120)
assert d == "backoff" and resume == seven_reset + 120, (d, resume)

# C5: BOTH windows over → the soonest exceeding reset is chosen (re-check clears one window).
d, resume = decide(state(95, 92, now), now, 90, 30, 120)
assert d == "backoff" and resume == five_reset + 120, (d, resume)

# C6: staleness guard — written_at older than 2× cadence → unknown (conservative), never ok.
assert decide(state(10, 10, now - 61), now, 90, 30, 120) == ("unknown", None)
# ...and exactly at the 2× boundary is still fresh.
assert decide(state(10, 10, now - 60), now, 90, 30, 120) == ("ok", None)

# C7: missing / malformed state → unknown.
assert decide(None, now, 90, 30, 120) == ("unknown", None)
assert decide({}, now, 90, 30, 120) == ("unknown", None)
assert decide({"written_at": "soon"}, now, 90, 30, 120) == ("unknown", None)

# C8: forward-only wakeup — an over-threshold window whose reset is already in the PAST
#     never yields a resume epoch in the past: resume = now + margin (immediate re-check).
d, resume = decide(state(95, 10, now, five_r=now - 100), now, 90, 30, 120)
assert d == "backoff" and resume == now + 120, (d, resume)

# C9: a window missing from the state (e.g. payload carried only five_hour) is not fatal;
#     the present window still decides.
partial = {"written_at": now, "five_hour": {"used_percentage": 95, "resets_at": five_reset}}
d, resume = decide(partial, now, 90, 30, 120)
assert d == "backoff" and resume == five_reset + 120, (d, resume)
PY

# ============================================================================
# Part D — `sail usage-state check` CLI: rc 0 ok / rc 1 backoff (prints resume epoch) /
#   rc 2 unknown. Env knobs SAIL_USAGE_THRESHOLD / SAIL_USAGE_REFRESH_SECS /
#   SAIL_USAGE_MARGIN_SECS override the defaults; flags override env.
# ============================================================================
payload 58 41 | python3 -m sail usage-state write --out "$STATE" --now "$NOW"

python3 -m sail usage-state check --state "$STATE" --now "$NOW" \
  || fail "D1: fresh below-threshold state must rc 0"

payload 95 41 | python3 -m sail usage-state write --out "$STATE" --now "$NOW"
set +e
out="$(python3 -m sail usage-state check --state "$STATE" --now "$NOW" --margin 120)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "D2: over-threshold must rc 1 (got $rc)"
[ "$out" = "backoff $((FIVE_RESET + 120))" ] || fail "D3: check must print 'backoff <resume_epoch>' (got: $out)"

# Stale state → rc 2 (unknown → conservative hold).
set +e
out="$(python3 -m sail usage-state check --state "$STATE" --now $((NOW + 3600)))"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "D4: stale state must rc 2 (got $rc)"
[ "$out" = "unknown" ] || fail "D5: stale check must print 'unknown' (got: $out)"

# Missing state file → rc 2 as well.
set +e
python3 -m sail usage-state check --state "$WORK/nope.json" --now "$NOW"; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "D6: missing state must rc 2 (got $rc)"

# Env-knob threshold: SAIL_USAGE_THRESHOLD=50 flips a 58% reading to backoff.
payload 58 41 | python3 -m sail usage-state write --out "$STATE" --now "$NOW"
set +e
SAIL_USAGE_THRESHOLD=50 python3 -m sail usage-state check --state "$STATE" --now "$NOW"; rc=$?
set -e
[ "$rc" -eq 1 ] || fail "D7: SAIL_USAGE_THRESHOLD env knob not honored (got rc $rc)"

# ============================================================================
# Part E — settings.reference.json documents the opt-in: statusLine.refreshInterval is a
#   number and statusLine.command points at the CK-Skills wrapper.
# ============================================================================
python3 - "$REPO_ROOT/home/settings.reference.json" <<'PY' || fail "E: settings.reference statusLine"
import json, sys
settings = json.load(open(sys.argv[1]))
sl = settings["statusLine"]
assert isinstance(sl.get("refreshInterval"), (int, float)) and sl["refreshInterval"] > 0, sl
assert "statusline-usage-state.sh" in sl.get("command", ""), sl
PY

echo "PASS: test_sail_166_usage_cap.sh"
