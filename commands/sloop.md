---
hooks:
  PreToolUse:
    - matcher: Write
      hooks:
        - type: command
          command: bash ~/.claude/hooks/ship-write-gate.sh
    - matcher: Edit
      hooks:
        - type: command
          command: bash ~/.claude/hooks/ship-write-gate.sh
  PostToolUse:
    - matcher: Bash
      hooks:
        - type: command
          command: bash ~/.claude/hooks/ship-wip.sh
  PreCompact:
    - matcher: ""
      hooks:
        - type: command
          command: bash ~/.claude/hooks/ship-precompact.sh
  PostCompact:
    - matcher: ""
      hooks:
        - type: command
          command: bash ~/.claude/hooks/ship-postcompact.sh
  Stop:
    - matcher: ""
      hooks:
        - type: command
          command: bash ~/projects/CK-Skills/hooks/sloop-stop-gate.sh
---
Standard-weight ship pipeline: plan (1 RT round) → implement → red-team (1 round) → commit on branch → learn. Middle ground between /skiff (direct-to-main) and /ship (full ceremony). Issue number: $ARGUMENTS

Sloop is the standard workboat — same crew, same standards, lighter loadout. Where `/ship` runs the full gated pipeline (board → orientation → plan red-team × 5 → per-step gates → full-branch red-team × 5 → simplify → learn → commit), and `/skiff` runs the bare minimum (plan → implement → red-team → commit direct to main), `/sloop` runs the load-bearing middle: plan with one red-team round, TDD implementation, one post-implementation red-team round, commit on a branch, and learn.

## When to use /sloop vs /skiff vs /ship

| Use `/skiff` for | Use `/sloop` for | Use `/ship` for |
|---|---|---|
| Bugfixes touching 1-3 files | Single-concern fix or small feature, <5 files | New features (multi-file architectural) |
| Follow-ups from prior ships | Work using existing patterns, <200 LOC | Anything with significant unknowns |
| Spec-text edits, doc edits | Changes that need a branch but not full ceremony | Work spanning >5 files or new patterns |
| Direct-to-main work | Standard issues from the board | Security-touching code |

If unsure, start with `/sloop`. If the plan grows past 5 steps or the red-team finds architectural issues, /sloop escalates to `/ship`.

## Arguments

Parse `$ARGUMENTS` for a single issue number (e.g., `42`). If empty, ask the user which issue to target.

## Setup

### Version banner

Print:
```
Sloop v1 — #<issue>
```

### Tool loading

Fetch required tools:

```
ToolSearch({ query: "select:AskUserQuestion,EnterPlanMode,ExitPlanMode", max_results: 3 })
```

If any fail, stop: "Failed to load required tools — retry `/sloop <issue>`."

### Issue fetch

Run `gh issue view <issue> --json number,title,body,labels,state` directly. Parse `title`, `body`, `labels`, `state`. If `state != "OPEN"`, ask whether to proceed.

Print: `#<issue>: <title> — labels: <labels>`

### Branch + worktree

