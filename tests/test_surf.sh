#!/usr/bin/env bash
# This file asserts doc invariants with the `grep -q … && pass … || fail …` idiom throughout.
# `pass`/`fail` always succeed (echo + arithmetic increment), so the SC2015 "C may run when A
# is true" caveat does not apply here; disable it file-wide to keep the assertions terse.
# Backticks inside single-quoted grep patterns are literal-by-design (matching `code` spans), so
# SC2016 ("expressions don't expand in single quotes") is also a non-issue here.
# shellcheck disable=SC2015,SC2016
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

# --- #124 INVERSION: the DEFAULT execution body is now a headless `claude -p` worker process
# per issue, NOT a tmux-pane agent-team teammate. The assertions below (formerly A1/A2/A10-A16
# pinning the #73 teammate/persistent-tmux model) are INVERTED to pin the headless default; the
# tmux/TeamCreate/pane machinery is re-asserted only as the OPTIONAL supervised lens. The brain
# (charter/journal/decision-log/revert-map/Step 5b/tombstone/resume/run-dir/surf/<issue>) stays
# GREEN — those assertions are untouched. ---

# A1. The DEFAULT delegation is a headless `claude -p` worker (the #124 body swap).
grep -qF -- 'claude --dangerously-bypass-permissions -p "/sail' "$TARGET" && pass "headless claude -p /sail worker invocation pinned" || fail "headless claude -p worker invocation missing"
grep -qiE 'claude.*-p.*/sail.*--unattended|/sail <[ni]>? *--unattended|/sail <issue> --unattended' "$TARGET" && pass "worker runs /sail in --unattended mode" || fail "worker --unattended mode missing"

# A1b. The supervisor is a thin LLM loop driving bash helpers; the operator talks only to the
# supervisor, never directly to a worker process.
grep -qiE 'thin LLM loop|supervisor.*(drives|driving).*(bash )?helper' "$TARGET" && pass "supervisor = thin LLM loop over bash helper pinned" || fail "thin-LLM-loop supervisor framing missing"
grep -qiE 'operator (interacts|talks) only with the supervisor|never directly with a worker|operator (talks|only).*supervisor' "$TARGET" && pass "operator talks only to the supervisor pinned" || fail "operator-only-to-supervisor framing missing"

# A2. The worker helper script is referenced as the delegation mechanism.
grep -qF 'config/surf-worker.sh' "$TARGET" && pass "worker helper script (config/surf-worker.sh) referenced" || fail "config/surf-worker.sh reference missing"

# A2-127. /surf must SOURCE its helper from a STABLE path that resolves regardless of which repo
# /surf is operating on — never cwd-relative. (#127: `. config/surf-worker.sh` only resolved when
# cwd was the CK-Skills checkout; /surf is a global command run against any repo's board.)
grep -qF '. ~/.claude/lib/surf-worker.sh' "$TARGET" && pass "surf-worker.sh sourced from the stable ~/.claude/lib path (#127)" || fail "stable source path '. ~/.claude/lib/surf-worker.sh' missing (#127)"
grep -qF '. config/surf-worker.sh' "$TARGET" && fail "regressive cwd-relative sourcing '. config/surf-worker.sh' still present (#127)" || pass "no cwd-relative helper sourcing remains (#127)"
# INSTALL.md documents the post-merge symlink that backs the stable source path.
grep -qF 'ln -s "$(pwd)/config/surf-worker.sh" ~/.claude/lib/surf-worker.sh' "$INSTALL" && pass "INSTALL.md documents the surf-worker.sh ~/.claude/lib symlink (#127)" || fail "INSTALL.md surf-worker.sh symlink step missing (#127)"

# A2b. The worker→supervisor contract is read from run-dir artifacts (review.json + exit code),
# NOT from log/pane scraping.
grep -qiE 'review\.json.*exit code|exit code.*review\.json|reads? .*review\.json|review\.json. *\+. *exit' "$TARGET" && pass "worker result read from review.json + exit code pinned" || fail "review.json+exit-code result contract missing"
grep -qiE 'not (log|pane).?scrap|no (log|pane).?scrap|never .*scrap' "$TARGET" && pass "no log/pane-scraping contract pinned" || fail "no-scraping contract missing"

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

