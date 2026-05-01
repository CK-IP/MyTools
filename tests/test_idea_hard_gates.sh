#!/usr/bin/env bash
# test_idea_hard_gates.sh
# Asserts that commands/idea.md enforces hard gates on every step.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/commands/idea.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- Assertion 1: "HARD GATE" appears BEFORE the first ## Step [0-9] header ---
# The compliance section must be near the top of the file.
FIRST_HARD_GATE=$(grep -n "HARD GATE" "$TARGET" 2>/dev/null | head -1 | cut -d: -f1 || true)
FIRST_STEP_HEADER=$(grep -nE "^## Step [0-9]" "$TARGET" 2>/dev/null | head -1 | cut -d: -f1 || true)
if [ -n "$FIRST_HARD_GATE" ] && [ -n "$FIRST_STEP_HEADER" ] && [ "$FIRST_HARD_GATE" -lt "$FIRST_STEP_HEADER" ]; then
  pass "HARD GATE text appears before first ## Step header"
else
  fail "HARD GATE text must appear before the first ## Step [0-9] header (compliance section at top)"
fi

# --- Assertion 2: at least 8 "DO NOT SKIP" directives (one per step) ---
DO_NOT_SKIP_COUNT=$(grep -c "DO NOT SKIP" "$TARGET" 2>/dev/null || true)
if [ "$DO_NOT_SKIP_COUNT" -ge 8 ]; then
  pass "DO NOT SKIP appears at least 8 times (got $DO_NOT_SKIP_COUNT)"
else
  fail "DO NOT SKIP must appear at least 8 times — got $DO_NOT_SKIP_COUNT (need one per step)"
fi

# --- Assertion 3: does NOT contain "only runs when relevant" ---
if ! grep -q "only runs when relevant" "$TARGET" 2>/dev/null; then
  pass "does not contain 'only runs when relevant'"
else
  fail "must NOT contain 'only runs when relevant' — epic check is now a mandatory hard gate"
fi

# --- Assertion 4: contains "NEVER" AND either "code directly" or "coding directly" ---
HAS_NEVER=$(grep -c "NEVER" "$TARGET" 2>/dev/null || true)
HAS_CODE_DIRECTLY=$(grep -cE "code directly|coding directly" "$TARGET" 2>/dev/null || true)
if [ "$HAS_NEVER" -gt 0 ] && [ "$HAS_CODE_DIRECTLY" -gt 0 ]; then
  pass "contains NEVER and code-directly prohibition"
else
  fail "must contain both 'NEVER' and 'code directly' or 'coding directly'"
fi

# --- Assertion 5: contains "/ship" ---
if grep -q "/ship" "$TARGET" 2>/dev/null; then
  pass "contains /ship invocation"
else
  fail "must contain /ship invocation"
fi

# --- Assertion 6: contains "/agent-team" ---
if grep -q "/agent-team" "$TARGET" 2>/dev/null; then
  pass "contains /agent-team invocation"
else
  fail "must contain /agent-team invocation"
fi

# --- Assertion 7: contains "MANDATORY" ---
if grep -q "MANDATORY" "$TARGET" 2>/dev/null; then
  pass "contains MANDATORY"
else
  fail "must contain MANDATORY (epic check and /ship or /agent-team invocation must be marked mandatory)"
fi

# --- Assertion 8: no Step X/7 remnants (7-step flow is replaced by 8-step flow) ---
STEP_SEVEN_FLOW=$(grep -cE "Step [0-9]+/7" "$TARGET" 2>/dev/null || true)
if [ "$STEP_SEVEN_FLOW" -eq 0 ]; then
  pass "no Step X/7 remnants"
else
  fail "must NOT contain Step X/7 patterns — got $STEP_SEVEN_FLOW occurrences (old 7-step flow must be fully removed)"
fi

# --- Assertion 9: does NOT contain legacy Epic Mode conditional section headers ---
HAS_NOT_ACTIVE=$(grep -c "When Epic Mode is NOT active" "$TARGET" 2>/dev/null || true)
HAS_IS_ACTIVE=$(grep -c "When Epic Mode IS active" "$TARGET" 2>/dev/null || true)
if [ "$HAS_NOT_ACTIVE" -eq 0 ] && [ "$HAS_IS_ACTIVE" -eq 0 ]; then
  pass "does not contain legacy Epic Mode conditional section headers"
else
  fail "must NOT contain 'When Epic Mode is NOT active' or 'When Epic Mode IS active' — steps are now always 8"
fi

# --- Assertion 10: exactly 8 numbered ## Step [0-9] headers ---
STEP_HEADER_COUNT=$(grep -cE "^## Step [0-9]" "$TARGET" 2>/dev/null || true)
if [ "$STEP_HEADER_COUNT" -eq 8 ]; then
  pass "exactly 8 numbered ## Step headers"
else
  fail "must have exactly 8 numbered ## Step [0-9] headers — got $STEP_HEADER_COUNT"
fi

# --- Assertion 11: does NOT contain "steps are renumbered" ---
if ! grep -q "steps are renumbered" "$TARGET" 2>/dev/null; then
  pass "does not contain 'steps are renumbered'"
else
  fail "must NOT contain 'steps are renumbered' — flow is always 8 steps, no conditional renumbering"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
