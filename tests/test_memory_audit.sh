#!/usr/bin/env bash
# test_memory_audit.sh
# Structural assertions for commands/memory-audit.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/commands/memory-audit.md"
INSTALL="$REPO_ROOT/INSTALL.md"
README="$REPO_ROOT/README.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- 1: skill file exists and is not empty ---
if [ -f "$SKILL" ] && [ -s "$SKILL" ]; then
  pass "commands/memory-audit.md exists and is not empty"
else
  fail "commands/memory-audit.md does not exist or is empty"
fi

# --- 2: contains all four step announcements ---
for step in "Step 1/4" "Step 2/4" "Step 3/4" "Step 4/4"; do
  if grep -q "$step" "$SKILL" 2>/dev/null; then
    pass "contains '$step'"
  else
    fail "does not contain '$step'"
  fi
done

# --- 3: contains ToolSearch bootstrap for AskUserQuestion ---
if grep -q "ToolSearch" "$SKILL" 2>/dev/null; then
  pass "contains ToolSearch (tool bootstrap)"
else
  fail "does not contain ToolSearch (tool bootstrap)"
fi

# --- 4: contains verified date convention ---
if grep -q "verified" "$SKILL" 2>/dev/null; then
  pass "contains 'verified' date convention"
else
  fail "does not contain 'verified' date convention"
fi

# --- 5: contains severity levels ---
for sev in "STALE" "BROKEN-REF" "CONTRADICTION" "UNVERIFIED" "INDEX-DRIFT"; do
  if grep -q "$sev" "$SKILL" 2>/dev/null; then
    pass "contains severity '$sev'"
  else
    fail "does not contain severity '$sev'"
  fi
done

# --- 6: contains CRG graph cross-reference ---
if grep -q "semantic_search_nodes_tool" "$SKILL" 2>/dev/null || grep -q "CRG" "$SKILL" 2>/dev/null; then
  pass "contains CRG graph cross-reference"
else
  fail "does not contain CRG graph cross-reference"
fi

# --- 7: contains AskUserQuestion ---
if grep -q "AskUserQuestion" "$SKILL" 2>/dev/null; then
  pass "contains AskUserQuestion"
else
  fail "does not contain AskUserQuestion"
fi

# --- 8: does NOT contain hardcoded user-specific path ---
if ! grep -q "chriskuo" "$SKILL" 2>/dev/null; then
  pass "does not contain hardcoded 'chriskuo' path (portable)"
else
  fail "contains hardcoded 'chriskuo' path — should be portable"
fi

# --- 9: INSTALL.md has memory-audit symlink ---
if grep -q "commands/memory-audit.md" "$INSTALL" 2>/dev/null; then
  pass "INSTALL.md has memory-audit symlink"
else
  fail "INSTALL.md does not have memory-audit symlink"
fi

# --- 10: README.md mentions memory-audit ---
if grep -q "memory-audit" "$README" 2>/dev/null; then
  pass "README.md mentions memory-audit"
else
  fail "README.md does not mention memory-audit"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
