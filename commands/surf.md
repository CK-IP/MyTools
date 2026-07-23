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
    { label: "Supervised", description: "A human is around. /surf asks questions and waits (up to a deadline) before deciding." }
  ]
)
```

The chosen mode is recorded in the charter and governs how `/surf` behaves — **not** how it
delegates. Delegation is the same in both modes: **every** issue is built by a fresh per-issue
**headless `claude -p` worker process** (see Context model and Worker delegation). What the mode
changes is:

- **Decision behavior** — *Autonomous* decides-and-logs every reversible call; *Supervised* asks
  the question and waits on a deadline (Step 11) before deciding.
- **Visibility** — both modes run the same headless workers; *Supervised* simply assumes a human is
  around to answer the domain questions a worker surfaces (Step 11). Neither mode requires a human
  to watch a pane.

**Optional supervised (panes) lens.** A human who wants to *watch* a build can additionally run
`/surf` inside a named `surf` tmux session and attach a viewer — see **Step 3b (optional)**. The
panes are a **visibility layer over the same headless worker substrate** (the same per-issue
process + the same `.surf/runs/<n>` artifacts), **not** a second execution body — resume,
delegation, and the result contract are identical whether or not anyone is watching. The default
needs no tmux.

**The no-flags principle.** Every choice you make in `/surf` is an interactive selection
prompt — never a `--flag` to remember. There is deliberately no `--autonomous`,
`--supervised`, `--subset`, or `--issues` flag; mode, issue scope, and decision authority
are all answered through `AskUserQuestion` prompts at startup. This is a design rule, not an
omission: a non-programmer should be able to drive `/surf` by reading and clicking, with
nothing to memorize.

### Step 0b: Announce the active mode — the mode banner

Immediately after the mode is chosen — **and again at the top of every issue's re-anchor**
(Step 7) — `/surf` prints a one-line **mode banner** so the active mode **and its
decide-vs-ask behavior** are unmistakable with **zero user memory required**. The banner is
a single mechanism whose purpose is to make the mode-dependent behavior visible at a glance;
it states the **active mode**, the **active scope** (Step 4 #2 — `selected-set` or `whole-board`,
so what the run will pick up is visible at a glance and "what's left" is never a surprise), plus
an **inline switch-path note on the same line** (edit the charter's `mode` field or re-run
`/surf` in the other mode; the supported way to change modes is always shown, never memorized —
consistent with the no-flags principle). **Scope is chosen at Step 5**, *after* this
first banner, so the very first (startup) banner shows `scope: pending` and the scope token
resolves to the chosen mode from the Step 5 selection onward — and at every Step 7 re-anchor (the
banner's main reprint point), the resolved scope is always shown:

In both templates below the renderer substitutes a **single resolved scope value** — exactly one
of `selected-set` / `whole-board` (or `pending` before Step 5) — the same way it picks the AUTO vs
SUPERVISED stanza; `scope: <…>` is a placeholder, not a literal menu of alternatives:

- **Autonomous:**
  > ▶ `/surf` running in **AUTO** · **scope: `<selected-set | whole-board | pending>`** — code
  > decisions are made-and-logged, never waited on; an unresolved domain call gets a bounded
  > window then best-bet-and-record. *To switch to checkpoints, edit the charter's `mode` field
  > to `supervised` — or stop and re-run `/surf` in the other mode.*
- **Supervised:**
  > ▶ `/surf` running in **SUPERVISED** · **scope: `<selected-set | whole-board | pending>`** —
  > domain calls pause for you (up to the Step 11 deadline); code decisions still auto-proceed.
  > *To stop being asked, edit the charter's `mode` field to `autonomous` — or stop and re-run
  > `/surf` in the other mode.*

The banner exists so a non-programmer never has to remember which mode is live or what it will
and won't ask about. The load-bearing distinction it makes plain: **AUTO means "don't bug me
about code," it never means "guess at my domain"** (see Domain gating, Step 11b). The inline
switch path lives on the **same line** as the mode so the supported change is always visible and
never something to look up.

**The supported switch path is charter-anchored and applied at the next issue boundary.** If the
operator needs a different mode, edit the charter's `mode` field; `/surf` picks that up at the
next Step 7 re-anchor, which re-reads the charter and re-prints the banner. The alternative is to
stop and re-run `/surf` in the other mode. Either way, the change is durable because it updates the
mode recorded in the charter (Step 4), but it still takes effect from the **next** issue,
**never mid-build** — an in-flight worker finishes under the mode it started in — so mode stays a
charter-anchored fact, not a volatile chat state. This is still **no `--flag`**: mode changes are
explicit run decisions, not hidden runtime keystrokes, in keeping with the no-flags principle.

### Step 0a: Choose the run-style - Sequential or Parallel

After the mode choice, ask a second `AskUserQuestion`:

> "How should /surf build this run?"

- **Sequential** - the explicit default, and identical to today. It keeps the one-issue-at-a-time
  behavior already shipped.
- **Parallel** - build in waves, with a manual concurrency cap.

Sequential is the default run-style and behaves exactly as today. Parallel is only chosen
interactively, never by a `--flag`, and it prompts for a **concurrency cap** in the inclusive
range **2–10**. Values outside 2–10 are rejected and the prompt repeats until a valid integer is
entered.

When Parallel is selected, `/surf` uses `python3 -m sail waves` to compute each wave and keep the
number of live builds under the cap.

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

### Step 2: Confirm `--dangerously-skip-permissions`

The autonomous loop runs unattended: it edits files, commits, and merges without pausing for
per-action permission prompts. That requires the session to have been launched with
`--dangerously-skip-permissions`.

**`/surf` cannot enable this itself.** It is a launch-time CLI flag, not a runtime setting and
not something in `settings.json`, so there is no way to switch it on mid-session.

- **Detect first.** If the launch environment exposes the bypass state (e.g. a permission-mode
  indicator in the environment), read it and confirm.
- **Otherwise ask.** If it cannot be detected, ask the user directly:
  > "Did you launch this session with `--dangerously-skip-permissions`? `/surf` needs it to
  > commit and merge without stopping for permission prompts. (yes / no — if no, please exit
  > and relaunch with the flag, then re-run `/surf`.)"

**Refuse the autonomous loop until this is confirmed.** Do not begin working issues, and do
not "work around" the missing flag by pausing on every action — that defeats the point of an
autopilot and produces a half-supervised run nobody asked for.

> **No tmux required by default.** Every issue is delegated to a **headless `claude -p` worker
> process** (Step 8), not a tmux-pane teammate, so the default `/surf` run needs no named tmux
> session — start it from any terminal. A named `surf` tmux session is **optional**, only for the
> supervised (panes) visibility lens in **Step 3b (optional)**.

### Step 3: Engine-availability check (both modes)

`/surf` delegates **every** issue to a headless `claude -p` worker that runs `/sail`
(Step 8). The deterministic prerequisite is therefore that **`claude` is on `PATH`** and this
session was launched with `--dangerously-skip-permissions` (Step 2) so the headless worker can
inherit a non-interactive permission posture.

- Confirm `claude` is on `PATH` (the worker is `claude --dangerously-skip-permissions -p "/sail
  <n> --unattended"`). If it is missing, stop and say so in plain language.