/sloop creates a `ship/<issue>` branch with worktree isolation (unlike /skiff's direct-to-main).

```bash
repo_root=$(git rev-parse --show-toplevel)
wt_path="$repo_root/.claude/worktrees/sloop-<issue>"

git worktree prune 2>/dev/null || true

# Create worktree + branch (clean up stale if needed)
if git show-ref --verify --quiet "refs/heads/ship/<issue>"; then
  other_wt=""
  wt=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt="${line#worktree }" ;;
      "branch refs/heads/ship/<issue>") other_wt="$wt" ;;
    esac
  done < <(git worktree list --porcelain)
  if [ -n "$other_wt" ]; then
    git worktree remove "$other_wt" 2>/dev/null || true
  fi
  git branch -D "ship/<issue>" 2>/dev/null || true
fi

git worktree add "$wt_path" -b "ship/<issue>"
```

Ensure `.claude/worktrees/` and `.ship/review/` and `.ship/state/` are in `.gitignore` (use Read + Edit tools, idempotent).

### State file

Write the initial state using a Bash heredoc (hooks read this file):

```bash
cat > "$HOME/.ship/ship-state-$PPID.json" << 'SHIPSTATE'
{
  "issue": <N>,
  "pipeline": "sloop",
  "stage": "setup",
  "label": "initializing",
  "plan_step": 0,
  "plan_total": 0,
  "started_at": "<ISO timestamp>",
  "using_worktree": true,
  "worktree_path": "<wt_path>",
  "original_repo_path": "<repo_root>",
  "ship_log": {
    "issue": <N>,
    "title": "<title>",
    "branch": "ship/<N>",
    "started_at": "<ISO timestamp>",
    "completed_at": null,
    "plan_steps": 0,
    "tdd_cycles": 0,
    "test_results": null
  }
}
SHIPSTATE
```

### Sentinel write

```bash
rm -f "$HOME/.ship/sloop-active-$PPID"; : > "$HOME/.ship/sloop-active-$PPID"
```

### Domain knowledge

Read `$wt_path/.ship/domain.md` if it exists. This informs the plan and red-team.

## Stage 1: Plan

Update state: `"stage": "plan"`.

Call `EnterPlanMode`. Follow the standard plan-mode workflow:

1. **Phase 1 — Explore.** Launch 1 `Explore` agent (up to 3 for cross-cutting scope) to verify file paths, line numbers, helper APIs, and adjacent risks. Work in the worktree path.

2. **Phase 2 — Design.** Draft the plan in the plan file. Required sections:
   - **Context** — the bug or gap; what triggered it
   - **Approach** — single recommended fix vector
   - **Implementation** — concrete edits with file paths and line numbers
   - **Critical Files** — bullet list
   - **Verification** — test command + regression suite command
   - **Implementation order** — TDD sequence (test → fail → impl → pass → suite)
   - **Out of scope** — explicit exclusions

3. **Phase 3 — Red-team the plan.** Spawn 1 `@red-team` round on the plan only (read-only, no code changes). Prompt:

   ```
   You are @red-team reviewing a /sloop plan for issue #<N>.
   review_type: "plan"
   Working directory: <wt_path>

   === PLAN ===
   <plan content>

   === DOMAIN RULES ===
   <domain.md content or "(no domain.md present)">

   === FOCUS AREAS ===
   1. Plan completeness — are all affected files identified?
   2. TDD feasibility — can the test be written before implementation?
   3. Scope containment — does the plan stay within the stated boundaries?
   4. Domain rule compliance — does the plan conflict with known rules?

   === OUTPUT FORMAT ===
   Markdown findings table, then JSON fenced block.
   Severity in {CRITICAL, HIGH, MEDIUM, LOW}. fix_type in {plan_text, implementation, architectural}.
   ```

   If CRITICAL/HIGH findings: revise the plan and re-present in plan mode. If only MEDIUM/LOW: note them for awareness and proceed.

4. **Phase 4 — Call `ExitPlanMode`** for user approval.

If the user rejects the plan, clean up:

```bash
rm -f "$HOME/.ship/sloop-active-$PPID"
rm -f "$HOME/.ship/ship-state-$PPID.json"
git checkout main
git worktree remove "$wt_path" 2>/dev/null || true
git branch -D "ship/<issue>" 2>/dev/null || true
```

## Stage 2: Implement

Update state: `"stage": "implement"`.

Invoke the `implement` skill:

```
Skill({
  skill: "implement",
  args: "Execute the approved plan at <plan_file_path> (issue #<N>: <title>).

         Working directory: <wt_path>. You are on branch ship/<N>
         in a worktree at <wt_path>.

         CONSTRAINTS:
         - Follow the plan's 'Implementation order' section verbatim.
         - Run the test suite at each gate per the plan's 'Verification' section.
         - DO NOT commit. The orchestrator runs red-team after you return,
           then commits.
         - DO NOT push. Do not run /ship or /skiff.
         - Step 7 (internal red-team) of /implement is redundant under
           /sloop — the orchestrator runs full-branch red-team after
           you return — so you may omit it.

         STOP IF PLAN IS WRONG: if during execution you discover that the
         plan references a function/file/path that does not exist, or its
         'Implementation order' cannot be completed without changes outside
         the plan's stated scope, STOP. Return immediately with an anomaly
         entry 'plan_discovery: <one-line description>' instead of
         expanding scope.

         RETURN FORMAT (structured JSON in your final message):
           { files_modified: [<path>, ...],
             test_counts:   { before: <N>, after: <M>, added: <K> },
             anomalies:     [<tag>: <one-line>, ...] }"
})
```

When `/implement` returns, capture files modified, test counts, and anomalies.

Log: `→ /sloop #<N>: /implement returned — <X> files changed, <Y/Z> tests pass`

**Auto-transition to Stage 3 is unconditional and silent for the Clean case.** ZERO user-facing text between /implement's return and the Stage 3 red-team dispatch for the Clean case.

### Post-/implement recovery matrix

| Case | Detection | Recovery |
|---|---|---|
| **Clean** | test_counts.after >= before AND anomalies == [] AND files in Critical Files | Proceed to Stage 3 silently |
| **Test failing** | test_counts.after < before OR test_failing anomaly | AskUserQuestion: 1) Re-enter plan 2) Escalate to /ship 3) Abort + revert |
| **No code written** | files_modified == [] AND anomalies == [] | AskUserQuestion: 1) Re-enter plan 2) Escalate to /ship 3) Abort cleanly |
| **Plan was wrong** | plan_discovery or scope_creep anomaly | AskUserQuestion: 1) Re-enter plan 2) Escalate to /ship 3) Abort cleanly |

