#!/usr/bin/env bash
# test_sail_167_cap_wait.sh — #167: same-window unmanned cap-wait + auto-resume.
#
# The orchestrator (a FOREGROUND interactive window — survives screen lock, unlike a
# harness background job, per Stage-1/2 empirical tests + the #157 reap) senses a usage
# wall via the #166 feed, then WAITS IN THE SAME WINDOW by chaining ScheduleWakeup toward
# `wake = resetsAt + buffer`. Because ScheduleWakeup caps at 3600s, a long (e.g. 5h) wait
# must chain in <=3600s hops; a multi-day (7d) wall is too long to hold a window open, so it
# parks + hands off (the convoy-adapted wall-length policy).
#
# This pins the two NEW pure helpers #167 adds to sail/usage_cap.py:
#   - next_hop(wake, now)   -> the next ScheduleWakeup hop: min(3600, wake-now); forward-only
#                              (never negative / past-arming); terminal 0 once now >= wake.
#   - wall_policy(wake, now) -> 'wait-in-window' for a <=ceiling (5h) wall; 'park-and-handoff'
#                              for a multi-day/7d wall. Ceiling default 21600s (6h, convoy's
#                              PARK_THRESHOLD), overridable via SAIL_WALL_CEILING_SECONDS.
# It reuses (does NOT reinvent) #166's reset_wakeup_epoch (wake = resetsAt + margin) and the
# dual-window _window_reset for the soonest-applicable-reset selection.
#
# Infra-placement: the deterministic wake-timer math lives in tested sail/usage_cap.py; the
# sense->chain->resume-in-place sequencing lives in surf.md.
#
# Repo is SHELL-TEST-ONLY (no pytest suite) — deterministic Python is unit-tested INLINE via
# python3 (the #166/#146 pattern). Hermetic: fake $HOME, SAIL_* cleared, fixed/frozen `now`
# passed in, never the live clock.
#
# shellcheck disable=SC1091
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
unset "${!SAIL_@}" || true
cd "$REPO_ROOT"
fail() { echo "FAIL: $*"; exit 1; }

# Frozen "now" + reset epochs: a 5h window resetting in 5h, a 7d window resetting in 3 days.
NOW=1753142400
FIVE_RESET=$((NOW + 18000))     # 5h out
SEVEN_RESET=$((NOW + 259200))   # 3 days out
MARGIN=120                      # buffer past reset

# ---- next_hop: forward-only, <=3600 cap, terminal at/after wake ----
python3 - "$NOW" <<'PY' || fail "next_hop behavior"
import sys
from sail.usage_cap import next_hop
now = int(sys.argv[1])

# >1h remaining -> capped at 3600
assert next_hop(now + 18000, now) == 3600, "should cap at 3600 for a long wait"
# within the final hour -> exact remaining, and > 0
assert next_hop(now + 900, now) == 900, "should return exact remaining under 1h"
assert next_hop(now + 3600, now) == 3600, "exactly 1h -> 3600"
assert next_hop(now + 1, now) == 1, "1s remaining -> 1"
# terminal at/after wake -> 0, never negative
assert next_hop(now, now) == 0, "at wake -> terminal 0"
assert next_hop(now - 10, now) == 0, "past wake -> terminal 0 (never negative)"
assert next_hop(now - 100000, now) == 0, "far past wake -> terminal 0"
# never returns a negative hop for any ordering
for w in (now - 5, now, now + 1, now + 3600, now + 999999):
    assert next_hop(w, now) >= 0, "hop is never negative"
print("next_hop ok")
PY

# ---- wall_policy: 5h wall waits in-window; multi-day parks; boundary at the ceiling ----
python3 - "$NOW" "$FIVE_RESET" "$SEVEN_RESET" "$MARGIN" <<'PY' || fail "wall_policy behavior"
import sys
from sail.usage_cap import wall_policy, reset_wakeup_epoch
now, five, seven, margin = map(int, sys.argv[1:5])

# a 5h wall -> wait in the same window
wake_5h = reset_wakeup_epoch(five, now, margin)
assert wall_policy(wake_5h, now) == "wait-in-window", "5h wall should wait in-window"
# a multi-day (7d) wall -> park and hand off
wake_7d = reset_wakeup_epoch(seven, now, margin)
assert wall_policy(wake_7d, now) == "park-and-handoff", "multi-day wall should park"

