#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/commands/fleet.md"

PASS=0
FAIL=0

pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
}

# 1. File exists and not empty
[ -e "$TARGET" ] && [ -s "$TARGET" ] && pass "exists and not empty" || fail "missing or empty"

# 2. Contains "contract-tests.sh"
grep -q 'contract-tests.sh' "$TARGET" && pass "contract-tests.sh present" || fail "contract-tests.sh missing"

# 3. Contains "Step 5b" or "5b:"
grep -qE 'Step 5b|5b:' "$TARGET" && pass "Step 5b present" || fail "Step 5b missing"

# 4. Contains "SEMANTIC-CONFLICT"
grep -q 'SEMANTIC-CONFLICT' "$TARGET" && pass "SEMANTIC-CONFLICT present" || fail "SEMANTIC-CONFLICT missing"

# 5. Contains "import graph"
grep -q 'import graph' "$TARGET" && pass "import graph present" || fail "import graph missing"

# 6. Contains "behavioral" or "behavioral contracts"
grep -qiE 'behavioral contract' "$TARGET" && pass "behavioral contracts present" || fail "behavioral contracts missing"

# 7. Contains "type compatibility"
grep -qi 'type compatibility' "$TARGET" && pass "type compatibility present" || fail "type compatibility missing"

# 8. Contains "fortify gate" or "Fortify gate"
grep -qi 'fortify gate' "$TARGET" && pass "Fortify gate present" || fail "Fortify gate missing"

# 9. Contains "BLOCK" (fortify verdict)
grep -q 'BLOCK' "$TARGET" && pass "BLOCK verdict present" || fail "BLOCK missing"

# 10. Contains "Ship Health"
grep -q 'Ship Health' "$TARGET" && pass "Ship Health present" || fail "Ship Health missing"

# 11. Contains "Contract test results per worker" (exact phrase)
grep -q 'Contract test results per worker' "$TARGET" && pass "Contract test results per worker present" || fail "Contract test results per worker missing"

# 12. Test chain uses glob or includes test_fortify.sh
grep -qE 'test_\*\.sh|test_fortify\.sh' "$TARGET" && pass "test chain uses glob or includes test_fortify.sh" || fail "test chain stale"

# 13. Step 18 exists (renumbering — old 17 → 18)
grep -qE '### Step 18' "$TARGET" && pass "Step 18 exists (renumbered)" || fail "Step 18 missing"

# 14. Step 23 exists (renumbering — old 22 → 23)
grep -qE '### Step 23' "$TARGET" && pass "Step 23 exists (renumbered)" || fail "Step 23 missing"

# 15. Step 17 refers to fortify
grep -qiE 'Step 17.*[Ff]ortify|[Ff]ortify.*[Gg]ate' "$TARGET" && pass "Step 17 is fortify gate" || fail "Step 17 not fortify gate"

# 16. Contains "CONFLICT HIGH" (contract test failure verdict)
grep -q 'CONFLICT HIGH' "$TARGET" && pass "CONFLICT HIGH present" || fail "CONFLICT HIGH missing"

# 17. Contains "Contract tests failed after merging"
grep -q 'Contract tests failed after merging' "$TARGET" && pass "Contract tests failed after merging present" || fail "Contract tests failed after merging missing"

# 18. Contains remote branch cleanup
grep -q 'git push origin --delete "ship/<sub_issue>"' "$TARGET" && pass "remote branch cleanup present" || fail "remote branch cleanup missing"

# 19. Contains local branch cleanup for workers
grep -q 'git branch -d "ship/<sub_issue>"' "$TARGET" && pass "local branch cleanup present" || fail "local branch cleanup missing"

# 20. Step 22 is branch cleanup (renumbered from old 22)
grep -qE '### Step 22.*[Cc]lean' "$TARGET" && pass "Step 22 is branch cleanup" || fail "Step 22 is not branch cleanup"

# 21. Old Step 22 renumbered to Step 23
grep -qE '### Step 23.*[Cc]lose' "$TARGET" && pass "Step 23 is Close Epic (renumbered)" || fail "Step 23 not Close Epic"

# 22. Old Step 23 renumbered to Step 24
grep -qE '### Step 24.*ship' "$TARGET" && pass "Step 24 is ship's log (renumbered)" || fail "Step 24 not ship's log"

# 23. Worker shutdown: TeamDelete present (end-of-run team teardown)
grep -q 'TeamDelete' "$TARGET" && pass "TeamDelete present" || fail "TeamDelete missing"

# 24. Shutdown language present (graceful shutdown request)
grep -qiE 'shut down|shutdown' "$TARGET" && pass "shutdown language present" || fail "shutdown language missing"

# 25. Step 22b exists (team teardown — does not renumber 22/23/24)
grep -qE '### Step 22b' "$TARGET" && pass "Step 22b present" || fail "Step 22b missing"

# 26. Wave discipline documented (Step 10c)
grep -qiE 'Step 10c|[Ww]ave discipline' "$TARGET" && pass "wave discipline present" || fail "wave discipline missing"

# 27. Worker dismissal on QA CLEAR present
grep -qi 'dismiss' "$TARGET" && pass "worker dismissal present" || fail "worker dismissal missing"

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
