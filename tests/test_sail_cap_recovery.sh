#!/usr/bin/env bash
# test_sail_cap_recovery.sh — hermetic tests for sail/cap_recovery.py, the single source of truth
# for /surf cap-recovery decisions (#163). All decisions the launchd watcher (config/surf-resume.sh)
# and the /surf supervisor share live here: cap-vs-park classification, dual-horizon reset parsing
# (5h clock+IANA-TZ AND weekly weekday/date/in-N-days), forward-only `resume-after` arming with a
# default->real correction, per-issue cap-state.json, the zero-relaunch-before-resume-after gate,
# wall-clock-bounded recovery, and the anomaly-count.
#
# Hermetic: cd into the repo, unset every SAIL_* var so a caller's env cannot leak in, use throwaway
# temp dirs, inject a frozen `--now` epoch everywhere so no test reads the wall clock, and make no
# live git / working-tree / branch assertions. The CLI is invoked exactly as the shell glue invokes
# it (cap text on STDIN, never interpolated) so the injection-safe interface is exercised too.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SRC_DIR"
# Scrub SAIL_* AND SURF_* so the module's behavior is pinned by args/stdin only (hermetic): the
# module reads BOTH the SAIL_CAP_RECOVERY_* knobs and the legacy SURF_RESUME_* / SURF_CAP_RECOVERY_*
# fallbacks from the environment, so a caller's SURF_* var would otherwise leak into a test's floor math.
for v in $(env | sed -nE 's/^((SAIL|SURF)_[A-Za-z0-9_]+)=.*/\1/p'); do unset "$v"; done

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1  ($2)"; FAIL=$((FAIL + 1)); }

CR() { python3 -m sail cap-recovery "$@"; }

# A fixed reference "now": 2026-07-21T18:00:00Z (Tue). Reset "1:20pm America/New_York" == 17:20Z the
# same day, which is in the PAST of 18:00Z, so the next occurrence rolls to the next day (5h shape).
NOW=1784656800   # `date -u -d 2026-07-21T18:00:00Z +%s` (Tue)
DAY=86400

epoch_of() { # RFC3339 Z -> epoch (portable)
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" "+%s" 2>/dev/null || date -u -d "$1" "+%s" 2>/dev/null || true
}

# --- 1. Classifier: cap wall vs build-park -----------------------------------------------------
if printf 'You have hit your session limit · resets 1:20pm (America/New_York)\n' | CR classify >/dev/null 2>&1; then
  pass "classify: session-limit line is a cap (rc 0)"
else
  fail "classify: session-limit line should classify as cap" "rc!=0"
fi
if printf 'weekly limit reached; resets Monday\n' | CR classify >/dev/null 2>&1; then
  pass "classify: weekly-limit line is a cap"
else
  fail "classify: weekly-limit line should be a cap" "rc!=0"
fi
if printf 'sail: parked — genuine oscillation; wrote wip-handoff.md\n' | CR classify >/dev/null 2>&1; then
  fail "classify: a build-park must NOT be a cap" "rc==0"
else
  pass "classify: build-park/handoff is not a cap (rc!=0)"
fi
if printf 'review found 2 HIGH findings; converge=revise\n' | CR classify >/dev/null 2>&1; then
  fail "classify: an ordinary non-zero build result must NOT be a cap" "rc==0"
else
  pass "classify: ordinary build failure is not a cap"
fi

# --- 2. 5h reset parse (clock + IANA TZ) -------------------------------------------------------
OUT="$(printf 'You have hit your session limit · resets 1:20pm (America/New_York)\n' | CR parse-reset --now "$NOW")"
if [ -n "$OUT" ]; then
  E="$(epoch_of "$OUT")"
  # Next 1:20pm ET after 18:00Z 2026-07-21 is 2026-07-22 17:20Z == NOW + (23h20m).
  if [ -n "$E" ] && [ "$E" -gt "$NOW" ] && [ "$E" -lt $((NOW + 2*DAY)) ]; then
    pass "parse-reset: 5h clock+TZ -> next future occurrence ($OUT)"
  else
    fail "parse-reset: 5h reset epoch out of expected window" "$OUT / $E"
  fi
