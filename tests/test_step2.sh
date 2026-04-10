#!/usr/bin/env bash
# test_step2.sh
# Asserts that .gitignore exists, is tracked by git, and contains required entries.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/.gitignore"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- Assertion 1: .gitignore exists ---
if [ -e "$TARGET" ]; then
  pass ".gitignore exists"
else
  fail ".gitignore does not exist (expected path: $TARGET)"
fi

# --- Assertion 2: .gitignore is tracked by git ---
if git -C "$REPO_ROOT" ls-files --error-unmatch .gitignore > /dev/null 2>&1; then
  pass ".gitignore is tracked by git"
else
  fail ".gitignore is not tracked by git (git ls-files --error-unmatch .gitignore failed)"
fi

# --- Assertion 3: .gitignore contains .claude/worktrees/ ---
if [ -e "$TARGET" ] && grep -qF '.claude/worktrees/' "$TARGET"; then
  pass ".gitignore contains '.claude/worktrees/'"
elif [ -e "$TARGET" ]; then
  fail ".gitignore exists but does not contain '.claude/worktrees/'"
else
  fail ".gitignore does not exist — cannot check for '.claude/worktrees/'"
fi

# --- Assertion 4: .gitignore contains .ship/review/ ---
if [ -e "$TARGET" ] && grep -qF '.ship/review/' "$TARGET"; then
  pass ".gitignore contains '.ship/review/'"
elif [ -e "$TARGET" ]; then
  fail ".gitignore exists but does not contain '.ship/review/'"
else
  fail ".gitignore does not exist — cannot check for '.ship/review/'"
fi

# --- Assertion 5: .gitignore contains .handoffs/ ---
if [ -e "$TARGET" ] && grep -qF '.handoffs/' "$TARGET"; then
  pass ".gitignore contains '.handoffs/'"
elif [ -e "$TARGET" ]; then
  fail ".gitignore exists but does not contain '.handoffs/'"
else
  fail ".gitignore does not exist — cannot check for '.handoffs/'"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
