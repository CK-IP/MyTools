#!/usr/bin/env bash
# test_culture_add.sh
# Structural assertions for the streamlined /culture add workflow (#25).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CULTURE="$REPO_ROOT/commands/culture.md"
WORKER="$REPO_ROOT/agents/culture-worker.md"
INSTALL="$REPO_ROOT/INSTALL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- 1: commands/culture.md exists and is not empty ---
if [ -f "$CULTURE" ] && [ -s "$CULTURE" ]; then
  pass "commands/culture.md exists and is not empty"
else
  fail "commands/culture.md does not exist or is empty"
fi

# --- 2: agents/culture-worker.md exists and is not empty ---
if [ -f "$WORKER" ] && [ -s "$WORKER" ]; then
  pass "agents/culture-worker.md exists and is not empty"
else
  fail "agents/culture-worker.md does not exist or is empty"
fi

# --- 3: Add section contains run_in_background pattern ---
if grep -q "run_in_background" "$CULTURE" 2>/dev/null; then
  pass "Add section contains run_in_background pattern"
else
  fail "Add section does not contain run_in_background pattern"
fi

# --- Add section references culture-worker agent by name ---
if grep -q 'culture-worker' "$CULTURE" 2>/dev/null; then
  pass "Add section references culture-worker agent"
else
  fail "Add section missing reference to culture-worker agent"
fi

# --- 4: Add section does NOT contain old domain prompt ---
if ! grep -q "Which area does this belong to" "$CULTURE" 2>/dev/null; then
  pass "Add section does not contain old domain prompt"
else
  fail "Add section still contains old domain prompt 'Which area does this belong to'"
fi

# --- 5: Add section does NOT contain old slug confirmation ---
if ! grep -q "I'll call this article" "$CULTURE" 2>/dev/null; then
  pass "Add section does not contain old slug confirmation"
else
  fail "Add section still contains old slug confirmation \"I'll call this article\""
fi

# --- 6: Add section does NOT contain old summary prompt ---
if ! grep -q "what's the key takeaway" "$CULTURE" 2>/dev/null; then
  pass "Add section does not contain old summary prompt"
else
  fail "Add section still contains old summary prompt 'what's the key takeaway'"
fi

# --- 7: Add section does NOT contain old tags prompt ---
if ! grep -q "Any tags for this" "$CULTURE" 2>/dev/null; then
  pass "Add section does not contain old tags prompt"
else
  fail "Add section still contains old tags prompt 'Any tags for this'"
fi

# --- 8: Add section does NOT contain old PR creation ---
add_section=$(sed -n '/^## Add$/,/^## Search$/{ /^## Search$/d; p; }' "$CULTURE")
if printf '%s' "$add_section" | grep -q 'gh pr create'; then
  fail "Add section still contains old 'gh pr create'"
else
  pass "Add section does not create a PR"
fi

# --- 9: Add section DOES contain INDEX.md check ---
if grep -q "INDEX.md" "$CULTURE" 2>/dev/null; then
  pass "Add section contains INDEX.md check"
else
  fail "Add section does not contain INDEX.md check"
fi

# --- 10: Add section DOES contain duplicate or related article detection ---
if grep -qiE "duplicate|related article" "$CULTURE" 2>/dev/null; then
  pass "Add section contains duplicate or related article detection"
else
  fail "Add section does not contain duplicate or related article detection"
fi

# --- 11: culture-worker.md contains reviewed-by field ---
if grep -q "reviewed-by" "$WORKER" 2>/dev/null; then
  pass "culture-worker.md contains reviewed-by field"
else
  fail "culture-worker.md does not contain reviewed-by field"
fi

# --- 12: culture-worker.md contains review-date field ---
if grep -q "review-date" "$WORKER" 2>/dev/null; then
  pass "culture-worker.md contains review-date field"
else
  fail "culture-worker.md does not contain review-date field"
fi

# --- 13: culture-worker.md contains git push ---
if grep -q "git push" "$WORKER" 2>/dev/null; then
  pass "culture-worker.md contains git push"
else
  fail "culture-worker.md does not contain git push"
fi

