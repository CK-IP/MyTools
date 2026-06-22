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
  charter with no done-marker is a phantom in-progress run: the Step 16 revive watcher's
  "newest charter present AND no done-marker → work remains" gate would keep treating the dead
  run as resumable forever. Tombstone it, then fall through to Step 0.
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

The chosen mode is recorded in the charter and governs how `/surf` behaves — **not** how it
delegates. Delegation is the same in both modes: **every** issue is built by a fresh per-issue
agent-team teammate (see Context model and Worker delegation). What the mode changes is:

- **Decision behavior** — *Autonomous* decides-and-logs every reversible call; *Supervised* asks
  the question and waits on a deadline (Step 11) before deciding.
- **Monitoring** — *Supervised* assumes a human is attached to the tmux session watching the
  teammate panes; *Autonomous* runs the same panes with nobody watching.

The start gate's agent-teams settings check (Step 3) now runs in **both** modes, because both
modes spawn teammates.

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

> **Launch in the named `surf` tmux session.** Because every issue is delegated to a teammate
> (Step 8) and teammates render as panes inside the launching session, `/surf` is meant to be
> started inside a **named** tmux session so the operator has one front door for monitoring and
> the resume watcher has one session to revive. The documented start procedure is in the
> **Start / monitor in a named tmux session** subsection below; the canonical session name is
> **`surf`**.

### Step 3: Agent-teams environment check (both modes)

This step runs in **both** modes. `/surf` delegates **every** issue to an agent-team teammate
(Step 8), so the agent-teams feature is required regardless of mode — this is the change from the
old "supervised-only" check (autonomous no longer uses subagents; see Step 8).

- Check `~/.claude/settings.json` for `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: 1`. If missing,
  stop with: "`/surf` builds every issue with a visible teammate. Add
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: 1` to `~/.claude/settings.json` and restart Claude
  Code, then re-run `/surf`."
- Recommend **opus** for this orchestrating session:
  > "For best results the `/surf` session should run **opus** — it makes all the merge and
  > park decisions. Switch now if you're not on opus."
- **Confirm `/surf` was launched inside the named `surf` tmux session** (see the next
  subsection). The teammate panes spawn as siblings in whatever session hosts `/surf`; running
  inside the named session is what makes single-command monitoring (`tmux attach -t surf`) and
  the resume watcher (Step 16) work. The agent-teams framework handles the pane splits *within*
  that session automatically — **never split panes or create extra tmux windows by hand**, but
  **do** start `/surf` inside the named session yourself (the framework does not name the session
  for you).

### Step 3b: Start / monitor in a named tmux session

`/surf` is launched inside a **named** tmux session so one session serves all four purposes —
**start → monitor → revive → teardown**. The canonical session name is **`surf`**.

**Start (copy-pasteable):**

```bash
# 1. Create (or re-create) the named session and attach to it
tmux new -s surf