# --- #124: headless-worker-for-every-issue (default) + durable-file resume; panes optional ---

# A10. Engine: /sail default, /ship optional (UNCHANGED by #124 — kept GREEN).
grep -qiE 'sail.{0,12}default|default engine.*sail' "$TARGET" && pass "/sail-default engine pinned" || fail "/sail-default engine missing"
grep -qiE 'ship.{0,6}optional|optional.*heavier engine' "$TARGET" && pass "/ship-optional engine pinned" || fail "/ship-optional engine missing"

# A11. DEFAULT resume is the durable-file `/surf resume` headless relaunch (#53 LaunchAgent model),
# NOT a persistent-tmux send-keys revive. The headless relaunch is no longer "retired" on the
# default path — the verified headless-hosts-the-crew fact restores it.
grep -qiE 'durable.?file|/surf resume.*relaunch|relaunch.*/surf resume' "$TARGET" && pass "durable-file /surf resume relaunch pinned (default)" || fail "durable-file resume relaunch missing"
grep -qiE 'headless relaunch|claude .*-p .*/surf resume' "$TARGET" && pass "headless /surf resume relaunch named (default cap-recovery)" || fail "headless relaunch (default) missing"
grep -qiE 'reboot' "$TARGET" && pass "reboot/recovery discussed" || fail "reboot/recovery discussion missing"

# A11b. The false 'agent teams / only a teammate can host the crew / cannot run headless' premise
# is REMOVED from the default path (it survives only inside the optional supervised lens prose, if
# at all). A headless `-p` process hosts /sail's crew (depth-0 subagents) — assert that fact.
grep -qiE 'depth-0|subagent|hosts? .*crew|headless .*host' "$TARGET" && pass "headless-hosts-the-crew fact pinned" || fail "headless-hosts-crew fact missing"

# A12. tmux start/monitor commands appear ONLY inside the OPTIONAL supervised lens (a viewer over
# the same run-dir process), not as the default start front door.
# Either: no default-path tmux-start command at all, OR every tmux-start lives near an optional-lens qualifier.
if grep -qF 'tmux new -s surf' "$TARGET"; then
  # Every `tmux new -s surf` line must have an optional/supervised-lens qualifier within ±40 lines.
  awk '
    tolower($0) ~ /optional/ && tolower($0) ~ /lens|supervised|demo/ { q[NR]=1 }
    /tmux new -s surf/ { starts[NR]=1 }
    END {
      for (s in starts) {
        ok=0
        for (n in q) { if (n>=s-40 && n<=s+40) { ok=1; break } }
        if (!ok) { exit 1 }
      }
      exit 0
    }' "$TARGET" \
    && pass "tmux start command qualified as optional/supervised lens" || fail "tmux start not scoped to optional lens"
else
  pass "no default-path tmux-start command (headless default)"
fi

# A13. Worker lifecycle is HARNESS-owned (#124 final decision): the worker is backgrounded via the
# harness `run_in_background` Bash facility (survives turns; harness-managed kill), NOT pure-bash
# daemonization. The wall-clock cap is enforced by the SUPERVISOR (elapsed-since-spawn) issuing the
# harness kill — no bash process-group kill / PID-reuse guard on the default path.
grep -qiE 'run_in_background|run-in-background' "$TARGET" && pass "harness run_in_background worker lifecycle pinned" || fail "run_in_background lifecycle missing"
grep -qiE 'wall-clock cap|elapsed' "$TARGET" && pass "supervisor-enforced wall-clock cap pinned" || fail "wall-clock cap missing"
grep -qiE 'harness.*kill|kill.*harness|background-task kill|task-stop|KillShell' "$TARGET" && pass "harness-managed kill pinned (no bash pgkill)" || fail "harness-managed kill missing"
# The OLD bash daemonization functions must NOT be INVOKED as the active model anymore (prose may
# still EXPLAIN that they were removed). Assert no callable invocation syntax survives:
#   `surf_worker_spawn <`, `surf_worker_wait <`, `surf_worker_pgkill <`, or `surf_worker_command`
# being called with a run-dir arg (the old spawn signature). The emitter is invoked as
# `surf_worker_command <issue>` (no run-dir), so that's allowed.
grep -qE 'surf_worker_spawn <|surf_worker_wait "|surf_worker_wait <|surf_worker_pgkill |surf_worker_identity_ok |surf_worker_start_token ' "$TARGET" && fail "stale bash-daemonization function INVOCATION still in surf.md" || pass "no stale spawn/wait/pgkill/identity invocations in surf.md"

