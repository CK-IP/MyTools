#!/usr/bin/env bash
# test_surf_134_housekeeping.sh — pins the #124 housekeeping cleanup (issue #134).
#
# #124 swapped /surf's per-issue body to a headless worker but left the pre-swap
# pane/exit-code model in place, so both co-exist and in two spots CONTRADICT the
# new contract. These assertions pin the cleaned-up state:
#   Tier 1 — the stale-and-now-wrong exit-code/agent-teams/teammate text is gone and
#            the merge contract reads as artifact-based (matching Steps 6/7/8).
#   Tier 2 — the #124 contract is de-duplicated (one authoritative home + pointers).
#   Tier 3 — the tmux send-keys auto-revive is gone; the panes lens survives as a
#            pure visibility option.
# shellcheck disable=SC2015,SC2016
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SURF="$REPO_ROOT/commands/surf.md"
WORKER="$REPO_ROOT/config/surf-worker.sh"
RESUME="$REPO_ROOT/config/surf-resume.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Extract the "## Merge policy" section so Step-9 assertions are scoped, not file-wide.
MERGE_SECTION="$(awk '/^## Merge policy/{f=1} f{print} f&&/^## Dependent issues/{exit}' "$SURF")"

# ── Tier 1: stale-and-now-wrong ────────────────────────────────────────────────

# T1. Step 9 no longer DEFINES green as "sail run … exited 0".
grep -qF 'Green means `python3 -m sail run --diff main` **exited 0**' "$SURF" \
  && fail "T1 Step 9 still defines green as 'exited 0' (contradicts the #124 artifact contract)" \
  || pass "T1 Step 9 no longer defines green via 'exited 0'"

# T2. Step 9 no longer parks on "Any exit-1 run" as the rule.
printf '%s' "$MERGE_SECTION" | grep -qF 'Any exit-1 run' \
  && fail "T2 Step 9 still parks on 'Any exit-1 run' (exit-code framing)" \
  || pass "T2 Step 9 no longer keys park on 'Any exit-1 run'"

# T3. The Merge-policy section states the artifact-based, fail-closed contract and that the
#     worker process exit code is informational/ignored (matches Steps 6/7/8 + surf-worker.sh).
printf '%s' "$MERGE_SECTION" | grep -qiE 'run-state\.json' \
  && printf '%s' "$MERGE_SECTION" | grep -qiE 'review\.json' \
  && pass "T3 Merge policy names the durable run-dir artifacts (run-state.json + review.json)" \
  || fail "T3 Merge policy does not state the durable-artifact green source"
# T3c. wip-handoff.md is the THIRD fail-closed signal in Step 9's green/park definition — pin it so a
# future edit can't silently drop it from the contract (lens1 test-adequacy finding, #134 review r1).
printf '%s' "$MERGE_SECTION" | grep -qiF 'wip-handoff' \
  && pass "T3c Merge policy names wip-handoff.md as a fail-closed signal" \
  || fail "T3c Merge policy missing the wip-handoff.md condition"
# (newlines→spaces so the check survives prose line-wrapping of "exit\ncode")
printf '%s' "$MERGE_SECTION" | tr '\n' ' ' | grep -qiE 'exit code.*(ignored|informational)|(ignores|ignored|informational).*exit code' \
  && pass "T3b Merge policy states the worker exit code is ignored/informational" \
  || fail "T3b Merge policy does not state the exit code is ignored/informational"

# T4. The Rules start-gate bullet no longer demands agent-teams "in both modes / refuse the loop".
grep -qiF 'since both delegate to teammates' "$SURF" \
  && fail "T4 Rules still demands agent-teams 'since both delegate to teammates' (contradicts Steps 2/3)" \
  || pass "T4 Rules no longer demands agent-teams in both modes"

# T5. The Rules no longer says auto-merge keys on "exit 0 / any other exit code is parked".
grep -qF 'Auto-merge only on `python3 -m sail run --diff main` exit 0' "$SURF" \
  && fail "T5 Rules still says 'Auto-merge only on … exit 0' (reintroduces the Step-9 defect)" \
  || pass "T5 Rules auto-merge bullet no longer keys on exit 0"

# T6. The "stalled teammate's already-green work" wording is de-teammate'd. (NB: the phrase wraps
#     across a line break in the source — match the single-line fragment that actually exists.)
grep -qiF "teammate's already-green" "$SURF" \
  && fail "T6 'teammate's already-green work' wording remains on the headless default path" \
  || pass "T6 teammate wording de-teammate'd"

# T7. surf-worker.sh comment no longer names the removed liveness functions.
grep -qE 'surf_worker_wait|surf_worker_pgkill|_identity\)' "$WORKER" \
  && fail "T7 surf-worker.sh still names removed funcs (surf_worker_wait/_pgkill/_identity)" \
  || pass "T7 surf-worker.sh no longer names the removed liveness functions"

# ── Tier 2: de-duplicate the #124 contract ─────────────────────────────────────

# T8. The macOS-lesson signature is de-duplicated within surf.md (was 3×).
MACOS_N="$(grep -ciF 'fights macOS' "$SURF")"
[ "$MACOS_N" -le 2 ] \
  && pass "T8 'fights macOS' de-duplicated in surf.md (count=$MACOS_N ≤ 2)" \
  || fail "T8 'fights macOS' still duplicated in surf.md (count=$MACOS_N > 2)"

# T9. Step 8b is reduced to a pointer (not a re-narration of the docs §7 table).
# Span from the Step-8b heading to its closing '---'. Was 19 lines (full re-narration); a pointer
# is materially shorter. ≤10 proves the table is no longer restated inline.
STEP8B_LINES="$(awk '/^### Step 8b/{s=NR} s&&/^---/{print NR-s; exit}' "$SURF")"
{ [ -n "$STEP8B_LINES" ] && [ "$STEP8B_LINES" -le 10 ]; } \
  && pass "T9 Step 8b reduced to a pointer (span=$STEP8B_LINES lines ≤ 10, was 19)" \
  || fail "T9 Step 8b still re-narrates the table (span=${STEP8B_LINES:-?} lines > 10)"
# T9b. Step 8b still points to docs §7 (the authoritative home survives).
awk '/^### Step 8b/{f=1} f{print} f&&/^---/{exit}' "$SURF" | grep -qiE '§7|surf-convoy-comparison' \
  && pass "T9b Step 8b still points to docs §7" \
  || fail "T9b Step 8b lost its pointer to docs §7"

# ── Tier 3: trim the panes lens (keep visibility, cut auto-revive) ──────────────

# T10. The tmux send-keys in-place auto-revive note is gone from surf.md.
grep -qiE 'revive the still-alive session in place|in-place revive' "$SURF" \
  && fail "T10 surf.md still carries the send-keys in-place auto-revive note" \
  || pass "T10 send-keys in-place auto-revive note removed from surf.md"

# T11. The panes lens SURVIVES as a pure visibility option (not removed).
grep -qiE 'supervised \(panes\) lens' "$SURF" \
  && grep -qi 'visibility' "$SURF" \
  && pass "T11 optional panes lens retained as a visibility option" \
  || fail "T11 panes visibility lens was lost (should be trimmed, not removed)"

# T12. surf-resume.sh no longer claims the optional lens may revive a session in place.
grep -qiF 'may still revive a long-lived session in place' "$RESUME" \
  && fail "T12 surf-resume.sh still claims the lens 'may still revive … in place'" \
  || pass "T12 surf-resume.sh auto-revive claim removed"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