# 2. Inside that tmux session, launch Claude Code with the bypass flag and run /surf
claude --dangerously-bypass-permissions
#   …then at the Claude prompt:
/surf
```

**Monitor:**

- **Attach** from any terminal to watch the run and the per-issue teammate panes:
  `tmux attach -t surf`
- **Switch panes** to watch a specific build: `Ctrl-b o` (next pane) or `Ctrl-b q` then a number.
- **Detach without killing the run:** `Ctrl-b d`. The session — orchestrator **and** teammate
  panes — keeps running in the background; this detachability is exactly what lets `/surf`
  survive a closed terminal and a usage-cap window.

**How monitoring composes with teardown (Step 14):** after a run reports done, `tmux attach -t
surf` to confirm the teardown was clean — the per-issue teammate panes should be **gone** (Step
14 dismisses every teammate and kills its pane), leaving only the orchestrator pane. A leftover
teammate pane means teardown didn't complete and should be investigated. The `surf` session
itself is left alive for the next run / resume; only the per-issue panes are torn down.

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
- **Every issue is delegated to a fresh per-issue teammate** — never built inline (see Worker
  delegation). The orchestrator does **not** run gates, edits, or reviews itself; it spawns a
  teammate, then ingests only a **compact per-issue result** (exit code + a one-line summary +
  the merge SHA or park reason) and writes the detail to the journal. This is the core anti-drift
  property: because no build ever runs in the orchestrator's own context, that context stays
  **flat regardless of board length** — a 5-issue board and a 30-issue board cost the orchestrator
  roughly the same. (This is what makes the 200K tmux context cap acceptable — see the tmux note
  below.)
- **The orchestrator keeps only a bounded running summary in context** — the per-issue
  compact results plus running counts (merged / parked / remaining). All per-issue detail lives
  on disk in the journal, which is the source of truth for `/surf resume` (Step 15), not the
  conversation.
- **The 200K tmux context cap is acceptable here.** Agent-teams panes in tmux are capped at 200K
  context (the known `/fleet` Step 10a gotcha). That cap is fine for `/surf` precisely **because**
  full delegation keeps the orchestrator tiny (only compact per-issue results) and each teammate
  only ever needs **one issue's** worth of context. Neither side accumulates a board's worth of
  history, so neither approaches the cap over a long run.
- **A hard stop is different from running low on context.** If the run is killed outright — a
  crash, a machine reboot, or the Max-subscription usage window cutting it off mid-issue — the
  session cannot re-anchor from chat at all. The persistent-tmux model (Steps 15–16) keeps the
  session alive **across a usage-cap window** so a cap is *not* a hard stop; a reboot or kill that
  destroys the session **is** a hard stop, and recovery from it goes through **Resume (Step 15)**,
  which rebuilds board position from the charter + journal + git, not from the conversation.
- **Live-session marker.** At the start of the per-issue loop (Step 7), write `.surf/active`
  containing this process's PID — and record this orchestrator's tmux pane id to
  `.surf/orchestrator-pane` (`tmux display-message -p '#{pane_id}'`) so the revive watcher
  (Step 16) can send keys to the right pane — and **remove both on clean exit** (board exhausted,
  or the user stops the run). This is the marker the revive watcher (Step 16) checks: a **live**
  PID in
  `.surf/active` (process still alive, named `surf` session still up) is what tells the watcher
  there is a real session to **revive in place** after the cap resets. A *stale* marker (its PID
  is dead — the session was killed or the machine rebooted) means there is **no live session to
  nudge**: the watcher ignores and cleans it, and recovery falls to a manual `/surf resume`
  (Step 16's reboot path), never an automatic headless relaunch.

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
2. **Delegate the build to a fresh teammate.** The orchestrator never builds inline. Spawn a
   fresh per-issue teammate (Step 8) and hand it the issue. The teammate creates the issue branch
   off **current `main`** (so a parent merged earlier in this run is already in the baseline) and
   runs the engine **in a stable per-issue run-dir**, then reports a compact result back:
   ```bash
   # the TEAMMATE runs this (the orchestrator only receives the exit code + summary):
   git checkout main
   git checkout -b surf/<issue>
   python3 -m sail run --diff main --run-dir .surf/runs/<issue>
   ```
   This is the one-pass `/sail` mode (the teammate's default engine; `/ship` is the optional
   heavier engine — see Step 8): it runs the deterministic gates **and** the blocking LLM review
   against the diff vs. `main`. It exits **0** when the issue is green (all gates pass and the
   blocking review found no CRITICAL/HIGH) and **1** when something is blocking. The teammate
   reports that exit code plus a one-line summary; the orchestrator ingests only that.

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
5. **Dismiss the teammate.** Every issue has a teammate, so always dismiss it now — via
   `SendMessage` (a shutdown request) and then tear down its pane — before moving on. A fresh
   teammate is spawned per issue (see Worker delegation); never carry one across issues. Leaving a
   teammate alive between issues is both a context leak and an orphaned pane (Step 14 teardown
   depends on per-issue dismissal holding).

---

## Worker delegation (teammate for every issue)

### Step 8: Delegating every issue to a teammate

**Every** issue is built by a fresh per-issue **agent-team teammate** — never inline, never a
one-shot subagent, and this is the same in **both** run modes. Use `TeamCreate` once at the start
of the run, then spawn one named teammate per issue:

```
TeamCreate(team_name: "surf", description: "/surf board run")
Agent(team_name: "surf", name: "issue-<n>", model: "sonnet",
      description: "Build issue #<n>",
      prompt: "<spawn contract — see below>")
