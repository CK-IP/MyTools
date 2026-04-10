#!/usr/bin/env bash
# test_step1.sh
# Asserts that commands/idea.md exists and is not empty.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/commands/idea.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- Assertion 1: commands/idea.md exists ---
if [ -e "$TARGET" ]; then
  pass "commands/idea.md exists"
else
  fail "commands/idea.md does not exist (expected path: $TARGET)"
fi

# --- Assertion 2: commands/idea.md is not empty ---
if [ -e "$TARGET" ] && [ -s "$TARGET" ]; then
  pass "commands/idea.md is not empty"
elif [ -e "$TARGET" ]; then
  fail "commands/idea.md exists but is empty"
else
  fail "commands/idea.md does not exist — cannot check if non-empty"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