# boundary at the default 6h (21600s) ceiling
assert wall_policy(now + 21600, now) == "wait-in-window", "exactly 6h -> wait-in-window"
assert wall_policy(now + 21601, now) == "park-and-handoff", "just over 6h -> park"
print("wall_policy ok")
PY

# ---- wall_policy ceiling is env-overridable (SAIL_WALL_CEILING_SECONDS) ----
SAIL_WALL_CEILING_SECONDS=3600 python3 - "$NOW" <<'PY' || fail "wall_policy env override"
import sys
from sail.usage_cap import wall_policy
now = int(sys.argv[1])
# with a 1h ceiling, a 2h wait now parks
assert wall_policy(now + 7200, now) == "park-and-handoff", "2h wait parks under a 1h ceiling"
assert wall_policy(now + 3600, now) == "wait-in-window", "1h wait waits under a 1h ceiling"
print("wall_policy env ok")
PY

# ---- dual-window: the SELECTION logic in decide() picks the soonest reset (not the test's own
#      min): drive decide() with BOTH windows over threshold and assert the returned wake epoch
#      corresponds to the five_hour (soonest) reset — so a mutation to decide()'s min/tie-break
#      would actually fail this test (it did NOT before: the test computed min() itself). ----
python3 - "$NOW" "$FIVE_RESET" "$SEVEN_RESET" "$MARGIN" <<'PY' || fail "dual-window soonest reset via decide()"
import sys
from sail.usage_cap import decide, reset_wakeup_epoch, BACKOFF
now, five, seven, margin = map(int, sys.argv[1:5])
threshold, refresh = 90, 30
# both windows over threshold; five_hour resets soonest -> its reset must govern the wake.
state = {"written_at": now,
         "five_hour": {"used_percentage": 95, "resets_at": five},
         "seven_day": {"used_percentage": 99, "resets_at": seven}}
decision, wake = decide(state, now, threshold, refresh, margin)
assert decision == BACKOFF, f"both over threshold -> backoff, got {decision}"
assert wake == reset_wakeup_epoch(five, now, margin), "soonest (five_hour) reset must drive the wake"
# and the first chained hop toward that wake is capped at 3600
from sail.usage_cap import next_hop
assert next_hop(wake, now) == 3600, "first hop toward a >1h wake is capped"
# flip which window is sooner -> selection must follow (seven_day now sooner)
state2 = {"written_at": now,
          "five_hour": {"used_percentage": 95, "resets_at": now + 200000},
          "seven_day": {"used_percentage": 99, "resets_at": now + 4000}}
_, wake2 = decide(state2, now, threshold, refresh, margin)
assert wake2 == reset_wakeup_epoch(now + 4000, now, margin), "selection must follow the actually-soonest reset"
print("dual-window ok")
PY

# ---- CLI reachability (#167 redteam finding): the helpers must be invocable via the
#      `python3 -m sail usage-state ...` pattern the surf.md loop consumes — not orphaned. ----
HOP="$(python3 -m sail usage-state hop --wake $((NOW + 18000)) --now "$NOW")" || fail "usage-state hop rc"
[ "$HOP" = "3600" ] || fail "usage-state hop: expected 3600, got '$HOP'"
HOP2="$(python3 -m sail usage-state hop --wake $((NOW - 5)) --now "$NOW")" || fail "usage-state hop terminal rc"
[ "$HOP2" = "0" ] || fail "usage-state hop: past wake -> 0, got '$HOP2'"
WP="$(python3 -m sail usage-state wall-policy --wake "$FIVE_RESET" --now "$NOW")" || fail "usage-state wall-policy rc"
[ "$WP" = "wait-in-window" ] || fail "usage-state wall-policy: 5h -> wait-in-window, got '$WP'"
WP2="$(python3 -m sail usage-state wall-policy --wake "$SEVEN_RESET" --now "$NOW")" || fail "usage-state wall-policy rc2"
[ "$WP2" = "park-and-handoff" ] || fail "usage-state wall-policy: multi-day -> park-and-handoff, got '$WP2'"
echo "cli ok"

# ---- hermetic clock: the test never reads the live clock (every call injects `now`) ----
grep -Eq 'time\.time|datetime\.now|date \+%s' "$0" && fail "test must not read the live clock" || true

echo "PASS: test_sail_167_cap_wait.sh"
