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

# --- Assertion 3: contains "/fleet" ---
if grep -q "/fleet" "$TARGET"; then
  pass "contains '/fleet'"
else
  fail "does not contain '/fleet'"
fi

# --- Assertion 4: contains "epic-brief" ---
if grep -q "epic-brief" "$TARGET"; then
  pass "contains 'epic-brief'"
else
  fail "does not contain 'epic-brief'"
fi

# --- Assertion 5: contains "Epic check" in a step header ---
if grep -q "Epic check" "$TARGET"; then
  pass "contains 'Epic check' step header"
else
  fail "does not contain 'Epic check' step header"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
