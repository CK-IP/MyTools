#!/usr/bin/env bash
# test_fortify.sh
# Asserts that commands/fortify.md exists and contains all required structural elements for the /fortify skill.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/commands/fortify.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- Assertion 1: fortify.md exists ---
if [ -f "$SKILL" ]; then
  pass "fortify.md exists"
else
  fail "fortify.md exists"
fi

# --- Assertion 2: Has Security Scan section ---
if grep -q 'Security Scan' "$SKILL" 2>/dev/null; then
  pass "Has Security Scan section"
else
  fail "Has Security Scan section"
fi

# --- Assertion 3: Has Coverage section ---
if grep -q 'Coverage' "$SKILL" 2>/dev/null; then
  pass "Has Coverage section"
else
  fail "Has Coverage section"
fi

# --- Assertion 4: Has Static Analysis section ---
if grep -q 'Static Analysis' "$SKILL" 2>/dev/null; then
  pass "Has Static Analysis section"
else
  fail "Has Static Analysis section"
fi

# --- Assertion 5: Has verdict rules ---
if grep -q 'Verdict' "$SKILL" 2>/dev/null; then
  pass "Has verdict rules"
else
  fail "Has verdict rules"
fi

# --- Assertion 6: Uses AskUserQuestion for gates ---
if grep -q 'AskUserQuestion' "$SKILL" 2>/dev/null; then
  pass "Uses AskUserQuestion for gates"
else
  fail "Uses AskUserQuestion for gates"
fi

# --- Assertion 7: References gitleaks ---
if grep -q 'gitleaks' "$SKILL" 2>/dev/null; then
  pass "References gitleaks"
else
  fail "References gitleaks"
fi

# --- Assertion 8: References semgrep ---
if grep -q 'semgrep' "$SKILL" 2>/dev/null; then
  pass "References semgrep"
else
  fail "References semgrep"
fi

# --- Assertion 9: Has BLOCK verdict ---
if grep -q 'BLOCK' "$SKILL" 2>/dev/null; then
  pass "Has BLOCK verdict"
else
  fail "Has BLOCK verdict"
fi

# --- Assertion 10: Has ADVISORY verdict ---
if grep -q 'ADVISORY' "$SKILL" 2>/dev/null; then
  pass "Has ADVISORY verdict"
else
  fail "Has ADVISORY verdict"
fi

# --- Assertion 11: Has CLEAR verdict ---
if grep -q 'CLEAR' "$SKILL" 2>/dev/null; then
  pass "Has CLEAR verdict"
else
  fail "Has CLEAR verdict"
fi

# --- Assertion 12: Handles missing tools gracefully ---
if grep -qE 'graceful|skip' "$SKILL" 2>/dev/null; then
  pass "Handles missing tools gracefully"
else
  fail "Handles missing tools gracefully"
fi

# --- Assertion 13: Scans changed files only ---
if grep -qE 'changed.*files|CHANGED_FILES|git diff main' "$SKILL" 2>/dev/null; then
  pass "Scans changed files only"
else
  fail "Scans changed files only"
fi

# --- Assertion 14: Fail-fast on HIGH findings ---
if grep -q 'Fail-fast' "$SKILL" 2>/dev/null || grep -qE 'HIGH.*skip|skip.*Pass 2|skip.*Pass 3' "$SKILL" 2>/dev/null; then
  pass "Fail-fast on HIGH findings"
else
  fail "Fail-fast on HIGH findings"
fi

# --- Assertion 15: Uses three-dot diff syntax ---
if grep -q 'main\.\.\.HEAD' "$SKILL" 2>/dev/null; then
  pass "Uses three-dot diff syntax"
else
  fail "Uses three-dot diff syntax"
fi

# --- Assertion 16: Writes report to file ---
if grep -qE 'fortify-report|\.ship/' "$SKILL" 2>/dev/null; then
  pass "Writes report to file"
else
  fail "Writes report to file"
fi

INSTALL="$REPO_ROOT/INSTALL.md"
README="$REPO_ROOT/README.md"

# --- Assertion 17: INSTALL.md has fortify symlink ---
if grep -q 'commands/fortify.md' "$INSTALL" 2>/dev/null; then
  pass "INSTALL.md has fortify symlink"
else
  fail "INSTALL.md has fortify symlink"
fi

# --- Assertion 18: README.md mentions fortify ---
if grep -q 'fortify' "$README" 2>/dev/null; then
  pass "README.md mentions fortify"
else
  fail "README.md mentions fortify"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
