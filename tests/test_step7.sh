#!/usr/bin/env bash
# test_step7.sh
# Asserts that INSTALL.md contains the new skill setup instructions.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/INSTALL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- Assertion 1: contains "commands/epic-brief-schema.md" ---
if grep -q "commands/epic-brief-schema.md" "$TARGET" 2>/dev/null; then
  pass "contains 'commands/epic-brief-schema.md'"
else
  fail "does not contain 'commands/epic-brief-schema.md'"
fi

# --- Assertion 2: contains "~/.claude/commands/epic-brief-schema.md" ---
if grep -q '~/.claude/commands/epic-brief-schema.md' "$TARGET" 2>/dev/null; then
  pass "contains '~/.claude/commands/epic-brief-schema.md'"
else
  fail "does not contain '~/.claude/commands/epic-brief-schema.md'"
fi

# --- Assertion 3: contains "commands/agent-team.md" ---
if grep -q "commands/agent-team.md" "$TARGET" 2>/dev/null; then
  pass "contains 'commands/agent-team.md'"
else
  fail "does not contain 'commands/agent-team.md'"
fi

# --- Assertion 4: contains "~/.claude/commands/agent-team.md" ---
if grep -q '~/.claude/commands/agent-team.md' "$TARGET" 2>/dev/null; then
  pass "contains '~/.claude/commands/agent-team.md'"
else
  fail "does not contain '~/.claude/commands/agent-team.md'"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
