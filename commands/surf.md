Work the GitHub issue board on its own — the whole board or a chosen subset — building each issue to done by driving `/sail`, auto-merging what passes and parking what doesn't. Usage: `/surf`

## ⚠️ Critical: what `/surf` is

`/surf` is the **board-working autopilot**. Where `/sail` builds one issue, `/surf` works
*through the board*: it picks up issues one at a time, builds each by driving
`python3 -m sail run --diff main`, auto-merges everything that comes back green, parks
everything that doesn't, and writes down every decision so any single issue can be undone
later without losing the rest.

It is designed to run for a long time with little or no supervision. That makes the safety
rails — the start gate, the charter, the journal, the decision-log, the merge policy, and
the guardrails — the load-bearing parts of this spec. Read them as hard rules, not advice.

Two things shape every run:

- **The run mode** — *Autonomous* (no human watching) or *Supervised* (a human is around to
  answer questions). Chosen once at startup via an interactive prompt.
- **The charter** — the up-front Q&A that records the mission, which issues are in scope,
  how they depend on each other, who decides what, and the hard guardrails.

Everything `/surf` does is anchored to those two artifacts, not to chat history. The session
re-reads them at the top of every issue so it never drifts, even on a board of 30 issues.

---

## Run-mode selection (interactive, no flags)

### Step 0-pre: Detect an in-progress run

**Before** asking for the run mode, check whether a previous run was left unfinished. If `.surf/`
holds a charter (`.surf/charter-*.md`) whose journal shows **unfinished work** — a picked-but-not-
resolved issue, a parked issue still listed in `.surf/parked-issues.md`, and **no done-marker**
(see Step 14) — then a prior run stopped before the board was exhausted.

When that is the case, **offer to resume instead of re-running run-mode + charter**:

> "I found an in-progress `/surf` run (charter `<charter>`, last activity `<when>`). Want me to
> **resume** it where it stopped, or **start a fresh run**?"

- **Latest charter = newest by timestamp** (`.surf/charter-<timestamp>.md`). If several
  in-progress charters exist, list them (charter, mission line, last journal activity) and let the
  user pick one interactively via `AskUserQuestion`.
- **Resume reuses the run mode recorded in the chosen charter** — Step 4 already wrote the mode
  there, so resume does **not** re-ask Step 0. It jumps straight to **Resume (Step 15)**.
- **Before a fresh run, tombstone the superseded charter.** If the user chooses a fresh run over
  resuming a detected in-progress charter — **or** if a detected charter's board is found **already
  externally exhausted** (its issues all merged/closed by other work and `main` has moved past it, so
  there is nothing left to resume) — **lay the old charter to rest before starting**: write its
  done-marker `.surf/<charter>-done` **and** append a `- done: superseded <ISO>` line to its journal
  (the same done-marker Step 14 writes and `config/surf-resume.sh` reads). Without this, a superseded
  charter with no done-marker is a phantom in-progress run: the Step 16 scheduler's
  "newest charter present AND no done-marker → work remains" gate would keep trying to resume the dead
  run forever. Tombstone it, then fall through to Step 0.
- If there is no in-progress charter at all, fall through to Step 0 below as normal.

### Step 0: Choose the run mode

Before anything else, ask the user to pick the run mode with `AskUserQuestion`:

```
AskUserQuestion(
  question: "How should /surf run the board?",
  options: [
    { label: "Autonomous", description: "No human watching. /surf decides, logs, and continues. Best for a long unattended run on a sandbox repo." },
    { label: "Supervised", description: "A human is around. /surf asks questions and waits (up to a deadline) before deciding. Visible teammates, watchable panes." }
  ]
)
```

The chosen mode is recorded in the charter and governs three later behaviors: the start
gate's settings check (supervised only), how heavy issues are delegated (visible teammate
vs. subagent), and whether questions are asked-and-waited-on or decided-and-logged.

**The no-flags principle.** Every choice you make in `/surf` is an interactive selection
prompt — never a `--flag` to remember. There is deliberately no `--autonomous`,
`--supervised`, `--subset`, or `--issues` flag; mode, issue scope, and decision authority
are all answered through `AskUserQuestion` prompts at startup. This is a design rule, not an
omission: a non-programmer should be able to drive `/surf` by reading and clicking, with
nothing to memorize.

---

## Start gate

The start gate must fully pass before the autonomous loop begins. If any check fails, stop
and explain in plain language — do not start working issues.

### Step 1: Confirm the repo and working folder

State the repository and working directory you are about to operate on, and ask the user to
confirm it is the intended one:

