#!/usr/bin/env bash
# test_step5.sh
# Asserts that commands/idea.md contains Epic Mode content.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/commands/idea.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- Assertion 1: contains "Epic Mode" ---
if grep -q "Epic Mode" "$TARGET"; then
  pass "contains 'Epic Mode'"
else
  fail "does not contain 'Epic Mode'"
fi

# --- Assertion 2: contains "independent workstreams" ---
if grep -q "independent workstreams" "$TARGET"; then
  pass "contains 'independent workstreams'"
else
  fail "does not contain 'independent workstreams'"
fi

# --- Assertion 3: contains "/agent-team" ---
if grep -q "/agent-team" "$TARGET"; then
  pass "contains '/agent-team'"
else
  fail "does not contain '/agent-team'"
fi

# --- Assertion 4: contains "epic-brief" ---
if grep -q "epic-brief" "$TARGET"; then
  pass "contains 'epic-brief'"
else
  fail "does not contain 'epic-brief'"
fi

# --- Assertion 5: contains "Step 6/8" or "Step 7/8" or "Step 8/8" ---
if grep -qE "Step [678]/8" "$TARGET"; then
  pass "contains Epic Mode step numbering (Step X/8)"
else
  fail "does not contain any Epic Mode step numbering (Step 6/8, 7/8, or 8/8)"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
