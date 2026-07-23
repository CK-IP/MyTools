#!/usr/bin/env bash
# test_sail_144_within_wave_priority.sh — #144: within-wave launch order honors the Step 5b
# approved priority order (option (b)), not the ascending-id tie-break.
#
#   Follow-up to #91. Within a single wave, `sail/waves.py::wave_eligible` returns the eligible set
#   sorted by ascending id, and `launchable` takes the cap-many from the FRONT of that order. When
#   the eligible set exceeds the manual cap, the LOWEST-numbered issues win the cap slots — which
#   ignores the risk/value rank Step 5b established for the approved work list (the dependency graph
#   carries deps, not rank, so priority was invisible to the helper).
#
#   #144 plumbs the Step 5b ordered work-list ids into `launchable`/`state` as an optional
#   `priority` input: launchability is computed exactly as today (deps satisfied — parent-before-
#   dependent is unaffected because a dependent is never eligible before its parent merges), THEN
#   the launchable pool is stable-ordered by each id's position in the priority list (ascending-id
#   fallback for ids absent from the list), and the cap-many are taken from the front of THAT
#   ranked order. With no priority list the behavior is exactly today's (back-compat).
#
#   Per the repo infra-placement rule the ranking decision is a tested Python predicate in
#   sail/waves.py; the wall-clock scheduling stays prose in commands/surf.md. Repo is
#   SHELL-TEST-ONLY, so the predicates are unit-tested inline via python3 (the established
#   test_sail_91/95/113/131 pattern); CLI reachability is exercised through `python3 -m sail waves`;
#   the prose is asserted structurally from canonical new tokens.
#
# shellcheck disable=SC1091
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
unset "${!SAIL_@}" || true   # hermetic: a real shell exports SAIL_* codex knobs — clear them
cd "$REPO_ROOT"
fail() { echo "FAIL: $*"; exit 1; }

# ============================================================================
# Part A — priority-ordered cap selection as a deterministic predicate (AC#4/#5/#6 + back-compat)
# ============================================================================
python3 - <<'PY' || fail "A: sail.waves priority-ordered launchable contract"
from sail.waves import launchable, make_run_state

# --- back-compat: NO priority -> exactly today's ascending-id-from-eligible behavior -------------
assert launchable([1, 2, 3, 4], cap=2, in_flight=[]) == [1, 2], "no-priority must keep today's behavior"
assert launchable([1, 2, 3, 4], cap=2, in_flight=[], priority=[]) == [1, 2], "empty priority == no priority"
assert launchable([1, 2, 3, 4], cap=2, in_flight=[], priority=None) == [1, 2]

# --- AC#4: cap-constrained wave + INVERTED priority -> highest-ranked win the cap slots ----------
# eligible {1,2,3,4}, cap 2, priority inverts id order (4 highest, then 3,2,1).
# Ascending-id would pick [1,2]; priority must pick the two HIGHEST-ranked -> [4,3].
assert launchable([1, 2, 3, 4], cap=2, in_flight=[], priority=[4, 3, 2, 1]) == [4, 3], \
    "cap-constrained: the cap-many selected must be the highest-ranked ids, not the lowest-numbered"
# a partial re-rank: priority says do 3 first, then 1; 2 and 4 unranked (fall back to ascending id).
# ranked-first order: [3, 1, 2, 4]; cap 2 -> [3, 1].
assert launchable([1, 2, 3, 4], cap=2, in_flight=[], priority=[3, 1]) == [3, 1], \
    "ranked ids come first in priority order; cap slices from the front of the ranked order"

# --- AC#6: ids ABSENT from priority sort AFTER ranked ids, in ascending-id order -----------------
# priority ranks only 4; the rest (1,2,3) are unranked -> [4, 1, 2, 3]; cap 3 -> [4, 1, 2].
assert launchable([1, 2, 3, 4], cap=3, in_flight=[], priority=[4]) == [4, 1, 2], \
    "unranked ids must follow ranked ids in ascending-id order"
# priority ids not present in the eligible set are simply ignored (never invent work).
assert launchable([1, 2], cap=10, in_flight=[], priority=[99, 2, 1]) == [2, 1], \
    "priority ids absent from the eligible set are ignored; present ranked ids order the pool"

