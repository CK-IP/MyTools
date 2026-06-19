#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/commands/surf.md"
GITIGNORE="$REPO_ROOT/.gitignore"
INSTALL="$REPO_ROOT/INSTALL.md"

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
[ -e "$TARGET" ] && [ -s "$TARGET" ] && pass "surf.md exists and not empty" || fail "surf.md missing or empty"

# 2. Line 1 is a one-line description with usage
head -1 "$TARGET" 2>/dev/null | grep -q '/surf' && pass "line 1 references /surf" || fail "line 1 missing /surf"
head -1 "$TARGET" 2>/dev/null | grep -q 'Usage:' && pass "line 1 has Usage:" || fail "line 1 missing Usage:"

# 3. Start gate: bypass-permissions
grep -qF -- '--dangerously-bypass-permissions' "$TARGET" && pass "bypass-permissions gate present" || fail "bypass-permissions gate missing"

# 4. Supervised env check: agent-teams setting
grep -qF 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS' "$TARGET" && pass "agent-teams setting present" || fail "agent-teams setting missing"

# 5. Engine: sail run --diff main
grep -qF 'python3 -m sail run --diff main' "$TARGET" && pass "sail engine invocation present" || fail "sail engine invocation missing"

# 6. Charter / journal / decision-log
grep -qi 'charter' "$TARGET" && pass "charter present" || fail "charter missing"
grep -qi 'journal' "$TARGET" && pass "journal present" || fail "journal missing"
grep -qiE 'decision.log' "$TARGET" && pass "decision-log present" || fail "decision-log missing"

# 7. Run-mode selection is interactive (AskUserQuestion) + no-flags principle (positive assertion)
grep -qF 'AskUserQuestion' "$TARGET" && pass "AskUserQuestion present" || fail "AskUserQuestion missing"
grep -qi 'interactive selection prompt' "$TARGET" && pass "interactive-selection principle present" || fail "interactive-selection principle missing"
grep -qiE 'never a .*flag|not a .*flag' "$TARGET" && pass "no-flags principle present" || fail "no-flags principle missing"

# 8. Both run modes named
grep -qi 'autonomous' "$TARGET" && pass "autonomous mode present" || fail "autonomous mode missing"
grep -qi 'supervised' "$TARGET" && pass "supervised mode present" || fail "supervised mode missing"

# 9. Recovery: git revert + per-issue --no-ff merge commits
grep -qF 'git revert' "$TARGET" && pass "git revert recovery present" || fail "git revert recovery missing"
grep -qF -- '--no-ff' "$TARGET" && pass "--no-ff per-issue commit present" || fail "--no-ff missing"

# 10. Merge policy: auto-merge green + park non-green
grep -qiE 'auto-merge' "$TARGET" && pass "auto-merge policy present" || fail "auto-merge policy missing"
grep -qi 'park' "$TARGET" && pass "park (non-green) present" || fail "park missing"

# 11. Guardrails: no force-push, sandbox repo only
grep -qi 'force-push' "$TARGET" && pass "force-push guardrail present" || fail "force-push guardrail missing"
grep -qi 'sandbox' "$TARGET" && pass "sandbox guardrail present" || fail "sandbox guardrail missing"

# 12. Supervised timeout: open-questions file + deadline (load-bearing mechanism)
grep -qi 'open-questions' "$TARGET" && pass "open-questions file present" || fail "open-questions file missing"
grep -qi 'deadline' "$TARGET" && pass "deadline present" || fail "deadline missing"

# 13. Dependent issues: stacked branches / branch-from-parent
grep -qiE 'stacked branch|branch-from-parent|branch from the parent' "$TARGET" && pass "dependent-issue stacking present" || fail "dependent-issue stacking missing"

# 14. Wrap-up: plain-language final summary with revert map
grep -qiE 'final summary' "$TARGET" && pass "final summary present" || fail "final summary missing"
grep -qiE 'revert map|issue.*SHA' "$TARGET" && pass "revert map present" || fail "revert map missing"

# 15. .gitignore ignores .surf/
grep -qF '.surf/' "$GITIGNORE" && pass ".surf/ gitignored" || fail ".surf/ not gitignored"

# 16. INSTALL.md documents the /surf symlink
grep -qF 'commands/surf.md' "$INSTALL" && pass "INSTALL.md /surf symlink present" || fail "INSTALL.md /surf symlink missing"

# A1. Supervised delegation mechanism pinned
grep -qF 'TeamCreate' "$TARGET" && pass "supervised delegation (TeamCreate) pinned" || fail "supervised delegation (TeamCreate) missing"

# A2. Autonomous delegation: fleet-rule exception + concrete subagent mechanism pinned
grep -qiF 'deliberate exception' "$TARGET" && pass "fleet-rule exception pinned" || fail "fleet-rule exception missing"
grep -qiE 'subagent_type|general-purpose' "$TARGET" && pass "autonomous subagent mechanism pinned" || fail "autonomous subagent mechanism missing"

# A3. Context model / anti-drift pinned
grep -qi 're-anchor' "$TARGET" && pass "re-anchor pinned" || fail "re-anchor missing"
grep -qi 'compact' "$TARGET" && pass "compact (anti-drift) pinned" || fail "compact missing"

# A4. Fail-closed + exit semantics pinned
grep -qi 'fail-closed' "$TARGET" && pass "fail-closed pinned" || fail "fail-closed missing"
grep -qiE 'exit[ -]?0' "$TARGET" && pass "exit-0 semantics pinned" || fail "exit-0 semantics missing"
grep -qiE 'exit[ -]?1' "$TARGET" && pass "exit-1 semantics pinned" || fail "exit-1 semantics missing"

# A5. Canonical branch naming pinned
grep -qF 'surf/<issue>' "$TARGET" && pass "canonical branch naming pinned" || fail "canonical branch naming missing"

# A6. Stronger charter / journal assertions (mechanism-specific)
grep -qF '.surf/charter-' "$TARGET" && pass "charter file path pinned" || fail "charter file path missing"
grep -qi 'append-only' "$TARGET" && pass "append-only journal pinned" || fail "append-only journal missing"

# A7. Stacked-parent merge guard (FIX 4) pinned
grep -qiE 'before auto-merging|verify .*parent.*merged|park the dependent' "$TARGET" && pass "stacked-parent merge guard pinned" || fail "stacked-parent merge guard missing"

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