# A14. Worker run-to-terminus contract (the worker runs /sail --unattended to terminus).
grep -qiE 'start immediately|run autonomously to terminus|do not idle|without idling|--unattended' "$TARGET" && pass "worker run-to-terminus contract pinned" || fail "run-to-terminus contract missing"

# A15. Injection-safe boundary: numeric issue id + answers via files (the worker command is EMITTED
# by surf_worker_command, not forked by bash).
grep -qF 'surf_worker_command' "$TARGET" && pass "surf_worker_command emitter referenced" || fail "surf_worker_command reference missing"
grep -qiE 'numeric.*issue id|issue id.*numeric|injection.?safe|answers? .*(via|in) (a )?file' "$TARGET" && pass "injection-safe boundary pinned" || fail "injection-safe boundary missing"

# A16. Resume reconciliation: an in-flight run-dir WITHOUT a completion sentinel is ORPHANED
# (re-check/re-run against the SAME run-dir), never treated as done.
grep -qiE 'completion sentinel|done sentinel|sentinel' "$TARGET" && pass "completion sentinel concept pinned" || fail "completion sentinel missing"
grep -qiE 'orphan' "$TARGET" && pass "in-flight run-dir treated as orphaned pinned" || fail "orphaned-run-dir reconciliation missing"

# --- #57: domain-gated input windows + clear mode banner ---

# D1. Mode banner: states active mode + inline escape instruction on the same line
grep -qiE 'mode banner' "$TARGET" && pass "mode banner present" || fail "mode banner missing"
grep -qiE 'inline escape instruction' "$TARGET" && pass "inline escape instruction present" || fail "inline escape instruction missing"
grep -qiE 'zero user memory|nothing to memorize|never (something to look up|memorized)' "$TARGET" && pass "banner zero-memory rationale present" || fail "banner zero-memory rationale missing"

# D1b. Bind each mode's Step-0b banner to its OWN escape — a swap or a missing escape must fail.
# The mode labels recur in Step 11b and the banner phrases wrap across lines, so: bound extraction
# to the Step-0b section, capture each mode's stanza, strip the blockquote markers, and collapse
# wrapping. Keyword-anywhere greps would pass even on a supervise/autonomous escape swap.
norm() { sed -E 's/^[[:space:]]*>[[:space:]]?//' | tr '\n' ' ' | tr -s ' '; }
AUTO_BLOCK=$(awk '/### Step 0b:/{s=1} /^## Start gate/{s=0} s&&/\*\*Autonomous:\*\*/{f=1} s&&/\*\*Supervised:\*\*/{f=0} f' "$TARGET" | norm)
SUP_BLOCK=$(awk '/### Step 0b:/{s=1} /^## Start gate/{s=0} s&&/\*\*Supervised:\*\*/{f=1} s&&/^The banner exists/{f=0} f' "$TARGET" | norm)
printf '%s' "$AUTO_BLOCK" | grep -qF 'AUTO' && pass "autonomous banner names AUTO" || fail "autonomous banner missing AUTO"
printf '%s' "$AUTO_BLOCK" | grep -qF '`supervise`' && pass "AUTO banner escape token is supervise" || fail "AUTO banner escape (supervise) missing/swapped"
printf '%s' "$AUTO_BLOCK" | grep -qiF 'switch to checkpoints' && pass "AUTO banner escape target = checkpoints" || fail "AUTO banner escape target missing/swapped"
printf '%s' "$AUTO_BLOCK" | grep -qiF 'Press Esc' && pass "AUTO banner has Press Esc escape" || fail "AUTO banner Press Esc missing"
printf '%s' "$SUP_BLOCK" | grep -qF 'SUPERVISED' && pass "supervised banner names SUPERVISED" || fail "supervised banner missing SUPERVISED"
printf '%s' "$SUP_BLOCK" | grep -qF '`autonomous`' && pass "SUPERVISED banner escape token is autonomous" || fail "SUPERVISED banner escape (autonomous) missing/swapped"
printf '%s' "$SUP_BLOCK" | grep -qiF 'stop being asked' && pass "SUPERVISED banner escape target = stop being asked" || fail "SUPERVISED banner escape target missing/swapped"
printf '%s' "$SUP_BLOCK" | grep -qiF 'Press Esc' && pass "SUPERVISED banner has Press Esc escape" || fail "SUPERVISED banner Press Esc missing"