> "I'm about to work the board for **<repo>** in `<working folder>`. Is that the right place? (yes / no)"

If the user says no, stop. `/surf` makes real commits and merges — it must never run against
the wrong repo.

### Step 2: Confirm `--dangerously-bypass-permissions`

The autonomous loop runs unattended: it edits files, commits, and merges without pausing for
per-action permission prompts. That requires the session to have been launched with
`--dangerously-bypass-permissions`.

**`/surf` cannot enable this itself.** It is a launch-time CLI flag, not a runtime setting and
not something in `settings.json`, so there is no way to switch it on mid-session.

- **Detect first.** If the launch environment exposes the bypass state (e.g. a permission-mode
  indicator in the environment), read it and confirm.
- **Otherwise ask.** If it cannot be detected, ask the user directly:
  > "Did you launch this session with `--dangerously-bypass-permissions`? `/surf` needs it to
  > commit and merge without stopping for permission prompts. (yes / no — if no, please exit
  > and relaunch with the flag, then re-run `/surf`.)"

**Refuse the autonomous loop until this is confirmed.** Do not begin working issues, and do
not "work around" the missing flag by pausing on every action — that defeats the point of an
autopilot and produces a half-supervised run nobody asked for.

### Step 3: Supervised-mode environment check

This step runs **only when the chosen mode is Supervised** (autonomous runs spawn subagents,
which do not need the agent-teams feature).

