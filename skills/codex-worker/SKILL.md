---
name: codex-worker
description: Use BEFORE spawning a Claude subagent (Agent tool) for leadsman, red-team (plan / per-step / full-branch), implement, or simplify substeps inside /ship or /agent-team workflows. Delegates those substeps to OpenAI Codex CLI (`codex exec`) instead — preserves Claude as the captain (plan-drafting, gate presentations, commits, ship's log stay with Claude). Targets ~3-4× token savings on the delegated substeps while preserving output quality via structured JSON contracts and independent Claude-side verification.
version: 0.1.0
---

# Codex Worker — captain / worker delegation

## Why this exists

Claude Code burns roughly **3-4× the tokens of Codex CLI on identical coding tasks** (Morph LLM benchmark, 2026). The biggest token sinks in `/ship` are implementation, red-team review, and simplify — all mechanical, repo-grounded, and well-suited to Codex. This skill routes those substeps through `codex exec` while Claude (you) stays in the captain seat for plan-drafting, gate presentations, commits, and ship's log writing.

## When to engage this skill

Engage **before** invoking the Agent tool when the context matches any of:

- Stage 2c — red-team plan review
- Stage 3a — leadsman (write failing test)
- Stage 3c — implementation
- Stage 3e — red-team per-step
- Stage 4a — simplify
- Stage 4b — red-team full-branch
- `/agent-team` worker substeps that match any of the above
- `/agent-team` QA reviewer (rolling adversarial review of worker diffs)
- Any standalone request that maps to "write failing test", "implement minimum code", "red-team this diff", or "simplify this diff"

## When NOT to engage

Don't delegate to Codex when any of these apply:

- The change is **trivial** (<50 LOC, single file, mechanical edit). The Codex process-startup overhead exceeds the savings; inline-edit in Claude.
- The task is **ambiguous or under-specified**. Codex over-implements ambiguous specs ("compiles but does nothing meaningful"). Tighten the spec in Claude first.
- The substep is **judgment-heavy / plain-language** — plan drafting, compass orientation, gate presentations, ship's log writing, commit messages, PR bodies. Keep these with Claude.
- The substep is **push / merge / close** — explicit user confirmation per `feedback_confirm_push_per_action`. Codex must never touch remote-affecting actions.
- `codex` binary is unavailable or auth is broken. Fall back to a native Claude subagent.

## Universal invocation contract

For every delegation:

```bash
out=$(mktemp -t codex-worker.XXXXXX)
prompt=$(mktemp -t codex-prompt.XXXXXX)
cat > "$prompt" << 'PROMPT_EOF'
<role preamble + working-directory rules + task body + JSON output instruction>
PROMPT_EOF

codex exec \
  -C "$worktree_path" \
  -s <sandbox_mode> \
  -m gpt-5.4-mini \
  -c model_reasoning_effort=high \
  --skip-git-repo-check \
  --ephemeral \
  -o "$out" \
  - < "$prompt"

# Parse the final message (which MUST be JSON per the prompt)
result=$(cat "$out")
# Validate + extract: python3 -c "import json,sys; json.loads(sys.argv[1])" "$result"
rm -f "$out" "$prompt"
```

Flag rationale:

- **`-C "$worktree_path"`** — work in the active worktree, not the original repo. Required for `/ship` worktree isolation.
- **`-s <sandbox_mode>`** — `read-only` for red-team, `workspace-write` for leadsman / implement / simplify. **Never `danger-full-access`.**
- **`-m gpt-5.4-mini`** — explicit pin so behavior doesn't drift across config changes. Mini model for token savings; high reasoning compensates for capability.
- **`-c model_reasoning_effort=high`** — always `high` for all roles. The smaller model needs full reasoning to maintain output quality.
- **`--skip-git-repo-check`** — worktrees are git-aware; this just suppresses the friendly warning.
- **`--ephemeral`** — don't persist session rollout for one-shots. Saves disk and prevents accidental cross-call leakage.
- **`-o "$out"`** — capture the agent's final message to a file. We don't read the JSONL event stream — final message is enough.

## Universal prompt preamble (use verbatim for every role)

```
You are running as a worker subagent. Reply with a single JSON object matching
the schema below. No prose, no markdown, no code fences — JSON only.

Working directory: <ABSOLUTE WORKTREE PATH>. Use absolute paths for all
Read/Edit/Write/Glob/Grep operations. Prefix ALL Bash commands with
`cd <WORKTREE PATH> && `.

Do NOT inline file contents in your reasoning — read files with your repo
tools instead. Do NOT make architectural decisions or scope changes; if the
spec is ambiguous, return an empty result with a `clarification_needed`
field in your JSON output.

Project conventions live in <WORKTREE>/.ship/domain.md (read it before any
non-trivial work). Recent ship logs live in <ORIGINAL_REPO>/.handoffs/.
```

## Per-role recipes

Each recipe specifies: sandbox mode, reasoning effort, prompt body, output schema, and the verification Claude must run after Codex returns.

### Red-team plan review (Stage 2c, plan_red_team)

**Sandbox:** `read-only` · **Effort:** `high` · **Schema:** `schemas/red-team.schema.json`

**Prompt body (after preamble):**

```
ROLE: Red Team — plan review.

Critique the proposed plan below against project domain rules. Find
plan gaps, missing edge cases, hidden dependencies, scope mismatches.

PLAN (full text):
<PASTE THE FULL DRAFT PLAN MARKDOWN — this is the only acceptable inline
content; plans are small>

ISSUE: #<N> — <title>
ACCEPTANCE CRITERIA:
<bulleted AC>

PRIOR ROUND FINDINGS AND RESOLUTIONS (round N>1 only):
<orchestrator-constructed resolution notes from previous rounds; omit on round 1>

Read <WORKTREE>/.ship/domain.md end-to-end before flagging anything.

Severity: HIGH (will cause bugs / data loss / test failures), MEDIUM
(correctness or design concern), LOW (minor). Root cause for plan reviews:
plan_gap | domain_gap | emergent (implementation_drift is N/A — no code yet).

Confidence threshold: ONLY report findings where you are >80% confident.

Continue finding IDs from prior rounds when applicable.

Output ONLY this JSON shape (see red-team.schema.json):
{
  "review_type": "plan",
  "findings": [{"id": "RT-1", "severity": "...", "root_cause": "...",
                "issue": "...", "fix": "...", "category": "..."}],
  "verdict": "pass" | "pass-with-notes" | "fail",
  "summary": "one-liner"
}
```

**Verification (Claude-side):**
1. Parse JSON; reject non-conforming output.
2. Write to `<worktree>/.ship/review/red-team-round-N.md` (preserve existing artifact convention).
3. Increment `red_team_plan_rounds` in `~/.ship/ship-state-$PPID.json`.

### Leadsman (Stage 3a, write failing test)

**Sandbox:** `workspace-write` · **Effort:** `high` · **Schema:** `schemas/leadsman.schema.json`

**Prompt body:**

```
ROLE: Leadsman — write ONE failing test.

Behavior to verify (WHAT, not HOW):
<one-paragraph description of the behavior the test must check>

Acceptance criteria:
<bulleted AC>

You may read existing tests under <WORKTREE>/tests/ to match style.
DO NOT read or use the implementation plan — you only know the spec.

Write the test to the natural location (tests/<file>.py per convention).
The test MUST fail today (the feature does not exist yet). Failures must
be for the RIGHT reason (assertion mismatch, missing function, etc.) —
NOT for syntax errors, import errors, or typos.

Output ONLY this JSON (leadsman.schema.json):
{
  "test_file": "<absolute path>",
  "test_names": ["test_a", "test_b"],
  "run_command": "cd <WORKTREE> && python3 -m pytest <test_file>::<test_a> -v",
  "failure_reason": "<one-line: which assertion fails, what message>"
}
```

**Verification (Claude-side):**
1. Run `run_command`; confirm the test fails for the reason given.
2. If passes or fails for wrong reason: re-spawn Codex once with the actual error pasted in; if still wrong, write the test yourself.
3. Mark `substeps.leadsman: "complete"` in `~/.ship/ship-substeps-$PPID.json`.

### Implement (Stage 3c)

**Sandbox:** `workspace-write` · **Effort:** `high` · **Schema:** `schemas/impl-result.schema.json`

**Prompt body:**

```
ROLE: Implementer — write the MINIMUM code to make the failing test pass.

Behavior under test (from leadsman):
<paste leadsman.failure_reason and test_names>

Approved plan for this step:
<paste the plan step body — what to do, which files, the approach>

Files you may modify: <list — usually inferred from the plan>
Files OFF-LIMITS: tests/ (don't modify the failing test); .ship/ (domain rules
are not code); .handoffs/ (ship logs).

Follow existing patterns in the codebase. Do NOT refactor unrelated code.
Do NOT add error handling for impossible states. Do NOT introduce new
abstractions beyond what the step requires.

After your edits, run the failing test to confirm it now passes:
<run_command from leadsman>

Output ONLY this JSON (impl-result.schema.json):
{
  "files_changed": ["<absolute path>", ...],
  "summary": "one-paragraph what-and-why",
  "follow_ups": ["any deferred work or cleanup", ...]
}
```

**Verification (Claude-side):**
1. `git diff` — read the actual changes. Confirm files_changed matches.
2. Run the leadsman test independently; it must pass.
3. Run the full project test suite (`make test` or per CLAUDE.md). New failures block step advance.
4. Run lint / typecheck if the project has them.
5. Mark `substeps.implement: "complete"` then `substeps.verify_suite: "complete"` (only after `verify_suite_result.new_failures == 0`).

### Red-team per-step (Stage 3e)

**Sandbox:** `read-only` · **Effort:** `high` · **Schema:** `schemas/red-team.schema.json`

**Prompt body:**

```
ROLE: Red Team — per-step diff review.

Review the diff for the current step against the approved plan and project
domain rules. Check plan compliance, bugs, security, correctness,
domain-rule violations.

DIFF (cd <WORKTREE> && git diff):
<paste the step diff inline — diffs are small enough for this; do not
re-read files Codex already sees in the diff>

APPROVED PLAN (for plan-compliance check):
<paste the plan step body>

DOMAIN RULES:
Read <WORKTREE>/.ship/domain.md end-to-end.

PRIOR ROUND FINDINGS (round M>1 only):
<orchestrator-constructed resolution notes>

Severity: HIGH | MEDIUM | LOW. Root cause: plan_gap |
implementation_drift | domain_gap | emergent.

Confidence threshold: >80%.

Output ONLY this JSON (red-team.schema.json):
{
  "review_type": "per-implement",
  "findings": [...],
  "verdict": "pass" | "pass-with-notes" | "fail",
  "summary": "..."
}
```

**Verification (Claude-side):**
1. Parse JSON; reject non-conforming.
2. Write to `<worktree>/.ship/review/red-team-step-N-round-M.md`.
3. Increment `red_team_impl_rounds`.

### Simplify (Stage 4a)

**Sandbox:** `workspace-write` · **Effort:** `high` · **Schema:** `schemas/impl-result.schema.json`

**Prompt body:**

```
ROLE: Simplifier — review the branch diff and apply idiomatic cleanup.

Branch diff (cd <WORKTREE> && git diff main...HEAD):
<paste the full branch diff inline if reasonably small; otherwise just
provide the file list and let Codex re-read>

LOOK FOR (and FIX if safe):
- Code duplication that can be extracted
- Unnecessary complexity from iteration (dead branches, dead vars)
- Dead code (functions, imports, parameters)
- Naming improvements

DO NOT:
- Add new features or behaviors
- Restructure module boundaries
- Touch test files (test_*.py / *_test.py)
- Introduce new abstractions for hypothetical future use

After your edits, run the full test suite to confirm no regressions:
cd <WORKTREE> && <test command>

Output ONLY this JSON (impl-result.schema.json):
{
  "files_changed": [...],
  "summary": "what was simplified and why",
  "follow_ups": [...]
}
```

**Verification (Claude-side):**
1. `git diff` — confirm changes are pure cleanup, no behavior changes.
2. Run full suite. Any regression rolls back the simplify diff.
3. Proceed to Stage 4b red-team full-branch.

### Red-team full-branch (Stage 4b)

**Sandbox:** `read-only` · **Effort:** `high` · **Schema:** `schemas/red-team.schema.json`

**Prompt body:**

```
ROLE: Red Team — full-branch adversarial review.

Final comprehensive review of all changes on the branch before commit.
Read the cumulative diff with your repo tools:
cd <WORKTREE> && git diff main...HEAD

APPROVED PLAN (for plan-compliance):
<paste plan>

DOMAIN RULES:
Read <WORKTREE>/.ship/domain.md end-to-end.

ADVERSARIAL POSTURE: look for race conditions, state-machine gaps,
silent-failure no-ops, concurrent-request state collisions, navigation
stranding, security issues, and edge-case seams the happy-path review
would miss. Be steerable: <FOCUS — e.g., "race conditions" or
"backwards-compat shims" — if the captain narrowed the scope>.

PRIOR ROUND FINDINGS (round N>1 only):
<orchestrator-constructed resolution notes>

Severity / root cause / confidence threshold as before.

Output ONLY this JSON (red-team.schema.json):
{
  "review_type": "full-branch",
  "findings": [...],
  "verdict": "pass" | "pass-with-notes" | "fail",
  "summary": "..."
}
```

**Verification (Claude-side):**
1. Parse JSON.
2. Write to `<worktree>/.ship/review/red-team-full-round-N.md`.
3. Increment `red_team_full_rounds`.
4. Independently run the full test suite — never trust Codex's "tests still pass" claim.

### QA reviewer for `/agent-team` (rolling worker review)

**Sandbox:** `read-only` · **Effort:** `high` · **Schema:** `schemas/red-team.schema.json` (extended verdict)

Use the same red-team full-branch recipe but anchor the prompt on `git diff main..ship/<sub_issue>` and pass the locked `contracts.md` plus the worker's ownership map. Map the verdict to `/agent-team`'s `CLEAR | CONFLICT | ADVISORY` taxonomy in Claude after parsing.

## Loop bounds

- Plan red-team: ≤5 rounds.
- Per-step red-team: ≤5 rounds (auto-loop on HIGHs fixes code + re-runs).
- Full-branch red-team: ≤5 rounds.
- Leadsman retry: ≤2 retries before Claude writes the test.
- Implement retry: ≤1 retry before Claude escalates the substep.

At cap, the user gets the "Approve with noted risks" path per `/ship` rules.

## Validation-prompt pattern (apply Codex review findings carefully)

After receiving Codex red-team findings, DO NOT blindly apply them. Pipe the findings back through Claude (you) with this validation lens:

1. For each finding, ask: is this a real issue in this specific code, or a generic pattern Codex pattern-matched on?
2. Surface judgment calls (severity, scope) for the user, not as automatic rules.
3. Reject false-positives explicitly (record in the artifact: "REJECTED: <reason>").

This prevents false-positive churn that re-burns the tokens Codex saved.

## Fallback rules

**Before every fallback:** write the signal file so the PreToolUse hook allows Agent through:

```bash
touch ~/.ship/codex-fallback
```

Then fall back to native Claude subagent (general-purpose with role prompt).

- **`codex` binary missing** → signal + fall back immediately. One-line warning to the user.
- **`codex login` auth failure** → ask user to re-auth (`codex login`), then retry once. If still failing, signal + fall back.
- **Sandbox refusal** (Codex blocks a needed write) → retry once with `--ignore-rules`. If still blocked, signal + fall back.
- **Malformed JSON output** → retry once with the prompt amended to "Your previous output was not valid JSON. Reply with JSON only, no prose." If still bad, signal + fall back.
- **Network error / token exhaustion** → retry once after 30s. Then signal + fall back.

The signal file is auto-cleaned by the hook at the start of each new `/ship` run (compared against the ship-substeps timestamp). No manual cleanup needed.

Every fallback writes a one-line note to the ship's log under "Process Improvements" so we can tune the skill later.

## Token-saving discipline checklist

Before EVERY codex exec invocation, confirm:

- [ ] You're not pasting whole files into the prompt — pass paths and line ranges instead.
- [ ] The prompt has a clear pass/fail criterion (a leadsman has a `failure_reason`; an implementer has a leadsman test to make pass; a red-team has a structured JSON schema).
- [ ] Sandbox mode matches the role (`read-only` for review; `workspace-write` for writing).
- [ ] Reasoning effort is set to `high` (required for `gpt-5.4-mini` quality).
- [ ] You're using `--ephemeral` for one-shots.
- [ ] You're using `--output-last-message` to a temp file (not `--json` JSONL stream — too verbose to parse).
- [ ] The task is non-trivial (≥50 LOC OR multi-file OR ambiguous-edge-case-heavy). Trivial edits stay inline.

## Quick-reference summary table

| Substep | Sandbox | Effort | Schema |
|---|---|---|---|
| Red-team plan | `read-only` | `high` | red-team |
| Leadsman | `workspace-write` | `high` | leadsman |
| Implement | `workspace-write` | `high` | impl-result |
| Red-team per-step | `read-only` | `high` | red-team |
| Simplify | `workspace-write` | `high` | impl-result |
| Red-team full-branch | `read-only` | `high` | red-team |
| `/agent-team` QA | `read-only` | `high` | red-team (CLEAR/CONFLICT/ADVISORY mapped) |

## Provenance and references

Patterns sourced from (2026):

- Tiago Valverde — *How to Reduce Token Consumption with Claude Code and Codex* (path-not-content, one-session-per-task).
- OpenAI Developers — *Codex Non-interactive mode* docs (flag reference).
- OpenAI Community — *Introducing Codex Plugin for Claude Code* (captain/worker pattern).
- Morph LLM — *Codex vs Claude Code 2026 Benchmarks* (3-4× token ratio).
- SmartScope — *Claude Code × Codex Review Loop Automation 2026* (loop bounds, VERDICT contract).
- Addy Osmani — *The Code Agent Orchestra* (verification-is-the-bottleneck).
- Nathan Onn — *The Claude Code Codex Plugin: Code Reviews Without Blind Spots* (adversarial review, validation-prompt pattern).
- OpenAI Developers — *Codex Sandbox and Approval* docs (sandbox/approval guidance).

Full URLs in the research review captured at session start (2026-05-12).