else
  fail "parse-reset: 5h clock+TZ should parse" "empty"
fi

# --- 3. Weekly reset parse (the +1-day bug fix) ------------------------------------------------
# "in 3 days" is unambiguous and TZ-free -> must land >1 day out (old +1-day roll-forward could not).
OUT="$(printf 'weekly limit reached; resets in 3 days\n' | CR parse-reset --now "$NOW")"
E="$(epoch_of "${OUT:-}")"
if [ -n "$E" ] && [ "$E" -gt $((NOW + DAY)) ] && [ "$E" -le $((NOW + 4*DAY)) ]; then
  pass "parse-reset: weekly 'in 3 days' lands >1 day out ($OUT)"
else
  fail "parse-reset: weekly 'in 3 days' should be >1 day out" "$OUT / $E"
fi
# A weekday shape must also parse to a future epoch that can be >1 day out.
OUT="$(printf 'weekly limit; resets Monday 9am (America/New_York)\n' | CR parse-reset --now "$NOW")"
E="$(epoch_of "${OUT:-}")"
if [ -n "$E" ] && [ "$E" -gt "$NOW" ] && [ "$E" -le $((NOW + 8*DAY)) ]; then
  pass "parse-reset: weekly weekday shape parses to a future epoch ($OUT)"
else
  fail "parse-reset: weekly weekday shape should parse" "$OUT / $E"
fi

# --- 4. Unparseable / bad TZ -> empty (caller uses bounded default) ----------------------------
OUT="$(printf 'usage limit reached; try again later\n' | CR parse-reset --now "$NOW")"
if [ -z "$OUT" ]; then
  pass "parse-reset: unparseable reset -> empty (caller backs off safely)"
else
  fail "parse-reset: unparseable reset should be empty" "$OUT"
fi
OUT="$(printf 'session limit; resets 9am (Not/AZone)\n' | CR parse-reset --now "$NOW")"
if [ -z "$OUT" ]; then
  pass "parse-reset: bad IANA TZ -> empty, no bogus epoch"
else
  fail "parse-reset: bad TZ should yield empty (safe), not a bogus epoch" "$OUT"
fi

# --- 5. arm writes resume-after + per-issue cap-state.json -------------------------------------
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
SURF="$WORK/.surf"; mkdir -p "$SURF"
printf 'session limit · resets 1:20pm (America/New_York)\n' | CR arm --surf-dir "$SURF" --issue 163 --now "$NOW" >/dev/null
if [ -f "$SURF/resume-after" ]; then
  pass "arm: writes .surf/resume-after"
else
  fail "arm: should write .surf/resume-after" "missing"
fi
CS="$SURF/runs/163/cap-state.json"
if [ -f "$CS" ]; then
  if python3 -c "import json,sys; d=json.load(open('$CS')); assert d.get('limit-type') in ('5h','weekly','unknown'); assert 'reset-after' in d; assert int(d.get('anomaly-count',0))>=0" 2>/dev/null; then
    pass "arm: writes per-issue cap-state.json with reset-after/limit-type/anomaly-count"
  else
    fail "arm: cap-state.json schema" "bad schema"
  fi
else
  fail "arm: should write per-issue cap-state.json" "missing $CS"
fi

# --- 6. gate: zero relaunch before resume-after (the ~6-attempt regression) --------------------
# Freshly armed floor is in the future -> gate must say WAIT (rc!=0), no relaunch.
if CR gate --surf-dir "$SURF" --now "$NOW" >/dev/null 2>&1; then
  fail "gate: must NOT be ready while resume-after is in the future" "rc==0"
else
  pass "gate: waits (no relaunch) while resume-after is in the future"