```

**Why a teammate and not a subagent (the load-bearing rationale).** The teammate runs `/sail`
(or `/ship`), and those skills **spawn their own crew** (compass / leadsman / red-team / board).
A one-shot subagent (the `Agent` tool with `subagent_type`) **cannot** host them: a subagent is
terminal — it cannot spawn its own sub-subagents ("no nested teams"). Only an **agent-team
teammate** (`TeamCreate` → `Agent(team_name)`) runs as its own full session and can host
`/sail`/`/ship` with their crews. So the delegation mechanism is a teammate for **every** issue,
in both modes — there is no subagent path.

> **This replaces the old "autonomous = subagent" rule.** Earlier `/surf` delegated heavy issues
> to a visible teammate in supervised mode but to an invisible `subagent_type: "general-purpose"`
> subagent in autonomous mode (treated as a deliberate exception to `commands/fleet.md`'s
> no-invisible-workers rule). That rule is **retired**: a subagent can't host `/sail`'s crew, so
> it was never a viable engine host. `/surf` now follows fleet's visible-teammate rule in **both**
> modes — the mode no longer changes the delegation mechanism, only decision behavior and whether
> a human is watching the panes (Step 0).

**Engine: `/sail` by default, `/ship` optional.** The teammate runs **`/sail`** (`python3 -m sail
run --diff main --run-dir .surf/runs/<n>`) as its default engine. **`/ship`** is the optional
heavier engine for an unusually demanding issue. Both produce the exit-0-green / exit-1-blocking
contract `/surf` reads.

**Spawn contract (the teammate's prompt).** The prompt handed to each teammate must tell it to:

1. **Start immediately and run autonomously to terminus — do not idle waiting for input.**
   (Freshly spawned teammates have been observed going idle on spawn instead of starting, forcing
   an extra orchestrator round-trip; this directive in the spawn prompt removes that nudge.)
2. Create branch `surf/<n>` off current `main` and run the engine (`/sail` default) in run-dir
   `.surf/runs/<n>`.
3. Report back a **compact result only**: the exit code, a one-line summary, and the branch name
   — the orchestrator does the land/merge itself (Step 7), so the teammate does **not** merge.

**Teammate model.** The example uses `sonnet`, mirroring `fleet.md`'s sonnet-worker-under-opus-
orchestrator pattern. That is a sensible default, not a fixed rule — the user may raise it (e.g.
to opus) for an unusually heavy issue.

**Fresh teammate per issue, dismissed at terminus.** Spawn a new teammate for each issue and
**dismiss it** (via `SendMessage` shutdown, then tear down its pane) the moment that issue is
merged or parked. Never reuse a teammate across issues — stale context is exactly the drift
`/surf` is built to avoid. Per-issue dismissal is what keeps the Step 14 teardown cheap (only the
current pane to clean, not a board's worth).

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
(merged, parked, or won't-fix) — record that this run is finished so the auto-resume watcher
(Step 16) goes quiet: append a `- done: board exhausted <ISO>` line to the journal **and** write a
marker file `.surf/<charter>-done`. The done-marker is the **authoritative quiet signal**: the
work-remaining gate in Step 16 treats it as "nothing to resume," so the watcher stops reviving
a completed run. (If the marker is already present from a self-healing resume — see Step 15 — keep
it.) A user-stopped (not exhausted) run is **not** marked done — it is left resumable on purpose.

**Remove the live-session marker.** On any clean exit — board exhausted or user-stopped — delete
`.surf/active` (the PID marker written at Step 7) and `.surf/orchestrator-pane` so the watcher
sees no live session to revive.

### Step 14b: Teardown — dismiss every teammate and tear down the panes (every stop path)

`/surf` spawns a teammate per issue, so a run that ends must never leave orphaned teammates or
panes behind. **Teardown is mandatory on every stop path**, not just the happy one:

- **Board exhausted** (Step 14 wrap-up),
- **User-stop** (the user halts the run mid-board),
- **Error / abort** (an unrecoverable failure ends the run).

On any of these, before the process exits:

1. **Dismiss every teammate.** Send each live teammate a `SendMessage` shutdown and confirm it
   ends; then `TeamDelete` the `surf` team so no teammate is left running.
2. **Tear down the per-issue panes.** Kill every per-issue teammate pane so none is orphaned in
   the tmux session. The **`surf` session itself is left alive** (it is the persistent session the
   next run / resume reuses, and the resume watcher revives — Step 16); only the per-issue
   *panes* are torn down.
3. **Verify clean.** The operator can `tmux attach -t surf` to confirm only the orchestrator pane
   remains (the monitoring-meets-teardown check from Step 3b). A residual teammate pane means
   teardown didn't complete.

This must hold for **long runs** too: because each teammate is already dismissed at its own issue
boundary (Step 7 step 5), teardown at the end normally has only the current/last teammate to
clean — but it must still sweep for and dismiss **any** straggler so a 30-issue run ends as clean
as a 1-issue run.

---

## Resume

### Step 15: Resuming after a stop

A `/surf` run can be cut off mid-board. With the persistent-tmux model (Step 16) the **common
case — a usage-cap window — is no longer a hard stop**: the named `surf` session stays alive
across the cap, and the resume watcher revives it in place so the teammates survive. Resume
(`/surf resume`) is therefore for a **genuine hard stop** that destroys the session: a machine
reboot, or the tmux session being killed. The durable charter + journal + decision-log +
parked-issues files (all under the gitignored `.surf/`) plus git itself hold everything needed to
pick the board back up. Resume reads those, not chat history.

- **Invocation:** `/surf resume` — used manually (e.g. after a reboot, inside a fresh
  `tmux new -s surf` → `claude --dangerously-bypass-permissions` → `/surf resume`) and as the
  reboot/last-resort path the watcher points operators to when there is no live session to revive
  (Step 16).
- **Short-circuit the start gate, but verify bypass.** The original run already confirmed the repo
  and `--dangerously-bypass-permissions` and recorded the run mode in the charter, so resume does
  **not** re-prompt Step 1–2. It **does** verify that `--dangerously-bypass-permissions` is
  actually active for this process. If bypass is **not** active, resume must **park and exit** with
  a note rather than prompting — a permission prompt would hang an unattended resume forever. (The
  documented manual restart launches with the flag — see Step 16.)
- **Re-entry reconstruction.** Read the latest `.surf/charter-*`, its journal, `.surf/decision-log-*`,
  and `.surf/parked-issues.md`, then **cross-check against git**: for each issue the journal says was
  merged, confirm `surf/<issue>` is actually merged into `main` (capture the SHA); for each in-flight
  issue, check whether the `surf/<issue>` branch exists. From that, rebuild the merged-issue→SHA map,
  the parked set, and the **next unfinished issue**. Append `- ↺ resume <ISO>` to the journal
  (mirroring `/sail`'s decision-log resume marker), then re-enter the Step 7 per-issue loop at the
  next unfinished issue — **without** re-charter. As in a fresh run, write `.surf/active` with this
  process's PID before re-entering the loop, and remove it on clean exit (this is the live-session
  marker the revive watcher checks; see Step 16).
- **Self-heal an already-exhausted board.** If reconstruction finds the board is **already
  exhausted** — no remaining unbuilt issues, every selected issue at a terminal outcome — write the
  done-marker (`.surf/<charter>-done` and a `- done: board exhausted <ISO>` journal line) and **exit
  cleanly without re-entering the loop**. This covers a crash that happened after the board was done
  but before Wrap-up (Step 14) wrote the marker: the simplified Step 16 gate (charter present + no
  done-marker → work remains) would otherwise keep treating the run as revivable, so writing the
  marker here is what finally silences the watcher.
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

### Step 16: Persistent-tmux + revive (usage-cap auto-resume)

The subscription usage window is **not** API-readable (the `anthropic-ratelimit-*` headers report
API-key per-minute throughput, a different pool), so auto-resume is **reactive**: capture the reset
time the cap reports and resume after it — not a proactive remaining-quota monitor.

**Why not the old headless relaunch.** `/surf` used to be relaunched headlessly
(`claude --dangerously-bypass-permissions -p "/surf resume"`) by a LaunchAgent on a timer. That is
**retired** as the primary mechanism: a teammate-based build needs the **agent-teams** feature, and
agent teams **cannot run in headless `-p` mode** — they require an interactive terminal. A headless
relaunch could not host the per-issue teammates at all, so it is fundamentally incompatible with the
"teammate for every issue" model (Step 8). The replacement keeps the session **interactive and
alive** across the cap.

**The model: persistent tmux + in-place revive.** `/surf` runs in the long-lived named `surf` tmux
session (Step 3b). The session — orchestrator pane **and** the live per-issue teammate pane — is
**not killed** when the usage cap hits; it just stalls. An **external revive watcher** (out of
band, unaffected by the cap) waits for the reset and then **wakes the still-alive session in place**
with `tmux send-keys -t surf` (a one-line nudge to continue). Because the session was never
restarted, the teammate survives the cap window — which restarting the Claude process (`claude
--resume`) or a headless relaunch could not guarantee.

- **The revive watcher.** `config/surf-resume.sh`, fired on an interval by the LaunchAgent
  (`config/com.surf.resume.plist`), is **reframed** from a headless relauncher into the
  session-bound watcher: instead of `claude -p`, its action is `tmux send-keys` to the
  **orchestrator pane** of the live session. It is **not** a headless `claude -p` relaunch — it
  touches no Claude tokens to decide, and it only ever revives a session that is already alive.
- **The watcher is pure bash and gates before any Claude call** — zero Claude tokens on an idle
  tick. It acts only when **all** of: no live revive lock; a **live `.surf/active` session**
  exists (a PID marker whose process is still alive — written by a running interactive or resumed
  `/surf`, Steps 7 and 15 — and a live named `surf` tmux session to send keys to; a stale marker
  with a dead PID, or no session to revive, means there is nothing to nudge → it logs and exits);
  and **real unfinished work remains**. Otherwise it exits immediately.
- **Positive stall evidence is required before any nudge (state machine).** The watcher never
  guesses from historical scrollback and never nudges a healthy session. It reads the **current
  visible screen** of the orchestrator pane and runs a four-state machine:
  1. **Cap still in effect** (the cap notice is the pane's active tail **and** its reset time is
     still in the future, or it is the first sight of a cap) → **arm** `.surf/resume-after` from
     the reset time and exit — never nudge a still-capped session. A **lingering** cap notice
     whose reset has already passed does **not** re-arm (re-arming a notice that stays on screen
     until the nudge would push the floor forward every tick and never revive — a livelock); it
     falls through to state 2.
  2. **Armed AND `now ≥ .surf/resume-after`** → the session *was* observed capped and the window
     has reset → **revive once** (send-keys to the orchestrator pane), then **disarm** (delete
     `.surf/resume-after`).
  3. **Armed AND reset still pending** → wait.
  4. **Not capped AND not armed** → a healthy/working session that was never observed capped →
     **do nothing.** The armed floor is the proof-of-prior-cap that licenses a nudge; without it
     the watcher will not send keys.
- **"Work remains" = charter present AND no done-marker.** The gate is deliberately broad: if the
  newest `.surf/charter-*.md` exists and there is **no** done-marker (no `.surf/<charter>-done` file
  and no `- done:` journal line — written as `board exhausted` or `superseded`), the watcher treats
  the board as unfinished. The **done-marker is the single authoritative quiet signal** — it is how a
  finished run (written at Wrap-up, Step 14), an abandoned one (written by self-healing resume,
  Step 15), or a superseded one (tombstoned when a fresh run starts over it, Step 0-pre) silences the
  watcher. To stop a mid-board run that you do **not** want revived, either `touch` the done-marker
  (`.surf/<charter>-done`) or bootout the LaunchAgent.
- **Reset capture (conservative floor).** When state (1) observes the cap on the current screen,
  the watcher arms `resume-after = max(parsed_reset, now + MIN_BACKOFF)`. If the reset time is
  **unparseable**, it arms a long default (`now + DEFAULT_BACKOFF`, multi-hour — subscription
  windows are multi-hour). A parse-miss is therefore a *long* wait, never a per-tick hot-loop.
- **Precise pane targeting.** So the revive keystroke lands on the orchestrator and not a
  teammate's pane, the orchestrator records its own tmux pane id to `.surf/orchestrator-pane` at
  the top of the per-issue loop (Step 7); the watcher sends keys to that pane id, falling back to
  the named session only if the file is absent.
- **Cap detection is pane-read, and that is a documented limitation.** The watcher reads the
  orchestrator pane's **active tail** (`tmux capture-pane`, last few non-empty lines) to spot the
  cap notice. This is the **only** out-of-band cap signal available: a capped session is blocked
  on the API and **cannot write a marker itself**, so there is nothing machine-readable to gate on
  instead. The fragility is bounded by design — the conservative `MIN_BACKOFF` floor, the
  active-tail restriction, and the single-shot idempotent nudge mean a misread costs at most one
  harmless keystroke or a longer wait, never a hot-loop. The cap-notice patterns should be
  **validated against a real capped Claude Code pane** before being trusted in production.
- **Anti-pattern guard.** Never put the "is it time yet?" decision inside a Claude call — that would
  burn tokens on every idle tick and can't run while the session is capped. The decision lives in
  the pure-shell watcher; the live session is nudged only once the gate has already said yes.

**The reboot trade-off (documented, accepted).** The persistent-tmux model survives a **usage-cap
window** but **not a machine reboot** — a reboot destroys the tmux session, so there is no live
session for the watcher to revive, and **automatic recovery is lost**. That is the accepted
trade-off for keeping teammates alive across caps. Recovery after a reboot is **manual**: start a
fresh named session and resume —

```bash
tmux new -s surf
claude --dangerously-bypass-permissions
#   …then at the Claude prompt:
/surf resume
```

— which rebuilds board position from charter + journal + git (Step 15). The `claude --resume
<uuid>` form may also be used to rehydrate the prior session id, but `/surf resume` reconstructing
from the durable files is the canonical path.

---

## Rules

- The start gate is non-negotiable: confirm the repo, confirm `--dangerously-bypass-permissions`,
  and (in **both** modes, since both delegate to teammates) confirm
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: 1`. Refuse the loop until all hold.
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
- **Every issue is built by a fresh per-issue `Agent(team_name)` teammate — in both modes**, never
  inline and never a one-shot subagent (a subagent can't host `/sail`'s crew). The teammate runs
  `/sail` by default (`/ship` optional). The mode changes only decision behavior and whether a
  human watches the panes — not the delegation mechanism. Run `/surf` inside the named `surf` tmux
  session; the agent-teams framework splits panes within it — never split panes by hand.
