# `/surf` vs `/convoy` — comparison, architecture decision, and improvement backlog

**Status:** working document. Captures the analysis from the 2026-06-28 session so the
improvements can be worked one at a time. The **architecture swap (§4)** is the critical
first item and is being taken through `/idea` now; everything else (§5) is queued behind it.

**Sources analyzed (read in full):**
- `CK-Skills/commands/surf.md` (~1,260 lines) — the board-working autopilot
- `cc-dotfiles/home/shell/convoy.sh` (~460 lines) — the `/ship --autopilot` batch launcher
- `cc-dotfiles/home/lib/ship-tide.py` (~341 lines) — the shared tide/retry classifier both lean on

---

## 1. The fundamental architectural difference

These are not the same kind of thing; nearly every difference falls out of this.

| | `/convoy` | `/surf` |
|---|---|---|
| What it is | ~460-line **pure-bash shell function** | ~1,260-line **LLM-driven skill spec** |
| Engine per issue | `/ship --autopilot` | `/sail` (`/ship` optional) |
| Unit of execution | a separate **OS child process** (`claude -p`) it forks; owns its log file | an **agent-team teammate** (tmux pane) delegated from inside a live session |
| Who decides | nobody — dumb sequential launcher | the orchestrating Claude session reasons about everything |
| Issue order | **literal arg order** | **derived** — dependency graph + risk/value (Step 5b) |

**Pivotal consequence:** convoy owns PIDs and log files, so it gets OS process primitives
(PID, signals, exit codes, log mtime) for free — that's why hang-detection, subscription
check, retry, and proactive tide are cheap in bash. surf owns none of that (a teammate is a
pane, not a forked child), so its cap-recovery lives in an *external bash watcher that scrapes
pane text*. Convoy's robustness is process-level; surf's is pane-level.

---

## 2. Capability matrix

| Capability | `/convoy` | `/surf` |
|---|---|---|
| Mode selection | attended/unattended (config + flags) | autonomous/supervised (interactive, no flags) |
| Issue ordering | literal arg order | dependency-graph analysis + reconciliation |
| Merge/park policy | delegated entirely to `/ship` | own green-merge/park + dual-lens & stacked-parent guards |
| Audit trail | per-run `.jsonl` logs only | charter + journal + decision-log + **issue→SHA revert map** |
| Domain gating | none | auto-for-code / ask-for-domain (Step 11b) |
| Whole-board auto-pickup | none (fixed list) | yes, anti-regress generation-set (Step 7c) |
| Resume after hard stop | **none** | full reconstruction from durable files + git (Step 15) |
| Usage-cap survival | **proactive tide gate** (reads prior log, holds before next launch) | **reactive** revive watcher (scrapes pane after stall) |
| Hang watchdog | **yes** — SIGKILL on stale log mtime, PID-reuse guarded | **none** |
| Subscription check | **yes** — polls `apiKeySource`, warns if on API key | **none** |
| Retry-on-failure | **opt-in** classify→retry/wait/park w/ backoff | **none** — exit 1 → park |
| Failure isolation | continue queue, return 1 if any failed | park & continue |

**Pattern:** surf wins on *intelligence* (top half); convoy wins on *process robustness*
(bottom half) — and it wins there precisely because it owns processes.

---

## 3. The two halves of surf

- **Intent layer (KEEP — the soul):** charter, domain gating, decision authority, journal +
  decision-log + issue→SHA revert map, park-loudly, plain-language summary, dependency-order
  analysis. This is what lets a non-coder pour in domain knowledge and trust the output.
- **Execution substrate (the weight + fragility):** agent-team teammates as tmux panes, named
  `surf` session, idle-zsh detection, `kill-pane`, `TeamDelete` teardown, 200K pane cap, and the
  external revive watcher that *scrapes pane text* for the cap notice. The user never sees this
  and never benefits from it. Every gap in §5 lives here — they are the cost of choosing panes.