fi
# Once now passes the floor, the gate opens.
FUTURE=$((NOW + 10*DAY))
if CR gate --surf-dir "$SURF" --now "$FUTURE" >/dev/null 2>&1; then
  pass "gate: ready once now >= resume-after"
else
  fail "gate: should be ready after resume-after passes" "rc!=0"
fi

# --- 7. Forward-only arming; default->real correction ------------------------------------------
# Re-arm with a LATER reset -> floor advances forward.
FLOOR1="$(epoch_of "$(cat "$SURF/resume-after")")"
printf 'weekly limit; resets in 5 days\n' | CR arm --surf-dir "$SURF" --issue 163 --now "$NOW" >/dev/null
FLOOR2="$(epoch_of "$(cat "$SURF/resume-after")")"
if [ "$FLOOR2" -gt "$FLOOR1" ]; then
  pass "arm: a later reset advances the floor forward"
else
  fail "arm: later reset should advance the floor" "$FLOOR1 -> $FLOOR2"
fi
# Re-arm with an EARLIER *real* reset -> a real reset does NOT move the floor backward (monotonic).
printf 'session limit; resets 1:20pm (America/New_York)\n' | CR arm --surf-dir "$SURF" --issue 163 --now "$NOW" >/dev/null
FLOOR3="$(epoch_of "$(cat "$SURF/resume-after")")"
if [ "$FLOOR3" -ge "$FLOOR2" ]; then
  pass "arm: an earlier real reset does not move the floor backward (monotonic)"
else
  fail "arm: monotonic forward violated by earlier real reset" "$FLOOR2 -> $FLOOR3"
fi
# default->real correction: a DEFAULT placeholder floor is replaceable by a real parsed reset.
SURF2="$WORK/.surf2"; mkdir -p "$SURF2"
printf 'usage limit reached; try again later\n' | CR arm --surf-dir "$SURF2" --issue 200 --now "$NOW" >/dev/null   # unparseable -> default floor
DEF="$(epoch_of "$(cat "$SURF2/resume-after")")"
printf 'session limit; resets 1:20pm (America/New_York)\n' | CR arm --surf-dir "$SURF2" --issue 200 --now "$NOW" >/dev/null  # real reset
REAL="$(epoch_of "$(cat "$SURF2/resume-after")")"
if [ -n "$DEF" ] && [ -n "$REAL" ] && [ "$REAL" != "$DEF" ]; then
  pass "arm: a real reset corrects a prior default/placeholder floor"
else
  fail "arm: default->real correction did not take effect" "$DEF vs $REAL"
fi

# --- 8. Wall-clock bounded (>= 8 days), never an unbounded wait --------------------------------
CEIL="$(CR ceiling-seconds)"
if [ -n "$CEIL" ] && [ "$CEIL" -ge $((8*DAY)) ]; then
  pass "ceiling-seconds: default wall-clock ceiling is >= 8 days ($CEIL)"
else
  fail "ceiling-seconds: default ceiling should be >= 8 days" "$CEIL"
fi
# An armed floor can never be beyond now + ceiling even for a far reset.
SURF3="$WORK/.surf3"; mkdir -p "$SURF3"
printf 'weekly limit; resets in 30 days\n' | CR arm --surf-dir "$SURF3" --issue 300 --now "$NOW" --ceiling-secs $((8*DAY)) >/dev/null
FAR="$(epoch_of "$(cat "$SURF3/resume-after")")"
if [ -n "$FAR" ] && [ "$FAR" -le $((NOW + 8*DAY + 3600)) ]; then
  pass "arm: an armed floor is capped at now + ceiling (never waits beyond the ceiling)"
else
  fail "arm: floor exceeded the wall-clock ceiling" "$FAR"
fi

