#!/usr/bin/env bash
# test_sail_91_parallel_waves.sh — #91: /surf parallel-build / serial-merge mode with a manual cap.
#
#   /surf today clears the board one issue at a time. #91 adds an OPTIONAL parallel-build mode:
#   build several *independent* issues at once (bounded by a manual cap), while keeping MERGES
#   strictly serial with a safety re-check (`sail run --diff main`) immediately before each merge.
#
#   Per the repo's infrastructure-placement rule, the two DETERMINISTIC decisions —
#     (a) wave-eligibility  (an issue is buildable now iff ALL its deps are merged to main), and
#     (b) cap enforcement   (live concurrent builds never exceed the manual cap),
#   plus cap input-validation (2–10) — live in a tested `sail/waves.py` helper (judgment→LLM,
#   deterministic decisions→tested Python). The wall-clock scheduling (launching workers, waiting
#   on merges) stays prose orchestration in commands/surf.md.
#
#   Repo is SHELL-TEST-ONLY (no pytest suite), so the Python predicates are unit-tested INLINE via
#   python3 (the established test_sail_95/113/131 pattern); the CLI reachability is exercised through
#   `python3 -m sail waves …`; the prose is asserted structurally from canonical new tokens that do
#   NOT exist in surf.md today (so the red phase genuinely fails before the build).
#
# shellcheck disable=SC1091
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
unset "${!SAIL_@}" || true   # hermetic: a real shell exports SAIL_* codex knobs — clear them
cd "$REPO_ROOT"
fail() { echo "FAIL: $*"; exit 1; }

# ============================================================================
# Part A — wave-eligibility + cap enforcement + cap-validation as deterministic predicates (AC#3)
# ============================================================================
python3 - <<'PY' || fail "A: sail.waves deterministic predicate contract"
from sail.waves import normalize_cap, wave_eligible, launchable

# --- (1) cap input-validation: a manual cap is an integer in [2,10] -----------------------------
assert normalize_cap(2) == 2
assert normalize_cap(10) == 10
assert normalize_cap("2") == 2          # accept an int-like string (interactive prompt input)
assert normalize_cap(" 7 ") == 7
for bad in (0, 1, 11, 100, -3, "abc", "", None, 2.5):
    try:
        normalize_cap(bad)
    except (ValueError, TypeError):
        pass
    else:
        raise AssertionError(f"normalize_cap({bad!r}) must reject an out-of-range / non-integer cap")

# --- (2) wave-eligibility: an issue is buildable now iff ALL deps are merged to main -------------
# Graph: A has no deps; B depends on A; C depends on A and B. (Step 5b dependency graph shape.)
graph = {1: [], 2: [1], 3: [1, 2]}

# Nothing merged yet -> only the dependency-free issue (A=1) is eligible; B,C wait for their parents.
assert wave_eligible(graph, merged=[]) == [1], "only the dep-free issue is eligible on an empty main"
assert 2 not in wave_eligible(graph, merged=[]), "a dependent issue must NOT be eligible while its parent is unmerged"

# A merged -> B becomes eligible; A (already merged) is no longer eligible; C still waits for B.
assert wave_eligible(graph, merged=[1]) == [2], "dependent becomes eligible only after its parent merges to main"

# A and B merged -> C becomes eligible.
assert wave_eligible(graph, merged=[1, 2]) == [3]

# Already-merged / explicitly-excluded (parked, in-flight, done) issues are never re-offered.
assert wave_eligible(graph, merged=[1, 2, 3]) == [], "fully-merged board yields no eligible issue"
assert wave_eligible(graph, merged=[1], exclude=[2]) == [], "an excluded (in-flight/parked) issue is not eligible"

# --- (3) cap enforcement: live concurrent builds never exceed the cap ----------------------------
# 4 eligible, cap 2, nothing in flight -> launch exactly 2 (the cap), in eligible order.
assert launchable([1, 2, 3, 4], cap=2, in_flight=[]) == [1, 2]
# 1 already building (cap 2) -> only 1 more slot, never exceeding the cap of 2 live builds.
got = launchable([2, 3, 4], cap=2, in_flight=[1])
assert len(got) == 1 and len(got) + 1 <= 2, "launchable must leave total live builds <= cap"
assert got == [2]
# Already AT the cap -> launch nothing.
assert launchable([3, 4], cap=2, in_flight=[1, 2]) == [], "no new builds when already at the cap"
# An in-flight issue is never double-launched even if it reappears in the eligible set.
assert 1 not in launchable([1, 2, 3], cap=3, in_flight=[1]), "an in-flight issue must never be re-launched"
# Fewer eligible than free slots -> launch only what's eligible (never negative / never invents work).
assert launchable([5], cap=10, in_flight=[]) == [5]
PY

