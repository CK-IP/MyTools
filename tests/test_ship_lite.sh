#!/usr/bin/env bash
# test_ship_lite.sh
# Structural assertions for commands/ship-lite.md and hooks/ship-lite-stop-gate.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/commands/ship-lite.md"
HOOK="$REPO_ROOT/hooks/ship-lite-stop-gate.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- Skill file assertions ---

# 1: skill file exists and is not empty
if [ -e "$SKILL" ] && [ -s "$SKILL" ]; then
  pass "commands/ship-lite.md exists and is not empty"
else
  fail "commands/ship-lite.md does not exist or is empty"
fi

# 2: contains /implement invocation
if grep -q "/implement" "$SKILL" 2>/dev/null; then
  pass "contains /implement invocation"
else
  fail "does not contain /implement invocation"
fi

# 3: contains @red-team reference
if grep -q "red-team" "$SKILL" 2>/dev/null; then
  pass "contains red-team reference"
else
  fail "does not contain red-team reference"
fi

# 4: contains worktree management
if grep -q "worktree" "$SKILL" 2>/dev/null; then
  pass "contains worktree management"
else
  fail "does not contain worktree management"
fi

# 5: contains ship-state reference (for shared hooks)
if grep -q "ship-state" "$SKILL" 2>/dev/null; then
  pass "contains ship-state reference"
else
  fail "does not contain ship-state reference"
fi

# 6: contains domain.md reference
if grep -q "domain.md" "$SKILL" 2>/dev/null; then
  pass "contains domain.md reference"
else
  fail "does not contain domain.md reference"
fi

# 7: contains ship-write-gate.sh hook
if grep -q "ship-write-gate.sh" "$SKILL" 2>/dev/null; then
  pass "contains ship-write-gate.sh hook"
else
  fail "does not contain ship-write-gate.sh hook"
fi

# 8: contains ship-wip.sh hook
if grep -q "ship-wip.sh" "$SKILL" 2>/dev/null; then
  pass "contains ship-wip.sh hook"
else
  fail "does not contain ship-wip.sh hook"
fi

# 9: contains escalation to /ship
if grep -q "Escalate to /ship" "$SKILL" 2>/dev/null; then
  pass "contains escalation to /ship"
else
  fail "does not contain escalation to /ship"
fi

# 10: contains sentinel cleanup
if grep -q "ship-lite-active" "$SKILL" 2>/dev/null; then
  pass "contains ship-lite-active sentinel"
else
  fail "does not contain ship-lite-active sentinel"
fi

# 11: contains "pipeline.*ship-lite" in state file
if grep -q '"pipeline": "ship-lite"' "$SKILL" 2>/dev/null; then
  pass "state file has pipeline: ship-lite identifier"
else
  fail "state file missing pipeline: ship-lite identifier"
fi

# 12: does NOT contain "compass" (ship-lite skips compass)
if ! grep -qi "compass" "$SKILL" 2>/dev/null; then
  pass "does not contain compass (correctly omitted)"
else
  fail "contains compass — ship-lite should not use compass"
fi

# 13: does NOT contain "leadsman" (ship-lite skips leadsman)
if ! grep -qi "leadsman" "$SKILL" 2>/dev/null; then
  pass "does not contain leadsman (correctly omitted)"
else
  fail "contains leadsman — ship-lite should not use leadsman"
fi

# --- Hook file assertions ---

# 14: hook file exists and is executable
if [ -e "$HOOK" ] && [ -x "$HOOK" ]; then
  pass "hooks/ship-lite-stop-gate.sh exists and is executable"
else
  fail "hooks/ship-lite-stop-gate.sh does not exist or is not executable"
fi

# 15: hook contains sentinel check
if grep -q "ship-lite-active" "$HOOK" 2>/dev/null; then
  pass "hook checks ship-lite-active sentinel"
else
  fail "hook does not check ship-lite-active sentinel"
fi

# 16: hook contains stop_hook_active guard
if grep -q "stop_hook_active" "$HOOK" 2>/dev/null; then
  pass "hook has stop_hook_active infinite-loop guard"
else
  fail "hook missing stop_hook_active guard"
fi

# 17: hook contains agent_id guard
if grep -q "agent_id" "$HOOK" 2>/dev/null; then
  pass "hook has agent_id subagent guard"
else
  fail "hook missing agent_id guard"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