# --- 9. Anomaly-count: only a post-reset-still-capped retry increments -------------------------
SURF4="$WORK/.surf4"; mkdir -p "$SURF4"
printf 'session limit; resets 1:20pm (America/New_York)\n' | CR arm --surf-dir "$SURF4" --issue 400 --now "$NOW" >/dev/null
A1="$(python3 -c "import json;print(json.load(open('$SURF4/runs/400/cap-state.json'))['anomaly-count'])")"
# A PREMATURE re-cap (before the armed reset) re-arms forward WITHOUT incrementing.
printf 'session limit; resets 1:20pm (America/New_York)\n' | CR arm --surf-dir "$SURF4" --issue 400 --now $((NOW + 60)) >/dev/null
A2="$(python3 -c "import json;print(json.load(open('$SURF4/runs/400/cap-state.json'))['anomaly-count'])")"
if [ "$A2" = "$A1" ]; then
  pass "anomaly-count: a premature re-cap re-arms forward without incrementing"
else
  fail "anomaly-count: premature re-cap must not increment" "$A1 -> $A2"
fi
# A retry AFTER the armed reset that is STILL capped is a genuine anomaly -> increments.
POST=$((NOW + 3*DAY))   # well past the armed 5h floor
printf 'session limit; resets 1:20pm (America/New_York)\n' | CR arm --surf-dir "$SURF4" --issue 400 --now "$POST" >/dev/null
A3="$(python3 -c "import json;print(json.load(open('$SURF4/runs/400/cap-state.json'))['anomaly-count'])")"
if [ "$A3" -gt "$A2" ]; then
  pass "anomaly-count: a post-reset-still-capped retry increments the anomaly count"
else
  fail "anomaly-count: post-reset-still-capped retry should increment" "$A2 -> $A3"
fi

# --- 10. Clean-relaunch clears the floor + cap-state (lifecycle) -------------------------------
CR clear --surf-dir "$SURF4" --issue 400 >/dev/null 2>&1 || true
if [ ! -f "$SURF4/resume-after" ] && [ ! -f "$SURF4/runs/400/cap-state.json" ]; then
  pass "clear: a clean relaunch clears resume-after and per-issue cap-state"
else
  fail "clear: should remove resume-after and cap-state" "still present"
fi

# --- 11. Injection-safe: a malicious reset string / issue id cannot inject shell ---------------
SURF5="$WORK/.surf5"; mkdir -p "$SURF5"
# shellcheck disable=SC2016  # the $(...)/`...` MUST stay literal — this string is the injection payload.
MAL='session limit; resets 1:20pm (America/New_York) $(touch '"$WORK"'/PWNED) `touch '"$WORK"'/PWNED2` ; rm -rf /'
printf '%s\n' "$MAL" | CR arm --surf-dir "$SURF5" --issue 500 --now "$NOW" >/dev/null 2>&1 || true
if [ ! -e "$WORK/PWNED" ] && [ ! -e "$WORK/PWNED2" ]; then
  pass "injection-safe: cap text on stdin cannot execute embedded shell"
else
  fail "injection-safe: embedded shell in cap text executed" "PWNED present"
fi
# A non-numeric / malicious issue id is rejected (no path traversal / injection).
if printf 'session limit; resets 1:20pm (America/New_York)\n' | CR arm --surf-dir "$SURF5" --issue '../../etc' --now "$NOW" >/dev/null 2>&1; then
  fail "injection-safe: a malicious issue id should be rejected" "accepted"
else
  pass "injection-safe: a non-numeric/malicious issue id is rejected"
fi

# --- 12. apiKeySource preflight (AC10) — subscription (none) is quiet; an API key WARNs ---------
# Per convoy `_convoy_check_apikeysource`: apiKeySource=none == NO API key == subscription (the
# healthy case cap-recovery is built for) -> QUIET (#112: don't cry wolf). Any other source == on an
# API key -> WARN at ALERT tier.
if CR apikey-preflight --source none >/dev/null 2>&1; then
  pass "apikey-preflight: apiKeySource=none (subscription) is quiet (rc 0)"
