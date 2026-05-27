Walk Claude through running a parallel agent team build for an Epic (XL tier of the S/M/L/XL t-shirt size framework). The orchestrator coordinates workers and a rolling QA agent. Usage: `/fleet <epic-issue-number>`

## ⚠️ Critical: How to spawn teammates

**Always use `TeamCreate` + the `Agent` tool with `team_name` parameter.**
**Never use `run_in_background: true` without `team_name` — that creates invisible background subagents the user cannot see or interact with.**

| Correct — visible teammates | Wrong — invisible subagents |
|---|---|
| `Agent(team_name: "epic-2", name: "worker-a", ...)` | `Agent(run_in_background: true, ...)` |

The native Claude Code agent teams feature handles split panes automatically when tmux or iTerm2 is available. Do not create tmux sessions or windows manually — the framework does this.

---

## Setup phase

### Step 0: Orchestrator model check

Before doing anything else, say:

> "For best results, the orchestrator (this session) should be running **opus**. If you're not already on opus, switch now — then re-run `/fleet <issue>`. Workers will run on sonnet; QA will run on opus automatically."

Ask: **"Are you on opus? (yes to continue, no to switch first)"**

Do not proceed until the user confirms yes.

### Step 1: Read epic-brief

Find `.handoffs/epic-brief-<issue>-*.md` — use the latest by modification time.

- If none found: stop with "No epic-brief found for issue #<N>. Run /idea first to generate one."

### Step 2: Verify agent teams setting

Check `~/.claude/settings.json` for `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: 1`.

- If missing: stop with "Agent teams must be enabled. Add `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: 1` to `~/.claude/settings.json` and restart Claude Code."

### Step 3: Announce the team

Say in plain language:

> "Starting team build for Epic #<N>: <title>
> Workers: <list each worker name + scope + sub-issue>
> QA: Rolling (reviews each worker as they finish — model: opus)
> Waiting for Gate P confirmation before spawning."

---

## Contract lock phase

### Step 4: Extract contracts from epic-brief

Read all `pipeline`, `integration_contracts_produces`, and `integration_contracts_consumes` fields from the epic-brief.

### Step 5: Write contracts.md

Write `.ship/epic-<issue>/contracts.md` — the locked contract document.

One section per contract name: producer, consumers, exact interface spec.

### Step 5b: Generate contract-tests.sh

After writing contracts.md, auto-generate `.ship/epic-<issue>/contract-tests.sh` — a
runnable validation script derived from the locked contracts:

```bash
cat > .ship/epic-<issue>/contract-tests.sh << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# One assert_* function per contract — generated from contracts.md
# Example (replace with actual contracts):
# assert_user_api() {
#   grep -q 'def get_user' src/api/users.py || fail "get_user missing in users.py"
#   grep -q 'def create_user' src/api/users.py || fail "create_user missing in users.py"
#   pass "user_api contract satisfied"
# }

# Invoke each contract assertion (one call per assert_* function above):
# assert_user_api
# assert_<contract2>

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
SCRIPT
chmod +x .ship/epic-<issue>/contract-tests.sh
```

The actual assert functions are generated from the `exact interface spec` fields in
contracts.md. One function per contract name. Present the generated script to the user
as part of Gate P (Step 6) — they approve both contracts.md AND contract-tests.sh.

### Step 6: Gate P — user approval

Present the contracts to the user. Ask:

> "Do these contracts look right? Approve to spawn the team."

**Do not spawn anyone until the user confirms.** This is Gate P.

---

## Spawn phase

### Step 7: Register the team

Use the `TeamCreate` tool:

```
TeamCreate(
  team_name: "epic-<issue>",
  description: "Epic #<N> parallel build: <title>"
)
```

### Step 8: Create shared tasks

Use `TaskCreate` for each worker and QA so the user can track progress via Ctrl+T:

```
TaskCreate(subject: "Worker <name> — build sub-issue #<N>", description: "<scope>")
TaskCreate(subject: "QA — rolling review", description: "Review each worker as they complete")
```

### Step 9: Spawn QA FIRST (model: opus)

Use the `Agent` tool with `team_name` and `name` — this makes QA a visible teammate:

```
Agent(
  team_name: "epic-<issue>",
  name: "qa",
  model: "opus",
  description: "Rolling QA reviewer",
  prompt: "<use the template below>"
)
```

**QA prompt template** — fill in the `<placeholders>` from the epic-brief before spawning:

```
You are the rolling QA reviewer for Epic #<epic_issue>: <epic_title>.

You will be notified via SendMessage as each worker completes. Review each worker
immediately upon notification — do not wait for all workers to finish.

Your context:
- Locked contracts: .ship/epic-<epic_issue>/contracts.md
- Epic acceptance criteria: <paste from epic-brief>
- Worker ownership map: <list each worker name and their files_owned>

## What the worker's pipeline already guarantees

Each worker ran /ship or /sloop on their sub-issue. By the time they report complete:
- Full test suite passes (green) on their branch
- Red-team findings reviewed (per-step and full-branch for /ship; full-branch for /sloop)
- A commit exists on ship/<sub_issue>
- A ship's log exists at .handoffs/ship-log-<sub_issue>*.md

Do NOT re-run the worker's pipeline checks. Trust the pipeline. Your job is to
catch what individual pipelines cannot see: integration conflicts between workers.

## For each worker you review

1. Read their diff: git diff main..ship/<sub_issue>
2. Read their ship's log (.handoffs/ship-log-<sub_issue>*.md) — note any HIGH findings
   accepted as risk that could affect integration
3. Check contracts: Does the output match their integration_contracts_produces in
   contracts.md?
4. Check cross-worker conflicts: Does anything conflict with previously cleared workers?
5. Check file ownership: Are all changed files in this worker's files_owned list?
   File ownership violations are always CONFLICT, never ADVISORY.

6. Check type compatibility: For each function or class in this worker's diff that
   is consumed by another worker (per integration_contracts_consumes in contracts.md),
   verify the signature matches exactly — parameter count, names, and type annotations
   if present. A mismatch is CONFLICT MEDIUM unless it causes a runtime TypeError, in
   which case CONFLICT HIGH.

7. Check behavioral contracts: For each contract in integration_contracts_produces,
   verify not just file presence but that the exact interface spec is satisfied —
   function name, return shape, and any documented invariants. Passing check 3 does
   not exempt this check — verify the full interface spec, not just contract file
   presence.

8. Check import graph conflicts: If this worker's diff adds or removes module-level
   imports used by another cleared worker's code, flag as CONFLICT MEDIUM. Use
   `git diff main..ship/<sub_issue> -- '*.py' '*.ts' '*.js'` and scan import lines.

## Verdicts

- CLEAR: Send "CLEAR — Worker <name> (ship/<sub_issue>). <one-line summary>."
- CONFLICT: Send "CONFLICT — <description>. Severity: HIGH|MEDIUM. Blocks: <workers>."
- ADVISORY: Send "ADVISORY — <note>." (non-blocking, continue)

## Severity (use /ship's scale)

- HIGH: Will cause bugs, data loss, or test failures when merged — must resolve
- MEDIUM: Correctness or design concern — flag, orchestrator decides whether to block
- LOW: Always ADVISORY

Write your findings to .ship/epic-<epic_issue>/qa-<sub_issue>.md before sending
your verdict.

Wait for SendMessage from the orchestrator before reviewing each worker.
```

### Step 10: Spawn all workers simultaneously

For each worker in the epic-brief, use the `Agent` tool with `team_name` — visible teammates.
**Model: sonnet** — workers handle implementation execution. The orchestrator (opus) handles all high-stakes reasoning: contract lock, conflict resolution, merge decisions.

```
Agent(
  team_name: "epic-<issue>",
  name: "worker-<name>",
  model: "sonnet",
  description: "Worker <name> — sub-issue #<sub_issue>",
  prompt: "<use the template below>"
)
```

**Worker prompt template** — fill in the `<placeholders>` from the epic-brief for each worker before spawning:

```
You are Worker <name> for Epic #<epic_issue>: <epic_title>.

Sub-issue: #<sub_issue>
Files you own (exclusive write): <files_owned>
Files you may read: <files_readonly>
Contracts you produce: <integration_contracts_produces>
Contracts you consume: <integration_contracts_consumes>
Domain rules: <paste contents of .ship/domain.md, or "none yet">

## Your task

Run <pipeline> <sub_issue> to build your sub-issue.

If your pipeline is `/ship`, this runs the full TDD pipeline
(board → plan → implement → review → commit → learn).
If your pipeline is `/sloop`, this runs the standard-weight pipeline
(plan → implement → red-team → commit on branch → learn).

## Rules — these override your pipeline's end-of-run defaults

### If your pipeline is `/ship`:

1. End-of-run: When /ship presents end-of-run options (Stage 6e), always select
   "Done — I'll handle it". Never merge, push, or close issues. The orchestrator
   handles all merging.

2. Domain write: At Stage 6d, do NOT write to domain.md. Note your proposed rules
   and include them in your completion report to the orchestrator. The orchestrator
   is the single writer for domain.md.

### If your pipeline is `/sloop`:

1. End-of-run: When /sloop presents the convergence gate (Stage 3d), select
   "Commit only". Never push or close issues. The orchestrator handles all
   merging.

2. Domain write: At Stage 5 (Learn), do NOT write to domain.md. Note your proposed
   rules and include them in your completion report to the orchestrator. The
   orchestrator is the single writer for domain.md.

### All pipelines:

3. File ownership: Only write to files in your files_owned list. Do not modify any
   other files, even if the plan suggests doing so.

4. Contracts: Your output must satisfy integration_contracts_produces. If a contract
   you consume (integration_contracts_consumes) doesn't match what you find in the
   codebase, report it to the orchestrator immediately — do not work around it silently.

## When your pipeline completes

Report back to the orchestrator:
- Worker name: <name>
- Pipeline used: <pipeline>
- Branch: ship/<sub_issue>
- Domain proposals: <list each proposed rule, or "none">
- Advisories: <anything the orchestrator or QA should know>
```