# D1c. Banner is reprinted at the Step 7 re-anchor (not only at startup) + is spec'd as one-line.
# Bind the reprint check to the Step 7 section so a regression that drops it from re-anchor fails.
REANCHOR=$(awk '/### Step 7:/{s=1} s&&/### Step 8:/{s=0} s' "$TARGET")
printf '%s' "$REANCHOR" | grep -qiF 'mode banner' && pass "Step 7 re-anchor reprints the mode banner" || fail "Step 7 re-anchor banner reprint missing"
grep -qiE 'one-line (\*\*)?mode banner|one-line banner' "$TARGET" && pass "banner specified as one-line" || fail "one-line banner property missing"

# D1d. The banner escape is a real control: a runtime mode-toggle path consumes Esc/keyword input.
grep -qiE 'applies it at the next issue boundary|consumed at the next checkpoint|escape is (a )?real control' "$TARGET" && pass "mid-run mode-toggle runtime path defined" || fail "mode-toggle runtime path missing"
grep -qiE 'never mid-build|effect from the \*\*next\*\* issue|takes effect from the' "$TARGET" && pass "mode switch takes effect next issue (not mid-build)" || fail "mode-switch timing missing"

# D2. Domain gating: auto-for-code / ask-for-domain ownership split
grep -qiE 'domain gating|auto-for-code|ask-for-domain' "$TARGET" && pass "domain-gating concept present" || fail "domain-gating concept missing"
grep -qiE 'coding decision|code decision' "$TARGET" && pass "coding-decision ownership present" || fail "coding-decision ownership missing"
grep -qiE 'domain (decision|assumption|call|question)' "$TARGET" && pass "domain-decision ownership present" || fail "domain-decision ownership missing"

# D3. .ship/domain.md is the domain memory that stops re-asking
grep -qF '.ship/domain.md' "$TARGET" && pass ".ship/domain.md memory referenced" || fail ".ship/domain.md missing"
grep -qiE 'stops? (re-)?asking|not (be )?asked twice|not (be )?re-asked|fewer (windows|pauses)' "$TARGET" && pass "domain-memory stops-re-asking present" || fail "stops-re-asking missing"

# D4. /train teaches the domain memory
grep -qF '/train' "$TARGET" && pass "/train referenced" || fail "/train missing"

# D5. One primitive, mode-dependent behavior
grep -qiE 'one primitive|single mechanism' "$TARGET" && pass "one-primitive framing present" || fail "one-primitive framing missing"
grep -qiE 'mode-dependent' "$TARGET" && pass "mode-dependent behavior present" || fail "mode-dependent behavior missing"

# D6. Autonomous: bounded window -> best bet, record options + chosen route
grep -qiE 'bounded window|bounded' "$TARGET" && pass "bounded window (autonomous) present" || fail "bounded window missing"
grep -qiE 'best bet|best-bet' "$TARGET" && pass "best-bet present" || fail "best-bet missing"
grep -qiE 'options it weighed|record(s|ed)? the options|options .*route|route it chose|route chosen|chosen route' "$TARGET" && pass "record-options-and-route present" || fail "record-options-and-route missing"