- **Teardown is mandatory on every stop path** (board-exhausted, user-stop, error): dismiss every
  teammate and tear down its pane; leave the `surf` session itself alive for resume.
- **Auto-resume is persistent-tmux + revive, not headless relaunch.** The named session stays
  alive across a usage cap and an external watcher revives it in place (`tmux send-keys`); the
  headless `claude -p` LaunchAgent relaunch is retired (can't host teammates). A reboot loses
  automatic recovery → manual `/surf resume`.
- The charter + journal are the source of truth; re-anchor from them at the top of every issue.
  Do not rely on `/compact` or chat history.

## Cross-references

- `commands/idea.md` — triage skill; `/surf` is the board-level autopilot above per-issue pipelines
- `commands/fleet.md` — parallel epic build; source of the `TeamCreate`/`Agent(team_name)`/dismiss
  teammate pattern, the named-tmux/agent-teams setup, and the visible-teammate rule `/surf` now
  follows in **both** modes for **every** issue (no subagent exception)
- `cc-dotfiles: home/commands/sail.md` (and the `/sail` README) — the **default engine** each
  per-issue teammate runs via `python3 -m sail run --diff main` (`/ship` is the optional heavier
  engine); defines the exit-0/exit-1 and fail-closed-review contract `/surf` relies on