**Detection precedence:** Plan was wrong > Test failing > No code written > Clean.

All non-Clean cases use `header: "Anomalous /implement return"` (load-bearing for the stop gate).

**Escalate to /ship:** Stash work, sentinel cleanup, end. User re-runs `/ship <N>`.

```bash
cd "$wt_path" && git stash push -u -m "sloop-<N>-prelude"
rm -f "$HOME/.ship/sloop-active-$PPID"
rm -f "$HOME/.ship/ship-state-$PPID.json"
```

**Abort + revert:**

```bash
cd "$wt_path" && git checkout -- .
rm -f "$HOME/.ship/sloop-active-$PPID"
rm -f "$HOME/.ship/ship-state-$PPID.json"
git checkout main
git worktree remove "$wt_path" 2>/dev/null || true
git branch -D "ship/<issue>" 2>/dev/null || true
```

## Stage 3: Red-team (1 round)

Update state: `"stage": "review"`.

### 3a. Pre-stage untracked files

```bash
cd "$wt_path" && git ls-files -z --others --exclude-standard | xargs -0 -r git add -N --
```

### 3b. Dispatch @red-team

Spawn `@red-team` via the `Agent` tool with `subagent_type: "Explore"`, `model: "opus"`.

```
You are @red-team performing a full-branch review of /sloop #<issue>.

review_type: "full-branch"
Working directory: <wt_path>. Use absolute paths for Read/Glob/Grep.

=== DIFF ===
<output of: cd "$wt_path" && git diff HEAD>

=== APPROVED PLAN ===
<plan content>

=== DOMAIN RULES ===
<domain.md content or "(no domain.md present)">

=== FOCUS AREAS ===
1. Wiring & scaffolding — new files installed and referenced by callers
2. Spec self-consistency — references resolve correctly
3. Shell safety — quoted heredocs, no shell injection
4. Test coverage — changes have tests
5. Domain rule compliance — no conflicts with domain.md

=== OUTPUT FORMAT ===
Markdown findings table, then JSON fenced block.
Severity in {CRITICAL, HIGH, MEDIUM, LOW}. fix_type in {plan_text, implementation, architectural}.
```

Parse the JSON findings.

### 3c. Evaluate findings

Compute:
- `crit_count` = CRITICAL findings
- `high_count` = HIGH findings
- `has_structural` = any (CRITICAL|HIGH) with fix_type == "architectural"

**If `has_structural`:** Present escalation gate:

```json
{
  "question": "Architectural CRIT/HIGH detected. /sloop runs 1 RT round and cannot safely iterate on architectural issues. Recommend re-running as /ship.",
  "header": "Architectural finding",
  "multiSelect": false,
  "options": [
    {"label": "Escalate to /ship (Recommended)", "description": "Stash work, end sloop, re-run as /ship <issue>."},
    {"label": "Attempt fix anyway", "description": "Apply fix inline; if it fails, the commit gate will catch it."},
    {"label": "Abort", "description": "Revert all changes, remove branch."}
  ]
}
```

On escalate: stash + sentinel cleanup (same as Stage 2 escalation).
On abort: revert + cleanup (same as Stage 2 abort).
On attempt: apply fix via Edit/Write, re-run suite, proceed to 3d.

**If CRIT/HIGH but not structural:** Auto-fix via Edit/Write, re-run suite to confirm no regression, proceed to 3d.

**If no CRIT/HIGH (converged):** Proceed to 3d.

### 3d. Convergence gate

For each MEDIUM/LOW finding, classify as:
- **Address inline** — apply fix, mark addressed
- **Defer to follow-up** — file issue via `gh issue create --label red-team-follow-up`
- **Won't fix** — mark with rationale

Present to user:

```json
{
  "question": "Sloop #<N> reviewed (<C>C <H>H <M>M <L>L). <summary>. Ready to commit on ship/<N> and push?",
  "header": "Sloop complete",
  "multiSelect": false,
  "options": [
    {"label": "Commit + push (Recommended)", "description": "Commit on ship/<N>, push, close issue."},
    {"label": "Commit only", "description": "Land commit locally; defer push."},
    {"label": "Hold — review first", "description": "Pause; inspect diff before deciding."}
  ]
}
```

On hold: sentinel cleanup, end. User inspects and decides.

## Stage 4: Commit

Update state: `"stage": "commit"`.

### 4a. Stage files

```bash
cd "$wt_path" && git add <enumerated files from /implement + inline fixes>
git status --short
```

