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

# A8. Auto-sequencing (#71) — /surf analyzes the board and proposes a build order
grep -qiE 'Step 5b|analyze the board' "$TARGET" && pass "Step 5b analysis step present" || fail "Step 5b analysis step missing"
grep -qiE 'cross-reference|depends on #|blocked by' "$TARGET" && pass "reads bodies/labels/cross-references" || fail "cross-reference analysis missing"
grep -qiE 'recommended build (order|sequence)|propose the (sequence|build order)' "$TARGET" && pass "proposes a recommended build order" || fail "proposed build order missing"
grep -qiE 'flag the conflict|silently reorder' "$TARGET" && pass "conflict flag-and-ask present" || fail "conflict flag-and-ask missing"
grep -qiE 'ordering guidance|not the authoritative' "$TARGET" && pass "Step-4 input demoted to guidance" || fail "guidance-layer demotion missing"
grep -qiE 'parent always sequences before its dependents|parent-before-dependent' "$TARGET" && pass "parent-before-dependent preserved" || fail "parent-before-dependent missing"
# A8 (RT-1): pin the load-bearing protocol, not just the keyword
grep -qF 'Issue | Topic | Dependencies | Why this position' "$TARGET" && pass "proposed-order table has the 4 fixed columns" || fail "4-column table header missing"
grep -qiE 'get approval, then record' "$TARGET" && pass "approval-before-record ordering pinned" || fail "approval-before-record ordering missing"
grep -qiE 'record the resolution' "$TARGET" && pass "conflict resolution recorded in decision-log" || fail "decision-log conflict-resolution missing"

# --- Resume (#53) ---

# R1. Resume section / Step 15 exists
grep -qiE 'Step 15|## Resume' "$TARGET" && pass "Resume section / Step 15 present" || fail "Resume section / Step 15 missing"

# R2. Resume marker mirrors /sail
grep -qF '↺ resume' "$TARGET" && pass "↺ resume marker present" || fail "↺ resume marker missing"

# R3. Per-issue stable run-dir
grep -qF -- '--run-dir' "$TARGET" && pass "--run-dir present" || fail "--run-dir missing"

# R4. Resume invocation
grep -qF '/surf resume' "$TARGET" && pass "/surf resume invocation present" || fail "/surf resume invocation missing"

# R5. Bypass flag carried at relaunch (resume context)
grep -qiE 'resume.*--dangerously-bypass-permissions|--dangerously-bypass-permissions.*resume' "$TARGET" && pass "bypass flag in resume/relaunch context present" || fail "bypass flag in resume/relaunch context missing"

# R6. resume-after timestamp file referenced
grep -qF '.surf/resume-after' "$TARGET" && pass ".surf/resume-after referenced" || fail ".surf/resume-after missing"

# R7. Per-issue runs dir referenced
grep -qF '.surf/runs/' "$TARGET" && pass ".surf/runs/ referenced" || fail ".surf/runs/ missing"

# R8. Wrapper script referenced
grep -qF 'config/surf-resume.sh' "$TARGET" && pass "config/surf-resume.sh referenced" || fail "config/surf-resume.sh missing"

# R9. Cheap-shell-gate principle (zero tokens before any Claude call)
grep -qiE 'before any Claude call|zero tokens|pure[ -]?shell|pure[ -]?bash' "$TARGET" && pass "cheap-gate principle present" || fail "cheap-gate principle missing"

# R10. In-progress run detection before Step 0
grep -qiE 'Step 0-pre|in-progress run|detect an in-progress' "$TARGET" && pass "in-progress detection present" || fail "in-progress detection missing"

# R11. INSTALL.md documents the surf auto-resume LaunchAgent
grep -qF 'com.surf.resume.plist' "$INSTALL" && pass "INSTALL.md com.surf.resume.plist present" || fail "INSTALL.md com.surf.resume.plist missing"

# R12. Done-marker named as the scheduler's quiet signal
grep -qiE 'done-marker' "$TARGET" && pass "done-marker referenced" || fail "done-marker missing"
grep -qiE 'quiet signal|goes quiet|silenc' "$TARGET" && pass "scheduler quiet-signal language present" || fail "scheduler quiet-signal language missing"

# R13. Live-session marker (.surf/active) referenced
grep -qF '.surf/active' "$TARGET" && pass ".surf/active live-session marker present" || fail ".surf/active missing"

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