**All workers spawn in the same call — do not wait for one before spawning the next.**

### Step 10b: Branch-clean check

After all workers spawn, verify each worker's branch starts clean. Run:

```bash
git diff main --name-only  # on each worker's branch
```

If any files appear that are NOT in that worker's `files_owned` list, stop that worker immediately via `SendMessage` before it does real work and alert the user: "Worker <name>'s branch contains files outside their ownership: <files>. This needs to be resolved before work begins."

---

## Coordination phase (rolling)

### Step 11: As each worker reports completion

a. Verify the worker followed the rules. Run on their branch:
   ```bash
   # 1. Pipeline completed through commit (ship's log must exist)
   ls .handoffs/ship-log-<sub_issue>*.md 2>/dev/null
   # 2. No unauthorized merges
   git log main..<branch> --oneline | grep -i "^merge"   # must return nothing
   # 3. domain.md not touched
   git diff main..<branch> --name-only | grep "^domain\.md$"  # must return nothing
   ```
   If check 1 fails: "Worker <name> has no ship's log — the worker's pipeline may not have completed through commit. Do not route to QA until confirmed."
   If check 2 or 3 fails: "Worker <name> broke a rule: [merged a branch / wrote to domain.md]. This needs fixing before QA review."
b. Run contract tests: `bash .ship/epic-<issue>/contract-tests.sh` on the worker's
   branch. If any assertion fails, treat as CONFLICT HIGH — **skip items c–e entirely**,
   report the specific failing assertion to the user, and wait for resolution before
   re-running.
   _(Step 11b semantic check runs next — gates items c/d/e)_
c. Use `TaskUpdate` to mark their task completed.
d. Reply to the worker: "Done — I'll handle it from here."
e. Send to QA via `SendMessage`:
   `SendMessage(to: "qa", message: "Worker <name> complete. Branch: ship/<sub_issue>.")`

### Step 11b: Semantic conflict check

**Execution order:** Step 11 items a and b run first. Then this step runs as a gate.
On clean pass, continue with Step 11 items c/d/e.

Run a lightweight semantic analysis on the worker's branch to detect cross-worker
naming collisions not caught by contract tests:

```bash
# Scope temp files to this epic to avoid cross-epic collisions
mkdir -p /tmp/epic-<issue>

# Detect cross-worker naming collisions in Python files
git diff main..ship/<sub_issue> -- '*.py' | grep '^+def \|^+class ' | \
  cut -d' ' -f2 | cut -d'(' -f1 | sort > /tmp/epic-<issue>/new_symbols_<sub_issue>.txt

# Compare against symbols from previously cleared workers
cat /tmp/epic-<issue>/new_symbols_*.txt 2>/dev/null | sort | uniq -d > /tmp/epic-<issue>/collisions.txt

if [ -s /tmp/epic-<issue>/collisions.txt ]; then
  # SEMANTIC-CONFLICT — report to user and do not route to QA
  echo "SEMANTIC-CONFLICT: duplicate symbols: $(cat /tmp/epic-<issue>/collisions.txt)"
fi
```

For TypeScript/JavaScript, adapt the grep pattern to `^+export .*function \|^+export class `.

**Verdicts:**
- **SEMANTIC-CONFLICT HIGH:** Symbol collision that will cause a runtime error — blocks QA
  routing, notify user. Skip Step 11 items c/d/e until resolved.
- **SEMANTIC-CONFLICT MEDIUM:** Symbol collision in test scope only — ADVISORY, log and
  continue to Step 11 items c/d/e (non-blocking).
- **Clean:** Proceed to Step 11 items c/d/e.

### Step 12: QA reports back

QA sends `SendMessage` to orchestrator with CLEAR / CONFLICT / ADVISORY.