# D7. Supervised domain questions flow through the Step 11 deadline (reconciled, not duplicated)
grep -qiE 'flows? through.*Step 11|Step 11 (open-questions|deadline)|asks within the deadline' "$TARGET" && pass "supervised domain ties to Step 11 deadline" || fail "Step 11 tie-in missing"

# D8. Even AUTO surfaces domain pauses (don't bug me about code / never guess at my domain)
grep -qiE "don.t bug me about code" "$TARGET" && pass "auto=don't-bug-me-about-code present" || fail "auto framing missing"
grep -qiE "guess .{0,12}(at )?my domain|guess at my domain" "$TARGET" && pass "never-guess-at-domain present" || fail "never-guess-at-domain missing"

# D9. An irreversible / no-defensible-default domain call is parked, not guessed
grep -qiE 'irreversible|no defensible default' "$TARGET" && pass "irreversible-domain-call parks present" || fail "irreversible-domain park missing"

# --- #86: auto-pickup until the board is truly empty + scope toggle + anti-regress guard ---

# Extract the Step 7c (auto-pickup) section once; several assertions bind to it so a keyword
# living elsewhere in the doc can't satisfy a Step-7c-specific contract.
STEP7C=$(awk '/### Step 7c:/{s=1} /^## Worker delegation/{s=0} s' "$TARGET")

# S1. Scope choice named explicitly at charter time (the policy is named, not improvised per run)
grep -qiE 'scope (mode|choice|toggle)' "$TARGET" && pass "scope choice named" || fail "scope choice naming missing"
grep -qiE 'selected.set|only the selected' "$TARGET" && pass "scope (a) selected-set named" || fail "scope (a) selected-set missing"
grep -qiE 'whole.board.*(filed during the run|including .*run)|including issues filed during the run' "$TARGET" && pass "scope (b) whole-board-including-run-filed named" || fail "scope (b) whole-board missing"

# S2. Auto-pickup re-scan loop in whole-board mode: re-list each pass, terminate when truly empty
grep -qiE 're-?scan|re-?list the board each pass|re-list .*open' "$TARGET" && pass "re-scan-each-pass loop present" || fail "re-scan loop missing"
grep -qiE 'truly empty|board is (truly )?empty|until the board is empty' "$TARGET" && pass "terminate-when-truly-empty present" || fail "terminate-when-empty missing"
# Re-scan must hydrate labels BEFORE the build/defer decision (resolves the HIGH plan risk).
# Bind to Step 7c AND require the hydrated command to appear before the build-vs-defer decision text.
printf '%s' "$STEP7C" | grep -qF 'gh issue list --state open --json number,title,labels' && pass "Step 7c re-scan hydrates labels (--json …labels)" || fail "Step 7c label-hydration command missing"
printf '%s' "$STEP7C" | awk '/gh issue list --state open --json number,title,labels/{h=NR} /build-?vs-?defer|build-vs-defer|decide build/{if(h && NR>=h) d=1} END{exit d?0:1}' && pass "label-hydration precedes the build/defer decision" || fail "label-hydration not ordered before build/defer decision"

# S3. Anti-regress guard (load-bearing): run-filed refinements go to backlog, not auto-build
grep -qiE 'anti-regress' "$TARGET" && pass "anti-regress guard named" || fail "anti-regress guard missing"
grep -qF 'surf-pilot' "$TARGET" && pass "charter-named refinement label (surf-pilot) pinned" || fail "charter-named label missing"
grep -qiE 'backlog' "$TARGET" && pass "run-filed refinements routed to backlog" || fail "backlog routing missing"
grep -qiE 'not (be )?auto-built|never auto-built|without explicit opt-in' "$TARGET" && pass "not-auto-built-without-opt-in pinned" || fail "opt-in gate missing"