# ============================================================================
# Part B — the helper is REACHABLE by the markdown driver via `python3 -m sail waves …` (AC#3)
# ============================================================================
# cap validation: an in-range cap prints the normalized value (rc 0)
out="$(python3 -m sail waves cap --value 2)" || fail "B1: 'waves cap --value 2' rc!=0 for a valid cap"
[ "$out" = "2" ] || fail "B2: expected normalized cap '2', got '$out'"
out="$(python3 -m sail waves cap --value 10)" || fail "B3: 'waves cap --value 10' rc!=0 for a valid cap"
[ "$out" = "10" ] || fail "B4: expected '10', got '$out'"
# out-of-range caps are rejected (rc!=0) — the picker must never accept 1 or 11.
# `if`-guarded so the bug case (a wrongly-accepted cap) unambiguously aborts: under `set -e` a
# `fail` as the last command of the then-branch terminates the script (no trailing `|| true` to
# dilute the signal).
if python3 -m sail waves cap --value 1  2>/dev/null; then fail "B5: cap 1 must be rejected (below 2)"; fi
if python3 -m sail waves cap --value 11 2>/dev/null; then fail "B6: cap 11 must be rejected (above 10)"; fi

# eligibility is reachable: graph A->B (B deps on A), nothing merged -> only A eligible
elig="$(python3 -m sail waves eligible --graph '{"1": [], "2": [1]}' --merged '')" \
  || fail "B7: 'waves eligible' rc!=0"
echo "$elig" | grep -qw 1 || fail "B8: dep-free issue 1 must be eligible on empty main"
if echo "$elig" | grep -qw 2; then fail "B9: dependent issue 2 must NOT be eligible while parent 1 unmerged"; fi
# after the parent merges, the dependent is eligible
elig2="$(python3 -m sail waves eligible --graph '{"1": [], "2": [1]}' --merged '1')" \
  || fail "B10: 'waves eligible' rc!=0 (parent merged)"
echo "$elig2" | grep -qw 2 || fail "B11: dependent 2 must be eligible once parent 1 merged to main"

# ============================================================================
# Part C — the orchestration POLICY is documented in commands/surf.md (AC#1/#2/#4/#5)
# ============================================================================
SURF_MD="commands/surf.md"

# AC#1 — startup run-style picker: Sequential (default, == today) vs Parallel, interactive (no flags)
grep -qi "run-style" "$SURF_MD"        || fail "C1: surf.md missing the 'run-style' picker"
grep -qi "Sequential" "$SURF_MD"       || fail "C2: surf.md missing the Sequential run-style"
grep -qi "Parallel"   "$SURF_MD"       || fail "C3: surf.md missing the Parallel run-style"
# Sequential is the explicit default whose behavior equals today's
grep -Eqi "Sequential[^.]*default|default[^.]*Sequential" "$SURF_MD" \
  || fail "C4: surf.md must name Sequential as the default run-style"
# no-flags principle preserved — the picker is an interactive AskUserQuestion choice, not a --flag
grep -qi "AskUserQuestion" "$SURF_MD"  || fail "C5: run-style picker must be an interactive AskUserQuestion choice"

# AC#2 — Parallel prompts for a manual cap in [2,10]; concurrent builds never exceed it
grep -qi "concurrency cap" "$SURF_MD"  || fail "C6: surf.md missing the 'concurrency cap'"
grep -Eqi "2[ –to-]+10" "$SURF_MD"     || fail "C7: surf.md missing the 2–10 cap range"

# AC: the deterministic decisions are reached via the tested helper, not eyeballed in prose
grep -qi "sail waves" "$SURF_MD"       || fail "C8: surf.md must invoke 'python3 -m sail waves' (driver reachability)"

# the wave scheduler concept: a wave = issues whose deps are already merged to main
grep -qi "wave scheduler\|wave =\|wave:" "$SURF_MD" || fail "C9: surf.md missing the wave scheduler"
grep -Eqi "merged to .?main" "$SURF_MD"            || fail "C10: surf.md wave must key on deps merged to main"