### Step 13: On CLEAR

- Use `TaskUpdate` to note QA cleared.
- Reply to QA: "Acknowledged — awaiting next worker."

### Step 14: On CONFLICT

- Send to affected workers via `SendMessage` to block their final steps if not yet submitted.
- Tell the user in plain language:
  > "QA found a conflict: <explanation>. Worker <name>'s output doesn't match what Worker <other> expected. Specifically: <contract name> — expected <X>, got <Y>."
- Wait for user resolution before unblocking.

### Step 15: On ADVISORY

Log in conversation. Continue without blocking.

---

## Completion phase

### Step 16: Confirm all clear

When all workers are done and QA has cleared all sub-issues, proceed.

### Step 17: Fortify gate

With all workers cleared by QA, run `/fortify` across the integration candidate before
merging to main.

Create a temporary integration branch:

```bash
git checkout -b epic-<issue>-integration main
for branch in <worker branches in dependency_order>; do
  git merge "$branch" --no-ff -m "integration-check: $branch"
done
```

Then run `/fortify` on the integration branch. Read the verdict from the fortify report:

- **BLOCK:** Do not proceed to merge. Tell the user: "Fortify BLOCK on integration
  branch: <finding summary>. Resolve before merging." Delete the integration branch and
  wait for user direction.
- **ADVISORY:** Log the finding in the epic ship's log (Step 24). Continue to Step 18.
- **CLEAR:** Continue to Step 18.

Delete the integration branch after the check regardless of outcome:
```bash
git checkout main
git branch -D epic-<issue>-integration
```

### Step 18: Collect and write domain proposals

Collect domain proposals from all workers.
Write `.ship/domain.md` once — append all accepted rules in a single pass.
(Workers skipped domain.md writes. The orchestrator is the single writer. No collision risk.)

### Step 19: Full integration validation

- Check all worker branches: `git diff main..<each branch>`
- Verify no file ownership violations (no worker modified a file owned by another).
- Run full test suite:
  ```bash
  # Tests are order-independent; glob sorts alphabetically
  for t in tests/test_*.sh; do
    bash "$t" || { echo "FAILED: $t"; exit 1; }
  done
  ```

### Step 20: Merge in dependency order

Follow `dependency_order` from epic-brief Merge Rules. For each branch in order:

```bash
git checkout main
git merge ship/<sub_issue> --no-ff -m "merge: ship/<sub_issue> — <title>"
# Verify contracts still hold after this merge
bash .ship/epic-<issue>/contract-tests.sh || {
  echo "Contract tests failed after merging ship/<sub_issue> — do not proceed."
  exit 1
}
```

Run the full test suite after each merge before continuing.

### Step 21: Push

`git push`

### Step 22: Clean up worker branches

For each merged worker branch:

```bash
git push origin --delete "ship/<sub_issue>" 2>/dev/null || true
git branch -d "ship/<sub_issue>" 2>/dev/null || true
```

### Step 23: Close Epic

Spawn @board with: `done <epic_issue>`

### Step 24: Write epic ship's log

Save to `.handoffs/ship-log-epic-<issue>-<timestamp>.md`.

Sections: Epic summary, worker results, QA findings, domain updates, merge order.

- Ship Health:
  - Fortify verdict (BLOCK / ADVISORY / CLEAR) with finding summary
  - Contract test results per worker (pass/fail counts per assert function)
  - QA finding counts: total CLEAR, CONFLICT (by severity), ADVISORY
  - HIGH findings accepted as risk (from individual worker ship's logs)
  - Integration test suite result (pass/fail per test file)

---

## Rules

- Gate P is non-negotiable. Never spawn workers before user approves contracts.
- **Always use `TeamCreate` + `Agent(team_name: ...)` — never `run_in_background: true` alone.**
- **Never create tmux sessions or windows manually — the framework handles split panes.**
- Workers do not merge, push, or close issues. Orchestrator handles all of this.
- Orchestrator is the single writer for domain.md. Workers only propose.
- **Model assignments:** Orchestrator = opus (manual — confirm at Step 0), QA = opus (auto), Workers = sonnet (auto).
- On any CONFLICT: stop and explain in plain language before proceeding.

## Cross-references

- `commands/idea.md` — triage skill that routes to /fleet for XL
- `commands/sloop.md` — standard-weight pipeline; available as worker pipeline
- `cc-dotfiles: home/commands/ship.md` — full pipeline; default worker pipeline
- `cc-dotfiles: home/commands/skiff.md` — lightweight pipeline; excluded from /fleet (no branch isolation)
- `commands/epic-brief-schema.md` — epic-brief template consumed at Step 1