# S4. Generation-set backstop guarantees termination: the load-bearing clause is that issues
# filed by the run do NOT re-enter the same run. Bind to Step 7c and require that specific clause
# (a bare 'generation-set' keyword elsewhere must not satisfy the termination guarantee).
printf '%s' "$STEP7C" | grep -qiE 'generation.set' && printf '%s' "$STEP7C" | grep -qiE 'do not re-enter|don.t re-enter|not re-enter the same run' && pass "generation-set re-entry/termination clause pinned in Step 7c" || fail "generation-set re-entry clause missing"

# S5. New build-appropriate issues are re-triaged on intake (same rules / Step 5b), not tacked on
grep -qiE 'triaged by the same rules|re-triage.*intake|same triage|run through the same' "$TARGET" && pass "re-triage-on-intake pinned" || fail "re-triage-on-intake missing"

# S6. Park-class unchanged: domain/irreversible/needs-validation still park, never best-bet-built
grep -qiE 'park-class (is )?unchanged|park.class .*unchanged|needs-validation' "$TARGET" && pass "park-class-unchanged pinned" || fail "park-class-unchanged missing"

# S7. Wrap-up reports the active scope, termination cause, and deferred backlog issue numbers
WRAPUP=$(awk '/### Step 14:/{s=1} s&&/### Step 14b:/{s=0} s' "$TARGET")
printf '%s' "$WRAPUP" | grep -qiE 'active scope|scope (that )?was active|which scope' && pass "wrap-up reports active scope" || fail "wrap-up active-scope report missing"
printf '%s' "$WRAPUP" | grep -qiE 'issue numbers deferred to the backlog' && pass "wrap-up lists explicit deferred backlog issue numbers" || fail "wrap-up deferral issue-numbers list missing"

# S8. Mode banner also surfaces the active scope (so what's left is never a surprise)
grep -qiE 'banner.*scope|scope.*banner|states.*active scope' "$TARGET" && pass "banner surfaces active scope" || fail "banner scope-surfacing missing"
# S8b. The scope token is in the actual banner TEMPLATES, not only the intro prose (lens1 fix).
# Bind to the Step-0b blockquotes so a regression that drops it from the rendered banner fails.
AUTO_B=$(awk '/### Step 0b:/{s=1} /^## Start gate/{s=0} s&&/\*\*Autonomous:\*\*/{f=1} s&&/\*\*Supervised:\*\*/{f=0} f' "$TARGET")
SUP_B=$(awk '/### Step 0b:/{s=1} /^## Start gate/{s=0} s&&/\*\*Supervised:\*\*/{f=1} s&&/^The banner exists/{f=0} f' "$TARGET")
printf '%s' "$AUTO_B" | grep -qiE 'scope:' && pass "AUTO banner template carries scope token" || fail "AUTO banner scope token missing"
printf '%s' "$SUP_B" | grep -qiE 'scope:' && pass "SUPERVISED banner template carries scope token" || fail "SUPERVISED banner scope token missing"
# S8c. Scope is chosen at Step 5 (after the first banner) — startup banner shows pending (ordering fix)
grep -qiE 'scope is chosen at Step 5|shows .?pending.? until Step 5|scope: pending' "$TARGET" && pass "banner scope-pending ordering pinned" || fail "banner scope-ordering missing"

# S9. Generation-set is DEFINED: durable storage + populated at the issue-filing site (HIGH redteam fix)
grep -qF '.surf/created-issues' "$TARGET" && pass "generation-set durable storage path pinned" || fail "generation-set storage path missing"
grep -qiE 'issue-filing|appends? the new issue number' "$TARGET" && pass "generation-set populated at issue-filing site" || fail "generation-set population instruction missing"

# S10. Anti-regress guard ties BOTH signals together (label + generation-set), with an OR/either
# rule (matching EITHER signal defers). Reuse the STEP7C block (no re-extract). Guard against a
# wrong boolean: require the 'either' rule, not 'both signals'/'all signals'.
printf '%s' "$STEP7C" | grep -qiE 'matching .{0,6}either.{0,8}signal' && pass "anti-regress: matching either signal defers" || fail "anti-regress either-signal rule missing"
printf '%s' "$STEP7C" | grep -qiE 'matching .{0,6}both signals|all signals' && fail "anti-regress wrongly requires BOTH/ALL signals (should be either)" || pass "anti-regress does not require both/all signals"
printf '%s' "$STEP7C" | grep -qF 'surf-pilot' && printf '%s' "$STEP7C" | grep -qiE 'generation.set' && pass "anti-regress ties label AND generation-set" || fail "anti-regress both-signals tie missing"

