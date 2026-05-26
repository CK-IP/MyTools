#!/usr/bin/env bash
# test_refresh.sh
# Structural assertions for commands/refresh.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/commands/refresh.md"
INSTALL="$REPO_ROOT/INSTALL.md"
README="$REPO_ROOT/README.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- 1: skill file exists and is not empty ---
if [ -f "$SKILL" ] && [ -s "$SKILL" ]; then
  pass "commands/refresh.md exists and is not empty"
else
  fail "commands/refresh.md does not exist or is empty"
fi

# --- 2: contains all five step announcements ---
for step in "Step 1/5" "Step 2/5" "Step 3/5" "Step 4/5" "Step 5/5"; do
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
for sev in "STALE" "BROKEN-REF" "CONTRADICTION" "DUPLICATE" "UNVERIFIED" "INDEX-DRIFT"; do
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

# --- 9: INSTALL.md has refresh symlink ---
if grep -q "commands/refresh.md" "$INSTALL" 2>/dev/null; then
  pass "INSTALL.md has refresh symlink"
else
  fail "INSTALL.md does not have refresh symlink"
fi

# --- 10: README.md mentions refresh ---
if grep -q "/refresh" "$README" 2>/dev/null; then
  pass "README.md mentions /refresh"
else
  fail "README.md does not mention /refresh"
fi

# --- 11: contains preview / dry-run step ---
if grep -q "Preview proposed changes" "$SKILL" 2>/dev/null || grep -q "Apply all" "$SKILL" 2>/dev/null; then
  pass "contains preview/dry-run step"
else
  fail "does not contain preview/dry-run step"
fi

# --- 12: contains merge behavior ---
if grep -q "Merge behavior" "$SKILL" 2>/dev/null || grep -q "merging two duplicate" "$SKILL" 2>/dev/null; then
  pass "contains merge behavior for duplicates"
else
  fail "does not contain merge behavior for duplicates"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