else
  fail "apikey-preflight: apiKeySource=none (subscription) must be quiet" "rc!=0"
fi
if CR apikey-preflight --source ANTHROPIC_API_KEY >/dev/null 2>&1; then
  fail "apikey-preflight: a run on an API key must WARN (non-zero/ALERT)" "rc==0 quiet"
else
  pass "apikey-preflight: a run on an API key warns (rc!=0, ALERT tier)"
fi
OUTW="$(CR apikey-preflight --source ANTHROPIC_API_KEY 2>&1 || true)"
case "$OUTW" in
  *ALERT*|*WARN*) pass "apikey-preflight: emits an ALERT/WARN-tier message on an API key" ;;
  *) fail "apikey-preflight: should emit an ALERT/WARN message on an API key" "$OUTW" ;;
esac

# --- 13. Global (issue-agnostic) arm — the whole-board launchd watcher path (#163 review) --------
SURF6="$WORK/.surf6"; mkdir -p "$SURF6"
printf 'session limit; resets 1:20pm (America/New_York)\n' | CR arm --surf-dir "$SURF6" --now "$NOW" >/dev/null
if [ -f "$SURF6/resume-after" ] && [ -f "$SURF6/cap-state.json" ] && [ ! -d "$SURF6/runs" ]; then
  pass "arm (no --issue): arms the GLOBAL cap-state (.surf/cap-state.json), no per-issue dir"
else
  fail "arm (no --issue): should write global resume-after + cap-state.json" "$(ls "$SURF6" 2>/dev/null)"
fi

# --- 14. Never-hot-loop MIN_BACKOFF floor even on an imminent parsed reset (watcher delegates) ----
# With a MIN_BACKOFF larger than the parsed reset (~23h) but under the ceiling, the armed floor is
# pushed out to now + MIN_BACKOFF — never sooner (no hot-loop).
SURF7="$WORK/.surf7"; mkdir -p "$SURF7"
ARMED_RFC="$(printf 'session limit; resets 1:20pm (America/New_York)\n' \
  | SAIL_CAP_RECOVERY_MIN_BACKOFF_SECS=200000 CR arm --surf-dir "$SURF7" --now "$NOW")"
ARMED_E="$(epoch_of "${ARMED_RFC:-}")"
if [ -n "$ARMED_E" ] && [ "$ARMED_E" -ge $((NOW + 200000)) ]; then
  pass "arm: never hot-loops — floor respects MIN_BACKOFF even when the parsed reset is sooner"
else
  fail "arm: MIN_BACKOFF floor not enforced" "$ARMED_RFC / $ARMED_E"
fi

# --- 15. relinquish arms the shared floor AND writes the .surf/capped marker (scenario 5) --------
SURF8="$WORK/.surf8"; mkdir -p "$SURF8"
printf 'session limit; resets 1:20pm (America/New_York)\n' | CR relinquish --surf-dir "$SURF8" --now "$NOW" >/dev/null
if [ -f "$SURF8/resume-after" ] && [ -f "$SURF8/capped" ]; then
  pass "relinquish: arms resume-after AND writes the .surf/capped self-relinquish marker"
else
  fail "relinquish: should arm resume-after and write .surf/capped" "$(ls "$SURF8" 2>/dev/null)"
fi
# --- 16. clear (global) removes resume-after + cap-state + the stuck capped marker (redteam fix) --
CR clear --surf-dir "$SURF8" >/dev/null 2>&1 || true
if [ ! -f "$SURF8/resume-after" ] && [ ! -f "$SURF8/capped" ] && [ ! -f "$SURF8/cap-state.json" ]; then
  pass "clear (global): removes resume-after, global cap-state AND the capped marker (no stuck marker)"
else
  fail "clear (global): should remove resume-after/cap-state/capped" "$(ls "$SURF8" 2>/dev/null)"
fi

echo
echo "cap-recovery: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