- Check `~/.claude/settings.json` for `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: 1`. If missing,
  stop with: "Supervised mode uses visible teammates for heavy issues. Add
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: 1` to `~/.claude/settings.json` and restart Claude
  Code, then re-run `/surf`."
- Recommend **opus** for this orchestrating session:
  > "For best results the `/surf` session should run **opus** — it makes all the merge and
  > park decisions. Switch now if you're not on opus."
- Note tmux / iTerm2: the native agent-teams feature handles split panes automatically when
  tmux or iTerm2 is available. **Never create tmux sessions or windows manually — the
  framework does this.**

---

## Charter

### Step 4: Up-front Q&A → charter file

Before the autonomous run begins, hold a short interactive Q&A and write the answers to a
**charter file** at `.surf/charter-<timestamp>.md` (the `.surf/` directory is gitignored, so
the charter never dirties the tree or gets swept into a merge commit). The charter is the
contract for the whole run; the session re-reads it at the top of every issue.

Ask, via `AskUserQuestion` and follow-ups, and record:

1. **Mission** — one or two sentences: what is this run for? (e.g. "Clear the bug backlog on
   the sandbox repo before the demo.")
2. **Issue selection** — the whole board or a subset (resolved in Step 5).
3. **Ordering guidance (optional)** — any dependencies, sequencing constraints, or priorities
   the user already knows — especially **domain-knowledge ordering only the user can supply**
   (e.g. "the demo needs #50 working first", "#44 must land before #45"). This is *guidance*,
   **not the authoritative dependency graph**: in **Step 5b** `/surf` analyzes the selected
   issues and derives the dependency graph + recommended build order itself, then reconciles
   this guidance against its analysis (flagging conflicts — see Step 5b). Record whatever the
   user provides; an empty answer is fine.
4. **Decision authority** — what may `/surf` decide on its own, and what must always come back
   to the user? (e.g. "Decide naming and refactors; always ask before changing the public
   API.") In supervised mode this sets which questions wait on the deadline; in autonomous
   mode it sets which decisions are auto-made-and-logged vs. parked.
5. **Hard guardrails** — the non-negotiables for this run (see the Guardrails section): sandbox
   repo only, no force-push or history rewriting, park anything irreversible.

Write the charter, show it to the user in plain language, and get a "yes, go" before starting
the loop. The charter is the single source of intent — if it's wrong, fix it here, not mid-run.

---

## Issue selection

### Step 5: Pick the issues

List the board's open issues using the `/board` interface — `gh issue list` and, where a
project board is in use, `gh project item-list`. Present them as a readable list (number,
title, and any dependency note from the charter).

Then let the user pick interactively — **the whole board or a subset** — via `AskUserQuestion`
(this is an interactive selection prompt, never a flag). Record the selected **issue set** in
the charter. The *order* is not fixed here — **Step 5b** analyzes those issues and proposes the
build sequence for approval.

---

## Build-order analysis

### Step 5b: Analyze the board and propose a build sequence

Before the run starts, `/surf` derives the build order **itself** rather than taking it on
faith from the user — Chris is a non-programmer and can't reliably know the safe or optimal
order. For the selected issues:

1. **Analyze.** Read each selected issue via `gh issue view <n> --json title,body,labels` (and
   any project-board fields). Extract:
   - **Dependencies** — explicit **cross-references** like "depends on #44", "blocked by #X",
     "after #Y", native sub-issue parent/child links, and shared-file / shared-area hints in
     the bodies.
   - **Risk** — how hard the issue is to undo (irreversible migrations, shared-history touches)
     and how likely it is to block others.
   - **Value** — how much the issue unblocks (a parent many depend on) or delivers.
2. **Reconcile with the user's guidance (Step 4 #3).** Layer the Step-4 ordering guidance on
   top of the analysis. The user's **domain-knowledge ordering wins where it doesn't break a
   hard dependency**. **On conflict** — where the user's guidance contradicts an analysed
   dependency (e.g. the user says "do #50 first" but #50 depends on un-built #48) — **do NOT
   silently reorder: flag the conflict and ask** via `AskUserQuestion`, showing both the user's
   stated order and what the analysis found, and let the user decide. Record the resolution in
   the decision-log (Step 12).
3. **Propose the recommended build order.** Present it as a table for approval — the four
   columns are fixed:

   | Issue | Topic | Dependencies | Why this position |
   |-------|-------|--------------|-------------------|
   | #44   | …     | none         | builds first — 3 issues depend on it; low risk |
   | #45   | …     | #44          | needs #44's API; sequenced after its parent |
   | …     | …     | …            | … |

   **Parent-before-dependent is non-negotiable** in the proposed order (a parent always
   sequences before its dependents); **risk and value break ties** among otherwise-independent
   issues — lower-risk, higher-unblocking issues first.
4. **Get approval, then record.** Get a "yes, go" on the order (or apply the user's edits and
   re-present). Write the approved **ordered work list** — plus the per-issue dependency notes —
   to the charter. This recorded order is the single source the per-issue loop (Step 7) and
   dependent-issue handling (Step 10) read; re-anchoring at the top of every issue reads it from
   the charter, so the analysis is done **once, up front**, not re-derived mid-run.

---

## Context model

### Step 6: How `/surf` stays oriented across many issues

`/surf` runs **single-session by default**. It does *not* rely on `/compact` or on chat history
surviving — those are unreliable over a long board run. Instead:

- The **goal and current status live in the charter + journal files**, not in the conversation.
- At the **top of every issue**, `/surf` re-anchors by re-reading the charter (mission, scope,
  authority, guardrails) and the journal (what's merged, what's parked, where we are). This
  re-anchoring is what lets the run survive a long board without drifting.
- **Light and medium issues run inline** in this session — no worker, no extra panes.
- **Only a genuinely heavy issue is delegated** to a worker (see Worker delegation). Delegation
  is the exception, reserved for work big enough that running it inline would blow the session's
  context budget.
- **A hard stop is different from running low on context.** If the run is killed outright — a
  crash, or (the common case) the Max-subscription usage window cutting it off mid-issue — the
  session cannot re-anchor from chat at all. Recovery from a hard stop goes through **Resume
  (Step 15)**, which rebuilds board position from the charter + journal + git, not from the
  conversation.
- **Live-session marker.** At the start of the per-issue loop (Step 7), write `.surf/active`
  containing this process's PID, and **remove it on clean exit** (board exhausted, or the user
  stops the run). This is the marker the auto-resume scheduler (Step 16) checks: while a live PID
  sits in `.surf/active`, the scheduler will not launch a second `/surf` on top of a running
  session. A crash leaves a *stale* marker (its PID is dead), which the scheduler ignores and
  cleans — so it never blocks recovery.

---

## Per-issue loop

### Step 7: For each selected issue, in order

Repeat this loop for every issue in the work list:

**Canonical branch naming.** Every issue is built on a branch named **`surf/<issue>`** (where
`<issue>` is the GitHub issue number) — this one convention is used everywhere: build, merge,
dependent stacking (§10), and wrap-up (§14). No other branch-naming scheme is used.

1. **Re-anchor.** Re-read the charter and the journal. Confirm this issue's dependencies have
   landed (or handle them per the Dependent issues section). State, in one line, what you're
   about to build and why it's next.
2. **Create the branch, then build.** Each issue starts from **current `main`**, so a parent
   merged earlier in this run is already included in the baseline. Create the issue branch off
   up-to-date `main`, then run the engine **in a stable per-issue run-dir** so a hard stop
   mid-issue can be resumed cleanly:
   ```bash
   git checkout main
   git checkout -b surf/<issue>
   python3 -m sail run --diff main --run-dir .surf/runs/<issue>
   ```
   This is the one-pass `/sail` mode: it runs the deterministic gates **and** the blocking LLM
   review against the diff vs. `main`. It exits **0** when the issue is green (all gates pass and
   the blocking review found no CRITICAL/HIGH) and **1** when something is blocking.

   The run-dir is **stable per issue** (`.surf/runs/<issue>/`, under the gitignored `.surf/`) so
   that if the run is killed mid-issue, Resume (Step 15) can re-invoke the *same* `--run-dir` and
   `/sail` skips the gates it already finished. The per-issue **journal entry** written in step 4
   below is the resume checkpoint: a hard stop loses at most the single in-flight issue.
3. **Evaluate the exit code.**
   - **Exit 0 → green → auto-merge** — *but first, the stacked-parent guard.* Before merging,
     verify every dependency parent of this issue is **itself already merged to `main`**. If any
     parent is still parked, **park this dependent too** — never auto-merge a stacked branch whose
     base is not on `main`, because a branch stacked on a parked parent (branch-from-parent, §10)
     carries the parent's commits in the diff, can exit 0, and would smuggle the parent's unmerged
     work into `main` past its parked status. With all parents confirmed merged, **land** the
     issue via the **shared `sail land` logic** (the closing bookend, #59 — same source of truth
     `/sail` Stage 5 uses; keep the two in sync): emit the closing artifacts from the
     already-produced review evidence, merge into `main` as a single `--no-ff` commit whose
     `Closes #<issue>` keyword **auto-closes the issue** (the board's native *Item closed → Done*
     automation then flips status — no `gh issue close`, no board API call), **record the merge
     SHA**, publish the review evidence as the closing comment, and prune the branch. `/surf` is
     unattended — it runs this **without pausing** (unlike `/sail`'s human-gated terminus). Then
     return to `main` for the next issue:
     ```bash
     RD=.surf/runs/<issue>
     python3 -m sail land --run-dir "$RD" --issue <issue> --title "<title>" --prefix surf
     git checkout main
     git merge surf/<issue> --no-ff -F "$RD/land-commit-msg.txt"   # `Closes #<issue>` lives in the merge message
     git push origin main                                         # REQUIRED: only a merge on origin's DEFAULT branch fires GitHub auto-close + the board's Item-closed→Done automation; a local-only merge does neither
     git rev-parse HEAD                                            # capture this SHA into the journal/decision-log
     gh issue comment <issue> -F "$RD/land-comment.md"            # publish review evidence (reused, not re-derived)
     # Prune ONLY after the merge is on origin/main (`git push origin --delete` ignores merge state):
     git branch -d surf/<issue>                                    # safe local delete: refuses if not fully merged
     git ls-remote --exit-code --heads origin surf/<issue> >/dev/null 2>&1 && git push origin --delete surf/<issue> || true
     ```
   - **Exit 1 → not green → park.** Do **not** merge. **Parking** = leave the branch
     (`surf/<issue>`) intact, do not merge, and write a **parking note** recording the issue
     number, the branch name (`surf/<issue>`), the blocking reason (the sail summary), and a
     recommendation. Write the parking note to the journal **and** to a parked-issues record at
     `.surf/parked-issues.md` under the gitignored `.surf/` — this is the defined source §14's
     wrap-up reads parked issues from. Leave the branch intact, then move on to the next
     independent issue.
4. **Journal the decision.** Append an entry recording the outcome (merged + SHA, or parked +
   reason), the alternatives weighed, and whether the result is reversible (see Recovery).
5. **Dismiss the worker.** If this issue was delegated to a worker, dismiss it now — a fresh
   worker is spawned per issue (see Worker delegation). Never carry a worker across issues.

---

## Worker delegation (mode-linked)

### Step 8: Delegating a heavy issue

When an issue is heavy enough that building it inline would exhaust the session's context, spin
up a dedicated worker for it. **How** the worker is spawned depends on the run mode:

- **Supervised → a visible `Agent(team_name)` teammate.** Use `TeamCreate` once, then spawn the
  worker as a named teammate so the human can watch its pane and intervene, exactly as
  `commands/fleet.md` does. A teammate is a long-lived visible worker: it must be **explicitly
  dismissed via `SendMessage`** when the issue is done.

  ```
  TeamCreate(team_name: "surf", description: "/surf board run")
  Agent(team_name: "surf", name: "issue-<n>", model: "sonnet", description: "Build issue #<n>", prompt: "<run python3 -m sail run --diff main for issue #<n>>")
  ```

- **Autonomous → a subagent via the Agent tool.** With no human watching, delegate using the
  **`Agent` tool with `subagent_type: "general-purpose"`** — a normal subagent that does the work
  and **returns its result to the orchestrator**, not a visible teammate. A subagent needs **no
  explicit dismissal**: unlike the supervised teammate (which is dismissed via `SendMessage`), it
  simply ends when it returns its result.

  ```
  Agent(subagent_type: "general-purpose", description: "Build issue #<n>", prompt: "<run python3 -m sail run --diff main for issue #<n> in its branch and report the exit code + summary>")
  ```

  > **Deliberate exception.** `commands/fleet.md` says *never* use invisible background workers —
  > because in `/fleet` a human is supervising the panes. `/surf` autonomous mode is the one
  > sanctioned exception to that rule: there is no human to watch a pane, so a visible teammate
  > buys nothing, and a subagent is the right tool. This exception is scoped to autonomous mode
  > only; supervised mode keeps fleet's visible-teammate rule.

**Worker model.** The example uses `sonnet`, mirroring `fleet.md`'s sonnet-worker-under-opus-
orchestrator pattern. That is a sensible default, not a fixed rule — the user may raise it (e.g.
to opus) for an unusually heavy issue.

**Fresh worker per issue.** Whichever mode, spawn a new worker for each delegated issue and end it
(dismiss the supervised teammate; let the autonomous subagent return) the moment that issue is
merged or parked. Never reuse a worker across issues — stale context is exactly the drift `/surf`
is built to avoid.

---

## Merge policy

### Step 9: Auto-merge green, park everything else

The merge rule is simple and strict:

- **Auto-merge everything GREEN.** Green means `python3 -m sail run --diff main` **exited 0** —
  all deterministic gates passed *and* the blocking LLM review passed with no CRITICAL or HIGH
  findings. A green issue is merged as one `--no-ff` commit and its SHA is logged.
- **Park everything else.** Any exit-1 run, or any issue with an unanswered question past its
  deadline that the charter says `/surf` may *not* decide, is parked with a written note — never
  merged.

**Safety property — the review is fail-closed.** In one-pass `sail run --diff` mode the blocking
LLM review is **fail-closed**: if the review backend is unavailable, the run exits **1** (per the
`/sail` README), not 0. So a run with no review backend is **parked, never silently
auto-merged**. `/surf` does not need to special-case a missing backend — the engine already
turns "couldn't review" into "not green," and not-green is parked. Treat any exit code other
than 0 as park.

---

## Dependent issues

### Step 10: Building on top of other issues

The dependency graph — derived by the Step 5b analysis, reconciled with the user's Step-4
guidance, and recorded in the charter — drives ordering. For a dependent issue:

- **Parent already auto-merged → build on fresh `main`.** This is the happy path: the parent's
  work is on `main`, so the dependent issue branches from `main` and `python3 -m sail run --diff
  main` sees the parent's changes as part of the baseline. Prefer this whenever the parent is
  green and merged.
- **Parent blocked / parked → stack via plain git (branch-from-parent).** When a parent is not
  green and can't merge, but the dependent work is still worth doing, use **stacked branches**:
  **branch-from-parent** — create the dependent branch (`surf/<issue>`) off the parent's
  (unmerged) branch (`surf/<parent-issue>`) using plain git, so the dependent work builds on the
  parent's commits rather than on `main`. Record the stacking in the journal; when the parent
  eventually merges, rebase or re-evaluate the stack.

  > `gh stack` is mentioned only as an **optional extension** a user may have installed for
  > managing stacked branches more ergonomically. It is **not** a built-in `gh` subcommand and is
  > **not required** — plain-git branch-from-parent is the baseline `/surf` always assumes.

**Stacked-parent merge guard (load-bearing).** A branch stacked on a parked parent carries the
parent's commits, so `python3 -m sail run --diff main` can exit 0 — which, if merged blindly,
would smuggle the parent's unmerged work into `main` past its parked status. So **before
auto-merging any dependent, verify every dependency parent is itself already merged to `main`; if
any parent is still parked, park the dependent too.** Never auto-merge a stacked branch whose base
is not on `main`. Never park a whole chain because its head is parked if the downstream work can
stand on a stacked branch — but always log that the stack depends on an unmerged parent so it
isn't merged to `main` prematurely.

---

## Supervised decision timeout

### Step 11: The open-questions file and its deadline

In supervised mode, when `/surf` hits a question the charter says it may *not* decide alone, it
does **not** block the whole board waiting for an answer. Instead:

1. **Record the question** in an open-questions file at `.surf/open-questions.md`, with the
   question text, the issue it belongs to, an **asked-at** timestamp, and a **deadline** roughly
   **30 minutes** out.
2. **Work other issues meanwhile.** `/surf` moves on to the next independent issue rather than
   idling.
3. **Re-check at every checkpoint.** At each issue boundary / checkpoint, `/surf` re-reads
   `.surf/open-questions.md`. **This re-check is the load-bearing mechanism** — it is what makes
   the deadline real. If the user has answered, apply the answer and continue.
4. **Past the deadline, decide and log.** If a question is still unanswered when its deadline has
   passed (as observed at a checkpoint), `/surf` makes the call itself, **logs the decision plus
   the alternatives it weighed**, tags it **reversible**, and continues.

> **The deadline is approximate.** It is resolved at the *next checkpoint* after it passes, not on
> a precise stopwatch — a 30-minute deadline checked at a boundary 35 minutes out resolves at 35.
> `ScheduleWakeup` or `/loop` may be used as an **optional self-pacing accelerator** where
> available, to nudge `/surf` to checkpoint sooner — but the open-questions file + checkpoint
> re-check is the mechanism that must always hold; the wakeup is only an accelerator.

In autonomous mode there is no waiting: any decision the charter authorizes is made-and-logged
immediately; anything it doesn't authorize is parked.

---

## Recovery / decision-log

### Step 12: Append-only journal + structured decision-log

Every run keeps two artifacts under `.surf/` (gitignored):

- **An append-only journal** at `.surf/journal-<timestamp>.md` — a running narrative of the run:
  which issue was picked, what `/sail` returned, what was merged or parked, and why. Append only;
  never rewrite history in the journal.
- **A structured decision-log** at `.surf/decision-log-<timestamp>.md` — a dedicated file under
  the gitignored `.surf/`, one entry per decision, each recording:
  - the decision and the **alternatives weighed**,
  - whether it is reversible,
  - and, for a merge, the **merge SHA**.

(Parked issues are also recorded in `.surf/parked-issues.md` per §7, the source §14 reads from.)

The merge SHA is the recovery hinge. Because each green issue lands as one `--no-ff` commit with
its SHA logged, **any single issue is reversible** without disturbing the rest of the board:

```bash
git revert <sha>   # undo exactly one issue's merge; everything else stays
```

That is the whole point of one-commit-per-issue merges plus a SHA in the decision-log: the run is
not an all-or-nothing blob — it is a list of independently revertible decisions.

---

## Guardrails

### Step 13: Hard limits that always hold

These are non-negotiable for every `/surf` run, autonomous or supervised:

- **Sandbox repo only.** `/surf` runs unattended and merges on its own; it is only ever pointed at
  a **sandbox** repository, never a production or shared-history repo. The start gate's repo
  confirmation (Step 1) is where this is enforced.
- **No destructive git.** No **force-push**, no history rewriting (no `rebase`/`reset` that drops
  commits on a shared branch), no `git push --force`, no branch deletion that loses unmerged work.
  Merges are always `--no-ff` so every issue stays an isolated, revertible commit.
- **Park anything irreversible or truly ambiguous.** If a decision cannot be cleanly undone with a
  `git revert`, or the situation is genuinely ambiguous and the charter doesn't authorize a call,
  **park it with a written recommendation** rather than guessing. When in doubt, park — a parked
  issue costs a follow-up; a bad irreversible merge costs the board.

---

## Wrap-up

### Step 14: Plain-language final summary

When the work list is exhausted (or the user stops the run), write a **final summary** for the
user — who is a non-programmer, so keep it plain and concrete. Include:

- **What merged — the revert map.** A simple table mapping each merged **issue → SHA**, so the
  user (or a future session) can undo any one of them with `git revert <sha>`. This issue→SHA
  revert map is the single most important deliverable of the summary.
- **What was parked and why.** Read from `.surf/parked-issues.md`: each parked issue, the reason it
  didn't go green, and the branch it lives on (`surf/<issue>`) so it can be picked up later.
- **Open questions left.** Anything from `.surf/open-questions.md` that was decided-by-deadline
  (with the decision and that it's reversible) or is still genuinely open.
- **Recommended next steps.** In plain language: what to look at first, what to re-run, what to
  hand back to a human.

Point the user at the journal and decision-log (`.surf/journal-<timestamp>.md`) for the full
detail behind the summary.

**Mark the run done.** When the board is exhausted — every selected issue has a terminal outcome
(merged, parked, or won't-fix) — record that this run is finished so the auto-resume scheduler
(Step 16) goes quiet: append a `- done: board exhausted <ISO>` line to the journal **and** write a
marker file `.surf/<charter>-done`. The done-marker is the **authoritative quiet signal**: the
work-remaining gate in Step 16 treats it as "nothing to resume," so the scheduler stops relaunching
a completed run. (If the marker is already present from a self-healing resume — see Step 15 — keep
it.) A user-stopped (not exhausted) run is **not** marked done — it is left resumable on purpose.

**Remove the live-session marker.** On any clean exit — board exhausted or user-stopped — delete
`.surf/active` (the PID marker written at Step 7) so the scheduler is no longer blocked by it.

---

## Resume

### Step 15: Resuming after a stop

A `/surf` run can be cut off mid-board — a crash, or (the common case) the Max-subscription usage
window ending. The durable charter + journal + decision-log + parked-issues files (all under the
gitignored `.surf/`) plus git itself hold everything needed to pick the board back up. Resume reads
those, not chat history.

- **Invocation:** `/surf resume` — used both manually and by the auto-resume scheduler (Step 16).
- **Short-circuit the start gate, but verify bypass.** The original run already confirmed the repo
  and `--dangerously-bypass-permissions` and recorded the run mode in the charter, so resume does
  **not** re-prompt Step 1–2. It **does** verify that `--dangerously-bypass-permissions` is
  actually active for this process. A scheduled relaunch is non-interactive, so if bypass is **not**
  active, resume must **park and exit** with a note rather than prompting — a permission prompt
  would hang a headless run forever. (The scheduler passes the flag; see Step 16.)
- **Re-entry reconstruction.** Read the latest `.surf/charter-*`, its journal, `.surf/decision-log-*`,
  and `.surf/parked-issues.md`, then **cross-check against git**: for each issue the journal says was
  merged, confirm `surf/<issue>` is actually merged into `main` (capture the SHA); for each in-flight
  issue, check whether the `surf/<issue>` branch exists. From that, rebuild the merged-issue→SHA map,
  the parked set, and the **next unfinished issue**. Append `- ↺ resume <ISO>` to the journal
  (mirroring `/sail`'s decision-log resume marker), then re-enter the Step 7 per-issue loop at the
  next unfinished issue — **without** re-charter. As in a fresh run, write `.surf/active` with this
  process's PID before re-entering the loop, and remove it on clean exit (this is the live-session
  marker the scheduler checks; see Step 16).
- **Self-heal an already-exhausted board.** If reconstruction finds the board is **already
  exhausted** — no remaining unbuilt issues, every selected issue at a terminal outcome — write the
  done-marker (`.surf/<charter>-done` and a `- done: board exhausted <ISO>` journal line) and **exit
  cleanly without re-entering the loop**. This covers a crash that happened after the board was done
  but before Wrap-up (Step 14) wrote the marker: the simplified Step 16 gate (charter present + no
  done-marker → work remains) would otherwise keep relaunching, so writing the marker here is what
  finally silences the scheduler.
- **Idempotent half-issue recovery** (mirrors `/sail`'s "don't redo finished work"). For the issue
  that was in flight when the run stopped:
  1. **Branch merged to `main`, journal not updated** → record the merge (capture the SHA) and
     advance to the next issue.
  2. **Branch merged AND it was a stacked parent** → re-run the Step 10 dependent-issue guard for
     its dependents (a parent merging may now unblock or re-order them) before advancing — don't
     blindly skip.
  3. **Branch exists, unmerged, and a valid `.surf/runs/<issue>/` run-dir exists** → re-invoke
     `python3 -m sail run --diff main --run-dir .surf/runs/<issue>`. `/sail` skips the gates it
     already finished, and `--diff main` re-derives the baseline against **current** `main` — so a
     parent that merged since is included.
  4. **Run-dir missing, or corrupt/partial** (a crash mid-write) → discard it and build the issue
     **fresh**.
  5. **No branch at all** → build the issue **fresh**.
- **The per-issue journal entry is the checkpoint.** Because each issue's outcome is journaled as
  it lands, a hard stop loses at most the one in-flight issue — never the merged board behind it.

### Step 16: Reactive usage-cap auto-resume

The subscription usage window is **not** API-readable (the `anthropic-ratelimit-*` headers report
API-key per-minute throughput, a different pool), so auto-resume is **reactive**: capture the reset
time the cap reports and relaunch after it — not a proactive remaining-quota monitor. A capped
session can't wake itself, so the trigger is **external**.

- **External scheduler.** A macOS LaunchAgent (`config/com.surf.resume.plist`) fires
  `config/surf-resume.sh` on an interval and relaunches the run.
- **The wrapper is pure bash and gates before any Claude call** — zero Claude tokens on an idle
  tick. It launches Claude only when **all** of: no live resume lock; **no live `.surf/active`
  session** (a PID marker whose process is still alive — written by a running interactive or
  resumed `/surf`, see Steps 7 and 15 — so the scheduler never launches a second run on top of one
  already running; a stale marker with a dead PID is ignored and cleaned); `now ≥` the RFC3339
  timestamp in `.surf/resume-after` (or that file is absent); and **real unfinished work remains**.
  Otherwise it exits immediately.
- **"Work remains" = charter present AND no done-marker.** The gate is deliberately broad: if the
  newest `.surf/charter-*.md` exists and there is **no** done-marker (no `.surf/<charter>-done` file
  and no `- done:` journal line — written as `board exhausted` or `superseded`), the scheduler treats
  the board as unfinished. The **done-marker is the single authoritative quiet signal** — it is how a
  finished run (written at Wrap-up, Step 14), an abandoned one (written by self-healing resume,
  Step 15), or a superseded one (tombstoned when a fresh run starts over it, Step 0-pre) silences the
  scheduler. To stop a mid-board run that you do **not** want resumed, either `touch` the done-marker
  (`.surf/<charter>-done`) or bootout the LaunchAgent. (The broad gate is why the live-session marker
  above matters: without it the scheduler could relaunch on top of a running session.)
- **The relaunch carries the bypass flag:** `claude --dangerously-bypass-permissions -p "/surf
  resume"`. Without it the resumed run would stall at its own start gate (Step 15 parks on missing
  bypass).
