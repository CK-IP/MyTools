#!/usr/bin/env bash
# test_step3.sh
# Asserts that INSTALL.md exists and contains required symlink setup instructions.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/INSTALL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- Assertion 1: INSTALL.md exists ---
if [ -f "$TARGET" ]; then
  pass "INSTALL.md exists"
else
  fail "INSTALL.md does not exist (expected path: $TARGET)"
fi

# --- Assertion 2: INSTALL.md contains a ln -s command ---
if [ -f "$TARGET" ] && grep -q 'ln -s' "$TARGET"; then
  pass "INSTALL.md contains a 'ln -s' symlink command"
elif [ -f "$TARGET" ]; then
  fail "INSTALL.md exists but does not contain 'ln -s'"
else
  fail "INSTALL.md does not exist — cannot check for 'ln -s'"
fi

# --- Assertion 3: INSTALL.md contains \$(pwd) portable path pattern ---
if [ -f "$TARGET" ] && grep -q '\$(pwd)' "$TARGET"; then
  pass "INSTALL.md contains \$(pwd) portable path pattern"
elif [ -f "$TARGET" ]; then
  fail "INSTALL.md exists but does not contain \$(pwd)"
else
  fail "INSTALL.md does not exist — cannot check for \$(pwd)"
fi

# --- Assertion 4: INSTALL.md contains ~/.claude/commands/idea.md symlink destination ---
if [ -f "$TARGET" ] && grep -q '~/.claude/commands/idea.md' "$TARGET"; then
  pass "INSTALL.md contains '~/.claude/commands/idea.md' symlink destination"
elif [ -f "$TARGET" ]; then
  fail "INSTALL.md exists but does not contain '~/.claude/commands/idea.md'"
else
  fail "INSTALL.md does not exist — cannot check for '~/.claude/commands/idea.md'"
fi

# --- Assertion 5: INSTALL.md mentions commands/idea.md as the source ---
if [ -f "$TARGET" ] && grep -q 'commands/idea\.md' "$TARGET"; then
  pass "INSTALL.md mentions 'commands/idea.md' as source"
elif [ -f "$TARGET" ]; then
  fail "INSTALL.md exists but does not mention 'commands/idea.md' as source"
else
  fail "INSTALL.md does not exist — cannot check for source path 'commands/idea.md'"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
