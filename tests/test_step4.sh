#!/usr/bin/env bash
# test_step4.sh
# Asserts that commands/epic-brief-schema.md exists and contains required sections.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/commands/epic-brief-schema.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- Assertion 1: commands/epic-brief-schema.md exists and is not empty ---
if [ -e "$TARGET" ] && [ -s "$TARGET" ]; then
  pass "commands/epic-brief-schema.md exists and is not empty"
else
  fail "commands/epic-brief-schema.md does not exist or is empty"
fi

# --- Assertion 2: Contains "## Epic Metadata" ---
if grep -q "## Epic Metadata" "$TARGET" 2>/dev/null; then
  pass "contains '## Epic Metadata'"
else
  fail "missing '## Epic Metadata'"
fi

# --- Assertion 3: Contains "## Workers" ---
if grep -q "## Workers" "$TARGET" 2>/dev/null; then
  pass "contains '## Workers'"
else
  fail "missing '## Workers'"
fi

# --- Assertion 4: Contains "## QA Spec" ---
if grep -q "## QA Spec" "$TARGET" 2>/dev/null; then
  pass "contains '## QA Spec'"
else
  fail "missing '## QA Spec'"
fi

# --- Assertion 5: Contains "qa_mode" ---
if grep -q "qa_mode" "$TARGET" 2>/dev/null; then
  pass "contains 'qa_mode'"
else
  fail "missing 'qa_mode'"
fi

# --- Assertion 6: Contains "## Merge Rules" ---
if grep -q "## Merge Rules" "$TARGET" 2>/dev/null; then
  pass "contains '## Merge Rules'"
else
  fail "missing '## Merge Rules'"
fi

# --- Assertion 7: Contains "dependency_order" ---
if grep -q "dependency_order" "$TARGET" 2>/dev/null; then
  pass "contains 'dependency_order'"
else
  fail "missing 'dependency_order'"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