# S11. Re-triage intake is an explicit transaction reconciled with Step 5b's once-up-front rule
grep -qiE 'intake transaction' "$TARGET" && pass "intake transaction named" || fail "intake transaction missing"
grep -qiE 'whole-board (exception|mode re-runs)|exception .* whole-board' "$TARGET" && pass "Step 5b once-up-front whole-board exception reconciled" || fail "Step 5b reconciliation missing"

# S12. Wrap-up records the termination cause (board-empty vs cost/time cap) (lens1+lens2 fix)
printf '%s' "$WRAPUP" | grep -qiE 'termination cause|board-empty|cost/time cap' && pass "wrap-up records termination cause" || fail "wrap-up termination-cause missing"

# S13. Resume (Step 15) loads the generation-set before any re-scan (HIGH lens2/redteam fix)
STEP15=$(awk '/### Step 15:/{s=1} /### Step 16:/{s=0} s' "$TARGET")
printf '%s' "$STEP15" | grep -qF '.surf/created-issues-' && pass "Step 15 loads the generation-set file" || fail "Step 15 generation-set load missing"
printf '%s' "$STEP15" | grep -qiE 'before.{0,4}any.{0,20}re-?scan' && pass "generation-set loaded before re-scan on resume" || fail "resume load-before-rescan ordering missing"

# S14. Exhaustion / done-marker is scope-aware (selected-set vs whole-board re-scan) (HIGH lens2 fix)
grep -qiE 'mark the run done \(scope-aware\)|exhaustion is defined .*per the charter.s scope|scope-aware' "$TARGET" && pass "done-marker exhaustion is scope-aware" || fail "scope-aware exhaustion missing"

# S15. Step 7c hydrates each candidate (body AND comments) BEFORE the build-vs-defer decision — the
# cheap list only enumerates; build-appropriate/park-class signals live in body/comments (HIGH redteam).
# Require comments in the hydration command (a signal can live in a comment).
printf '%s' "$STEP7C" | grep -qF 'gh issue view <n> --json title,body,labels,comments' && pass "Step 7c hydration fetches comments" || fail "Step 7c hydration omits comments"
# Order-sensitive: the per-candidate `gh issue view` hydration must precede the actual
# 'decide build-vs-defer on' decision instruction (a keyword-anywhere grep would miss a reordering).
# Anchor the decision on 'decide build-vs-defer' (the final decision step), NOT 'deciding'
# (the earlier hydrate-first directive), so the hydration command must precede the real decision.
printf '%s' "$STEP7C" | awk '/gh issue view <n> --json title,body,labels,comments/{h=NR} /decide build-?vs-?defer/{if(h && NR>=h) d=1} END{exit d?0:1}' && pass "Step 7c hydration precedes the build/defer decision" || fail "Step 7c hydrate-before-decision ordering missing"