# AC#4 — merge-time safety re-check: re-run `sail run --diff main` before merging a parallel branch;
# green -> one --no-ff merge + SHA, not-green -> park (NOT merge). Merges stay one-at-a-time.
grep -qi "re-validat" "$SURF_MD"            || fail "C11: surf.md missing the merge-time re-validation"
grep -qi "sail run --diff main" "$SURF_MD"  || fail "C12: surf.md re-validation must re-run 'sail run --diff main'"
grep -Eqi "one at a time|one-at-a-time|serial" "$SURF_MD" || fail "C13: surf.md must keep merges serial"
# park-on-red is explicit at the re-validation gate (a now-red branch is parked, not merged)
grep -Eqi "not.?green[^.]*park|park[^.]*not.?green|re-validat[^.]*park|fail[^.]*park" "$SURF_MD" \
  || fail "C14: surf.md must park (not merge) a branch that fails re-validation"

# AC#5 — durable journal markers for in-flight parallel builds and built-green-awaiting-merge,
# plus resume reconciliation of those markers
grep -Eqi "awaiting.?merge" "$SURF_MD"      || fail "C15: surf.md missing the 'awaiting-merge' journal marker"
grep -qi "resume" "$SURF_MD"                || fail "C16: surf.md must reconcile the markers on resume"

# Sequential mode is unchanged / parallel is strictly additive
grep -Eqi "Sequential[^.]*unchanged|unchanged[^.]*Sequential|identical to today|exactly as today" "$SURF_MD" \
  || fail "C17: surf.md must state Sequential mode is unchanged from today"

# ============================================================================
# Part D — the COMPOSED scheduler tick (WaveRunState / make_run_state / `waves state`) is the
#   load-bearing integration surface surf.md drives, and it is behaviorally tested (AC#3/#6).
#   It composes graph + merged + in-flight + awaiting-merge + cap into one eligible+launchable
#   decision: live issues are excluded from eligibility (never re-launched), and — because the
#   cap counts concurrent BUILDS (#91: "how many issues may build at the same time") — a
#   built-green branch merely AWAITING the serial merge slot does NOT consume a build-cap slot.
# ============================================================================
python3 - <<'PY' || fail "D: WaveRunState composed scheduler tick contract"
from sail.waves import make_run_state

# eligibility excludes BOTH in-flight and awaiting-merge issues (so a live issue is never re-offered).
# A->B,C,D (B,C,D depend on A). A merged; B in-flight; C awaiting-merge -> only D is newly eligible.
st = make_run_state({1: [], 2: [1], 3: [1], 4: [1]}, cap=10, merged=[1], in_flight=[2], awaiting_merge=[3])
assert st.eligible() == [4], "in-flight (2) and awaiting-merge (3) must both be excluded from eligibility"

# the cap counts concurrent BUILDS: an awaiting-merge branch has finished building and must NOT
# consume a build slot. cap=2, 0 building, issue 1 awaiting-merge -> both 2 and 3 may build.
st2 = make_run_state({1: [], 2: [], 3: [], 4: []}, cap=2, merged=[], in_flight=[], awaiting_merge=[1])
assert st2.eligible() == [2, 3, 4], "awaiting-merge issue 1 excluded from eligibility"
assert st2.launchable() == [2, 3], "awaiting-merge must NOT consume a build-cap slot (cap=2 builds -> launch 2)"

# an actively-building issue DOES consume a build slot (the cap is real for live builds).
st3 = make_run_state({1: [], 2: [], 3: []}, cap=2, merged=[], in_flight=[1], awaiting_merge=[])
assert st3.launchable() == [2], "one build in flight (cap 2) leaves exactly one build slot"
PY

# `waves state` exposes the composed tick to the markdown driver end-to-end (AC#3 reachability)
state="$(python3 -m sail waves state --graph '{"1": [], "2": [], "3": []}' --cap 2 --in-flight '' --awaiting-merge '1')" \
  || fail "D-CLI: 'waves state' rc!=0"
python3 - "$state" <<'PY' || fail "D-CLI: 'waves state' did not compose eligible+launchable correctly"
import json, sys
s = json.loads(sys.argv[1])
assert s["eligible"] == [2, 3], f"state.eligible wrong: {s.get('eligible')}"
assert s["launchable"] == [2, 3], f"awaiting-merge must not consume a build slot: {s.get('launchable')}"
assert s["cap"] == 2
PY

echo "PASS: test_sail_91_parallel_waves"
