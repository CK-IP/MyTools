Walk Claude through running a parallel agent team build for an Epic. The orchestrator coordinates workers and a rolling QA agent. Usage: `/agent-team <epic-issue-number>`

## ⚠️ Critical: How to spawn teammates

**Always use `TeamCreate` + the `Agent` tool with `team_name` parameter.**
**Never use `run_in_background: true` without `team_name` — that creates invisible background subagents the user cannot see or interact with.**

| Correct — visible teammates | Wrong — invisible subagents |
|---|---|
| `Agent(team_name: "epic-2", name: "worker-a", ...)` | `Agent(run_in_background: true, ...)` |

The native Claude Code agent teams feature handles split panes automatically when tmux or iTerm2 is available. Do not create tmux sessions or windows manually — the framework does this.

---

## Setup phase

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

Read all `integration_contracts_produces` and `integration_contracts_consumes` fields from the epic-brief.

### Step 5: Write contracts.md

Write `.ship/epic-<issue>/contracts.md` — the locked contract document.

One section per contract name: producer, consumers, exact interface spec.

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
  prompt: "..."
)
```

### Step 10: Spawn all workers simultaneously

For each worker in the epic-brief, use the `Agent` tool with `team_name` — visible teammates.
**Model: sonnet** — workers do focused build work; sonnet is fast and cost-efficient at scale.

```
Agent(
  team_name: "epic-<issue>",
  name: "worker-<name>",
  model: "sonnet",
  description: "Worker <name> — sub-issue #<sub_issue>",
  prompt: "..."
)
```

**All workers spawn in the same call — do not wait for one before spawning the next.**

---

## Coordination phase (rolling)

### Step 11: As each worker reports completion

a. Use `TaskUpdate` to mark their task completed.
b. Reply to the worker: "Done — I'll handle it from here."
c. Send to QA via `SendMessage`:
   `SendMessage(to: "qa", message: "Worker <name> complete. Branch: ship/<sub_issue>.")`

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

### Step 17: Collect and write domain proposals

Collect domain proposals from all workers.
Write `.ship/domain.md` once — append all accepted rules in a single pass.
(Workers skipped domain.md writes. The orchestrator is the single writer. No collision risk.)

### Step 18: Full integration validation

- Check all worker branches: `git diff main...<each branch>`
- Verify no file ownership violations (no worker modified a file owned by another).
- Run full test suite: `bash tests/test_step1.sh && bash tests/test_step2.sh && bash tests/test_step3.sh && bash tests/test_step4.sh && bash tests/test_step5.sh && bash tests/test_step6.sh`

### Step 19: Merge in dependency order

Follow `dependency_order` from epic-brief Merge Rules. For each branch in order:

```bash
git checkout main
git merge ship/<sub_issue> --no-ff -m "merge: ship/<sub_issue> — <title>"
```

Run the full test suite after each merge before continuing.

### Step 20: Push

`git push`

### Step 21: Close Epic

Spawn @board with: `done <epic_issue>`

### Step 22: Write epic ship's log

Save to `.handoffs/ship-log-epic-<issue>-<timestamp>.md`.

Sections: Epic summary, worker results, QA findings, domain updates, merge order.

---

## Rules

- Gate P is non-negotiable. Never spawn workers before user approves contracts.
- **Always use `TeamCreate` + `Agent(team_name: ...)` — never `run_in_background: true` alone.**
- **Never create tmux sessions or windows manually — the framework handles split panes.**
- Workers do not merge, push, or close issues. Orchestrator handles all of this.
- Orchestrator is the single writer for domain.md. Workers only propose.
- **Model assignments:** Orchestrator = opus, QA = opus, Workers = sonnet.
- On any CONFLICT: stop and explain in plain language before proceeding.