# --- in-flight + priority compose: an in-flight id never launches; priority orders the rest ------
# eligible offered {2,3,4}, 1 in flight, cap 2 -> one free slot; priority [4,3,2] -> pick [4].
assert launchable([2, 3, 4], cap=2, in_flight=[1], priority=[4, 3, 2]) == [4], \
    "priority orders the launchable pool; the in-flight id still consumes its cap slot"

# --- AC#5: parent-before-dependent holds under priority ranking ----------------------------------
# Graph: 1 has no deps; 2,3 depend on 1. Priority tries to launch the DEPENDENTS first ([3,2,1]).
# Nothing merged: only the dep-free parent (1) is eligible, so priority CANNOT hoist a dependent
# ahead of its unmerged parent — launchability is computed before ranking.
st = make_run_state({1: [], 2: [1], 3: [1]}, cap=5, merged=[], in_flight=[], awaiting_merge=[], priority=[3, 2, 1])
assert st.eligible() == [1], "a dependent is not eligible before its parent merges — even if priority ranks it first"
assert st.launchable() == [1], "priority must never launch a dependent ahead of its unmerged parent"
# once the parent merges, the dependents become eligible and priority DOES order them: [3, 2].
st2 = make_run_state({1: [], 2: [1], 3: [1]}, cap=5, merged=[1], in_flight=[], awaiting_merge=[], priority=[3, 2, 1])
assert st2.eligible() == [2, 3], "dependents eligible once parent merged"
assert st2.launchable() == [3, 2], "with the parent merged, priority orders the now-eligible dependents"

# make_run_state with NO priority is back-compat (ascending-id).
st3 = make_run_state({1: [], 2: [], 3: [], 4: []}, cap=2, merged=[], in_flight=[], awaiting_merge=[])
assert st3.launchable() == [1, 2], "make_run_state without priority keeps ascending-id behavior"
PY

# ============================================================================
# Part B — the priority input is REACHABLE by the markdown driver via `python3 -m sail waves …`
# ============================================================================
# `waves launchable --priority` orders the cap selection by priority.
out="$(python3 -m sail waves launchable --eligible '1 2 3 4' --cap 2 --priority '4 3 2 1')" \
  || fail "B1: 'waves launchable --priority' rc!=0"
[ "$out" = "4 3" ] || fail "B2: expected priority-ordered '4 3', got '$out'"
# no --priority keeps today's ascending-id behavior (back-compat CLI default).
out="$(python3 -m sail waves launchable --eligible '1 2 3 4' --cap 2)" \
  || fail "B3: 'waves launchable' (no priority) rc!=0"
[ "$out" = "1 2" ] || fail "B4: expected back-compat '1 2', got '$out'"

# `waves state --priority` composes graph+cap+priority into the launchable decision.
state="$(python3 -m sail waves state --graph '{"1": [], "2": [], "3": [], "4": []}' --cap 2 --priority '4 3 2 1')" \
  || fail "B5: 'waves state --priority' rc!=0"
python3 - "$state" <<'PY' || fail "B6: 'waves state --priority' did not honor priority in the launchable slice"
import json, sys
s = json.loads(sys.argv[1])
assert s["eligible"] == [1, 2, 3, 4], f"state.eligible wrong: {s.get('eligible')}"
assert s["launchable"] == [4, 3], f"state.launchable must honor priority: {s.get('launchable')}"
PY

# ============================================================================
# Part C — the orchestration POLICY is documented in commands/surf.md
# ============================================================================
SURF_MD="commands/surf.md"
# within-wave launch honors the approved priority order (not ascending id)
grep -Eqi "within-wave|intra-wave" "$SURF_MD" || fail "C1: surf.md missing the within-wave launch-order note"
grep -qi "priority" "$SURF_MD"                || fail "C2: surf.md must document within-wave priority ordering"
# the priority is passed to the waves helper
grep -qi -- "--priority" "$SURF_MD"           || fail "C3: surf.md must pass --priority to the waves helper"
# the ordered list is read from the durable Step 5b artifact (charter) so resume re-ranks identically
grep -Eqi "resume[^.]*re-rank|re-rank[^.]*resume|durable[^.]*priorit|priorit[^.]*charter|charter[^.]*priorit" "$SURF_MD" \
  || fail "C4: surf.md must document the durable Step 5b ordered-list source so resume re-ranks identically"

echo "PASS: test_sail_144_within_wave_priority"