# --- 14: culture-worker.md contains make index ---
if grep -q "make index" "$WORKER" 2>/dev/null; then
  pass "culture-worker.md contains make index"
else
  fail "culture-worker.md does not contain make index"
fi

# --- 15: culture-worker.md does NOT contain old domain prompt ---
if ! grep -q "Which area does this belong to" "$WORKER" 2>/dev/null; then
  pass "culture-worker.md does not contain old domain prompt"
else
  fail "culture-worker.md still contains old domain prompt 'Which area does this belong to'"
fi

# --- 16: culture-worker.md contains slug collision recheck ---
if grep -qE "collision|already exist|slug.*exist" "$WORKER" 2>/dev/null; then
  pass "culture-worker.md contains slug collision recheck"
else
  fail "culture-worker.md does not contain slug collision recheck (collision|already exist|slug.*exist)"
fi

# --- 17: culture-worker.md contains each required frontmatter field ---
for field in "created" "updated" "author" "sources"; do
  if grep -q "$field" "$WORKER" 2>/dev/null; then
    pass "culture-worker.md contains field '$field'"
  else
    fail "culture-worker.md does not contain field '$field'"
  fi
done

# --- 18: INSTALL.md references culture-worker ---
if grep -q "culture-worker" "$INSTALL" 2>/dev/null; then
  pass "INSTALL.md references culture-worker"
else
  fail "INSTALL.md does not reference culture-worker"
fi

# --- 19: Setup section preserved ---
if grep -q "Run once per machine" "$CULTURE" 2>/dev/null; then
  pass "Setup section preserved (contains 'Run once per machine')"
else
  fail "Setup section not preserved (missing 'Run once per machine')"
fi

# --- 20: Search section preserved ---
if grep -q "Search is coming soon" "$CULTURE" 2>/dev/null; then
  pass "Search section preserved (contains 'Search is coming soon')"
else
  fail "Search section not preserved (missing 'Search is coming soon')"
fi

# --- 21: Refresh section preserved ---
if grep -q "Periodic health check" "$CULTURE" 2>/dev/null; then
  pass "Refresh section preserved (contains 'Periodic health check')"
else
  fail "Refresh section not preserved (missing 'Periodic health check')"
fi

# --- 22: culture-worker.md contains MkDocs nav update step ---
if grep -q "Update MkDocs nav" "$WORKER" 2>/dev/null; then
  pass "culture-worker.md contains MkDocs nav update step"
else
  fail "culture-worker.md does not contain MkDocs nav update step"
fi

# --- 23: culture-worker.md git add includes mkdocs.yml ---
if grep -q '\.mkdocs/mkdocs\.yml' "$WORKER" 2>/dev/null; then
  pass "culture-worker.md git add includes .mkdocs/mkdocs.yml"
else
  fail "culture-worker.md git add does not include .mkdocs/mkdocs.yml"
fi

# --- 24: culture-worker.md has 8 numbered steps ---
step_count=$(grep -cE '^### [0-9]+\.' "$WORKER" 2>/dev/null || true)
if [ "$step_count" -eq 8 ]; then
  pass "culture-worker.md has 8 numbered steps (got $step_count)"
else
  fail "culture-worker.md should have 8 numbered steps (got $step_count)"
fi

# --- 25: culture-worker.md nav step reads mkdocs.yml ---
if grep -q 'mkdocs\.yml' "$WORKER" 2>/dev/null; then
  pass "culture-worker.md nav step references mkdocs.yml"
else
  fail "culture-worker.md nav step does not reference mkdocs.yml"
fi

# --- 26: culture-worker.md nav step handles flat and nested domains ---
if grep -qE 'For nested domains|processing/(uf|fermentation)' "$WORKER" 2>/dev/null; then
  pass "culture-worker.md nav step handles nested domains"
else
  fail "culture-worker.md nav step does not handle nested domains"
fi

# --- 27: Help text no longer says old review copy ---
if ! grep -q "Creates a draft and opens it for review" "$CULTURE" 2>/dev/null; then
  pass "Help text no longer says 'Creates a draft and opens it for review'"
else
  fail "Help text still says 'Creates a draft and opens it for review'"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