- The **agent-teams** feature (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: 1`) is **no longer required**
  for the default headless path — a `-p` worker is a depth-0 process that hosts `/sail`'s crew
  directly (Step 8). It is needed **only** if you opt into the supervised (panes) lens (Step 3b),
  which renders the run inside a tmux session.
- Recommend **opus** for this orchestrating session:
  > "For best results the `/surf` session should run **opus** — it makes all the merge and
  > park decisions. Switch now if you're not on opus."
- **Subscription preflight (#163, AC6).** The whole cap-recovery model assumes a **subscription**
  (usage caps reset on a schedule that `sail cap-recovery` parses and waits out). A run on an **API
  key** instead is billed/rate-limited differently and the reset-based recovery does not apply — so
  warn if this session is on an API key. Read the effective `apiKeySource` and classify it with the
  tested predicate (never eyeballed here): `apiKeySource=none` == no API key == subscription → quiet
  (the healthy case; #112: don't cry wolf on every normal run); anything else → an **ALERT-tier**
  WARN. The classification borrows convoy's `_convoy_check_apikeysource` as a *pattern* only:
  ```bash
  # $SRC is the session's apiKeySource (e.g. from the stream-json init event / claude config).
  python3 -m sail cap-recovery apikey-preflight --source "$SRC"   # rc 0 + quiet on 'none'; rc 1 + an ALERT line on an API key
  ```
  This is a **surface-once WARN, not a gate** — the run still proceeds; the operator just knows
  auto-resume across a usage cap will not fire on an API-key session.

### Step 3b (optional): Supervised (panes) visibility lens

This subsection is **optional** — it is the **supervised (panes) lens**, a way to *watch* the run.
It wraps the **same** headless worker substrate (the same per-issue `claude -p` process and the
same `.surf/runs/<n>` artifacts) inside a named tmux session so a human can attach a viewer. It is
**not** a different execution body: delegation, the result contract, and resume are identical to
the default headless run. Skip this entirely for an unattended run.

If you opt in, enable `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: 1` (so the framework can render panes)
and launch inside the canonical **`surf`** session:

```bash
# OPTIONAL supervised lens — only if you want to watch the run in panes.
tmux new -s surf
claude --dangerously-skip-permissions
#   …then at the Claude prompt:
/surf
```

**Monitor (optional lens):** attach from any terminal with `tmux attach -t surf`; detach without
killing the run with `Ctrl-b d`. Even in this lens the per-issue work runs in the same headless
worker process — the pane is a viewer, not the engine. Resume after a cap is the **same**
durable-file `/surf resume` relaunch the default uses (Step 16); the optional lens adds no separate
revive mechanism.

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
2. **Issue selection + scope mode** — the whole board or a subset, **and** an explicit **scope
   mode** that names how the run treats issues created *while it runs* (resolved in Step 5):
   **(a) selected-set** — build only the issues picked here, then stop (this is the **default**,
   and it preserves today's behavior — a fixed work list); **(b) whole-board** — build the whole
   board *including issues filed during the run*, re-listing the board each pass until no
   build-appropriate issue remains (the auto-pickup loop, Step 7c). This **names** a scope choice
   that used to be improvised per run; it does not change what selected-set does — it adds the
   whole-board auto-pickup behavior as an explicit, operator-chosen mode.
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

**Whole-board scope adds two charter fields (Step 7c anti-regress wiring).** When the scope mode
is **whole-board**, the charter also records: (a) the **refinement label** that marks run-filed
issues (default `surf-pilot`), and (b) the **generation-set file path**
`.surf/created-issues-<charter-timestamp>.md`. **Once whole-board scope is chosen at Step 5**,
`/surf` **creates that file empty** (and writes both fields back to the charter), so the
issue-filing site (Step 7c) only ever appends to an existing file and Resume (Step 15) can locate
it from the charter. Selected-set scope needs neither field.

---

## Minor-finding disposition — split by blast radius (#113)

`/surf` drives `/sail` per issue and **inherits `/sail`'s minor-finding disposition policy verbatim**
(the source of truth is the "Minor-finding disposition" section of `commands/sail.md`). When a worker
**catches** a minor issue mid-build that the issue did not call for, split by **blast radius**, never
by self-assessed "cheapness":

- **Trivial AND inside code already being touched AND zero behavior change → fix inline, logged
  visibly** ("also corrected X while editing Y", recorded via `DecisionLog.inline_fix_marker`). The
  hard ceiling is testable (`sail/disposition.py::inline_fix_eligible`): **single file, a few lines,
  no public-interface change, no new dependency, no new behavior.** A fix touching a **second file**
  or a **public interface** is **not** inline-eligible.
- **Genuinely out-of-scope → never expand the diff.** Capture it as a **deferred finding** (the
  guaranteed floor — the existing #103/#100 `DecisionLog`) plus an **optional** auto-filed one-line
  follow-up issue (reuse the #108 safe `--body-file`/fixed-title/fingerprint-dedup pattern). This
  composes with `/surf`'s own run-filed-issue handling: an auto-filed follow-up carries the charter's
  refinement label (default `surf-pilot`) so the whole-board anti-regress guard defers it, exactly
  like any other run-filed issue.

Both dispositions are reported **INFO-tier** per #112 ("also corrected X …" / "out-of-scope Y noted →
filed #N"), never silent — this is a scoped, guarded exception to Surgical-Changes §3, not a repeal.

---

## Issue selection

### Step 5: Pick the issues

List the board's open issues using the `/board` interface — `gh issue list` and, where a
project board is in use, `gh project item-list`. Present them as a readable list (number,
title, and any dependency note from the charter).

Then let the user pick interactively — **the whole board or a subset** — via `AskUserQuestion`
(this is an interactive selection prompt, never a flag). In the **same** interactive prompt,
record the **scope mode** (Step 4 #2): **(a) selected-set** (build only the issues picked) or
**(b) whole-board** (the auto-pickup loop — build the whole board *including issues filed during
the run*). Record the selected **issue set** *and the scope mode* in the charter; the per-issue
loop (Step 7) reads the scope mode to decide whether to re-scan the board each pass. The *order*
is not fixed here — **Step 5b** analyzes those issues and proposes the build sequence for approval.

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
   the charter, so the analysis is done **once, up front**, not re-derived mid-run. **Exception —
   whole-board scope (Step 4 #2b):** when the run picks up issues filed *during* the run, this
   same analysis re-runs as an **intake transaction** (Step 7c #3) over the remaining + newly-
   admitted issues, rewriting the ordered work list in the charter. Selected-set mode keeps the
   once-up-front guarantee; whole-board mode re-triages per intake because its work list is open.

---

## Context model

### Step 6: How `/surf` stays oriented across many issues

`/surf` runs **single-session by default**. It does *not* rely on `/compact` or on chat history
surviving — those are unreliable over a long board run. Instead:

- The **goal and current status live in the charter + journal files**, not in the conversation.
- At the **top of every issue**, `/surf` re-anchors by re-reading the charter (mission, scope,
  authority, guardrails) and the journal (what's merged, what's parked, where we are). This
  re-anchoring is what lets the run survive a long board without drifting.
- **Every issue is delegated to a fresh per-issue headless worker process** — never built inline
  (see Worker delegation). The orchestrator (the supervisor) does **not** run gates, edits, or
  reviews itself; it spawns a `claude -p` worker via the worker helper, then ingests only a
  **compact per-issue result** read from the worker's **run-dir artifacts** (`run-state.json` gates
  + `review.json` findings + a `wip-handoff.md` if parked — **not** the claude process exit code) +
  the merge SHA or park reason, and writes the detail to the journal. This is the core anti-drift
  property: because no build ever runs in the supervisor's own context, that context stays **flat
  regardless of board length** — a 5-issue board and a 30-issue board cost the supervisor roughly
  the same. Full delegation, not a pane cap, is what keeps context flat.
- **The supervisor keeps only a bounded running summary in context** — the per-issue
  compact results plus running counts (merged / parked / remaining). All per-issue detail lives
  on disk in the journal, which is the source of truth for `/surf resume` (Step 15), not the
  conversation.
- **Each worker only ever needs one issue's worth of context.** A fresh headless `claude -p`
  process per issue starts clean and exits at the issue's terminus, so neither the supervisor nor
  any worker accumulates a board's worth of history over a long run.
- **A hard stop and a usage cap both recover the same way.** If the run is killed outright — a
  crash, a machine reboot, or the Max-subscription usage window cutting it off mid-issue — the
  supervisor cannot re-anchor from chat at all. Recovery goes through **Resume (Step 15/16)**,
  which rebuilds board position from the charter + journal + git, not from the conversation. The
  default cap-recovery is the durable-file `/surf resume` **headless relaunch** (Step 16) — viable
  because a headless `-p` process hosts `/sail`'s crew (depth-0 subagents) just as well as an
  interactive session does.
- **Live-session marker.** At the start of the per-issue loop (Step 7), write `.surf/active`
  containing this process's PID, and **touch `.surf/heartbeat` at each checkpoint** (worker launch,
  each poll tick, each merge/park decision, and each journal write) while the run is active; while
  a worker is in flight, keep touching `.surf/heartbeat` at least every 10 minutes; **remove
  `.surf/active` on clean exit** (board exhausted, or the user stops the run). This is the marker
  the cap-recovery watcher (Step 16) checks: a **live** PID in `.surf/active` with a **fresh**
  heartbeat means a `/surf` is already running, so the watcher does **not** relaunch on top of it;
  at every heartbeat checkpoint, before performing the checkpoint action, re-anchor and stand down
  if `.surf/active` no longer holds this session's pid instead of double-driving the board. A
  *stale* marker (its PID is dead — the session was killed or the machine rebooted) is ignored and
  cleaned, and the watcher then relaunches `/surf resume` headlessly once the cap resets.

---

## Per-issue loop

### Step 7: For each selected issue, in order

Repeat this loop for every issue in the work list:

**Canonical branch naming.** Each issue is built by `/sail`, whose isolate path (the opening
bookend, #65) creates the branch **`sail/<issue>`** on a worktree **`.claude/worktrees/sail-<issue>`**
off **current `main`**. `/surf` **adopts** that branch + worktree rather than imposing its own
naming — so `sail/<issue>` is the one convention used everywhere downstream: merge, dependent
stacking (§10), and wrap-up (§14). (`/surf` keeps a small **coordination** namespace of its own at
`.surf/runs/<issue>/` for durable sentinels — the `.done` completion marker and the parked-issues
record — but it does **not** own the build branch or the build run-dir; the latter is `/sail`'s
discovered `.sail/runs/sail-<issue>-<timestamp>/`, see Step 2.) No other branch-naming scheme is used.

**Launch precondition — the supervisor must be on the default branch (`main`) when it launches each
worker (load-bearing).** The worker is a fresh headless `claude -p` process that **inherits the
supervisor's current branch**, and `/sail`'s isolate decision is branch-sensitive: from **`main`** it
creates `sail/<issue>` (the case `/surf` relies on), but **on a feature branch it stays in place and
commits on that branch** — so launching a worker while the supervisor sits on some other branch would
make `/sail` commit in-place there, and `/surf` would later merge/park a `sail/<issue>` branch that
was never created. `/surf` therefore **returns to `main` between issues** (and after the per-issue
land/park below) and re-confirms it is on `main` before each launch; if it is not, that is a setup
error to surface, not to build through.

1. **Re-anchor.** Re-read the charter and the journal. **Re-print the mode banner** (Step 0b)
   so the active mode + decide-vs-ask behavior stays visible at every issue boundary. Confirm
   this issue's dependencies have landed (or handle them per the Dependent issues section).
   State, in one line, what you're about to build and why it's next.
2. **Delegate the build to a fresh headless worker via the HARNESS, then POLL (do not block-wait).**
   The supervisor never builds inline. It asks the worker helper `config/surf-worker.sh` to **emit**
   the exact worker command, then launches it with the **Bash tool using `run_in_background: true`** —
   Claude Code's own background facility, which keeps the worker alive across turns and **owns its
   lifecycle and kill**. The supervisor does **not** daemonize anything in bash (pure-bash
   daemonization fights macOS — no `setsid`, no cross-tick survival, unsafe process-group kill; see
   Step 8b). The worker runs `/sail` in `--unattended` mode (the #108 front-door terminus), which
   itself creates the issue branch off **current `main`** (so a parent merged earlier in this run is
   already in the baseline) and runs the engine in its OWN fresh per-run run-dir
   (`.sail/runs/sail-<issue>-<ts>/`, discovered by `/surf`, see below):
   ```bash
   # 0. Record SPAWN_TS *BEFORE* launching the worker, and persist it durably. ORDER IS LOAD-BEARING:
   # /sail creates its run-dir `.sail/runs/sail-<issue>-<ts>` at the very START of the worker, so
   # SPAWN_TS must be <= that ts or the generation guard would filter out THIS worker's own run-dir
   # (skip ts < min_ts) and poll it forever as 'still building' (#136 review). Recording it first
   # guarantees SPAWN_TS <= the worker's run-dir ts.
   # Runs on EVERY (re)launch and OVERWRITES spawn-ts — a relaunch (resume / domain-answer) MUST
   # record a fresh SPAWN_TS so the guard admits only the new generation, not a prior attempt's dir.
   mkdir -p .surf/runs/<issue>
   SPAWN_TS="$(date -u +%Y%m%dT%H%M%SZ)"; printf '%s\n' "$SPAWN_TS" > .surf/runs/<issue>/spawn-ts
   # 1. The SUPERVISOR derives the injection-safe command (no forking happens here). The helper is a
   # bash library, but /surf's runtime shell is zsh — so invoke it through a bash SUBSHELL and
   # capture stdout; NEVER source a bash `set -e` library straight into the zsh runtime (it aborts on
   # the unbound BASH_SOURCE guard and leaks set -e — #128). Stable ~/.claude/lib path (symlinked at
   # install, INSTALL.md), not cwd-relative (#127).
   worker_cmd="$(bash -c '. ~/.claude/lib/surf-worker.sh && surf_worker_command <issue>')"
   #   worker_cmd is: claude --dangerously-skip-permissions --output-format stream-json --verbose -p "/sail <issue> --unattended <HEADLESS-WORKER CONTRACT …>"
   #   #168: the stream-json flags make the worker emit machine-readable `rate_limit_event` lines (the
   #   authoritative cap signal — Step 8 Layer-1). The supervisor tees the harness task output to
   #   `.surf/runs/<issue>/worker-stream.jsonl`; the merge/green decision still reads ONLY the durable
   #   run-dir artifacts, never this stream.
   #   The emitted prompt carries a headless-worker-contract clause (#139): a headless `claude -p`
   #   worker EXITS at turn-end and is never re-invoked, so the clause FORBIDS run_in_background /
   #   background `&` / ScheduleWakeup and REQUIRES the codex build+review stages to run synchronously
   #   in-turn through the Stage-4 commit terminus. Without it the worker backgrounds the long codex
   #   stages, ends its turn expecting a wakeup that never fires in a headless process, and dies
   #   mid-build with no run-state.json/review.json/commit.
   ```
   ```
   # 2. The SUPERVISOR runs THAT command with the Bash tool, run_in_background: true.
   #    The harness returns a background-task id and keeps the worker alive across turns. Record the
   #    task id + the already-captured SPAWN_TS (step 0) together.
   #    SPAWN_TS (UTC, the SAME format /sail names its run-dir suffix) is now DURABLE in
   #    .surf/runs/<issue>/spawn-ts and is re-read on every poll/resume — NOT only from live context,
   #    which a session compaction between launch and the next poll would lose, silently dropping the
   #    guard to an empty min_ts (#136 review). SPAWN_TS serves BOTH the wall-clock cap AND the
   #    run-dir GENERATION GUARD: it is passed as the 3rd arg to surf_worker_resolve_run_dir so a
   #    relaunch never resolves a PRIOR attempt's stale run-dir while this fresh worker is starting.
   #    (On resume, if the spawn-ts file is
   #    absent for an in-flight issue, treat it as a fresh launch and record one before polling.)
   ```
   **Parallel bookkeeping.** In Parallel mode the supervisor writes `.surf/runs/<issue>/.in-flight`
   when the worker is launched. If that worker returns green but is waiting for the serial merge
   gate, the in-flight marker is replaced with `.surf/runs/<issue>/.awaiting-merge` until the
   merge-time re-check runs.

   `/sail <issue> --unattended` is the worker's default engine (`/ship` is the optional heavier
   engine — see Step 8). It runs `/sail`'s **own front door** with whatever review allocation the
   environment carries; the **live shipped default** (`home/settings.reference.json`, per #83) is
   **codex builds** (`SAIL_BUILD_CMD="codex exec …"`) and a **single-lens `claude` review**
   (`SAIL_REVIEW_CMD` sonnet→opus). That is **cross-family by construction** — the codex
   implementer is reviewed by a different-family `claude` lens — so `SAIL_REVIEW_CMD2` is
   **intentionally unset** and `/sail` runs **single-lens-by-design**, *not* `--dual-lens` (re-adding
   a codex review lens over codex-built code would be same-family self-review — the #83 rubber-stamp
   risk). `/surf` does **not** pass `--dual-lens` or a `--run-dir` to the worker: `/sail` risk-gates
   its own lenses and names its own run-dir. Step 8 explains why these **CLI-subprocess lenses** (not
   `advisor()`) work inside a headless `-p` worker; the pre-merge guards below use
   `sail.review.dual_lens_status()` (lens2, #74) and `sail.review.redteam_status()` (red-team, #151)
   to compensate **only** a genuinely degraded review, never a correct `single`-by-design one — and
   to **park fail-closed** when a configured cross-family lens gated-for but cannot be re-run.

   **`/sail` owns the run-dir; `/surf` discovers it.** `/sail`'s front door (sail.md Stage 0) always
   creates its **own** session run-dir `.sail/runs/sail-<issue>-<UTC-timestamp>/` and ignores any
   external `--run-dir`; the isolate path (Stage 0.5) writes it **inside** the worktree
   `.claude/worktrees/sail-<issue>/`. So `/surf` cannot hard-code the path — it **resolves** the
   ACTUAL run-dir with `surf_worker_resolve_run_dir <issue>` (the newest dir containing BOTH
   `run-state.json` and `review.json`, searched across the repo root **and** the worktree) and feeds
   that to `surf_worker_result` (next):
   ```bash
   # The generation guard is read from the DURABLE spawn-ts file (survives a session compaction),
   # not just live context — resolve only THIS worker's run-dir, never a prior attempt's stale one.
   # VALIDATE the file value to a UTC-timestamp shape BEFORE splicing it into the inner `bash -c`
   # string: a corrupt/tampered spawn-ts could otherwise inject shell run under
   # --dangerously-skip-permissions (#136 review HIGH). A non-conforming value → empty (un-guarded).
   SPAWN_TS="$(cat .surf/runs/<issue>/spawn-ts 2>/dev/null || true)"
   [[ "$SPAWN_TS" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || SPAWN_TS=""
   run_dir="$(bash -c '. ~/.claude/lib/surf-worker.sh && surf_worker_resolve_run_dir <issue> "" "'"$SPAWN_TS"'"')" \
     || { echo "no terminus-bearing /sail run-dir yet — still building; re-check next tick"; }
   ```

   **Poll, don't block-wait.** A worker runs to a multi-hour wall-clock cap, but the Bash tool caps
   a single call at ~10 minutes — so the supervisor must **never** block-wait the worker. Instead it
   **polls across its own ticks**, reading the durable run-dir artifacts AND the harness
   **background-task status** (running vs exited) — **not** the `.done` sentinel, which the
   supervisor only writes *after* a green terminus is read and merged (it is a Step 15 resume
   marker, never a live-poll terminus signal). On each tick:
   - **task still running** (under the cap) → still building → move on; re-check next tick. This holds
     **even if a green-looking `review.json` is already on disk**: `/sail` writes `run-state.json` +
     `review.json` during Stage 3 review, *before* its Stage 4 commit, so a present-but-pre-commit
     review is **not** a terminus — the synchronous worker contract (#139) guarantees `/sail` commits
     (or parks) **before** the task exits, so **task-exit is the authoritative terminus signal**, not
     "artifacts present." Evaluating a still-running worker as green could merge a `sail/<issue>`
     branch that has no commit yet (#136 review).
   - **task still running, OVER the wall-clock cap** → the supervisor stops the worker via the
     **harness's background-task kill** (e.g. the task-stop / KillShell facility), **not** a bash
     `kill -pgid` → treat as a timed-out park. The cap is enforced by the supervisor comparing
     *elapsed-since-spawn* against the cap; there is no bash timeout helper.
   - **task EXITED** → only now evaluate the run-dir with `surf_worker_result` (next): it positively
     confirms green from `run-state.json` + `review.json` (and parks on a `wip-handoff.md`),
     **fail-closed** on any missing/incomplete artifact. (A genuinely crashed worker that wrote no
     `run-state.json` parks fail-closed here, and Step 15 resume re-launches a fresh `/sail` worker
     for the issue.)
   The **`.done`-absent ⇒ orphaned** rule belongs ONLY to Step 15 *resume* reconciliation — a fresh
   supervisor with no live harness-task context, discriminating a completed-but-unjournaled run from
   a true orphan.

   **The worker→supervisor contract is /sail's durable run-dir artifacts, NEVER the claude exit
   code.** The `claude -p` process exit code reflects the *claude process*, not `/sail`'s
   commit-vs-park terminus (decided inside the agent turn), so it is **informational only — never a
   decision input**. `surf_worker_result` reads the terminus SOLELY from the artifacts `/sail`
   writes into its **discovered** run-dir (`surf_worker_resolve_run_dir`, above):
   **`wip-handoff.md`** (present ⇒ the run PARKED), **`run-state.json`**
   (every gate `status` in `{passed, skipped}`), and **`review.json`** (status `completed`; no
   CRITICAL/HIGH finding; every plan-verification AC `met`; no blocking tidiness; **and review
   currency** — `diff_hash`/`plan_hash`/`target` match the live diff, so a stale review never merges).
   It is **GREEN only when positively confirmed** on all of these; anything else — a wip-handoff, a
   non-pass gate, a blocking finding, an unmet AC, a stale fingerprint, or a missing/garbage
   artifact — **parks**. There is no log-scraping or pane-reading on the result path.

   **Polarity — the merge gate is FAIL-CLOSED.** `surf_worker_result` parks on any ambiguity
   (missing/garbage run-state, unconfirmed/stale review): we must **never merge a run that is not
   positively confirmed green**. This is **distinct** from the worker *liveness* path (the harness
   task status + the supervisor's elapsed-vs-cap kill, Step 8), which is fail-OPEN (don't wedge a
   healthy run). Two jobs, two opposite safe directions: the merge contract fails toward **park**,
   the watchdog fails toward **proceed**.

   **Resume model.** `/sail` names a **fresh** timestamped run-dir on each launch, so `/surf` does
   **not** rely on a stable build run-dir; it resolves `/sail`'s actual run-dir **fresh on every
   poll** via `surf_worker_resolve_run_dir`. The durable resume state is `/surf`'s own: the per-issue
   **journal entry** (step 4) plus the coordination sentinels under `.surf/runs/<issue>/`. If a run
   is killed mid-issue, Resume (Step 15) re-launches a fresh `/sail` worker for the issue (which
   creates a new `.sail/runs/sail-<issue>-<ts>/`, discovered anew); a hard stop loses at most the
   single in-flight issue.
3. **Evaluate the result (`surf_worker_result`, NOT the claude exit code).** Invoke it the same way —
   a bash SUBSHELL — but `surf_worker_result`/`surf_worker_cleanup` are **DECISION** functions that
   signal via **exit status** (not stdout), so branch on the subshell's exit code (#128).
   **Gate on harness TASK-EXIT FIRST** — this is the authoritative terminus signal (the #139
   synchronous contract guarantees `/sail` commits *or* parks before the task exits). A
   still-running worker is NEVER evaluated, **even if a green-looking `run-state.json`+`review.json`
   already exists** — `/sail` writes those during Stage 3 review, *before* its Stage 4 commit, so
   resolving + merging on them mid-run could merge a `sail/<issue>` branch with no commit yet (#136
   review HIGH). Only once the task has EXITED do we resolve `/sail`'s run-dir and read the verdict:
   ```bash
   if <harness task still running>; then
     :   # still building → re-check next tick. Do NOT resolve/evaluate yet (a pre-commit review.json
         # present while the worker runs is NOT a terminus — only task-exit is).
   else
     # task EXITED → /sail has committed or parked. Now it is safe to resolve + evaluate.
     SPAWN_TS="$(cat .surf/runs/<issue>/spawn-ts 2>/dev/null || true)"   # durable generation guard
     [[ "$SPAWN_TS" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || SPAWN_TS=""            # reject a corrupt/tampered ts (no bash -c injection)
     if rd="$(bash -c '. ~/.claude/lib/surf-worker.sh && surf_worker_resolve_run_dir <issue> "" "'"$SPAWN_TS"'"')" \
        && bash -c '. ~/.claude/lib/surf-worker.sh && surf_worker_result "'"$rd"'"'; then
       :   # green → auto-merge (subject to the stacked-parent + degradation guards below)
     else
       :   # exited but NOT green, or no resolvable terminus dir (a crashed worker) → fail-closed park
     fi
   fi
   ```
   A `green` verdict requires the positive run-dir confirmation above (no `wip-handoff.md`; all
   `run-state.json` gates pass; clean `review.json`); anything else parks (fail-closed).

   **Cap-sensing layers & precedence (#166/#168/#163).** Three *distinct* layers, not one linear
   cascade — each with its own trigger:
   1. **Proactive sensor — `#166` statusline** (Step 16, at every issue boundary, account-wide): the
      token-free `.rate_limits` feed. It *avoids* the wall before launching the next worker and is
      independent of any worker's output. Unchanged by #168.
   2. **Reactive authoritative — `#168` `rate_limit_event`** (this Layer-1, after a worker exits
      not-green): the worker's stream-json event is the *authoritative* reset source when a worker
      actually hits the wall mid-build.
   3. **Reactive fallback — `#163` cap-text** (self-relinquish, and the watcher's plain-text tail):
      the retired-on-the-worker-path #126 regex, kept only where there is no structured event stream.
   Within the reactive path the precedence is **event → cap-text → not-cap (build-park)**; the
   proactive `#166` layer runs on its own schedule (Step 16) and is not a reactive cascade tier.

   **Layer-1 cap-recovery — detect a cap wall BEFORE parking (#163, #168).** The fail-closed park above
   is correct for a genuine build failure, but a **usage-cap wall is not a build failure** — a
   cap-refused worker often writes **no** terminus artifacts (no `run-state.json`/`review.json`, no
   `wip-handoff.md`), so `surf_worker_result` would park a perfectly good issue and the run would
   stall until a human noticed (the #148 incident). So on an **exited-but-NOT-green** verdict, and
   **before** recording a park, run a **separate** cap-detection branch — `surf_worker_result` stays
   artifact-only for the green/merge decision (it never scrapes logs); this branch reads the worker's
   **stream-json** output.

   **The AUTHORITATIVE signal is the worker's `rate_limit_event` (#168), NOT the #126 cap-text regex.**
   Because Step 8 launches the worker with `--output-format stream-json --verbose`
   (`surf_worker_command`), the worker emits machine-readable `rate_limit_event` lines carrying
   `status` / `rateLimitType` / `utilization` / `resetsAt` — the same signal convoy's `ship-tide.py`
   reads, and *fresher + false-positive-free* vs the minutes-stale statusline (#166) and the
   FP-prone cap-text regex (#126). The supervisor **tees the harness background-task output** (the
   JSONL stream) to a durable file and feeds it to the tested `sail cap-recovery rate-limit-event`
   parser (never eyeballed here, never a bash regex — CLAUDE.md infra placement; the stream is passed
   by **file**, never interpolated on the command line — OWASP LLM01, the stream can carry
   attacker-influenced diff/issue content). **The #126 cap-text regex is RETIRED on this worker path**
   — `resetsAt` is the sole reset source here (it remains only for the supervisor self-relinquish
   path below, which has no worker stream):
   The worker was launched (Step 8, `surf_worker_command`) with `--output-format stream-json
   --verbose`; the supervisor **tees the harness background-task output to
   `.surf/runs/<issue>/worker-stream.jsonl` BEFORE any cap decision reads it** — this durable JSONL is
   the parser's only input (surviving worker/supervisor death). The single arming path parses the
   authoritative event and arms in one call:
   ```bash
   # The worker's stream-json output (harness background-task output) is teed to this durable JSONL.
   WORKER_STREAM=".surf/runs/<issue>/worker-stream.jsonl"
   # `arm --log-file` parses the AUTHORITATIVE rate_limit_event (rejected, OR allowed_warning with
   # utilization >= the window threshold: 0.90 five_hour / 0.98 seven_day; the LONGEST-wait window
   # dominates) and arms the shared, durable, forward-only floor from its resetsAt. NO --text-file is
   # passed here → the #126 cap-text regex is RETIRED on the worker path (the event is the sole
   # signal). arm bypasses the cap-text classify, applies the post-reset margin + never-hot-loop floor
   # + wall-clock ceiling (>= 8 days), and pushes `.surf/resume-after` FORWARD (a replayed/older/
   # duplicate event can never move the floor backward). It writes BOTH .surf/resume-after (RFC3339)
   # AND .surf/runs/<issue>/cap-state.json (integer reset-after == usage_cap.reset_wakeup_epoch(...),
   # the value the #167 hop/wall-policy chain consumes — Step 16). arm PRINTS the RFC3339 wake on a
   # cap, nothing when it is not a cap. arm reads the stream from the FILE (never the command line —
   # OWASP LLM01), and fails OPEN on a missing stream (a worker that wrote none → not-a-cap).
   ARMED="$(python3 -m sail cap-recovery arm --surf-dir .surf --issue <issue> \
              --now "$(date -u +%s)" --log-file "$WORKER_STREAM")"
   if [ -n "$ARMED" ]; then
     # CAP WALL, not a build-park. Never relaunch immediately (the LOAD-BEARING invariant: zero
     # relaunches before resume-after). A supervisor death mid-wait is picked up by the Step 16 watcher
     # at the identical reset (scenario 9).
     echo "sail: [INFO] issue <issue> hit a usage cap (rate_limit_event) — armed resume-after=$ARMED; waiting for reset (no premature relaunch)."
     # ScheduleWakeup to the reset (+margin already folded into $ARMED). ONE correct long wait, not
     # many short probes. On wake, re-check the gate before relaunching:
     #   python3 -m sail cap-recovery gate --surf-dir .surf --now "$(date -u +%s)"  (rc 0 => relaunch this issue's worker once; rc 1 => still waiting)
     # A relaunch that re-caps just re-arms the floor FORWARD (never a give-up-by-count). Recovery is
     # bounded ONLY by the wall-clock ceiling.
   else
     :   # no rate_limit_event → genuine build-park; record the fail-closed park as before. (A cap the
         # worker didn't report on its stream is still caught account-wide by the #166 proactive check
         # at the next issue boundary — Step 16.)
   fi
   ```
   **Supervisor self-relinquish (scenario 5).** The branch above covers a *worker* cap while the
   supervisor lives. When the **supervisor's OWN** calls cap (it is alive but every call it makes is
   refused), it must not sit as a live-but-useless pid that locks the Step-16 watcher out (the
   watcher stands down whenever `.surf/active` names a live pid with a fresh heartbeat). So the
   supervisor calls the single-sourced **`sail cap-recovery relinquish --surf-dir .surf --now
   "$(date -u +%s)" --text-file "$SUPERVISOR_OUT"`**, which arms the **same** shared, forward-only,
   ceiling-bounded `resume-after` (global cap-state) **and** writes the durable **`.surf/capped`**
   marker in one call — then the supervisor **relinquishes** (stops its heartbeat keeper / exits).
   The watcher **consumes** that marker — a live pid **plus** `.surf/capped` is treated as
   recoverable — and takes over the relaunch at the armed reset. The marker is cleared on a clean
   (uncapped) relaunch (`sail cap-recovery clear --surf-dir .surf`), so it never sticks past recovery
   (a stuck marker would otherwise let the watcher double-drive a later healthy session).

   - **Green → auto-merge** — *but first, the stacked-parent guard.* Before merging,
     verify every dependency parent of this issue is **itself already merged to `main`**. If any
     parent is still parked, **park this dependent too** — never auto-merge a stacked branch whose
     base is not on `main`, because a branch stacked on a parked parent (branch-from-parent, §10)
     carries the parent's commits in the diff, can look green, and would smuggle the parent's unmerged
     work into `main` past its parked status.

     *Second pre-merge guard — the review-degradation check (#74, AC5).* Classify the worker's
     review with `sail.review.dual_lens_status()` — the single tested source of truth — and branch
     on the verdict. **Do NOT assume the worker built with `--dual-lens`:** the live shipped default
     (#83) is **single-lens-by-design** (codex builds, one cross-family `claude` review,
     `SAIL_REVIEW_CMD2` unset), so the *expected* verdict is the literal string **`single-by-design`**
     (exactly what `dual_lens_status()` returns when `dual_lens_requested` is false), not `ok`.
     - **`single-by-design`** → **NOT a degradation.** `--dual-lens` was never requested
       (`dual_lens_requested == false`); the single cross-family review is the intended quality
       mechanism. **Proceed to merge** — do **not** compensate, do **not** park. (False-parking a
       correct single-lens build was the #136 sub-gap C bug this guard now avoids.)
     - **`ok`** → a requested second lens genuinely ran → **proceed to merge**.
     - **`degraded`** → and **only** then — the predicate
       **`dual_lens_requested == true AND lens2_ran == false`** held (it keys off the explicit
       `lens2_ran` boolean, NOT `len(lenses)`: a high-stakes diff can add a `redteam` lens, so
       `lens1`+`redteam` with no `lens2` is length 2 yet still degraded). The requested second lens
       could not run, so the review degraded to single-lens — **do not merge yet.**
     Only on a `degraded` verdict, **run the missing second lens** yourself, soundly (three
     sub-steps, none skippable):
     1. **Re-review the issue's content, not nothing.** Check out the issue branch (or a worktree
        holding it) so the diff is real, then assert it is **non-empty** — a re-review from bare
        `main` produces an empty diff that comes back trivially clean and would silently wave the
        degraded build through. An empty diff means park, not pass.
     2. **Run it; trust the exit code for blocking; confirm the second lens genuinely ran.**
        `sail review`'s exit code already covers the FULL blocking verdict (findings, unmet ACs,
        code-health) — do not re-derive it. But exit 0 alone is insufficient here: a missing
        *second-lens* backend still lets `sail review` complete single-lens and exit 0 (lens1 passed,
        `status: completed`, `lens2_ran=false`) — that is the degraded case, and exit 0 does not
        prove the second lens ran. (Only when *no* lens runs at all does the review write a
        `status: skipped` artifact and fail closed at exit 1.) So require BOTH the run to exit 0 AND
        `dual_lens_status(review.json) == "ok"` (the tested classifier in `sail.review`, which is
        `ok` only when the second lens actually ran). Only then is it safe to merge:
        ```bash
        RD="$(bash -c '. ~/.claude/lib/surf-worker.sh && surf_worker_resolve_run_dir <issue> "" "'"$SPAWN_TS"'"')"  # /sail's actual run-dir (this worker generation)
        # Run the re-review INSIDE a subshell so the `cd` into the worktree NEVER leaks into the
        # supervisor's cwd — the land block below must keep running from the primary worktree root
        # (where `main` is checked out), or sail_merge_to_default's `git checkout main` would fail.
        (
          cd .claude/worktrees/sail-<issue> 2>/dev/null || git checkout sail/<issue>  # operate where /sail isolated the build (branch sail/<issue>)
          [ -n "$(git diff main --name-only)" ] || { echo "empty diff — park, do NOT merge"; exit 1; }
          SAIL_REVIEW_CMD2="codex exec -m gpt-5.5 -c model_reasoning_effort=high" \
            python3 -m sail review --target . --diff main --run-dir "$RD" --dual-lens
        ) \
          && python3 -c 'import json,sys; from sail.review import dual_lens_status; sys.exit(0 if dual_lens_status(json.load(open(sys.argv[1])))=="ok" else 1)' "$RD/review.json" \
          || { echo "compensation blocked, or second lens did not run — park, do NOT merge"; exit 1; }
        ```
     3. Merge only if step 2's verification passes. If the second lens still cannot run anywhere
        (codex unavailable in the supervisor context too, so `lens2_ran` stays false):
        **never silently merge** the single-lens build — park it loudly with the dual-lens
        degradation as the blocking reason, exactly like any other exit-1 outcome.

     *Guard mechanics.* This compensation path fires **only** on a `degraded` verdict — under the
     live single-lens-by-design default (#83) it never does (the verdict is `single-by-design`). When it does,
     the supervisor operates in the worker's worktree `.claude/worktrees/sail-<issue>` (branch
     `sail/<issue>`) **inside a subshell** so the cwd change is confined and the land block keeps its
     primary-worktree-root basis. The build already lives there — the worker has exited and released its lock by
     this point. The compensation re-review overwrites the worker's
     degraded `review.json` in place; that is intentional (the upgraded dual-lens review supersedes
     the single-lens one), and the degradation *event* is preserved in the run journal (step 4) —
     the audit trail lives there, not in `review.json`.

     *Third pre-merge guard — the red-team degradation check (#151, fail-closed).* The lens2 guard
     above covers **only** a missing dual-lens second pass. A diff that gated **for** the
     repo-exploring red-team lens (#66) — `is_high_stakes` true, e.g. it touches
     `SAIL_REDTEAM_SPINE_PATHS` — whose red-team never ran (`SAIL_REDTEAM_CMD` unavailable mid-run,
     or a codex-family red-team backend latched off via #107) would otherwise merge with only a
     post-hoc #116 INFO line — a **silent-degrade hole** inconsistent with the fail-closed merge
     gate. Close it with the tested `sail.review.redteam_status(review, backend_available=<live probe>)`
     — the single source of truth, mirroring `dual_lens_status` but split into compensable-vs-degraded
     by whether a red-team backend is available **now** (classified off configured-ness + live
     availability per #116, **never** the review.json latch marker, so a stale marker cannot wave a
     degraded diff through). Pass the live probe explicitly:
     ```bash
     RTS="$(python3 -c 'import json,sys; from sail.review import redteam_status, redteam_available; print(redteam_status(json.load(open(sys.argv[1])), backend_available=redteam_available()))' "$RD/review.json")"
     ```
     Branch on the verdict:
     - **`single-by-design`** → **NOT a degradation.** Either the diff did not gate for red-team, or
       no red-team backend is configured (the operator's expected single-lens setup — reported INFO
       by #116). **Proceed to merge** — do not compensate, do not park. (Auto-gated `redteam_requested`
       means an UNCONFIGURED backend must never false-park every high-stakes diff — the #136 lens2
       false-park lesson applied to red-team.)
     - **`ok`** → the gated-for red-team pass genuinely ran → **proceed to merge**.
     - **`compensable`** → gated for, configured, absent, and a red-team backend is available **now**
       → **do not merge yet.** Run the red-team pass yourself before merging, soundly (same three
       non-skippable sub-steps as the lens2 guard: check out the branch/worktree so the diff is
       **real and non-empty** — an empty-diff re-review comes back trivially clean and would wave the
       degraded build through; run it; then confirm `redteam_status == "ok"` on the overwritten
       `review.json`). Its findings feed the **normal disposition flow** — a CRITICAL/HIGH red-team
       finding blocks via `sail review`'s exit code exactly like any other, so a compensation that
       surfaces a blocking finding **parks**, it does not merge:
       ```bash
       (
         cd .claude/worktrees/sail-<issue> 2>/dev/null || git checkout sail/<issue>  # operate where /sail isolated the build
         [ -n "$(git diff main --name-only)" ] || { echo "empty diff — park, do NOT merge"; exit 1; }
         python3 -m sail review --target . --diff main --run-dir "$RD" --red-team    # SAIL_REDTEAM_CMD from env (availability already confirmed)
       ) \
         && python3 -c 'import json,sys; from sail.review import redteam_status; sys.exit(0 if redteam_status(json.load(open(sys.argv[1])), backend_available=True)=="ok" else 1)' "$RD/review.json" \
         || { echo "red-team compensation blocked or did not run — park, do NOT merge"; exit 1; }
       ```
       On a clean compensation, surface the distinct **compensated** label (AC6) via the tested
       reporter, then proceed to land:
       ```bash
       python3 -c 'import sys; from sail.review import redteam_gate_report; t,m=redteam_gate_report("compensated", sha=sys.argv[1]); print(f"surf: [{t}] #<issue> {m}")' "$(git -C .claude/worktrees/sail-<issue> rev-parse HEAD 2>/dev/null || echo pending)" >&2
       ```
     - **`degraded`** → gated for, configured, absent, and the backend is **still down** → the
       compensation **cannot run** → **PARK, never merge** (the fail-closed guarantee). This rides
       the **existing park path** (below): leave `sail/<issue>` + its worktree intact, write **no**
       `.surf/runs/<issue>/.done` sentinel, and record the parking note in the journal **and**
       `.surf/parked-issues.md` with the **explicit red-team-degraded reason** — so Resume (Step 15)
       reconciles it as an unmerged, `.done`-absent branch and re-launches a fresh worker, **never**
       silently re-merges the degraded build. Emit the ALERT via the same reporter:
       ```bash
       python3 -c 'from sail.review import redteam_gate_report; t,m=redteam_gate_report("degraded"); print(f"surf: [{t}] #<issue> {m}")' >&2
       # then take the "Not green (park) → park" path below with reason: red-team gated-for but backend down
       ```

     *Guard mechanics.* The compensation path fires **only** on a `compensable` verdict; under the
     live default (`SAIL_REDTEAM_CMD` set to a claude backend) a mid-run outage that recovers by
     merge time is compensable, while one still down parks. Operate in the worker's worktree
     `.claude/worktrees/sail-<issue>` **inside a subshell** so the cwd change is confined and the land
     block keeps its primary-worktree-root basis. The compensation re-review overwrites the worker's
     degraded `review.json` in place (the upgraded red-team review supersedes the single-lens one);
     the degradation *event* is preserved in the run journal (step 4).

     With all parents confirmed merged and both the dual-lens and red-team guards satisfied, **land** the
     issue via the **shared `sail land` logic** (the closing bookend, #59 — same source of truth
     `/sail` Stage 5 uses). The LOCAL git mechanics are single-sourced as `sail_merge_to_default` /
     `sail_prune_merged_branch` in `home/lib/sail-git-lifecycle.sh` (#82, tested by
     `tests/test_sail_82_land_lifecycle.sh`) — edit there, not inline; only the residual **network
     sequence** (`git push origin main` → `git rev-parse HEAD` → `gh issue comment` → the
     ls-remote-guarded `git push origin --delete`) stays duplicated with `/sail` Stage 5 and must be
     kept identical. Emit the closing artifacts from the
     already-produced review evidence, merge into `main` as a single `--no-ff` commit whose
     `Closes #<issue>` keyword **auto-closes the issue** (the board's native *Item closed → Done*
     automation then flips status — no `gh issue close`, no board API call), **record the merge
     SHA**, publish the review evidence as the closing comment, and prune the branch. `/surf` is
     unattended — it runs this **without pausing** (unlike `/sail`'s human-gated terminus). Then
     return to `main` for the next issue:
     ```bash
     RD="$(bash -c '. ~/.claude/lib/surf-worker.sh && surf_worker_resolve_run_dir <issue> "" "'"$SPAWN_TS"'"')"  # /sail's actual run-dir (.sail/runs/sail-<issue>-<ts>/, this worker generation)
     [ -f "$HOME/.claude/lib/sail-git-lifecycle.sh" ] && . "$HOME/.claude/lib/sail-git-lifecycle.sh"  # shared LOCAL land mechanics (#82)
     python3 -m sail land --run-dir "$RD" --issue <issue> --title "<title>" --prefix sail
     # LOCAL mechanics are single-sourced tested code (#82): --no-ff merge onto default + safe prune.
     sail_merge_to_default . sail/<issue> main "$RD/land-commit-msg.txt"   # checkout main + --no-ff merge; `Closes #<issue>` rides the msg file; prints the merge SHA
     git push origin main                                         # REQUIRED: only a merge on origin's DEFAULT branch fires GitHub auto-close + the board's Item-closed→Done automation; a local-only merge does neither
     git rev-parse HEAD                                            # capture this SHA into the journal/decision-log
     # #116 degraded-merge visibility. Both the lens2 AND red-team (#151) pre-merge guards run
     # BEFORE this point, so a CONFIGURED cross-family lens that gated-for is now either compensated
     # (re-ran → review.json shows it ran) or parked (never reaches here). The surviving note this
     # line surfaces is therefore the EXPECTED single-lens case — a lens gated-for but with NO
     # backend configured (INFO per #112, the operator's normal setup), never a silent
     # configured-but-down degrade. Surface it — never block (proceed-but-track per #108). The
     # published land-comment ALREADY carries the note (`sail land` emits it from review.json); this
     # adds the ALERT/INFO operator log line. Reads the merged review.json directly (no freshness args).
     DEGRADED="$(python3 -m sail degraded-review --run-dir "$RD" --sha "$(git rev-parse HEAD)")"
     [ -n "$DEGRADED" ] && echo "surf: [${DEGRADED%% *}] merged #<issue> under a DEGRADED review (${DEGRADED#* }) — a cross-family lens did not run; tracked in the land-comment, work accepted" >&2
     gh issue comment <issue> -F "$RD/land-comment.md"            # publish review evidence (reused, not re-derived)
     # Prune ONLY after the merge is on origin/main (`git push origin --delete` ignores merge state):
     sail_prune_merged_branch . sail/<issue>                      # `git branch -d` (never -D): refuses an unmerged branch; removes the branch's linked worktree (.claude/worktrees/sail-<issue>) first
     git ls-remote --exit-code --heads origin sail/<issue> >/dev/null 2>&1 && git push origin --delete sail/<issue> || true
     ```
   - **Not green (park) → park.** Any non-green verdict (a `wip-handoff.md`, a failed/pending gate,
     a CRITICAL/HIGH finding, a timed-out worker, an abnormal process exit, or any ambiguity) parks.
     Do **not** merge. **Parking** = leave the branch
     (`sail/<issue>`) and its worktree (`.claude/worktrees/sail-<issue>`) intact, do not merge, and
     write a **parking note** recording the issue
     number, the branch name (`sail/<issue>`), the blocking reason (the sail summary), and a
     recommendation. Write the parking note to the journal **and** to a parked-issues record at
     `.surf/parked-issues.md` under the gitignored `.surf/` — this is the defined source §14's
     wrap-up reads parked issues from. Leave the branch intact, then move on to the next
     independent issue.
4. **Journal the decision, then write the completion sentinel.** Append an entry recording the
   outcome (merged + SHA, or parked + reason), the alternatives weighed, and whether the result is
   reversible (see Recovery). **Then write the per-issue completion sentinel
   `.surf/runs/<issue>/.done`** (in `/surf`'s own coordination namespace — *not* `/sail`'s build
   run-dir) — the durable signal that this issue reached a clean terminus (built + reviewed +
   journaled). The sentinel is what lets Resume (Step 15) distinguish a completed-but-just-unmerged
   issue from an **orphaned** in-flight issue: an issue whose `sail/<issue>` branch exists, is
   unmerged, and has **no** `.surf/runs/<issue>/.done` is re-launched with a **fresh** `/sail` worker
   (which creates a new `.sail/runs/sail-<issue>-<ts>/`), never skipped as done.
5. **Resolve and clean up when the worker's task ends.** The harness owns the worker process, so
   there is no bash reaping or pane teardown here — the supervisor observes terminus via the **poll**
   in step 2 (harness task **EXITED** — the authoritative terminus signal; *not* "artifacts present",
   which can predate the Stage-4 commit, see step 2). Cleanup is then a thin,
   deterministic boundary:
   1. **The worker is bounded by a wall-clock cap, enforced by the supervisor + harness.** When the
      poll (step 2) sees the task still running **past** the cap (elapsed-since-spawn ≥ cap), the
      supervisor stops it via the **harness background-task kill** (task-stop / KillShell) — not a
      bash `kill`. That outcome is classified **timed-out** and **parks** the issue, never merges it.
   2. **Cleanup is safe.** Invoke it the same bash-subshell way (#128) — it signals via exit status:
      ```bash
      # Pass the resolved run-dir when one exists, else an empty run-dir — cleanup's worktree/branch
      # handling does not depend on it (a resolver miss must not abort cleanup).
      bash -c '. ~/.claude/lib/surf-worker.sh && rd="$(surf_worker_resolve_run_dir <issue> "" "'"$SPAWN_TS"'" || true)"; surf_worker_cleanup "${rd:-}" "sail/<issue>"'
      ```
      `surf_worker_cleanup` removes only what this worker created — `git worktree remove` runs
      **without `--force`** (so it refuses to drop uncommitted work — the safety net now that the
      harness, not a bash pid file, owns liveness), and `/sail`'s run-dir is **left in place**. It
      never force-deletes a directory tree. On a **merged** issue the build worktree
      (`.claude/worktrees/sail-<issue>`) was already removed by `sail_prune_merged_branch`; on a
      **parked** issue the worktree is deliberately left intact for resume. Only call cleanup once
      the poll confirms the task has exited.

   A fresh worker is spawned per issue (see Worker delegation); never carry one across issues.
   Full hang-detection of a *wedged-but-not-capped* worker (heartbeat/adaptive timeout) is a
   deferred follow-up (docs §5a / §7); the wall-clock cap above is the minimal boundary this land
   ships.

### Step 7c: Auto-pickup — re-scan the board each pass until it is truly empty (whole-board mode)

This step runs **only when the charter's scope mode (Step 4 #2 / Step 5) is (b) whole-board**. In
**(a) selected-set** mode the work list is fixed at Step 5b and this step is skipped — the run ends
when that set is exhausted. In **whole-board** mode the work list is *open*: the run keeps building
until the board is **truly empty**, picking up issues filed *during* the run — but under an
**anti-regress guard** so it provably terminates and never auto-builds work it shouldn't.

After each issue resolves (and before declaring the board exhausted at Step 14), **re-scan the
board**:

```bash
# Re-list open issues WITH labels hydrated — the anti-regress classifier (below) decides
# build-vs-defer by label, so labels MUST be present BEFORE that decision, not fetched after.
# A bare summary list is insufficient; --json …labels is REQUIRED.
gh issue list --state open --json number,title,labels
```

The cheap list above **only enumerates** candidate issue numbers and their anti-regress labels —
it is sufficient for the label half of the anti-regress guard (#1 below) but **not** for the
build-appropriate / park-class / dependency decision, whose signals (domain, irreversibility,
needs-validation, "depends on #N") live in the **body and comments**, not the title/labels. So
**before deciding build-vs-defer for any candidate, hydrate it** with the Step 5b issue-view data
**including comments** — `gh issue view <n> --json title,body,labels,comments` — since a
dependency, irreversibility, or needs-validation signal can live in a comment, not just the
body/labels. Then, for every open issue **not already in the work list**, decide build-vs-defer
on the **hydrated** issue:

1. **Anti-regress guard (load-bearing).** An issue the run *itself* filed as a refinement is
   **deferred to the backlog — not auto-built — without explicit operator opt-in.** Two signals
   classify it, used together:
   - **Charter-named label** — the human-legible classifier: any issue carrying a refinement label
     the charter names (default **`surf-pilot`**) is a run-filed refinement. This is read from the
     hydrated `labels` field above.
   - **Generation-set** — the provable-termination backstop: the set of issue **numbers the run
     created this session**. Any issue in that set is treated as run-filed even if its label is
     missing or mislabelled, so termination never depends on labelling discipline alone.

   **Where the generation-set lives, and how it is populated (load-bearing — the guard is inert
   without it).** The generation-set is a **durable file** under the gitignored `.surf/`, named by
   the **charter timestamp** so it is resume-discoverable: `.surf/created-issues-<charter-timestamp>.md`
   (one issue number per line). Its exact path is **recorded in the charter at creation**, so
   Resume (Step 15) — which already restores the latest `.surf/charter-*` — locates the run's own
   generation-set unambiguously (never a stale or merged set). **The orchestrator owns population
   deterministically** — not the ephemeral per-issue worker, which may exit before it records
   anything: **after each issue resolves, the supervisor records into the generation-set every
   issue the run filed that pass** (whether the supervisor or a worker ran the `gh issue
   create`), **before the next board re-scan**. Step 7c reads the file each pass; **Resume
   (Step 15) re-loads it before any re-scan** so a run cut off mid-board does not lose its
   generation-set and re-admit its own refinements on resume. An **empty** file means the run has
   filed nothing yet (the guard then rests on the charter-named label); a **missing** file on a
   whole-board charter — which created it at scope-selection time — is **corruption, not an empty
   set**: treat it as recovery (recompute the likely run-created issues and recreate the file), not
   a silent disabling of the backstop.

   A new issue matching **either** signal goes to the backlog (recorded for Step 14's wrap-up),
   never into the auto-build queue.

2. **Generation cap — bounded termination.** Issues filed by the run **do not re-enter the same
   run** (the generation-set guarantees this). This **provably bounds the run's own
   self-regeneration**: a board that regenerates *its own* refinements faster than it drains still
   terminates, because each pass only admits issues from *outside* the run's generation set — the
   refinement feedback loop cannot run forever. **Issues filed by *others* (users/bots) during the
   run** are a separate, genuinely-open input: they are admitted (that is the point of whole-board
   scope) and are bounded **not** by the generation-set but by the **cost/time cap** (a terminal
   state the wrap-up records as cap-hit). So the proof is precise: self-created refinements
   provably terminate; externally-created work terminates at the cap or when the board drains.

3. **Re-triage on intake (same rules) — an explicit intake transaction.** A genuinely-new,
   build-appropriate issue (not run-filed, not park-class) is **run through the same Step 5b
   triage + ranking** as the original selection before it is built — appended issues are **not**
   tacked onto the queue tail in arrival order, so the priority/dependency ordering "triaged by
   the same rules" implies is preserved. Concretely, whole-board mode performs an **intake
   transaction**: re-run the Step 5b analysis over **the not-yet-built remaining issues plus the
   newly-admitted ones**, write the **revised ordered work list** (plus dependency notes) back to
   the charter, and append the change to the decision-log (Step 12). This is the **one whole-board
   exception** to Step 5b's "analysis is done once, up front" rule — which still holds for
   selected-set mode; whole-board mode re-runs that same analysis per intake because its work list
   is open by definition.

4. **Park-class unchanged.** This step changes **nothing** about parking: a domain / irreversible /
   needs-validation issue still **parks** (Step 9, Step 11b), never best-bet-built — auto-pickup only
   decides *whether a new issue enters the build queue*, never relaxes the merge/park gate it then
   faces.

**Terminate when the board is truly empty.** "Truly empty" here means **no build-appropriate open
issue remains outside the full anti-regress predicate** — i.e. outside **both** the run's
generation-set **and** the charter-named refinement label(s) — not literally zero open issues. The
loop ends when a re-scan finds no such issue — i.e. every remaining open issue is either run-filed
(backlog, by either anti-regress signal), park-class (parked), or already resolved.
Record the **termination cause** — **board-empty** (no build-appropriate issues left) vs a
**cost/time cap** hit — for the wrap-up, so a capped run is never mistaken for a drained board.

### Parallel wave scheduler

When the run-style is **Parallel**, the board is worked in **waves**. A wave is the set of
issues whose dependencies are all already merged to `main` in the Step 5b graph. `/surf` computes
the next scheduler tick with a **single composed call**, `python3 -m sail waves state`, passing it
the Step 5b dependency graph, the manual `--cap`, the set already `--merged` to `main`, and — this
is load-bearing — the live issues: those `--in-flight` (a worker is building) and those
`--awaiting-merge` (built green, queued for the serial merge re-check). `waves state` returns both
the `eligible` set and the `launchable` set in one shot:

- **Eligibility excludes every live issue.** A wave-eligible issue has all its deps merged to
  `main` **and** is not itself in-flight or awaiting-merge — so an issue already being worked is
  never re-offered or duplicate-launched. (Passing the in-flight + awaiting-merge sets is mandatory;
  the lower-level `waves eligible`/`waves launchable` subcommands exist but the composed `waves
  state` call is what `/surf` drives, precisely because it cannot forget to exclude the live set.)
- **The cap counts concurrent _builds_.** `launchable` never exceeds the manual cap counting only
  the **in-flight builds**; an awaiting-merge branch has finished building, so it holds no build
  slot (it is excluded from eligibility, but it does not starve the cap).

`/surf` launches the `launchable` issues, then after **each merge** re-runs `waves state` against
the updated `main`, so any issue newly unblocked by that merge joins the **next** wave. Sequential
mode skips this entirely and keeps today's one-at-a-time behavior.

---

## Worker delegation (headless worker for every issue)

### Step 8: Delegating every issue to a headless `claude -p` worker

**Every** issue is built by a fresh per-issue **headless `claude -p` worker process** — never
inline, and this is the same in **both** run modes. The supervisor (this `/surf` session) is a
**thin LLM loop**: it makes the merge/park judgment, asks `config/surf-worker.sh` to **emit** the
worker command, and launches it via the **harness `run_in_background` Bash facility** (which owns
the worker's lifecycle and kill — see Step 8b). The operator interacts only with the supervisor —
never directly with a worker process; a worker is a fire-and-background build task, not a chat
partner. One worker per issue:

```bash
# The helper is a bash library; /surf's runtime shell is zsh — so invoke it through a bash SUBSHELL
# and capture stdout (never source a bash `set -e` lib into the zsh runtime — #128). Stable
# ~/.claude/lib path (symlinked at install, INSTALL.md), not cwd-relative (#127):
worker_cmd="$(bash -c '. ~/.claude/lib/surf-worker.sh && surf_worker_command <issue>')"
#   worker_cmd PRINTS (no fork): claude --dangerously-skip-permissions --output-format stream-json --verbose -p "/sail <issue> --unattended <HEADLESS-WORKER CONTRACT …>"
#   #168: the worker launches with stream-json output so it emits machine-readable `rate_limit_event`
#   lines — the AUTHORITATIVE cap/reset signal (Step 8 Layer-1). The supervisor TEES the harness
#   background-task output (the JSONL stream) to `.surf/runs/<issue>/worker-stream.jsonl` so the cap
#   parser can read it from a durable file (survives worker/supervisor death). The merge/green
#   decision still reads ONLY the durable run-dir artifacts (never this stream).
#   The emitted prompt carries a headless-worker contract (#139) forbidding run_in_background /
#   background `&` / ScheduleWakeup and requiring synchronous codex build+review to the Stage-4
#   commit terminus — a headless `-p` worker exits at turn-end and never gets a wakeup, so a
#   backgrounded stage would die mid-build (no run-state.json / review.json / commit).
# The supervisor then runs THAT command with the Bash tool, run_in_background: true (harness-owned
# lifecycle). It records the harness task id + the spawn time for the wall-clock cap.
```

**Why a headless `claude -p` worker hosts the crew (the load-bearing fact).** `/sail` (and `/ship`)
**spawn their own crew** (compass / leadsman / red-team / board). A top-level headless `claude -p`
process is **depth-0**, and `/sail`'s lenses are ordinary CLI subprocesses (`claude -p` /
`codex exec`) and Agent-tool subagents — **not** agent-team teammates — so they nest comfortably
inside a `-p` process: the depth-5 subagent-nesting limit never bites at depth-0. A `-p` worker
therefore hosts `/sail` with its full crew. (This corrects the prior premise that "only a teammate
can host the crew / agent teams cannot run headless"; that premise is now verified FALSE — see the
decision record below and docs §4.) There is no need for the agent-teams feature on the default
path, and no tmux pane.

**Engine: `/sail` by default, `/ship` optional.** The worker runs **`/sail`** in `--unattended`
mode (the #108 front-door terminus), with its **own** front-door run-dir and review allocation —
`/surf` passes neither `--run-dir` nor `--dual-lens`. The **live shipped default** (#83) is **codex
builds** with a **single-lens `claude` review** (`SAIL_REVIEW_CMD2` intentionally unset); the codex
implementer reviewed by a different-family `claude` lens is **cross-family by construction**, so the
review is genuine **single-lens-by-design**, not `--dual-lens` (re-adding a codex review lens over
codex-built code would be same-family self-review — the #83 rubber-stamp risk). These lenses are
**CLI subprocesses** (`claude -p` / `codex exec`), with no `advisor()` dependency, so they are
reachable inside the headless worker exactly as inside the supervisor (#74; see Step 7's degradation
guard, which compensates only a genuinely `degraded` review — never a correct `single`-by-design
one). **`/ship`** is the optional heavier engine for an unusually demanding issue. Both write the
durable run-dir artifacts `/surf` discovers and reads.

**Worker→supervisor result contract (durable artifacts, fail-CLOSED).** The supervisor resolves
`/sail`'s actual run-dir (`surf_worker_resolve_run_dir <issue>` — `/sail` names its own
`.sail/runs/sail-<issue>-<ts>/`, not a surf path) and reads the outcome with
`surf_worker_result <run-dir>`. The **claude `-p` exit code is IGNORED for the
decision** — it reflects the claude process, not `/sail`'s commit-vs-park terminus (decided inside
the agent turn), and the harness, not the exit code, tells the supervisor whether the task is still
running. The verdict is read SOLELY from `/sail`'s durable artifacts: **`wip-handoff.md`** (present
⇒ parked), **`run-state.json`** (every gate `status` in `{passed, skipped}`), and **`review.json`**
(status `completed`; no CRITICAL/HIGH; every plan-verification AC `met`; no blocking tidiness; **and
review currency** — `diff_hash`/`plan_hash`/`target` match the live diff via `sail.review`
fingerprints, so a STALE review never merges). It is **GREEN only when positively confirmed** on all
of these; otherwise → **park**. These structured artifacts are the **only** result signal — never
the worker's stdout, log, exit code, or any pane.
**Polarity: FAIL-CLOSED** — any ambiguity (missing/garbage run-state, unconfirmed/stale review)
**parks**; we never merge a run that isn't positively confirmed green. (This is the opposite of the
worker *liveness* path below, which is fail-OPEN so a healthy run is never wedged.)

**Injection-safe boundary.** The issue id is **numeric-validated** (`^[0-9]+$`) before it appears in
the emitted command; `surf_worker_command` embeds only that validated integer (no string
interpolation of arbitrary text, no indirect execution); and any user/domain answer reaches the
worker only **via a file** referenced by path (Step 11b) — never interpolated onto a command line.

**Liveness/cleanup boundary (harness-owned).** The worker is a **harness background task**, so its
lifecycle and kill are the harness's job, not bash's. Liveness is the supervisor's **poll**
(Step 7 step 2): each tick reads the harness task status (running vs exited) and compares
elapsed-since-spawn against the wall-clock cap; on overrun it stops the worker via the **harness
background-task kill** (task-stop / KillShell), then classifies it **timed-out → park**.
`surf_worker_cleanup` removes only what the worker created (`git worktree remove` **without
`--force`**, run-dir left as the resume checkpoint). There is **no** bash process-group kill,
PID-reuse pid-file guard, or `surf_worker_wait`/`surf_worker_pgkill` — pure-bash daemonization was
removed (Step 8b: it fights macOS). Full hang-detection of a *wedged-but-not-capped* worker
(heartbeat/adaptive timeout) is a **deferred follow-up** (docs §5a) — the wall-clock cap is the
minimal boundary here.

**Worker model.** Workers inherit the orchestrating session's tier by default — e.g. an opus
supervisor spawns opus workers (`--unattended` runs `/sail`, whose own backends are configured via
the `SAIL_*` env, so the worker need not be told a model). `/surf` builds quality-critical issues,
so the build host should match the manager's tier rather than drop to sonnet.

**Foreground interactive orchestrator only.** The `/surf` supervisor itself stays in the
foreground as the live interactive session; it is not a background job. That is the shape proven by
the Stage-1/2 lock-survival runs, and it avoids the #157 background-reap failure mode that killed a
backgrounded supervisor on lock. Only the per-issue worker is delegated to the harness background
task.

**Fresh worker per issue, reaped at terminus.** Spawn a new worker for each issue; it exits at the
issue's terminus and is `wait`-reaped (Step 7 step 5). Never reuse a worker across issues — stale
context is exactly the drift `/surf` is built to avoid.

> **Optional supervised (panes) lens.** Step 3b's panes are a visibility wrapper over this **same**
> worker substrate — not a second execution body; same result contract and resume path.

**Recommended deferred — parallel workers.** This land runs workers **sequentially** (one issue at
a time), matching convoy's proven floor. Running independent issues concurrently (a bounded worker
pool ordered by the Step 5b dependency DAG) is a **recommended follow-up**, deferred so the
single-worker cleanup/identity/resume surface is proven first — see docs §7.

### Step 8b: Reuse-vs-optimize decision record (#124)

The #124 body swap reuses what `/convoy` proves useful but puts the **worker lifecycle on the
harness instead of bash**. The authoritative **per-mechanic decision table** (reused vs. done
differently, each with a rationale + best-in-class citation) and the two load-bearing lessons (the
#73 "only a teammate can host the crew" premise **verified false**; the platform-fit lesson) live in
`docs/surf-convoy-comparison-and-backlog.md` **§7**. The contract those mechanics implement is
stated at its point of use in Steps 7–8 above; §7 is the single home for the full table — do not
re-narrate it here.

---

## Merge policy

### Step 9: Auto-merge green, park everything else

The merge rule is simple and strict, and — since #124 — the green/park decision is read from the
worker's **durable run-dir artifacts**, not from any process exit code (see Worker delegation,
Step 8, for the full contract):

- **Auto-merge everything GREEN.** Green is **positively confirmed** by `surf_worker_result` from
  the run-dir: no `wip-handoff.md`, every `run-state.json` gate `passed`/`skipped`, and a
  `review.json` that is `completed` with no CRITICAL/HIGH finding, every AC `met`, no blocking
  tidiness, and current (not stale). Only then is the issue merged as one `--no-ff` commit and its
  SHA logged.
- **Park everything else.** Anything not positively confirmed green — a `wip-handoff.md`, a
  non-pass gate, a CRITICAL/HIGH finding, an unmet AC, a stale/garbage/missing artifact, or any
  issue with an unanswered question past its deadline the charter says `/surf` may *not* decide — is
  parked with a written note, never merged.

**Parallel merge safety.** In Parallel mode, a green worker does **not** merge immediately. `/surf`
writes `.surf/runs/<issue>/.awaiting-merge`, then immediately before the merge it reruns
`python3 -m sail run --diff main` against the current `main` so the branch is re-validated against
the moved baseline. Green at re-check time means one `--no-ff` merge and a logged SHA; not-green
means park the branch instead. Sequential mode keeps the merge path unchanged and stays one-at-a-time.

**Safety property — the contract is fail-closed.** The decision **ignores the worker process exit
code** (informational only — it reflects the `claude -p` process, not `/sail`'s commit-vs-park
terminus, and is unreliable across the macOS spawn fallback). `/sail`'s own review is fail-closed
inside the worker — a missing review backend makes the run not-green — and that surfaces to `/surf`
as a `review.json` that is not `completed` (or absent), which `surf_worker_result` treats as
**park**. So a run with no review backend is **parked, never silently auto-merged**: any ambiguity
fails toward park, never toward merge.

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
  **branch-from-parent** — create the dependent branch (`sail/<issue>`) off the parent's
  (unmerged) branch (`sail/<parent-issue>`) using plain git, so the dependent work builds on the
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

In autonomous mode there is no *blocking* wait: code decisions the charter authorizes are
made-and-logged immediately, and an unresolved **domain** assumption gets only a **bounded**
window before best-bet-and-record (Step 11b) — it never idles indefinitely; anything genuinely
irreversible or the human's alone is parked.

---

## Domain gating

### Step 11b: Domain-gated input windows (auto-for-code / ask-for-domain)

The deepest division of labor in `/surf` is **who owns which decision**: the agent owns
**coding** decisions, the user owns **domain** decisions (formulas, thresholds, what "done"
means for a feature). A naive autopilot would silently *guess* at domain calls and never
surface them — the real risk as `/surf` takes on domain-bearing issues, not just infra. Domain
gating is the guard, and it is **one primitive with mode-dependent behavior** (the mode banner,
Step 0b, states which behavior is live):

**What gates, and what doesn't.**

- **Coding decisions** — reversible, in-scope, unambiguous (a broken/non-hermetic test, a
  naming or refactor call, a clear code-quality fix, inserting a discovered fix-issue, a
  merge/park call) — are **always** made-and-logged, in **both** modes. This is the
  "fix, don't wait" Rule; `/surf` never opens a window for a code decision.
- **Domain assumptions** the plan **cannot resolve from the run's charter, `.ship/domain.md`, or
  the issue text** open a **user-input window**. `/surf` checks all three *first* — but the
  **charter's decision-authority (Step 4 #4) is the current run's intent and takes precedence**:
  where the charter and a stale `.ship/domain.md` entry disagree, the **charter wins** and the
  question is re-opened rather than silently suppressed by old memory. Only a genuinely unresolved
  domain assumption — unanswered by charter, memory, and issue alike — opens a window. This mirrors
  `/sail`'s risk-gated `--dual-lens` pattern, applied to *human* input.

**One primitive, mode-dependent behavior.** The user-input window is a **single mechanism**
whose behavior is **mode-dependent**:

- **Supervised:** the domain question is recorded and **waits for the user** — it **flows
  through** the **Step 11** open-questions file + ~30-minute deadline (record the question, work
  other independent issues meanwhile, re-check at every checkpoint, decide-and-log only if the
  deadline passes unanswered). Supervised therefore *asks within the deadline* rather than
  hard-blocking the whole board.
- **Autonomous (`/surf` board-run):** the window is **bounded** — `/surf` gives a short window,
  then **takes the best bet, records the options it weighed and the route it chose** in the
  decision-log for the user to review later, and keeps going. This preserves the unattended-run
  guarantee (never wait forever if the user is away); the audit trail is what lets the user
  adjust the domain call afterward.

**Even AUTO surfaces domain pauses.** Autonomous = **"don't bug me about code"** — it is
**never** "guess silently at my domain." A domain assumption in AUTO still opens the bounded
window and still records the options + chosen route; AUTO only removes the *code* questions, not
the domain ones. A domain call that is genuinely **irreversible** or has **no defensible
default** is **parked** with a written recommendation (the only "stop" path — Guardrails,
Step 13), never best-bet-guessed.

**Domain input under the headless worker (file-mediated park→answer→re-launch).** A headless
worker cannot prompt the operator mid-build, so an **unresolved domain assumption parks the
worker**: the worker writes the question to `.surf/open-questions.md` (a file, never an interactive
prompt) and exits blocking. The supervisor surfaces it per the mode above; on an answer, the
supervisor **re-launches that issue with a fresh `/sail` worker** — the answer reaches the
worker only **via a file** (the open-questions file the worker re-reads, mirroring `/sail`'s
`--body-file` convention), **never** interpolated onto the worker's command line. The fresh `/sail`
run creates a new `.sail/runs/sail-<issue>-<ts>/` (its per-run gate state, #105, is internal to that
run-dir). `/sail` now re-reads `.ship/domain.md` on each plan/review invocation, so a domain
answer written between checkpoints is picked up at the next checkpoint with no separate
re-launch; the park-then-relaunch path remains for the unresolved headless-worker question itself.

**`.ship/domain.md` is the memory that stops re-asking — but only *confirmed* answers persist.**
A **user-confirmed** domain answer is written back to `.ship/domain.md` so the same question is
not asked twice. An **autonomous best-bet is not** a confirmed answer: it is recorded as
**provisional** in the decision-log (the options weighed + the route chosen) and is **not**
promoted into durable `.ship/domain.md` memory until the user confirms it — otherwise a wrong
guess would silently suppress the very prompt that would have caught it. Teach the crew the
confirmed answers via **`/train`** (which maintains `.ship/` domain knowledge) and future runs
pause less: a well-trained `.ship/domain.md` is what makes a domain-bearing board runnable
unattended (more training → fewer windows → closer to fully autonomous).

---

## Recovery / decision-log

### Step 12: Append-only journal + structured decision-log

Every run keeps two artifacts under `.surf/` (gitignored). **One run timestamp, generated once at
charter creation (Step 4), names all of the run's files** — `charter-<timestamp>.md`,
`journal-<timestamp>.md`, `decision-log-<timestamp>.md`, and (whole-board scope)
`created-issues-<timestamp>.md` — so a charter is unambiguously paired with its own journal and
generation-set by the shared suffix (the revive watcher and Resume rely on this pairing):

- **An append-only journal** at `.surf/journal-<timestamp>.md` — a running narrative of the run:
  which issue was picked, what `/sail` returned, what was merged or parked, and why. Append only;
  never rewrite history in the journal.
- **A structured decision-log** at `.surf/decision-log-<timestamp>.md` — a dedicated file under
  the gitignored `.surf/`, one entry per decision, each recording:
  - the decision and the **alternatives weighed**,
  - whether it is reversible,
  - and, for a merge, the **merge SHA**.

For Parallel runs, the journal also records durable phase markers: `.surf/runs/<issue>/.in-flight`
while a worker is live, and `.surf/runs/<issue>/.awaiting-merge` after a green build has passed the
worker phase but is waiting for the serial merge re-check.

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
- **Convergence discipline is `/sail`'s, and it is codified (#77).** Each issue's plan/review
  convergence loops run inside `/sail`, which has no human to answer "continue / abort / proceed"
  unattended. `/sail` owns the autonomous-mode convergence rubric — see **`commands/sail.md` §
  Autonomous-mode convergence rubric**: (a) a plan risk the plan itself already mitigates is recorded
  (`disposition: self-mitigated` + rationale) and proceeds rather than burning rounds; (b) `exit 0`
  is the stop signal — non-blocking LOWs are never chased past green; (c) the driver consults the
  deterministic `sail converge` oracle (`proceed | revise | park | proceed-hardening | proceed-dissent`) with a trend-stall +
  wall-clock cost backstop (and a hard `--max-rounds` ceiling as the ultimate backstop, #130) as the
  genuine-non-convergence guards. `/surf` relies on this discipline so a single issue can neither
  burn its round budget nor park sound work; when `sail converge` returns `park`, `/surf` parks the
  issue per the rule above. On **`proceed-dissent`** (#108 — a red-team finding objecting to the
  issue's *mandated* design on an otherwise mechanically-sound run), `/surf` runs `/sail`'s
  **tracked-dissent terminus**: the branch is committed but **land-blocked** — `/surf` does **not**
  auto-merge it; it opens the `human-review` issue and parks the issue with a durable handoff so a
  human resolves the objection before any merge (never auto-merge over a spec-premise dissent).

---

## Wrap-up

### Step 14: Plain-language final summary

When the work list is exhausted (or the user stops the run), write a **final summary** for the
user — who is a non-programmer, so keep it plain and concrete. Include:

- **What merged — the revert map.** A simple table mapping each merged **issue → SHA**, so the
  user (or a future session) can undo any one of them with `git revert <sha>`. This issue→SHA
  revert map is the single most important deliverable of the summary.
- **What was parked and why.** Read from `.surf/parked-issues.md`: each parked issue, the reason it
  didn't go green, and the branch it lives on (`sail/<issue>`) so it can be picked up later.
- **Active scope + what was deferred to the backlog.** State which **scope mode** was active
  (`selected-set` or `whole-board`, Step 4 #2) and the **termination cause** (board-empty vs a
  cost/time cap). In whole-board mode, list the explicit **issue numbers deferred to the backlog**
  by the anti-regress guard (Step 7c) — run-filed refinements (e.g. `surf-pilot`-labelled) that were
  *not* auto-built — so "what's left" is never a surprise and the next run reconciles cleanly by
  re-listing `gh issue list --state open`.
- **Open questions left.** Anything from `.surf/open-questions.md` that was decided-by-deadline
  (with the decision and that it's reversible) or is still genuinely open.
- **Recommended next steps.** In plain language: what to look at first, what to re-run, what to
  hand back to a human.

Point the user at the journal and decision-log (`.surf/journal-<timestamp>.md`) for the full
detail behind the summary.

**Mark the run done (scope-aware).** Exhaustion is defined **per the charter's scope mode**:
in **selected-set** mode the board is exhausted when **every selected issue** has a terminal
outcome (merged, parked, or won't-fix); in **whole-board** mode it is exhausted only when a
**Step 7c re-scan finds no build-appropriate open issue remaining** (per Step 7c's termination
test — outside **both** the generation-set and the charter-named refinement label(s)) *and* the
run was not stopped by a cost/time cap or the user (a cap-hit run is **not** done — it is left
resumable). When exhausted, record that this run is finished so the auto-resume watcher
(Step 16) goes quiet: append a `- done: board exhausted <ISO>` line to the journal **and** write a
marker file `.surf/<charter>-done`. The done-marker is the **authoritative quiet signal**: the
work-remaining gate in Step 16 treats it as "nothing to resume," so the watcher stops reviving
a completed run. (If the marker is already present from a self-healing resume — see Step 15 — keep
it.) A user-stopped (not exhausted) run is **not** marked done — it is left resumable on purpose.

**A deliberate user-stop writes a paused sentinel (#124 R5-5).** A run the operator stops on
purpose (not board-exhausted) writes `.surf/<charter>-paused`. This is **distinct from a cap-stop**:
the Step 16 watcher's `should_launch` gate treats the paused sentinel like a done-marker (it does
**not** auto-relaunch a deliberately-paused run), whereas a usage-cap stop writes no sentinel and so
is auto-resumed. `/surf resume` **clears** the paused sentinel on re-entry, restoring auto-recovery.
Do **not** write it for a cap-stop or a crash (those should auto-resume).

**Remove the live-session marker.** On any clean exit — board exhausted or user-stopped — delete
`.surf/active` (the PID marker written at Step 7) so the cap-recovery watcher (Step 16) sees no
live session and does not relaunch on top of a finished run.

### Step 14b: Teardown — stop any in-flight worker task (every stop path)

A headless worker normally exits at its issue's terminus (the harness task ends), so a clean
board-exhausted stop usually has nothing left to stop. But a run can stop **mid-issue**, so teardown
is **mandatory on every stop path**, not just the happy one:

- **Board exhausted** (Step 14 wrap-up),
- **User-stop** (the user halts the run mid-board),
- **Error / abort** (an unrecoverable failure ends the run).

On any of these, before the process exits:

1. **Stop the in-flight worker task via the harness.** If the worker's harness background task is
   still running, stop it with the **harness background-task kill** (task-stop / KillShell) — the
   harness owns the worker's process group, so there is no bash `kill` here. (The supervisor knows
   the live task id from when it backgrounded the worker in Step 7.)
2. **Safe cleanup.** Call `surf_worker_cleanup` for the in-flight issue — `git worktree remove`
   without `--force` (refuses to drop uncommitted work), never a force directory delete. The stable
   run-dir is **left in place** as the resume checkpoint (Step 15 re-uses it).
3. **No tmux teardown on the default path.** There are no per-issue panes to kill — the default run
   uses no tmux. *(In the optional supervised lens, Step 3b's tmux session and its agent-teams
   panes are torn down by the framework when the session ends; the worker substrate underneath is
   reaped exactly as above.)*

This holds for **long runs** too: because each worker is reaped at its own issue boundary
(Step 7 step 5), teardown at the end normally has only the current in-flight worker (if any) to
reap, so a 30-issue run ends as clean as a 1-issue run.

---

## Resume

### Step 15: Resuming after a stop

A `/surf` run can be cut off mid-board — a usage-cap window, a crash, a reboot, or a user-stop.
Recovery is the **same durable-file path** in every case: `/surf resume` rebuilds board position
from the charter + journal + decision-log + parked-issues files (all under the gitignored `.surf/`)
plus git itself. Resume reads those, **not** chat history. The default cap-recovery (Step 16)
**relaunches `/surf resume` headlessly** once the cap resets — there is no persistent session to
keep alive, so there is nothing special about a cap versus any other stop.

- **Invocation:** `/surf resume` — relaunched **headlessly** by the Step 16 watcher
  (`claude --dangerously-skip-permissions -p "/surf resume"`) after a usage cap, and runnable
  **manually** the same way (e.g. after a reboot: `claude --dangerously-skip-permissions` →
  `/surf resume`).
- **Short-circuit the start gate, but verify bypass.** The original run already confirmed the repo
  and `--dangerously-skip-permissions` and recorded the run mode in the charter, so resume does
  **not** re-prompt Step 1–2. It **does** verify that `--dangerously-skip-permissions` is
  actually active for this process. If bypass is **not** active, resume must **park and exit** with
  a note rather than prompting — a permission prompt would hang an unattended resume forever. (The
  documented manual restart launches with the flag — see Step 16.)
- **Re-entry reconstruction.** Read the latest `.surf/charter-*`, its journal, `.surf/decision-log-*`,
  `.surf/parked-issues.md`, **and — for a whole-board-scope run — the run's generation-set file
  `.surf/created-issues-<charter-timestamp>.md`** (its path is recorded in the charter; load it
  **before** any Step 7c re-scan so the run does not re-admit its own refinements). Then
  **cross-check against git**: for each issue the journal says was
  merged, confirm `sail/<issue>` is actually merged into `main` (capture the SHA); for each in-flight
  issue, check whether the `sail/<issue>` branch exists. Also reconcile the per-issue markers:
  `.surf/runs/<issue>/.in-flight` means the issue needs to be re-queued, while
  `.surf/runs/<issue>/.awaiting-merge` means the build finished green and should resume at the
  serial merge re-check, not at the worker launch. From that, rebuild the merged-issue→SHA map,
  the parked set, the **generation-set + deferred-backlog set** (whole-board mode), and the **next
  unfinished issue**. **Re-rank any Step 7c auto-pickup issue into dependency order before launch**
  (re-run the Step 10 dependent-issue guard) so a parent discovered mid-run never sequences after a
  dependent. Append `- ↺ resume <ISO>` to the journal
  (mirroring `/sail`'s decision-log resume marker), then re-enter the Step 7 per-issue loop at the
  next unfinished issue — **without** re-charter. As in a fresh run, write `.surf/active` with this
  process's PID before re-entering the loop, and remove it on clean exit (this is the live-session
  marker the cap-recovery watcher checks; see Step 16). **Clear the user-stop sentinel:** delete
  `.surf/<charter>-paused` if present (a manual `/surf resume` re-arms auto-recovery — #124 R5-5).
- **Orphaned-park guard — surface parks aged >7 days with no activity (report-only, #153).** After
  the parked set is rebuilt (above), flag any park that has sat **>7 days with no activity** — an
  *orphaned* park nobody has re-worked. Last-activity is the durable `.surf/runs/<issue>/` dir mtime
  (poll/journal writes touch it). Consult the deterministic predicate — never eyeball the dates
  (CLAUDE.md infra-placement; the aging threshold lives in tested `sail/parked_aging.py`):
  ```bash
  # $PARKED_CSV = the reconstructed parked issue numbers, comma-separated.
  python3 -m sail parked-aging --runs-dir .surf/runs --issues "$PARKED_CSV" --now "$(date -u +%s)"
  ```
  This is **report-only — no auto-action**: it prints the orphaned parks (or a clean "none" note) for
  the operator/journal and **never** merges, closes, files, re-launches, or drops them. Surface the
  output in the resume summary + journal; the human decides what to do with an aged park. The CLI
  always exits 0 (a report, not a gate).
- **Completion sentinel — orphan vs done (load-bearing, round-2 risk #1).** A worker writes a
  per-issue **completion sentinel** (`.surf/runs/<issue>/.done`, in `/surf`'s coordination
  namespace) **only on a clean terminus** (the supervisor writes it the moment it records the issue's
  outcome in the journal at Step 7 step 4). On resume, an issue whose `sail/<issue>` branch exists,
  is unmerged, and has **no** `.done` sentinel is treated as **ORPHANED** — re-launched with a fresh
  `/sail` worker (a new `.sail/runs/sail-<issue>-<ts>/`), **never** silently treated as done.
  Without this rule, a worker that died after building but before journaling would look "finished"
  and surf would skip an unbuilt issue (a silent board gap). The sentinel is the durable
  orphan-vs-done discriminator; git cross-check (above) confirms whether the branch actually
  merged.
- **Self-heal an already-exhausted board (scope-aware).** If reconstruction finds the board is
  **already exhausted** — for **selected-set** scope, every selected issue at a terminal outcome;
  for **whole-board** scope, a Step 7c re-scan (with the generation-set loaded) finds no
  build-appropriate open issue remaining (per Step 7c's termination test — outside both the
  generation-set and the charter-named refinement label(s)) — write the done-marker
  (`.surf/<charter>-done` and a `- done: board exhausted <ISO>` journal line) and **exit
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
  3. **`sail/<issue>` branch exists, unmerged, and there is no `.surf/runs/<issue>/.done`
     completion sentinel** → the issue is **orphaned** (in-flight, no clean terminus) →
     re-launch via a fresh headless worker (Step 7: `surf_worker_command <issue>` → harness
     `run_in_background`), which runs `/sail <issue> --unattended`. The fresh `/sail` run creates a
     **new** `.sail/runs/sail-<issue>-<ts>/` (resolved via `surf_worker_resolve_run_dir`) and
     re-derives `--diff main` against **current** `main` — so a parent that merged since is included.
     An orphaned issue is never treated as done just because its branch exists.
     **Worktree reuse is collision-free (no cleanup needed here, #140).** A parked/orphaned run
     leaves its `sail/<issue>` worktree (`.claude/worktrees/sail-<issue>`) intact. The relaunched
     `/sail` worker's Stage 0.5 isolate calls `sail_setup_isolation`, which is **idempotent**
     (#65/#92/#115): an existing worktree already checked out on `sail/<issue>` is **reused as-is**
     (preserving any parked work-in-progress inside it), and a stale/mismatched occupant is safely
     cleared via `ship_safe_cleanup_orphan_dir`. So `/surf` does **not** detect/clean the worktree
     itself before relaunch — that reuse lives once in the shared `sail_setup_isolation` lib (adding
     it here would duplicate it). Regression-pinned by `tests/test_sail_140_followups.sh` T1.
  4. **Branch absent, or its build corrupt/partial** (a crash mid-write) → discard and build the issue
     **fresh**.
  5. **No branch at all** → build the issue **fresh**.
- **The per-issue journal entry is the checkpoint.** Because each issue's outcome is journaled as
  it lands, a hard stop loses at most the one in-flight issue — never the merged board behind it.

### Step 16: Durable-file `/surf resume` relaunch (usage-cap auto-resume)

The subscription usage window is **not** API-readable (the `anthropic-ratelimit-*` headers report
API-key per-minute throughput, a different pool), so auto-resume is **reactive**: capture the reset
time the cap reports and resume after it — not a proactive remaining-quota monitor.

**Branch A is the locked design.** The build-step-1 result confirmed that
`statusLine.refreshInterval` re-fires the statusline command on a token-free timer while idle, the
`.rate_limits` payload is fresh and account-wide, and `claude -p` workers emit no statusline
traffic. That rules out watcher/self-wake loops here: `/surf` does not keep its own timer alive or
try to wake itself early.

**Checkpoint sequence (#166).** At each issue boundary (before launching the next worker), `/surf`
consults the deterministic predicate — never eyeballs the JSON (CLAUDE.md infra-placement; the
threshold/staleness/wakeup decisions live in tested `sail/usage_cap.py`):

```bash
DECISION="$(python3 -m sail usage-state check --state "$HOME/.claude/usage-state.json" --now "$(date -u +%s)")" && RC=0 || RC=$?
# rc 0 ("ok")               → proceed: launch the next worker as normal.
# rc 1 ("backoff <epoch>")  → finish the current issue, STOP launching workers,
#                             ScheduleWakeup(<epoch> − now) — the printed epoch already folds in
#                             resets_at + margin (forward-only, never in the past) — then resume.
# rc 2 ("unknown")          → stale/missing usage-state (statusline stalled or not opted in):
#                             conservative HOLD — same stop-launching behavior, but wake on a short
#                             re-check interval instead of a reset epoch.
```

Threshold/cadence/margin default to 90% / 30s / 120s, overridable via `SAIL_USAGE_THRESHOLD` /
`SAIL_USAGE_REFRESH_SECS` / `SAIL_USAGE_MARGIN_SECS`. The reactive `#163` cap-message handler
remains the always-on floor: proactive avoids the wall; reactive catches misses (and headless-only
runs, which have no statusline feed, fall back to it entirely).

On a `backoff` result, `/surf` writes the wake target into the durable resume artifacts
(`.surf/resume-after` and `.surf/runs/<issue>/cap-state.json`), then decides how to wait by
**classifying the wall length** — never eyeballing it (the deterministic call lives in tested
`sail/usage_cap.py`, dispatched via the CLI the loop consumes):

```bash
# The wake target is the INTEGER epoch armed into cap-state.json (resets_at + margin, forward-only).
# Read it via `cap-recovery status` (`resume-after-epoch`), NOT `cat .surf/resume-after` — that file
# is RFC3339 text and `usage-state hop`/`wall-policy --wake` require an integer epoch (#168). Whether
# the reset came from a #168 rate_limit_event or the #163 cap-text path, it is armed the SAME way, so
# the authoritative `resetsAt` feeds this exact chain.
WAKE="$(python3 -m sail cap-recovery status --surf-dir .surf --issue <issue> --now "$(date -u +%s)" \
          | python3 -c 'import json,sys; print(json.load(sys.stdin)["resume-after-epoch"])')"
POLICY="$(python3 -m sail usage-state wall-policy --wake "$WAKE" --now "$(date -u +%s)")"
# wait-in-window  → chain ScheduleWakeup toward WAKE in <=3600s hops, resuming IN THIS WINDOW:
#   HOP="$(python3 -m sail usage-state hop --wake "$WAKE" --now "$(date -u +%s)")"
#   HOP==0 → wake reached, resume launching workers; HOP>0 → ScheduleWakeup(HOP) and re-check on wake.
# park-and-handoff → see below.
```

- **`wait-in-window`** (a ~5h wall, `<= SAIL_WALL_CEILING_SECONDS`, default 6h): the **foreground**
  orchestrator chains `ScheduleWakeup` toward `WAKE` in `<= 3600s` hops (the ScheduleWakeup cap) and
  **resumes in the same window** — visibility and board position are preserved across the wall. A
  woken turn re-reads the durable `WAKE` and continues; it never recomputes the wait from scratch
  (forward-only). This is the same-window path the Stage-1/2 lock-survival results make viable.
- **`park-and-handoff`** (a multi-day / 7d wall, `> ceiling`): too long to hold a window open (the
  machine will lock/sleep and — accepted-unfixable — the OAuth token may expire across days), so
  `/surf` does **not** try to sleep through it in-window. It writes the durable park handoff (the
  same `wip-handoff.md` / board-position state the reactive relaunch reads) and stops; recovery is
  the **#163 reactive durable-file relaunch** (Step 16 watcher / `/surf resume`) once the long window
  resets — no live window is required. This is the convoy-adapted split: short walls wait in-window,
  long walls park + hand off.

The `#166` sensing path and the `#163` reactive floor are reused here, not duplicated.

**The model: durable-file headless relaunch (the #53 model, restored).** Because a headless
`claude -p` process **can** host `/sail`'s crew (Step 8 — depth-0 subagents, verified), the default
cap-recovery is simply to **relaunch `/surf resume` headlessly** once the cap resets:
`claude --dangerously-skip-permissions -p "/surf resume"`. Nothing needs to stay alive across the
cap — the durable `.surf/` files + git are the entire state, and the relaunched headless run
rebuilds board position from them (Step 15) and spawns fresh per-issue workers. This **supersedes**
the #73 persistent-tmux send-keys revive (which existed only because the old teammate body could
not run headless — a premise now verified false).

- **The watcher.** `config/surf-resume.sh`, fired on an interval by the LaunchAgent
  (`config/com.surf.resume.plist`), is a **pure-bash gate** that decides whether to relaunch and,
  when it does, runs `claude --dangerously-skip-permissions -p "/surf resume"`. It touches **zero
  Claude tokens on an idle tick** — the "is it time yet?" decision is entirely in shell, never in a
  Claude call.
- **The gate (cheap-shell, no Claude call).** The watcher relaunches only when **all** hold: no
  live relaunch lock; **no live `.surf/active` session** already running (a live PID marker means a
  `/surf` is already working — do not launch on top of it; a stale marker with a dead PID is
  ignored and cleaned, so a crash self-heals. A live pid is only a blocker while `.surf/heartbeat`
  is fresh; if the heartbeat is stale or missing, the watcher treats the live pid as stalled and
  continues through the rest of the gate instead of double-driving. **A live pid that has posted a
  `.surf/capped` relinquish marker (#163 supervisor self-relinquish, scenario 5) is ALSO treated as
  recoverable** — the supervisor is alive but every call it makes is cap-refused, so the watcher must
  not let its live pid lock recovery out); the armed `.surf/resume-after`
  floor is absent or has passed; and **real unfinished work remains**. Otherwise it exits
  immediately.
- **"Work remains" = charter present AND no done-marker.** If the newest `.surf/charter-*.md` (by
  its sortable `<timestamp>` suffix) exists and there is **no** done-marker (no `.surf/<charter>-done`
  file and no `- done:` line in **that charter's own** journal — written as `board exhausted` or
  `superseded`), the watcher treats the board as unfinished. The **done-marker is the single
  authoritative quiet signal** — it is how a finished run (Wrap-up, Step 14), an abandoned one
  (self-healing resume, Step 15), or a superseded one (tombstoned at Step 0-pre) silences the
  watcher. To stop a mid-board run you do **not** want resumed, either `touch` the done-marker
  (`.surf/<charter>-done`) or bootout the LaunchAgent.
- **Resume reconciliation is marker-aware.** If the latest charter describes a Parallel run, the
  resume reader replays `.surf/runs/<issue>/.in-flight` and `.surf/runs/<issue>/.awaiting-merge`
  before any new launch: in-flight gets re-queued, awaiting-merge resumes at the serial merge
  re-check, and only then does `/surf` decide whether more work remains.
- **The takeover relaunch overwrites `.surf/active`.** If the watcher takes over a stalled live
  session, the fresh relaunch pid replaces the stale pid in `.surf/active` so the resumed run owns
  the marker again.
- **Reset capture (conservative floor) — single-sourced with the supervisor (#163).** When the
  relaunched run hits the cap again, the watcher classifies + parses the reset from the run's **own
  output** via the **same** tested `sail cap-recovery` module the supervisor's Layer-1 branch uses
  (`classify --text-file` then `parse-reset`), never a bash regex — so the two layers can never
  disagree. It arms `resume-after = max(parsed_reset + margin, now + MIN_BACKOFF)`; an **unparseable**
  reset arms a long multi-hour default. The module now parses **both** horizons — a 5h clock+IANA-TZ
  reset **and** a weekly weekday/date/"in N days" reset (fixing the old bash `parse_reset_time`
  `+1 day` roll-forward that could not represent a 7-day reset) — and caps any single wait at the
  wall-clock ceiling (>= 8 days). A parse-miss is therefore a *long* wait, never a per-tick hot-loop.
- **Shared durable state (scenarios 5 & 9).** `.surf/resume-after` and the per-issue
  `.surf/runs/<issue>/cap-state.json` are written by whichever layer notices the cap and read by the
  other — one mechanism over durable, watcher-visible state. So if the supervisor arms a floor and
  then **dies mid-wait** (reboot, terminal close, its own cap), the watcher reads the identical
  `resume-after` and resumes at the **same** reset (scenario 9); and a live-but-cap-blocked
  supervisor that posted `.surf/capped` is taken over by the watcher (scenario 5, gate bullet above).
  A clean (uncapped) relaunch clears both artifacts (`sail cap-recovery clear`) so stale state never
  gates a later run.
- **Follow-up splits.** Keep the stream-json worker plumbing and auth-liveness surface separate:
  `rate_limit_event` (authoritative reset signal) is **SHIPPED as #168** — the worker launches with
  `--output-format stream-json --verbose`, and Step 8 Layer-1 parses its `rate_limit_event` lines via
  `sail cap-recovery rate-limit-event` as the authoritative reset source (the #126 cap-text regex is
  retired on the worker path; the #166 statusline sensing + #163 reactive floor remain as the
  fallbacks). The `auth_dead` sentinel + auth-liveness precheck stay tracked as **#169**.
- **Anti-pattern guard.** Never put the "is it time yet?" decision inside a Claude call — that would
  burn tokens on every idle tick and can't run while the API is capped. The decision lives in the
  pure-shell gate; `/surf resume` is relaunched only once the gate has already said yes.

> **Optional supervised (panes) lens — cap-recovery is the same headless relaunch.** The Step 3b
> panes lens is a **pure visibility layer**; it has **no** cap-recovery of its own. A capped run —
> watched or not — recovers via the durable-file `/surf resume` headless relaunch above (a human at
> a manned panes run can also relaunch manually). Resume behaviour (the `.surf/` files Step 15
> reconstructs from) is identical either way.

**Recovery in every case is the same durable-file path.** A usage cap, a crash, a reboot, or a
user-stop all recover via `/surf resume` reading the durable `.surf/` files + git — there is no
session to keep alive, so a reboot is no longer a special "automatic recovery lost" case. After any
hard stop, the watcher relaunches automatically once its gate opens, or you can run it manually:

```bash
claude --dangerously-skip-permissions
#   …then at the Claude prompt:
/surf resume
```

— which rebuilds board position from charter + journal + git (Step 15).

---

## Rules

- The start gate is non-negotiable: confirm the repo and confirm
  `--dangerously-skip-permissions`; refuse the loop until both hold. `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: 1`
  is **not** required on the default headless path (Steps 2–3) — only if you opt into the optional
  supervised (panes) lens (Step 3b).
- Every user choice is an **interactive selection prompt — never a `--flag`**.
- **Auto-merge only on a positively-confirmed-green run-dir** (`surf_worker_result`: no
  `wip-handoff.md`, all gates `passed`/`skipped`, `review.json` `completed` & clean & current).
  The worker process exit code is ignored; any ambiguity fails closed to park (Step 8/9).
- **Autonomous mode = fix, don't wait.** When something is broken or a fix is needed and the fix is
  reversible, in-scope, and unambiguous (a broken/non-hermetic test, a clear code-quality fix,
  inserting a discovered fix-issue into the build order, a merge/park call, landing a stalled
  worker's already-green work), the orchestrator **makes the call and executes it — decide-and-log,
  never pause for the human.** Waiting defeats an unattended run. **Park is the only "stop"** and is
  reserved for the genuinely irreversible (cannot be undone by `git revert`), the genuinely ambiguous
  (no defensible default), or a non-code judgment that is truly the human's. Supervised mode asks
  within the deadline (§11); autonomous mode decides. (See #57 for the mode-banner treatment.)
- **Domain gating: auto-for-code, ask-for-domain (Step 11b).** Coding decisions are
  made-and-logged in both modes; an unresolved **domain** assumption (one not answerable from the
  charter, `.ship/domain.md`, or the issue text — the charter's current-run intent wins over stale
  memory) opens a **user-input window** — **supervised** waits on
  the Step 11 deadline, **autonomous** gives a **bounded** window then takes the best bet,
  recording the options it weighed + the route it chose. AUTO means "don't bug me about code,"
  **never** "guess at my domain." Only **user-confirmed** domain answers are written to
  `.ship/domain.md` (taught via `/train`) so they are not re-asked; an autonomous best-bet stays
  **provisional** in the decision-log until confirmed.
- **The mode banner makes decide-vs-ask unmistakable (Step 0b).** At startup and at each
  re-anchor, `/surf` prints a one-line banner stating the active mode + an **inline switch-path
  note on the same line** (edit the charter's `mode` field / re-run `/surf`) — zero user memory
  required.
- One `--no-ff` merge commit per green issue; log every merge SHA so each is `git revert`-able.
- **Sandbox repo only. No force-push or destructive git.** Park anything irreversible.
- **Every issue is built by a fresh per-issue headless `claude -p` worker — in both modes**, never
  inline. The worker runs `claude --dangerously-skip-permissions -p "/sail <n> --unattended"`
  (a depth-0 process that hosts `/sail`'s crew — `/ship` optional), **backgrounded by the harness**
  (`run_in_background`), which owns its lifecycle and kill. The mode changes only decision behavior,
  never the delegation mechanism. The default path needs **no tmux and no agent-teams feature**; the
  optional supervised (panes) lens (Step 3b) wraps the same worker substrate inside a tmux session
  purely for visibility.
- **Worker launch is injection-safe; lifecycle is harness-owned.** `surf_worker_command` numeric-
  validates the issue id and EMITS the exact command (no string interpolation of arbitrary text, no
  forking); the supervisor runs it via the harness Bash `run_in_background` facility. Domain answers
  reach the worker only via a file (Step 11b). The wall-clock cap is enforced by the SUPERVISOR
  (elapsed-vs-spawn) issuing the **harness background-task kill** — there is **no** bash
  process-group kill / PID-reuse pid-file guard (pure-bash daemonization was removed; it fights
  macOS). `surf_worker_cleanup` never force-deletes a tree and uses `git worktree remove` without
  `--force`. These thin helpers live in `config/surf-worker.sh`.
- **Teardown is mandatory on every stop path** (board-exhausted, user-stop, error): stop any
  in-flight worker via the harness background-task kill, then `surf_worker_cleanup` (safe, no force
  delete), leaving the run-dir as the resume checkpoint. No tmux teardown on the default path.
- **Auto-resume is the durable-file `/surf resume` headless relaunch (the #53 model).** A usage cap,
  crash, reboot, or user-stop all recover the same way: the Step 16 watcher relaunches
  `claude --dangerously-skip-permissions -p "/surf resume"` once its pure-shell gate opens, which
  rebuilds board position from the durable `.surf/` files + git. An in-flight issue (an unmerged
  `sail/<issue>` branch) without a `.surf/runs/<issue>/.done` completion sentinel is treated as
  **orphaned** (re-launched with a fresh `/sail` worker), never as done.
- The charter + journal are the source of truth; re-anchor from them at the top of every issue.
  Do not rely on `/compact` or chat history.

## Status-message tone — INFO vs ALERT (#112)

**Tone tracks severity.** *Expected absence is information; unexpected absence is a warning.* The
facts are the same either way — only the volume changes. This generalizes #108's "park loudly"
instinct to **all** operator-facing status output: if every line reads as a caveat, a real event (a
model downgrade, a missing-but-required tool, a gate failing red) stops being noticeable. So
calibrate each status line — every journal/decision-log note, every operator log line — to one of
two tiers.

**Neutral — flat, declarative INFO** (the system is doing exactly what it should):
- A gate **no-ops because its target is absent by design** — pytest / diff-coverage when the repo
  has no Python tests; npm-audit with no `package.json`.
- A **risk-gated step doesn't fire** on a low-stakes diff (e.g. red-team escalation skipped).
- The **materiality floor stays dormant** on a green run.
- **Dual-lens running on the configured backends** (both lenses present, as intended).

**ALERT — explicit `⚠` / "HEADS UP", made to stand out** (the intent was NOT met):
- A **configured backend is unavailable / the codex latch tripped → degrading to single-lens** (a
  cross-family lens the diff gated for did not run).
- A **fallback model** is used instead of the intended one.
- A tool that **should** be present is **missing** (e.g. bandit can't emit SARIF).
- A gate **genuinely fails red** (≠ skips).
- Any **silent-fallback** path (a denied/unrenderable prompt that would auto-take the recommended
  option — the exact class #108 kills).

**Conditional honesty guard.** The classification turns on whether intent was *actually met*, not on
the surface event — and the calm wording must stay truthful. "Coverage gate correctly no-ops" is
right **only** when the target is genuinely absent by design (0 `.py` tests in the repo); a repo that
*does* carry a pytest suite with a skipping coverage gate is a **real gap → ALERT**. So:
**no-pytest-by-design → INFO; pytest-present-but-skipped → ALERT.** Never dress a real deviation in
calm wording to keep the log quiet.

This is the same two-tier rule the `sail degraded-review` `TONE` already encodes — surfaced here at
the Step 7b land/merge line (the counterpart of `/sail`'s Stage 4 commit terminus): `ALERT` when a
configured lens latched off (a real deviation), `INFO` when the backend was simply unset (expected
single-lens). Extend it to every status line the run prints.

## Cross-references

- `commands/idea.md` — triage skill; `/surf` is the board-level autopilot above per-issue pipelines
- `config/surf-worker.sh` — the tested thin helper: `surf_worker_validate_id`,
  `surf_worker_command` (EMIT the injection-safe worker command — the harness backgrounds it),
  `surf_worker_result` (the fail-closed durable-artifact merge contract incl. review currency), and
  `surf_worker_cleanup` (safe `git worktree remove` without `--force`). Worker lifecycle/kill is the
  harness's job (`run_in_background`), not bash — no daemonization/process-group kill here
- `cc-dotfiles: home/shell/convoy.sh` + `home/lib/ship-tide.py` — proven patterns reused (safe
  worktree cleanup, fail-open liveness polarity); but worker lifecycle is harness-owned, not the
  bash daemonization convoy uses — see the `#124 convoy reuse-vs-optimize decision record` in
  `docs/surf-convoy-comparison-and-backlog.md` §7 (incl. the macOS platform-fit lesson)
- `commands/fleet.md` — parallel epic build using agent-team teammates; the **optional** supervised
  (panes) lens (Step 3b) borrows its named-tmux/agent-teams pane setup, but the `/surf` default no
  longer uses teammates at all (the body swapped to headless workers, #124)
- `cc-dotfiles: home/commands/sail.md` (and the `/sail` README) — the **default engine** each
  per-issue worker runs via `/sail <n> --unattended` (→ `python3 -m sail run --diff main`; `/ship`
  is the optional heavier engine); defines the exit-0/exit-1 and fail-closed-review contract
  `/surf` relies on
- `/train` — maintains `.ship/domain.md`, the domain memory **domain gating** (Step 11b) reads
  first; teaching the crew there turns repeated domain windows into already-answered questions so
  a domain-bearing board runs with fewer pauses