The spec's own hedges are tells the substrate fights the platform: *"validate cap-notice
patterns against a real capped pane," "the framework leaves idle zsh shells," "a reboot loses
automatic recovery."*

---

## 4. ★ Architecture decision (CRITICAL — in `/idea` now)

**Keep surf's brain; swap surf's body to convoy's headless-process-per-issue substrate.**

### The premise that locked surf into panes — and why it dissolves
surf chose panes (Step 8) because a per-issue worker must host `/sail`, `/sail` spawns its own
crew, and a one-shot **subagent** can't host a nested crew. True — **but only when delegating
via the Agent/subagent tool from inside the orchestrator session.** Delegate the way convoy does
— a fresh **headless `claude -p "/sail <n> --unattended"` process per issue** — and that worker is
a *top-level session* that hosts `/sail` and its crew with no trouble. The constraint vanishes,
and you regain every OS primitive convoy already exploits.

The only thing lost is the *live watchable pane* — which matters for supervised/demo, not for
unattended overnight runs (nobody's watching; they read the morning summary).

### Deeper principle (the real reason to swap)
> **Deterministic process mechanics → bash. Judgment → LLM.**

surf today puts the LLM in charge of spawn/idle-detect/kill-pane/TeamDelete/pane-scrape — brittle,
token-expensive, non-deterministic work that should be deterministic. convoy puts it in bash.
Adopting convoy's substrate isn't just "more robust," it's *correctly layered*.

### Target architecture (keep / swap / cut)
| Layer | Decision | Why |
|---|---|---|
| Charter / domain gating / decision authority | **Keep** | the non-coder's whole interface |
| Journal + decision-log + revert map | **Keep** | trust + undo |
| Dependency-order analysis (Step 5b) | **Keep** | real value convoy lacks |
| Per-issue execution | **Swap** to headless `claude -p` per issue | buys back hang/subscription/retry/tide/resume in tested bash; dissolves the "can't host crew" premise |
| Process mechanics (hang, cap, retry, cleanup) | **Move to bash** (adopt convoy's) | deterministic work doesn't belong in the LLM loop |
| Supervisor loop (ordering, adjudication, domain Q&A, summary) | **Keep as thin LLM loop**, driving bash helpers | judgment stays with the LLM |
| agent-teams panes + revive watcher + pane-scrape + teardown | **Cut as default; keep panes as optional supervised/demo lens** | the heaviness/fragility the user never sees |

### Why this serves the "light but trustworthy / non-coder" north star
- Trust = predictability + audit trail + easy undo + never-silently-wrong + survives unattended.
  The swap improves all of them (deterministic mechanics → fewer weird failures; convoy's
  robustness → actually survives the night).
- "Light" = move heaviness out of the user's view **and** out of the LLM loop into bash. User's
  surface stays: charter Q&A in → morning summary out.

### Honest tradeoff / the one thing that would change the call
Lose live multi-pane visibility as the default. Decider: **is watching agents work live a core
product value, or a debugging affordance?** If affordance → headless default, panes optional
(recommended). If it IS the product (a "watch the fleet" showpiece) → harden the substrate in
place instead. For a non-coder's overnight board-clearer, it's an affordance. Parallelism does
NOT favor panes — headless parallelizes via background processes just as well.

### Domain input under the headless model (resolved — must fold into the proposal)
**Concern:** can the user still provide domain knowledge mid-run with headless workers?
**Answer: yes, fully — and it's cleaner.** "Headless" forecloses *typing into the worker's
stdin*, not *the user interacting with the system*.

- **The user always talks to the supervisor, never the worker** — true in surf today too. Even
  with live panes, domain input flows through the orchestrator's open-questions file +
  decision-authority (Step 11/11b), never by typing into a teammate pane. The teammate's `/sail`
  runs autonomously and **parks** on unresolved domain. Identical in both architectures.
- **Input reaches a headless worker via a file it reads**, mediated by the supervisor:
  `you → supervisor (interactive) → writes .ship/domain.md + charter → worker reads it`.
  Headless ≠ can't-receive-input; input arrives as a watched file, not keystrokes.
- **Two granularities:**
  1. *Boundary-level (default, robust):* worker writes question to `.surf/open-questions.md`,
     exits "needs-domain-input"; supervisor surfaces it, user answers, supervisor writes the
     answer to domain memory and **re-launches that issue** (same run-dir → `/sail` skips finished
     gates). This is surf's existing Step 11 mechanism.
  2. *Mid-build pickup (optional upgrade):* if `/sail` re-reads `.ship/domain.md` at each internal
     stage (likely, given `/train`'s design — **OPEN: verify against `sail.md`**), a fact dropped
     mid-build is picked up at the worker's next checkpoint with no re-launch.
- **Scenarios:** manned → confirmed answers (promoted to domain memory), can pre-load facts;
  auto + periodic checks → supervisor stays a live session, clear pending questions / add notes;
  fully unattended → bounded window → best-bet + decision-log → adjudicate later (Step 11b).
- **Net:** the expectation that the user supplies domain knowledge during manned runs (and
  opportunistically during auto) is fully preserved and made cleaner — single calm front door
  (the supervisor) instead of "attach to tmux, find the right pane."

### Open verification items for the `/idea` phase
- [ ] Confirm whether `/sail` re-reads `.ship/domain.md` per stage (decides free vs wired mid-build pickup).
- [ ] Map exactly which surf steps survive unchanged, which simplify, which need rewriting (blast radius).
- [ ] Decide the supervisor's own form: thin LLM loop calling bash helpers vs how much stays pure bash.

---

## 5. Improvement backlog (queued behind §4 — work after the swap)

These are surf's gaps that convoy already solved. They all live in the process-robustness band,
so **most become straightforward once §4 lands** (the headless substrate gives the OS primitives
they need). Ranked.

### 5a. ★ Hang detection for a wedged (non-capped) teammate/worker — biggest gap
- convoy: `_convoy_supervise_child` (convoy.sh:234) — background watchdog SIGKILLs the child if
  log mtime is stale past `CONVOY_HANG_TIMEOUT` (default 3600s) while PID alive; PID-reuse guard
  via `ps -o lstart` start-token.
- surf: NO hang detection. Handles only (a) worker reports exit 0/1, or (b) usage-cap stall →
  revive watcher. A **non-cap hang** (infinite tool loop, deadlocked subprocess, LLM goes quiet)
  is the watcher's **state 4 → "do nothing"** (surf.md:1111) → board stalls forever on one issue.
  An overnight run that wedges on issue 3 of 30 silently burns the whole window.
- Post-§4: trivial — workers are processes again; lift convoy's watchdog directly. Pre-§4
  fallback: extend the pane-reading watcher with a staleness timeout (tail unchanged N min AND not
  a cap notice → hung → dismiss/kill/park-or-respawn).

### 5b. Subscription / `apiKeySource` confirmation at startup
- convoy: `_convoy_check_apikeysource` (convoy.sh:96) polls stream-json `init`; `apiKeySource=none`
  → subscription confirmed, else WARNING "run is on API key, not the subscription."
- surf: Step 16 reasons explicitly about the *subscription* usage window yet **never confirms the
  session is on the subscription.** If accidentally on an API key, the whole persistent/revive
  design is moot and it silently burns API credits.
- Fix: add an `apiKeySource` check to the start gate (alongside Step 2 bypass check). Low effort.

### 5c. Board-level bounded retry-on-transient before parking
- convoy: opt-in retry loop (convoy.sh:334–404) + `ship-tide.py classify` → `proceed | retry |
  wait_then_retry | park` with exponential backoff (`base·2^(n-1)`, clamp 300s) + attempt cap.
- surf: exit 1 → **park, full stop** (surf.md:521,730). Conflates *transient* failure (flaky net,
  momentary codex/lens outage, usage blip) with genuine not-green → **false-parks** buildable issues.
- Fix: classify before parking; transient/usage-limit → bounded retry reusing the same run-dir;
  park only on permanent failure or budget exhaustion. **Caveat:** CRITICAL/HIGH *review* findings
  are NOT transient — they must still park immediately; retry only infra-class failures
  (`ship-tide.py classify` already draws this line). Between-retry cleanup template:
  `_convoy_safe_cleanup_issue` (convoy.sh:150 — no `rm -rf`, `kill -0` live-guard, worktree remove
  without `--force`); surf already has analogous logic in Step 15.

### 5d. Proactive between-issue tide gate (complement surf's reactive cap handling)
- convoy: before launching the next issue (convoy.sh:317), runs `ship-tide.py tide` on the *prior*
  ship's log; non-allowed status with parseable `resetsAt` → **holds until reset before spawning.**
- surf: entirely *reactive* — spawns the next teammate regardless; only after it stalls does the
  external watcher scrape its pane. Spec admits this is fragile (surf.md:1138).
- Fix: at the Step 7 re-anchor, read the just-finished worker's `sail run` output via
  `ship-tide.py tide`; if over/approaching cap → hold before spawning the next worker. Log-reading
  is far more robust than visual pane-scraping. Complements, doesn't replace, the reactive path.

### 5e. Adopt convoy's fail-open polarity + identity-guard as patterns
- Any worker/pane supervision should copy: fail-open polarity (garbage/absent signal → proceed,
  never wedge — ship-tide.py:10) and the identity guard (`lstart` token → "same pane/PID" check).
  These keep a watchdog from doing harm on a misread.

---

## 6. What `/convoy` could adopt from `/surf` (reverse direction — lower priority)
Mostly category-bounded; convoy is deliberately a thin launcher:
- dependency ordering (Step 5b) — convoy runs args in literal order
- revert map / decision-log — convoy has only per-run `.jsonl`
- resume from durable state — a killed convoy just stops

Pushing surf's intelligence into convoy would just reinvent surf. Honest framing: **convoy fits
when you already know the issues and order and want dumb-but-robust execution; surf fits when the
board needs reasoning.**

---

## 7. #124 convoy reuse-vs-optimize decision record

#124 swapped `/surf`'s per-issue execution body from a tmux-pane agent-team teammate to a headless
`claude -p "/sail <n> --unattended"` worker process, lifting the process mechanics into the tested
helper `config/surf-worker.sh`. The brain (charter, domain gating, journal, decision-log, revert
map, dependency order, durable `/surf resume`) is unchanged. This table records, per mechanic, what
was reused from `/convoy` (cc-dotfiles `home/shell/convoy.sh`, `home/lib/ship-tide.py`) versus done
differently, with a one-line rationale and a best-in-class citation.

| Mechanic | Reused from convoy | Done differently | Rationale | Citation |
|----------|--------------------|------------------|-----------|----------|
| Worker→supervisor result contract | Convoy reads a child's exit code | `/surf` reads `/sail`'s **durable structured artifacts** — `wip-handoff.md` (parked), `run-state.json` (gate statuses), `review.json` (status/findings/ACs/tidiness) — and **IGNORES the claude `-p` exit code for the decision** (it reflects the claude process, not `/sail`'s terminus; and on macOS the `set -m` spawn fallback makes a cross-shell `wait` return 127 even on a clean exit). The supervisor **POLLS** the run-dir across its ticks (`.done`/`wip-handoff`/liveness/elapsed-vs-cap) rather than block-waiting (the Bash tool caps a call at ~10 min vs the worker's multi-hour cap). Never log/pane scraping. **Polarity is FAIL-CLOSED**: any ambiguity → park — the OPPOSITE of the liveness polarity row below | The exit code does not encode the terminus AND is unreliable across the spawn fallback, so keying merge on it is unsound (#124 R2-1/R5-1). A structured artifact is a stable contract (Hyrum's Law). A merge gate must fail safe = closed | Hyrum's Law; structured/event logging (Fowler, "StructuredLog"); fail-safe defaults (Saltzer & Schroeder) |
| Wall-clock cap + safe reap | Convoy's `_convoy_supervise_child` bounds + `wait`-reaps a child | `/surf` ships a **minimal wall-clock cap** (exit-124 = timed-out, distinct from clean exit) now; **heartbeat/log-mtime liveness deferred** (docs §5a) | Bound a wedged worker cheaply first; adaptive liveness multiplies surface area before the single-worker path is proven | GNU coreutils `timeout` (124 = timed-out convention); systemd `WatchdogSec` |
| Worker lifecycle (background + kill) | Convoy daemonizes the child itself in bash and SIGKILLs it (`setsid`/process-group, `ps -o lstart=` PID-reuse guard) | `/surf` does **NOT** daemonize in bash. The worker is launched via the orchestrator's **`run_in_background` harness facility** (built to survive turns); the harness owns the process group and the kill. The supervisor enforces the wall-clock cap by comparing *elapsed-since-spawn* and issuing the **harness background-task kill** (task-stop / KillShell) — no bash `kill -pgid`, no pid-file liveness | **Platform-fit lesson:** pure-bash daemonization fights macOS — there is no `setsid`, so a bash-backgrounded child gets no new session and cannot survive across tool turns, and a cross-shell `wait` returns 127 even on a clean exit; a process-group kill from the wrong session is unsafe. The harness facility is purpose-built to background a process across turns and manage its kill, so worker lifecycle belongs there, not in bash | Claude Code Bash `run_in_background` / background-task (KillShell) facility; macOS lacks `setsid(1)` (POSIX `setsid(2)` only) |
| Fail-open polarity — **LIVENESS only** | `ship-tide.py`: absent/garbage signal → cast_off (never wedge the queue) | `/surf` applies fail-OPEN to the **watchdog/liveness** path (a garbage/absent liveness signal → proceed, never wedge a healthy worker). It is **explicitly NOT** applied to the merge gate (`surf_worker_result`), which is fail-CLOSED (park on ambiguity) — two jobs, two opposite safe directions | A watchdog that wedges on a missing signal harms a healthy run; a merge gate that proceeds on a missing signal merges junk. The safe direction differs by job | convoy `ship-tide.py` decision polarity (header docstring); fail-safe defaults (Saltzer & Schroeder) |
| Durable-journal + `.done` sentinel resume | Convoy stops on kill (no resume) | `/surf` keeps its durable journal + adds a per-issue **completion sentinel**; an in-flight run-dir **without** the sentinel is **orphaned** (re-run same `--run-dir`), never treated as done | A crash between build and journal must re-check, not skip — else a silent board gap. Sentinel = the durable commit-point discriminator | WAL/ARIES recovery (in-flight vs committed); Hadoop `_SUCCESS` marker |
| Cap-recovery | Convoy holds between issues via a tide gate | `/surf` default reverts to the **durable-file `/surf resume` headless relaunch** (#53 model) — viable since a depth-0 `-p` process hosts the crew; the #73 persistent-tmux send-keys revive demotes to the optional panes lens | No session needs to stay alive once headless can host the crew; the durable files are the entire state | #53 LaunchAgent relaunch; reactive cap handling (subscription window not API-readable) |
| Parallelism | Convoy runs args sequentially in literal order | `/surf` ships **sequential** workers this land; a bounded pool ordered by the Step 5b dependency DAG is a **deferred follow-up** | Prove single-worker cleanup/identity/resume before multiplying it; surf already computes the DAG | GNU `make -j` (bounded parallelism); Kahn's algorithm (topological order from the DAG) |

**Premise correction (load-bearing).** #73 locked surf into panes on the premise that "agent teams
cannot run headless / only a teammate can host `/sail`'s crew." That premise is **verified FALSE**:
`/sail`'s lenses are CLI subprocesses (`claude -p` / `codex exec`) and Agent-tool subagents, not
agent-team teammates, and a top-level `claude -p` worker is depth-0 — so the depth-5 nesting limit
never bites. The headless body is therefore strictly simpler at no capability cost (see §4).