- **Reset capture (conservative floor).** When the relaunched run hits the cap again, the wrapper
  best-effort-parses the reset time from the output and writes
  `resume-after = max(parsed_reset, now + MIN_BACKOFF)`. If the reset time is **unparseable**, it
  writes a long default (`now + DEFAULT_BACKOFF`, multi-hour — subscription windows are multi-hour).
  A parse-miss is therefore a *long* wait, never a per-tick hot-loop.
- **Anti-pattern guard.** Never put the "is it time yet?" decision inside `claude -p` — that would
  burn tokens on every idle tick and can't run while the session is capped. The decision lives in
  the pure-shell wrapper; Claude is launched only once the gate has already said yes.

---

## Rules

- The start gate is non-negotiable: confirm the repo, confirm `--dangerously-bypass-permissions`,
  and (supervised only) confirm `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: 1`. Refuse the loop until
  all hold.
- Every user choice is an **interactive selection prompt — never a `--flag`**.
- **Auto-merge only on `python3 -m sail run --diff main` exit 0.** Any other exit code is parked.
  The review is fail-closed, so a missing backend parks; it never auto-merges.
- **Autonomous mode = fix, don't wait.** When something is broken or a fix is needed and the fix is
  reversible, in-scope, and unambiguous (a broken/non-hermetic test, a clear code-quality fix,
  inserting a discovered fix-issue into the build order, a merge/park call, finishing a stalled
  teammate's already-green work), the orchestrator **makes the call and executes it — decide-and-log,
  never pause for the human.** Waiting defeats an unattended run. **Park is the only "stop"** and is
  reserved for the genuinely irreversible (cannot be undone by `git revert`), the genuinely ambiguous
  (no defensible default), or a non-code judgment that is truly the human's. Supervised mode asks
  within the deadline (§11); autonomous mode decides. (See #57 for the mode-banner treatment.)
- One `--no-ff` merge commit per green issue; log every merge SHA so each is `git revert`-able.
- **Sandbox repo only. No force-push or destructive git.** Park anything irreversible.
- **Supervised:** visible `Agent(team_name)` teammates; never create tmux sessions manually.
  **Autonomous:** subagents — the deliberate exception to fleet's no-invisible-workers rule.
- The charter + journal are the source of truth; re-anchor from them at the top of every issue.
  Do not rely on `/compact` or chat history.

## Cross-references

- `commands/idea.md` — triage skill; `/surf` is the board-level autopilot above per-issue pipelines
- `commands/fleet.md` — parallel epic build; source of the `TeamCreate`/`Agent(team_name)`/dismiss
  teammate pattern and the tmux/agent-teams setup `/surf` borrows
- `cc-dotfiles: home/commands/sail.md` (and the `/sail` README) — the engine `/surf` drives per
  issue via `python3 -m sail run --diff main`; defines the exit-0/exit-1 and fail-closed-review
  contract `/surf` relies on
