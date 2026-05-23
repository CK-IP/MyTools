#!/usr/bin/env bash
# test_space.sh
# Structural assertions for commands/space.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/commands/space.md"
INSTALL="$REPO_ROOT/INSTALL.md"
README="$REPO_ROOT/README.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- 1: skill file exists and is not empty ---
if [ -f "$SKILL" ] && [ -s "$SKILL" ]; then
  pass "commands/space.md exists and is not empty"
else
  fail "commands/space.md does not exist or is empty"
fi

# --- 2: contains all nine step announcements ---
for step in "Step 1/9" "Step 2/9" "Step 3/9" "Step 4/9" "Step 5/9" "Step 6/9" "Step 7/9" "Step 8/9" "Step 9/9"; do
  if grep -q "$step" "$SKILL" 2>/dev/null; then
    pass "contains '$step'"
  else
    fail "does not contain '$step'"
  fi
done

# --- 3: contains code-review-graph (CRG integration) ---
if grep -q "code-review-graph" "$SKILL" 2>/dev/null; then
  pass "contains 'code-review-graph' (CRG integration)"
else
  fail "does not contain 'code-review-graph'"
fi

# --- 4: contains "code map" (plain-language CRG reference) ---
if grep -q "code map" "$SKILL" 2>/dev/null; then
  pass "contains 'code map'"
else
  fail "does not contain 'code map'"
fi

# --- 5: contains .code-review-graph/ in gitignore section ---
if grep -q '\.code-review-graph/' "$SKILL" 2>/dev/null; then
  pass "contains '.code-review-graph/' (gitignore entry)"
else
  fail "does not contain '.code-review-graph/' in gitignore"
fi

# --- 6: does NOT contain hardcoded user-specific path ---
if ! grep -q "chriskuo" "$SKILL" 2>/dev/null; then
  pass "does not contain hardcoded 'chriskuo' path (portable)"
else
  fail "contains hardcoded 'chriskuo' path — should be portable"
fi

# --- 7: INSTALL.md has space symlink ---
if grep -q "commands/space.md" "$INSTALL" 2>/dev/null; then
  pass "INSTALL.md has space symlink"
else
  fail "INSTALL.md does not have space symlink"
fi

# --- 8: README.md mentions space ---
if grep -q "/space" "$README" 2>/dev/null; then
  pass "README.md mentions /space"
else
  fail "README.md does not mention /space"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