### 4b. Commit

```bash
git commit -m "$(cat <<'EOF'
<prefix>: <one-line summary> (#<issue>)

<paragraph: what and why>

<paragraph: verification — test counts, suite results>

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

Prefix: `fix:` for bugfixes, `feat:` for features, `docs:` for doc changes. Match recent commit style.

Do NOT include `Closes #<N>` — issue closure is via `gh issue close`.

Update state: `"stage": "committed"`.

### 4c. Push (conditional)

If user selected "Commit + push":

```bash
cd "$wt_path" && git push -u origin "ship/<issue>"
```

### 4d. Merge to main

After push:

```bash
git checkout main
git merge "ship/<issue>" --no-ff -m "$(cat <<'EOF'
merge: ship/<issue> — <title> (#<issue>)
EOF
)"
git push
```

### 4e. Close issue

```bash
gh issue close <issue> --comment "Landed in $(git rev-parse --short HEAD) via sloop.

**Summary:** <one-paragraph what changed>

**Review:** 1 red-team round, <findings summary>.

**Tests:** <count> pass, 0 fail."
```

### 4f. Worktree cleanup

```bash
git push origin --delete "ship/<issue>" 2>/dev/null || true
git worktree remove "$wt_path" 2>/dev/null || true
git branch -d "ship/<issue>" 2>/dev/null || true
```

## Stage 5: Learn

Update state: `"stage": "learn"`.

Review the red-team findings from Stage 3. For each finding with root_cause == "domain_gap":

1. Propose a domain rule in plain language
2. Ask: "Should this be added to the project's knowledge file?"
3. If yes, write to `$original_repo_path/.ship/domain.md` using Edit (this is in the main repo, not the worktree — worktree is already cleaned up)

For findings with root_cause in {plan_gap, implementation_drift, emergent}: log in the ship's log but do not propose domain rules.

### Ship's log (abbreviated)

Write to `$original_repo_path/.handoffs/ship-log-<issue>.md`:

```markdown
# Ship's Log — #<issue>: <title>

**Pipeline:** sloop v1
**Branch:** `ship/<issue>`
**Started:** <ISO timestamp>
**Completed:** <ISO timestamp>
**Duration:** <human-readable>

## Summary
<1-2 paragraphs: what changed and why>

## Red-Team Findings
<findings table or "No findings">

## Test Results
<count> pass, <count> fail

## Domain Updates
<accepted rules or "None proposed">
```

### Sentinel cleanup

```bash
rm -f "$HOME/.ship/sloop-active-$PPID"
rm -f "$HOME/.ship/ship-state-$PPID.json"
```

## Rules

- **Never produce target-repo implementation code yourself outside /implement or Stage 3c inline fixes.** The /implement skill handles Stage 2 writes; /sloop orchestrates and applies bounded red-team fixes only.
- **Never skip the red-team round.** Even on a small change, the round catches wiring issues, domain violations, and test gaps.
- **Escalate architectural findings.** If the red-team flags CRIT/HIGH with fix_type: architectural, offer to escalate to /ship. /sloop's single round cannot safely iterate on structural issues.
- **Pre-stage untracked files before the red-team round.** `git add -N` makes new files visible to `git diff`.
- **Auto-transition Stage 2 → Stage 3.** Never pause between /implement return and red-team dispatch for the Clean case.
- **Always create a branch + worktree.** /sloop never commits direct to main. If the user wants direct-to-main, use /skiff.
- **State file via Bash heredoc only.** Write `ship-state-$PPID.json` via `cat >` in Bash, never via Write/Edit tools. The shared hooks intercept Bash output to read state.
- **All Bash heredocs with user-derived content use quoted delimiters** (`<< 'EOF'`).

## Limitations

- **Single-issue only.** No batch mode.
- **1 red-team round.** No convergence loop. Escalate to /ship if issues persist.
- **No orientation check.** No pre-plan research agent.
- **No independent test writer.** /implement writes its own tests.
- **No per-step gates.** Implementation runs as one unit.
- **No simplify step.** Code ships as /implement wrote it (plus inline fixes).
- **No codex shadow dispatch.** /implement may use codex internally; /sloop does not orchestrate it.
- **No cost tracking.** Estimate via usage trailers if needed.

## Cross-references

- `cc-dotfiles: home/commands/ship.md` — full pipeline; what /sloop escalates to
- `cc-dotfiles: home/commands/skiff.md` — lightweight pipeline; what /sloop is heavier than
- `cc-dotfiles: home/commands/implement.md` — TDD skill invoked at Stage 2
- `commands/idea.md` — triage skill that routes to /sloop
- `.ship/domain.md` — project-specific rules read by plan and red-team
