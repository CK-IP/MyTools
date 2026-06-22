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

# A2. Delegation model (#73): EVERY issue → fresh teammate; the old "autonomous = subagent" path is retired
grep -qiE 'every issue is (delegated|built by).*teammate|delegating every issue to a teammate' "$TARGET" && pass "every-issue-delegated-to-teammate pinned" || fail "every-issue-delegated-to-teammate missing"
grep -qiE 'cannot host|can.t host|never a one-shot subagent|no subagent path' "$TARGET" && pass "subagent-cannot-host-crew rationale pinned" || fail "subagent-incompatibility rationale missing"
grep -qiE 'replaces the old .*subagent|that rule is .*retired|no longer uses subagents' "$TARGET" && pass "autonomous=subagent rule retired" || fail "autonomous=subagent retirement missing"

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

# --- Tombstone-on-fresh (#72) ---

# A9. A superseded/dead charter is laid to rest (done-marker) before a fresh run starts
grep -qi 'tombstone' "$TARGET" && pass "tombstone-on-fresh language present" || fail "tombstone-on-fresh language missing"
grep -qiE 'done: superseded' "$TARGET" && pass "tombstone journal line (done: superseded) pinned" || fail "tombstone journal line missing"
grep -qi 'externally exhausted' "$TARGET" && pass "externally-exhausted trigger present" || fail "externally-exhausted trigger missing"
grep -qiE 'lay the old charter to rest' "$TARGET" && pass "tombstone instruction (lay the old charter to rest) present" || fail "tombstone lay-to-rest instruction missing"

# --- #73: teammate-for-every-issue + persistent-tmux revive ---

# A10. Engine: /sail default, /ship optional
grep -qiE 'sail.{0,12}default|default engine.*sail' "$TARGET" && pass "/sail-default engine pinned" || fail "/sail-default engine missing"
grep -qiE 'ship.{0,6}optional|optional.*heavier engine' "$TARGET" && pass "/ship-optional engine pinned" || fail "/ship-optional engine missing"

# A11. Persistent-tmux + revive resume model; headless relaunch retired/reframed; reboot trade-off
grep -qiE 'persistent.?tmux' "$TARGET" && pass "persistent-tmux model pinned" || fail "persistent-tmux model missing"
grep -qiF 'tmux send-keys' "$TARGET" && pass "send-keys revive mechanism pinned" || fail "send-keys revive missing"
grep -qiE 'retired|reframed' "$TARGET" && pass "headless-relaunch retired/reframed pinned" || fail "headless-relaunch retire/reframe missing"
grep -qiE 'reboot' "$TARGET" && pass "reboot trade-off pinned" || fail "reboot trade-off missing"

# A12. Named tmux session start/monitor procedure (the start front door)
grep -qF 'tmux new -s surf' "$TARGET" && pass "named-session start command pinned" || fail "named-session start command missing"
grep -qF 'tmux attach -t surf' "$TARGET" && pass "named-session attach/monitor command pinned" || fail "named-session attach command missing"

# A13. Teardown mandatory on every stop path
grep -qi 'teardown' "$TARGET" && pass "teardown referenced" || fail "teardown missing"
grep -qiE 'every stop path|dismiss (all|every) teammate' "$TARGET" && pass "teardown-on-every-stop-path pinned" || fail "teardown-on-every-stop-path missing"

# A14. Spawn contract: start immediately / run to terminus / don't idle (idle-on-spawn fix)
grep -qiE 'start immediately|run autonomously to terminus|do not idle|without idling' "$TARGET" && pass "teammate spawn-immediately contract pinned" || fail "spawn-immediately contract missing"

# A15. Agent-teams required in BOTH modes (no longer supervised-only)
grep -qiE 'both.{0,4}modes' "$TARGET" && pass "both-modes delegation pinned" || fail "both-modes requirement missing"

# A16. Revive watcher requires positive stall evidence + precise pane target (#73 review fixes)
grep -qiE 'positive stall evidence|never nudge a healthy session|armed floor' "$TARGET" && pass "positive-stall-evidence pinned" || fail "positive-stall-evidence missing"
grep -qF '.surf/orchestrator-pane' "$TARGET" && pass "orchestrator-pane targeting pinned" || fail "orchestrator-pane targeting missing"

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