# S16. The revive watcher's journal-done check is scoped to the LATEST charter's journal, not a
# global grep across all journals (#86 — an old completed run must not silence a new charter).
RESUME_SH="$REPO_ROOT/config/surf-resume.sh"
[ -f "$RESUME_SH" ] && grep -qF 'journal-${charter_ts}.md' "$RESUME_SH" && pass "watcher journal-done check scoped to latest charter's journal" || fail "watcher charter-scoped journal-done check missing"
[ -f "$RESUME_SH" ] && ! grep -qE 'grep -rqsiE .*journal-\*\.md' "$RESUME_SH" && pass "watcher no longer greps journals globally for done:" || fail "watcher still greps journals globally"
# S16b. BEHAVIORAL: source the watcher (SURF_RESUME_DIR override + sourcing guard make this possible)
# and prove work_remains() is charter-scoped — an OLD completed run's journal must NOT silence a
# NEWER unfinished charter, while the latest charter's OWN done journal still silences (#86 core fix).
s16b() {
  local tmpw; tmpw="$(mktemp -d)"
  export SURF_RESUME_DIR="$tmpw" SURF_RESUME_LOG="$tmpw/log"
  : > "$tmpw/charter-20260101T000000.md"; printf -- '- done: board exhausted\n' > "$tmpw/journal-20260101T000000.md"
  : > "$tmpw/charter-20260202T000000.md"; printf -- '- start\n' > "$tmpw/journal-20260202T000000.md"
  touch -t 202601010000 "$tmpw"/charter-20260101T000000.md "$tmpw"/journal-20260101T000000.md
  touch -t 202602020000 "$tmpw"/charter-20260202T000000.md "$tmpw"/journal-20260202T000000.md
  # shellcheck source=/dev/null
  source "$RESUME_SH"
  work_remains; local r1=$?               # newer charter unfinished → expect 0 (work remains)
  printf -- '- done: board exhausted\n' >> "$tmpw/journal-20260202T000000.md"
  work_remains; local r2=$?               # latest charter's own journal done → expect 1 (quiet)
  rm -rf "$tmpw"
  [ "$r1" -eq 0 ] && [ "$r2" -eq 1 ]
}
( s16b ) && pass "watcher work_remains() charter-scoped (behavioral: old done journal does not silence new charter)" || fail "watcher charter-scoping behavioral test failed"

# S16c. Latest charter is chosen by the SORTABLE timestamp suffix, not mtime — a `touch` on an OLD
# (done) charter must not make it look newest and silence a genuinely-newer unfinished run (redteam fix).
[ -f "$RESUME_SH" ] && ! grep -qE 'mt="\$\(mtime_of "\$charter"\)"' "$RESUME_SH" && pass "watcher charter selection no longer uses mtime" || fail "watcher still selects charter by mtime"
s16c() {
  local tmpw; tmpw="$(mktemp -d)"
  export SURF_RESUME_DIR="$tmpw" SURF_RESUME_LOG="$tmpw/log"
  : > "$tmpw/charter-20260101T000000.md"; printf -- '- done: board exhausted\n' > "$tmpw/journal-20260101T000000.md"
  : > "$tmpw/charter-20260202T000000.md"; printf -- '- start\n' > "$tmpw/journal-20260202T000000.md"
  # INVERT mtimes: the OLD (done) charter is touched MORE recently than the NEW unfinished one.
  touch -t 202602020000 "$tmpw"/charter-20260202T000000.md "$tmpw"/journal-20260202T000000.md
  touch -t 202612310000 "$tmpw"/charter-20260101T000000.md "$tmpw"/journal-20260101T000000.md
  # shellcheck source=/dev/null
  source "$RESUME_SH"
  work_remains; local r=$?    # lexical selection picks 20260202 (unfinished) → expect 0 (work remains)
  rm -rf "$tmpw"
  [ "$r" -eq 0 ]
}
( s16c ) && pass "watcher selects latest charter by timestamp suffix even when mtimes are inverted" || fail "watcher mtime-inversion regression failed"

# S17. Generation-set population is owned by the durable orchestrator, not the ephemeral teammate (lens1 fix)
printf '%s' "$STEP7C" | grep -qiE 'orchestrator owns population|orchestrator records into the generation-set' && pass "orchestrator owns generation-set population" || fail "orchestrator-owns-generation-set missing"
# S18. A missing generation-set file on a whole-board charter is recovery/corruption, not a silent empty set (lens2 fix)
printf '%s' "$STEP7C" | grep -qiE 'corruption, not an empty' && pass "missing generation-set treated as recovery, not empty" || fail "missing-file recovery handling missing"
# S19. Termination proof is narrowed to self-created refinements; external work bounded by the cap (lens2 fix)
printf '%s' "$STEP7C" | grep -qiE 'self-created refinements provably terminate|filed by \*?others\*?' && pass "termination proof narrowed (self vs external)" || fail "termination-proof narrowing missing"

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
