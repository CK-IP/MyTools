#!/usr/bin/env bash
# test_step6.sh
# Asserts that commands/fleet.md exists, is not empty, and contains key content.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/commands/fleet.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- Assertion 1: exists and is not empty ---
if [ -e "$TARGET" ] && [ -s "$TARGET" ]; then
  pass "commands/fleet.md exists and is not empty"
else
  fail "commands/fleet.md does not exist or is empty"
fi

# --- Assertion 2: contains "tmux" ---
if grep -q "tmux" "$TARGET" 2>/dev/null; then
  pass "contains 'tmux'"
else
  fail "does not contain 'tmux'"
fi

# --- Assertion 3: contains "QA" ---
if grep -q "QA" "$TARGET" 2>/dev/null; then
  pass "contains 'QA'"
else
  fail "does not contain 'QA'"
fi

# --- Assertion 4: contains "rolling" ---
if grep -q "rolling" "$TARGET" 2>/dev/null; then
  pass "contains 'rolling'"
else
  fail "does not contain 'rolling'"
fi

# --- Assertion 5: contains "merge" ---
if grep -q "merge" "$TARGET" 2>/dev/null; then
  pass "contains 'merge'"
else
  fail "does not contain 'merge'"
fi

# --- Assertion 6: contains "epic-brief" ---
if grep -q "epic-brief" "$TARGET" 2>/dev/null; then
  pass "contains 'epic-brief'"
else
  fail "does not contain 'epic-brief'"
fi

# --- Assertion 7: contains "contracts.md" ---
if grep -q "contracts.md" "$TARGET" 2>/dev/null; then
  pass "contains 'contracts.md'"
else
  fail "does not contain 'contracts.md'"
fi

# --- Assertion 8: contains "Done — I'll handle it" ---
if grep -q "Done — I'll handle it" "$TARGET" 2>/dev/null; then
  pass "contains 'Done — I'll handle it'"
else
  fail "does not contain 'Done — I'll handle it'"
fi

# --- Assertion 9: contains "domain.md" ---
if grep -q "domain.md" "$TARGET" 2>/dev/null; then
  pass "contains 'domain.md'"
else
  fail "does not contain 'domain.md'"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
