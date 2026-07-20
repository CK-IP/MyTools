Run the `/sail` pipeline for a GitHub issue — Chris's compact `/ship` replacement (quality > speed > token use). Usage: `/sail <issue-number>`

`/sail` is the front door. You name an issue and the pipeline runs its stages **in order, automatically** — you never invoke the sub-tools by hand. It optimizes `/ship`'s quality at lower cost: a shift-left **plan** stage up front (catch defects before code exists), then build, then the deterministic gates + LLM review. The convergence loops (re-run until no high+ issues) are kept as the quality guarantee; the multi-round/dual-lens ceremony that makes `/ship` heavy is dropped.

## Stages (the front door fires these in order)

```
plan  →  build  →  review
```

### Stage 0 — Session run-dir

Create one **shared session run-dir** so the plan stage and the review stage write to the same place (shared `decision-log.md`, and the review can later find `plan.json`):

```bash
SESSION_DIR=".sail/runs/sail-<issue>-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$SESSION_DIR"
```

Pass `--run-dir "$SESSION_DIR"` to **both** `sail plan` and `sail run --diff` below.

### Metrics ledger (#146)

`sail metrics` keeps a per-repo JSONL telemetry ledger at `.sail/metrics.jsonl` — the enabler for
every future /sail tuning decision (you can't tune what you don't measure). It records cost, rounds,
outcomes, degraded flags (#116), backends, and escape rate. The ledger resolves to the **primary**
worktree's `.sail/` even when the run is isolated in a linked worktree, so a worktree prune at land
never drops the history.

- The file is created automatically on first write; no INSTALL.md setup (it's under the gitignored `.sail/`).
- **Emit is DRIVER-owned, once per converge CYCLE at the terminus** — never per `sail run` round (a
  per-round emit cannot know the cycle terminus and would corrupt the rates). At the Stage-4 terminus
  the driver appends one record, mapping the `sail converge` decision to `--terminus`:
  `proceed`→`merged-green`, `proceed-hardening`→`proceed-hardening`, `proceed-dissent`→`proceed-dissent`,
  `park`→`parked+<reason>`. Backends are read from the run's `SAIL_*` env automatically:
  ```bash
  python3 -m sail metrics record --run-dir "$SESSION_DIR" --issue <issue> --terminus <terminus>
  ```
- `python3 -m sail metrics report [--ledger PATH]` prints the cross-run rollup (run count, merge/park
  rate, avg rounds, degraded-run rate, cost per merged issue when cost data is present, escape rate).
- `python3 -m sail metrics escape <issue> [--note TEXT]` records a post-land defect against the
  most-recent shipped run for that issue (tie-break: latest finished), making review-escape rate computable.
- Metrics are **fail-open**: any write/report error is logged to stderr and never blocks or fails the run.

### Stage 0.5 — Isolate (opening git bookend, #65)

`/sail`'s **opening bookend**: by default isolate the run on its own git worktree + branch so it never collides with a separate ongoing run in the shared working tree (the live `/surf` incident in #65 was exactly this collision). This is the OPENING bookend; the **commit** lands at the end of Stage 3 (after green), and #59 (land/merge) is the closing bookend.

Compute the spec (Stage 1 fetches it; do it here so the decision can reuse `is_plan_risky`), detect a concurrent run, then ask the engine for the decision. The **decision + rationale is written to the decision-log on every path** by `sail isolate`:

```bash
# (RAW/SPEC are fetched as in Stage 1 — assemble once, reuse here and in plan.)
# Guard the source (set -e safe): ship-resume-safety.sh is an EXTERNAL cc-dotfiles dep —
# a bare `.` of a missing file aborts rc=127. If it's absent, sail_setup_isolation's
# `command -v ship_safe_cleanup_orphan_dir` check fails closed and falls back to in-place.
[ -f "$HOME/.claude/lib/ship-resume-safety.sh" ] && . "$HOME/.claude/lib/ship-resume-safety.sh"  # #125 orphan-safety guard (reused, not reinvented)
[ -f "$HOME/.claude/lib/sail-git-lifecycle.sh" ] && . "$HOME/.claude/lib/sail-git-lifecycle.sh"   # #65 git mechanics (plain git worktree)

# <!-- SAIL-ISOLATION-PREFLIGHT-BEGIN -->
# #88: the isolation infra is a HARD dependency, not optional. sail_setup_isolation /
# sail_concurrent_run come from sail-git-lifecycle.sh; ship_safe_cleanup_orphan_dir comes
# from ship-resume-safety.sh. If any is missing/unsourced the run would SILENTLY degrade to
# in-place on the shared tree with COMMIT=no, defeating #65 invisibly. Assert all three at
# run start; if any is undefined, HALT loudly (autonomous /surf parks — see the Decision
# contract) rather than silently proceeding in-place. Runs BEFORE the first sail_concurrent_run use.
if ! command -v sail_setup_isolation >/dev/null 2>&1 \
   || ! command -v sail_concurrent_run >/dev/null 2>&1 \
   || ! command -v ship_safe_cleanup_orphan_dir >/dev/null 2>&1; then
  echo "sail: FATAL — isolation infra not loaded (sail-git-lifecycle.sh / ship-resume-safety.sh missing or unsourced); refusing to silently run in-place on the shared tree (#88, #65)." >&2
  echo "sail: fix the install — symlink the libs into ~/.claude/lib per INSTALL.md — then re-run /sail <issue>." >&2
  exit 1
fi
# <!-- SAIL-ISOLATION-PREFLIGHT-END -->

REPO_ROOT="$(git rev-parse --show-toplevel)"
BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
CONCURRENT=""; sail_concurrent_run "$REPO_ROOT" <issue> && CONCURRENT="--concurrent"
DECISION="$(printf '%s' "$SPEC" | python3 -m sail isolate \
  --run-dir "$SESSION_DIR" --branch "$BRANCH" --default-branch main $CONCURRENT)"
MODE="$(printf '%s' "$DECISION" | cut -f1)"    # isolate | in-place
COMMIT="$(printf '%s' "$DECISION" | cut -f2)"  # yes | no

WORK_DIR="$REPO_ROOT"
# <!-- SAIL-ISOLATION-ISOLATE-BEGIN -->
if [ "$MODE" = "isolate" ]; then
  # Capture sail_setup_isolation's rc robustly (correct even under set -e).
  WORK_DIR="$(sail_setup_isolation "$REPO_ROOT" <issue>)" && isolate_rc=0 || isolate_rc=$?
  case "$isolate_rc" in
    0) : ;;  # isolated onto the worktree; WORK_DIR is the new path
    3)
      # rc=3 is the lib's collision-specific signal (#92): branch sail/<issue> is held by another
      # live worktree (a true parallel run). The lib already positively confirmed the collision,
      # so the driver just trusts the code — no re-deriving it from `git worktree list`. Fall back
      # to in-place with COMMIT=no: never clobber the parallel run, never pause (#65 no-pause).
      echo "sail: sail/<issue> is held by a concurrent run — falling back to in-place (no commit); not clobbering the parallel run." >&2
      WORK_DIR="$REPO_ROOT"; COMMIT="no"
      ;;
    *)
      # Any other non-zero (rc=1 generic git/worktree error, rc=2 bad issue, rc≥2 incl. 127 =
      # undefined function): a real isolation infra/git error, NOT a collision. HALT loudly;
      # never silently degrade to in-place on the shared tree (#88, #65).
      echo "sail: FATAL — sail_setup_isolation returned rc=$isolate_rc (isolation infra/git error, not a concurrent-run collision); refusing to silently run in-place (#88)." >&2
      exit 1
      ;;
  esac
  cd "$WORK_DIR"
fi
# <!-- SAIL-ISOLATION-ISOLATE-END -->
```

**Decision contract (mirrors `--dual-lens`/`--plan-adversary` risk-gating):**

- **Isolate by default** on the default branch → worktree `.claude/worktrees/sail-<issue>` on a fresh `sail/<issue>` branch.
- **On a feature branch already** (e.g. `/surf`'s `surf/<issue>`) → stay in place and commit on **that** branch — by design (forcing a `sail/<issue>` checkout would fight `/surf`); the `sail/<issue>` name applies only to the from-default isolate path.
- **Risk-gated skip** (`--in-place`): work in place with **no commit** ONLY when not plan-risky AND no concurrent run; either condition flips it back to isolate. `--isolate` forces isolation (the two flags are mutually exclusive).
- **Concurrency-safe:** `sail_setup_isolation` idempotently **reuses** an existing clean `sail/<issue>` worktree (rerun-safe) and never destroys unsaved work — a true parallel-run collision makes it fail, and the driver falls back to in-place rather than clobbering the other run (autonomous `/surf` never pauses).
- **Hard dependency, not optional (#88):** the isolation infra (`sail_setup_isolation` / `sail_concurrent_run` from `sail-git-lifecycle.sh`, plus `ship_safe_cleanup_orphan_dir` from `ship-resume-safety.sh`) is **load-bearing**. A run-start preflight asserts all three are defined; if any is missing/unsourced the run **HALTS loudly** (autonomous `/surf` parks to its WIP handoff) — it never silently degrades to in-place on the shared tree. This is distinct from a genuine **collision** (a parallel run holds `sail/<issue>`), which is the one case where falling back to in-place with `COMMIT=no` is correct: `sail_setup_isolation` returns the collision-specific **rc=3** when (and only when) `sail/<issue>` is positively confirmed checked-out in another live worktree, and the driver maps **rc=3** to in-place; any other non-zero rc (rc=1 generic git/worktree error, or rc≥2/undefined) HALTS. The lib owns the collision decision, so the driver no longer re-derives it from `git worktree list` (#92).

All of plan → build → review then run **inside `$WORK_DIR`** (`--target .` from there). The mechanism is **plain `git worktree`** so it works in the autonomous/pinned-cwd `/surf` subagent (native `EnterWorktree(create)` is rejected there).

### Stage 1 — Plan (auto-fires; bounded convergence loop)

Fetch the issue, **checking `gh`'s exit code before feeding the planner** (a bare pipe would not), then run the plan stage:

```bash
RAW=$(gh issue view <issue> --json title,body,comments,author) || { echo "sail: gh failed to fetch issue <issue> — aborting"; exit 1; }
SPEC=$(python3 -m sail spec <<< "$RAW") || { echo "sail: issue <issue> spec is empty or has no body — aborting"; exit 1; }
# Derive TITLE ONCE here, at the top, so it is in scope for EVERY later stage that needs it —
# the Stage-2 mutation-verify `--title` gate (#131), the Stage-4 commit subject, and the Stage-5
# land/merge subject. (Without this, the Stage-2 `--title "$TITLE"` call receives an empty string →
# is_bug_fix_title("") is False → mutation-verify silently no-ops on every issue — #131 review HIGH.)
TITLE="$(printf '%s' "$RAW" | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])')"
python3 -m sail plan --target . --run-dir "$SESSION_DIR" <<< "$SPEC"
```

**Why `--json title,body,comments,author | sail spec` (#60):** the planner — and `is_plan_risky` — must see the **full** issue (body **and** comments), because the #55 failure shape needs a remediation signal and a reconcile/list signal that often live in *different* parts of the issue. A bare `gh issue view <issue>` is body-only, and `gh issue view <issue> --comments` is comments-only on some `gh` versions; either feeds a partial spec and the heuristic under-fires. The two statements above keep `gh`'s exit code genuinely checked (not swallowed by a pipe): `gh` is captured first, then `sail spec` assembles title + body + comments and **fails closed** (exit 1) on an empty fetch or an issue with no body. Comment bodies are wrapped by `sail spec` in an explicit untrusted-data fence, and `SAIL_COMMENT_TRUST=all|author|none` controls how much of that comment data is exposed to the planner (`all` default, `author` only the issue author's comments, `none` body-only).

`sail plan` does ONE LLM pass and writes `plan.json` (approach, acceptance criteria, test plan, a lightweight design/security risk check, and scope). The pass also runs a **free consistency self-check (#58):** for every user-facing instruction or remediation the change introduces, the plan must name the exact action in the change that fulfills it — a promise with no matching delivered action (an unresolvable remediation loop, an unreconciled file/list) is recorded as a blocking risk. This catches the broken promise→action failure class at plan-time, in the same single pass (no extra agent). The same pass also **surfaces design alternatives (#61):** when the spec carries a genuine design choice with no single right answer (the #55 doctor count: N=8 vs N=9), it populates a `design_alternatives` list (`option` / `tradeoff` / `recommended`) so a reviewer — auto or supervised human — sees the call and the trade-off the consistency check is blind to. This is **informational, never blocking** (it does not affect the exit code), and stays empty for trivial specs (no invented alternatives). The pass also requires **diff-verifiable acceptance criteria (#81):** each AC must assert something **observable in the diff** ("adds test `T20` pinning X", "review.py gains the probe directive"), never a **run-state claim** ("the suite still passes") — the diff-scoped reviewer sees only the diff, not a live run, so run-state guarantees are the deterministic pytest gate's job, not an LLM-checked AC. This is the preventive half of #81 (the oscillation symptom is already mitigated by the `unknown`-non-blocking spine + #77/#100); authoring ACs the reviewer can actually check against the diff keeps `plan_verification` from oscillating `unknown`↔`unmet`. The pass also carries a **risk-gated runtime/platform-assumptions probe (#129):** repo-grounding confirms a symbol/file *exists* but not that the change works in the **runtime** it actually runs in — the gap behind #127/#128 (a `#!/usr/bin/env bash` library sourced under the `/bin/zsh` runtime via a symlink, which bash-only tests passed) and #124 (a Mac-unfriendly `setsid` substrate surfaced only at review round 7). The gating is a **deterministic, unit-tested Python predicate** (`is_runtime_sensitive(spec)` in `sail/plan.py`, mirroring `is_plan_risky`), **not** a prompt-only conditional — so "would it have flagged #127/#128?" and "does it stay quiet on an ordinary diff?" are both hermetically testable. When the spec touches a runtime/OS/shell-sensitive surface (a shell script, a command sourced/executed by another process, a symlinked artifact, or OS-specific tooling), the `RUNTIME_PLATFORM_PROBE` directive is **conditionally injected** into both the blind `build_prompt` and the grounded `build_grounded_prompt`, directing the plan to record the assumptions to verify — runtime **shell**, **symlink** indirection, target **OS**, and external-tool availability — as explicit plan items/risks. An ordinary, non-runtime spec gets the directive **not at all** (zero added tokens — the no-cost-regression property). Its exit code is the convergence signal:

`sail plan` also re-reads `.ship/domain.md` on each invocation and injects it as DOMAIN MEMORY when present, so a domain answer written between checkpoints is picked up on the next plan pass without a relaunch.

- **exit 0** — no blocking (CRITICAL/HIGH) risks → the plan is clean, proceed.
- **exit 1** — blocking risks present (or an unusable backend on a non-empty spec, or an empty spec) → revise and re-run.

**Bounded convergence loop (single lens):** while `sail plan` exits 1, present the plan + its blocking risks to the user, revise the spec/approach, and re-run — bounded by the `sail converge` guardrails (the hard `--max-rounds` ceiling backstops the cheap plan passes; the trend-stall/cost guards primarily bound the expensive review loop — see § Convergence guardrails). If still blocking at the ceiling, resolve the terminus via the **terminus guard** (see § Unattended mode): compute `ACTION=$(python3 -m sail terminus --unattended "$UNATTENDED" --interactive "$INTERACTIVE")` and branch **before any prompt** — `ask` → present `plan.json` + its risks and ask the user (continue / abort / proceed-advisory `--advisory`); `auto` → consult `python3 -m sail converge` (no prompt); `park-loud` → `sail handoff` and stop. Do not loop unbounded, and never auto-select a recommended option on a denied/unrenderable prompt.

**`--plan-adversary` risk-gated escalation (#58).** Default plan is **single-pass** (the self-check above is free; most plans stay 1-pass — no uniform weight). When the change is **plan-risky** — it touches user-facing instructions/remediation, or reconciles multiple files/lists — `/sail` escalates to a **one-shot adversarial plan pass**: an independent second pass over the same spec with adversarial framing (it re-derives the gaps a careless author would miss; like `--dual-lens`'s second lens, it reviews independently rather than grading the first pass's output). The auto-trigger fires only on the strong #55 failure shape — a remediation/instruction signal **and** a file/list-reconciliation signal co-occurring, or an unambiguous failure phrase — so ordinary specs ("run the tests", "improve the error message") stay single-pass. Escalation fires when `--plan-adversary` is passed **or** the auto-trigger heuristic (`is_plan_risky`) detects a plan-risky spec, mirroring the review stage's `--dual-lens` escalation:

```bash
SAIL_PLAN_CMD2="codex exec -m gpt-5.5 -c model_reasoning_effort=high" \
  python3 -m sail plan --target . --run-dir "$SESSION_DIR" --plan-adversary <<< "$SPEC"
```

The adversary runs as a second independent backend (`SAIL_PLAN_CMD2`); its **explicitly CRITICAL/HIGH risks union into the plan gate** (each tagged `lens: adversary` in `plan.json`), and the gate fails closed (and writes `status: error` to `plan.json`, matching the exit code) if the adversary backend errors. On plan-risky work the adversary runs **even when the author plan is already blocking (#62)** — reversing the earlier skip-when-already-red. The skip saved a call but threw away the adversary's reason for being: a second, independent **design** perspective (the lens most likely to catch a wrong design shape, a materially simpler approach, or a design choice a single author pass misses). When a consistency bug is already flagged the gate is red regardless, but the adversary's job is **design breadth, not adding to the blocking count** — so its independent CRITICAL/HIGH design findings still union into `plan.json` (tagged `lens: adversary`) for the reviewer. Cost stays risk-gated (escalation still requires `--plan-adversary` or `is_plan_risky`), so only the rare risky-and-already-blocking intersection pays one bounded extra call; an adversary backend error fails closed uniformly (`status: error`, exit 1) regardless. `--plan-adversary`/auto-trigger with no `SAIL_PLAN_CMD2` degrades cleanly to single-pass (logged, not an error) — exactly as `--dual-lens` degrades with no `SAIL_REVIEW_CMD2`.

**`--grounded-plan` / `SAIL_PLAN_GROUNDED_CMD` risk-gated grounding (#93).** Default plan is **blind** — the author pass sees only the spec text. On a **plan-risky** spec (`is_plan_risky`) — or when `--grounded-plan` forces it — `/sail` escalates to a **grounded** pass: a tool-using backend (`cwd=target`) that Read/Greps the repo to verify the spec's assumptions against the real code (does each named function/file/constant exist? what is the real count/list to reconcile? does any code re-derive state internally so a planned test would be silently defeated?), and is **evidence-required** — every risk cites concrete tool-execution evidence or is dropped. Backend selection falls back **Codex → Claude → blind**: `SAIL_PLAN_GROUNDED_CMD` (e.g. `codex exec`) if runnable, else the default author backend run grounded, else degrade to the blind plan (logged, not an error). Because the grounded pass emits the full plan schema, when the author backend is absent it serves as the planner itself (`grounded.role: planner`); otherwise its evidenced CRITICAL/HIGH risks union into the plan gate tagged `lens: grounded` (`grounded.role: union`). A grounding-backend error fails closed (`status: error`, exit 1), mirroring `--dual-lens`. Ordinary non-risky specs stay single-pass (no grounding call).

```bash
SAIL_PLAN_GROUNDED_CMD="codex exec -m gpt-5.5 -c model_reasoning_effort=high" \
  python3 -m sail plan --target . --run-dir "$SESSION_DIR" --grounded-plan <<< "$SPEC"
```

**Fail closed on a skipped plan:** before proceeding to build, read `plan.json`. If `status == "skipped"` (no LLM backend was available), do **not** silently proceed — halt with: "no LLM backend — the plan stage did not validate; install `claude` or set `SAIL_PLAN_CMD`, then re-run." This mirrors how `sail run --diff` fails closed when a requested review has no backend.

### Stage 2 — Build (TDD, guided)

With a clean `plan.json` as the agreed baseline, build the change test-first: write a failing test that pins each acceptance criterion, then the minimum code to pass it, keeping the suite green at each step. The `sail-tdd-guard` hook (if installed) enforces a failing-test marker before source edits.

**`SAIL_BUILD_CMD` pluggable build backend (#95).** Stage 2 invokes `python3 -m sail build` by default when `SAIL_BUILD_CMD` is set; inline is the default only when `SAIL_BUILD_CMD` is unset. To delegate the expensive code-writing (and the per-round convergence fixes in Stage 3) to a configurable fast backend, set `SAIL_BUILD_CMD` and run:

```bash
SAIL_BUILD_CMD="claude -p" \
  python3 -m sail build --target . --run-dir "$SESSION_DIR"
```

Branch on `build.json`'s `status`: **`delegated`** → INFO; the backend wrote the change, so proceed to review. **`inline`** → inspect `reason`: `backend-unset` is INFO (expected clean degrade; inline is the default only when `SAIL_BUILD_CMD` is unset), while `backend-not-runnable` is ALERT (unexpected fallback, cross-family build lost) when `SAIL_BUILD_CMD` was set. **`error`** → **fail closed** (a missing `.sail/last-test-failed` marker, a backend error, or — in fix-mode — a missing/incomplete `review.json`); halt and surface, do not proceed. TDD is **enforced** on the delegated path: `sail build` fails closed unless a failing-test marker (`.sail/last-test-failed`) is on record — the failing test is authored first (the cheap part stays inline/leadsman-owned), only the code-writing is delegated, and the backend is told never to weaken or delete the failing test.

**Prose/spec routing (#133).** `sail build` classifies the change before it picks a backend: doc-dominated changes (`.md` / `.rst` via the shared `checkers._DOC_SUFFIXES`) are `prose`, everything else is `code`. Pass `--change-class prose|code` to override the deterministic backstop; when the flag is omitted, the runner derives the class from `plan.json`'s scoped `scope.in` files. Prose changes prefer the optional `SAIL_BUILD_CMD_PROSE` backend first, then fall back to `SAIL_BUILD_CMD`. When the selected prose builder resolves to the same family as the active reviewer lens (`SAIL_REVIEW_CMD`, and `SAIL_REVIEW_CMD2` when set), `build.json` records `cross_family: "lost"` plus a `same_family_warning`, the run still proceeds as `delegated`, and the operator should treat it as an **ALERT** per #112. Code-class routing stays on `SAIL_BUILD_CMD` and is unchanged.

**Mutation verification (`mutation.verify` / `mutation-verify`, #131).** After the green TDD build, run the executable mutation-verify check for bug-fix diffs that also introduce new/changed tests and non-test source changes. It is a deterministic no-op unless all three conditions hold: the issue is a bug-fix, the diff contains at least one new/changed test file, and the diff contains at least one non-test source change. Pass the raw issue title and let the engine decide — `python3 -m sail mutation-verify --target . --diff <base-ref> --run-dir "$SESSION_DIR" --title "$TITLE"`: the bug-fix decision is the **deterministic, unit-tested `is_bug_fix_title` predicate** in `sail/mutation_verify.py` (a conventional-commit `fix`/`bugfix`/`hotfix` title), **not** an orchestrator judgment call — so always pass `--title` rather than deciding bug-fix-ness in this prompt (CLAUDE.md infra-placement). `--bug-fix` remains an explicit operator override for the rare bug-fix whose title lacks a conventional-commit prefix. When it fires, the check reverts only the source hunks with `git apply -R`, reruns the new/changed tests as a collective verdict, and restores the tree (index state included — it never `git add`s the source) in a `try/finally` so a crash cannot leave the working tree mutated. A clean pass under the revert emits `category: test-adequacy` findings tagged `lens: mutation-verify` into the existing review pipeline (freshness-gated by `diff_hash`). This complements, and does not replace, the #70 inline mutation-survival probe in Stage 3.

**Backend choice — codex vs Sonnet 5 (#83).** Both work; document both. **codex (`gpt-5.4-mini`)** is cheapest, but if you also run `--dual-lens` with `SAIL_REVIEW_CMD2="codex …"`, codex becomes both the implementer **and** review lens2 → same-family self-review (the #83 rubber-stamp risk). **Sonnet 5 (`claude -p`)** keeps the implementer in a **different family** from the codex review lens, preserving genuine cross-family review of the implementation. **Recommended: Sonnet 5 for `SAIL_BUILD_CMD`** whenever a codex review lens is active; keep lens1 = `claude`. If `SAIL_BUILD_CMD` is set, `SAIL_REVIEW_CMD` is the single-lens `claude` reviewer, and `build.json` comes back `inline` with `reason: backend-not-runnable`, raise an **ALERT** that builder=reviewer=claude and the cross-family review was lost. `sail build` emits an advisory `same_family_warning` in `build.json` when the selected build backend and an active review lens resolve to the same family (best-effort, wrapper-aware, non-blocking).

**Live default — codex builds / claude reviews (#83).** The shipped allocation (see `home/settings.reference.json`) is **codex builds** (`SAIL_BUILD_CMD="codex exec -m gpt-5.4-mini"`) and **claude reviews** (lens1 `SAIL_REVIEW_CMD` = sonnet, escalating to opus at round 3). This satisfies the #83 cross-family invariant (implementer ≠ reviewer family) *without* a codex review lens: **`SAIL_REVIEW_CMD2` is intentionally unset** (no `--dual-lens`), so claude lens1 already provides the cross-family review of codex-built code — the conditional Sonnet-for-build guidance above applies only *when a codex review lens is active*, which this allocation deliberately is not. **Do not re-add `SAIL_REVIEW_CMD2`** to restore a second build/review lens: codex-as-lens2 over codex-built code would be same-family self-review (the very rubber-stamp risk #83 guards against), while claude lens1 already covers the cross-family angle. (`SAIL_TIDINESS_VERIFY_CMD` is likewise left unset → the Gear-2 tidiness check stays advisory-only.)

**Codex-availability latch (#107).** When a codex-family backend fails for an **availability** reason (out of credits / auth / network — not a normal task error), `/sail` writes a session-scoped marker (`${SAIL_STATE_DIR:-~/.sail}/codex-down`) and treats **every** codex-family backend as not-runnable for the rest of the session, degrading cleanly to the non-codex backend (e.g. Claude) — so it never re-launches a codex it already knows is down. The trip and each subsequent skip are logged visibly to stderr, and the latch **never blocks the run**. If codex's error reports a reset time, the latch auto-expires then (so a long run resumes codex once credits return); otherwise it stays latched for the rest of the session. A new session never inherits an old marker (stale-session cleanup on a different session id). **Caveat:** reset-time parsing is best-effort and depends on codex's error-string format staying stable. Tests override `SAIL_STATE_DIR` to isolate the marker (hermetic), so the latch never reads or writes the real `~/.sail` marker.

**Prove hermeticity — don't assume it (advisory, #64).** When a test claims to be *hermetic* / *isolated*, the autonomous author must **prove** the isolation, not assert it in the docstring and move on — an isolation that is a silent no-op flakes the same way the host-coupled test it replaced would. Concretely: a test that pins behavior under a scrubbed/empty `PATH` (or any cleared env/state) must confirm the **code under test does not silently re-derive** that state behind the test's back. The canonical failure (#55-v2): a "hermetic" `PATH` test was defeated because `doctor.sh` **re-augmented `PATH` internally**, so the scrubbed-environment check passed while the test still read the host — caught only at review, costing a round. The fix was a `CK_DOCTOR_NO_PATH_AUGMENT` test seam that lets the code skip its own augmentation under test. **The rule, with its escape hatch in the same breath:** scrubbing the *caller's* environment is **not sufficient** when the code re-derives state internally — so if a test cannot be made genuinely hermetic without a code seam, **add that seam in the same change** (the `CK_DOCTOR_NO_PATH_AUGMENT` pattern) rather than ship a test whose isolation silently does nothing. This is a **prompt-level reminder, not a new gate** — it adds no exit code and never blocks convergence; it just keeps `/sail`'s own autonomous TDD from manufacturing the review churn it exists to avoid.

### Stage 3 — Review (deterministic gates + blocking LLM review)

Run the existing one-pass gate + review over the change, into the **same** session run-dir:

```bash
python3 -m sail run --target . --diff <base-ref> --run-dir "$SESSION_DIR" --round N --tidiness
```

This runs the deterministic gates (ruff, mypy, pytest, bandit, semgrep, pip-audit — diff-scoped) **and** the blocking single-lens LLM review in one pass. The `--tidiness` flag adds the advisory tidiness/simplify lens (below).

**Mutation verification re-run (#131/#141, per round).** At the top of **every convergence round**, before that round's `python3 -m sail run --diff ...`, re-run `python3 -m sail mutation-verify --target . --diff <base-ref> --run-dir "$SESSION_DIR" --title "$TITLE"` against the round's current diff so `mutation-verify.json` is refreshed each pass — this closes the later-round gap (a vacuous test introduced in a later review round is re-checked; a stale prior-round artifact is dropped by the `diff_hash` freshness gate, never injected). The absent-runner visibility is **CLI-owned, not prompt-owned**: when the payload's `runner_absent` is true (a new/changed test needed a runner binary that was absent), the CLI itself prints `[ALERT] mutation-verify: tests were not actually run — pytest runner was absent` to stderr (the tested `runner_absent_alert` helper in `sail/mutation_verify.py`, per the #112 tone rule) — the driver just lets that stderr surface; an ordinary run (runner present) emits no ALERT.

`sail run --diff` also re-reads `.ship/domain.md` on each review invocation and injects it as DOMAIN MEMORY when present, so a domain answer written between checkpoints is picked up on the next review pass without a relaunch.

**Scanner findings as review triage context (#69).** Within this one pass the order is **series, not parallel**: the deterministic gates run **first**, and each gate's NEW diff-scoped findings (ruff/bandit/semgrep/pip-audit/…) are then fed into the LLM review as **triage context** — the hybrid LLM+SAST approach the literature found strongest (LLM-as-FP-filter over scanner output). Seeing what the scanners already flagged, the reviewer **corroborates** the genuine alarms (and raises confidence on them), **notes likely false positives** in its summary, and spends its own effort on the defects scanners can't catch (authorization/ownership gaps, business logic, design, scope) rather than re-deriving the scanner hits. The scanner block is delimited and marked **untrusted data** (it can carry attacker-influenced diff content — OWASP LLM01), so the reviewer never treats it as instructions. **Crucially, the triage is purely advisory and the deterministic gate stays authoritative:** a new blocking scanner finding still blocks the run on its own, regardless of what the LLM says about it — the LLM verdict never suppresses a gate block. With no diff gate findings (or in whole-repo/baseline mode) no triage block is emitted and behavior is unchanged.

**Test-adequacy probe (#70).** Coverage % alone is a weak proxy — the measured failure mode is a test that passes *even when the code is broken* (research found >99% of some LLM-generated "failing" tests still passed on unmutated code). So the **same single review pass** now carries a cheap mutation-survival probe: for the diff's core behavior change, the reviewer names a plausible mutation (a flipped comparison, off-by-one, dropped guard) and asks whether the diff's new/changed tests would actually FAIL under it. A test that would still pass — it asserts nothing, checks a tautology or only its own mock, re-implements the code it claims to verify, or pins an incidental detail — is flagged as a finding with category **`test-adequacy`** (vacuous/tautological test). It rides the existing finding pipeline: severity stays reviewer-assigned (a NEW feature whose only test is vacuous lands HIGH and blocks via the normal `has_blocking` flow; a weak signal lands MEDIUM/LOW and surfaces without blocking), so there is **no second LLM call and no new exit-code path**. The probe **no-ops on test-free diffs** (a code-only or docs-only change is not a finding — it does not invent missing-test complaints) and stays within the existing >80%-confidence bar. This is a deliberately cheap inline proxy; the gold-standard **full mutation-testing tool run is deferred to the `/fortify` stage** (heavy, run-on-demand), not inline here.

**Plan↔review traceability spine (#47).** Because Stage 0 put `plan.json` in this same run-dir, the review stage reads its `acceptance_criteria` and records per-criterion `met / unmet / unknown` in `review.json`'s `plan_verification` block (the define-at-plan → verify-at-review spine). An **unmet** AC blocks (the spine has teeth); an absent plan is non-blocking (`no-plan`); a malformed `plan.json` **fails closed** (`status: error`, blocks) — it is never silently treated as no-plan.

**Bounded convergence loop (review stage — driver-owned).** A non-zero exit means a gate failed, the review found CRITICAL/HIGH findings, or an AC is unmet. Mirror the plan stage's loop: fix the surfaced findings, **record a per-finding disposition each round** (`addressed` / `deferred` / `rejected` + a one-line rationale, keyed by the finding's stable `id` from `review.json`), and re-run `sail run --diff`. The loop is bounded by the `sail converge` guardrails (trend-stall + cost backstop, with the hard `--max-rounds` ceiling as the ultimate backstop — see § Convergence guardrails), **not** a fixed round count: a genuinely-converging run keeps going while a churning or runaway one is parked. If still blocking when a guard fires, resolve the terminus via the **terminus guard** (see § Unattended mode): compute `ACTION=$(python3 -m sail terminus --unattended "$UNATTENDED" --interactive "$INTERACTIVE")` and branch **before any prompt** — `ask` → present `review.json`'s findings + `plan_verification` and ask the user (continue / abort / proceed-advisory); `auto` → consult `python3 -m sail converge` (no prompt; honor `proceed`/`revise`/`park`/`proceed-hardening`/`proceed-dissent`); `park-loud` → `sail handoff` and stop. The single-invocation exit code is unchanged; the driver owns the re-run-after-fix loop, and never auto-selects a recommended option on a denied/unrenderable prompt.

**Per-round fix delegation (`SAIL_BUILD_CMD`, #95).** When `SAIL_BUILD_CMD` is set, route each convergence round's fixes through the same build backend instead of re-implementing inline-on-Opus every round (the dominant per-round wall-clock cost the ab-86b A/B measured):

```bash
SAIL_BUILD_CMD="claude -p" \
  python3 -m sail build --target . --run-dir "$SESSION_DIR" --mode fix --round N
```

`--mode fix` reads `review.json` (stable finding ids + severities) and the decision-log dispositions from the shared run-dir and feeds the live findings to the backend; it **fails closed** if the `.sail/last-test-failed` marker is missing, `review.json` is missing or not `status: completed`, or the decision-log is present but undecodable. With `SAIL_BUILD_CMD` unset, fixes stay inline as today (clean degrade).

**Docs-impact check (advisory definition-of-done, #56).** Before declaring the change done, run this lightweight checklist item: *does the change add a new **external tool dependency** (a new CLI the gates invoke) or a new **config knob** (e.g. a `.ship/domain.md` setting or an `env` var)? If so, verify `INSTALL.md` — this repo's source-of-truth for setup — and any relevant docs are updated to document it.* This recovers the docs-completeness `/ship`'s heavier planning surfaced (the #52 A/B shipped `diff-cover` + `diff-coverage-threshold:` with no `INSTALL.md` note). It is **purely advisory** — a prompt-level reminder, **not a new gate**: it adds no exit code, no deterministic check, and never blocks convergence. An undocumented dependency = a silently-dormant feature for the next person, so surface it and update the docs in the same change.

**`--round` multi-round discipline.** The driver increments `--round N` on each re-run, starting at 1. Round `N > 1` feeds the reviewer the prior round's findings + resolutions from the shared run-dir and tells it to review only the inter-round diff, so carried items stay stable instead of being re-litigated.

**Per-round model escalation.** Keep early rounds on the cheaper `SAIL_REVIEW_CMD` backend. On later rounds, set `SAIL_REVIEW_CMD_ESCALATED` to a stronger backend and optionally `SAIL_REVIEW_ESCALATE_ROUND` (default 3) to switch over once the round threshold is reached. The active backend is selected per round, so round 1 stays light and later rounds can escalate cleanly.

**`--dual-lens` risk-gated escalation (#47).** Default review is **single-lens** (industry norm; convergence is the quality mechanism). For a high-stakes diff — or when you simply want a cross-family second opinion — pass `--dual-lens` and set `SAIL_REVIEW_CMD2` to a second backend (e.g. a codex CLI):

```bash
SAIL_REVIEW_CMD2="codex exec -m gpt-5.5 -c model_reasoning_effort=high" \
  python3 -m sail run --target . --diff <base-ref> --run-dir "$SESSION_DIR" --dual-lens
```

Both lenses review independently; their findings are unioned (each tagged `lens1`/`lens2` in `review.json`) and the gate blocks if **either** lens blocks or errors. `--dual-lens` with no `SAIL_REVIEW_CMD2` degrades cleanly to single-lens (logged, not an error).

**`--red-team` risk-gated repo-exploring escalation (#66).** The default review (lens1, and lens2 under `--dual-lens`) is a single LLM pass over the diff **text** — it cannot hunt *beyond* the diff (a break in an out-of-diff caller slips past) and, with no tool-execution requirement, it can hallucinate findings it never verified (the real example: `/sail`-v1 raised a false "`info()` is undefined" that a file-read would have killed — `info()` is defined at `doctor.sh:31`). `--red-team` adds the review/implementation-side analogue of the #62 plan-adversary: on a **high-stakes diff** it escalates to a **tool-using** adversarial pass that **explores the repo beyond the diff** (Read/Grep related files, trace callers) and is **evidence-required** — every finding must cite concrete tool-execution evidence, and an unevidenced finding is **dropped, never blocked** (the precision lever; mirrors `/ship`'s repo-exploring `red-team` agent contract). This improves both recall (beyond-diff defects) and precision (verified findings), exactly where it matters.

- **Risk-gated, never always-on (marginal-value).** `is_high_stakes(diff)` is a deterministic predicate: a diff is high-stakes when it touches a **declared decision-spine / core-interface path** (comma-separated substrings in `SAIL_REDTEAM_SPINE_PATHS`, e.g. `sail/runner.py,sail/checkers.py` — fires regardless of diff size, so a small edit to a critical dispatcher/interface still escalates), is **cross-cutting** (touches ≥ `SAIL_REDTEAM_FILE_COUNT` files, default 5), is **large** (≥ `SAIL_REDTEAM_LINE_COUNT` changed lines, default 80), **or security-relevant** (touches an injection/secret/authz/crypto surface). An ordinary small diff does **not** trip it — no escalation, no token/time regression vs. current behavior. `SAIL_REDTEAM_SPINE_PATHS` defaults empty (the operator declares their spine, so the default never over-fires). `--red-team` **forces** the pass even on a low-stakes diff (mirrors `--plan-adversary`).
- **Opt-in by backend — purely additive.** The escalated pass runs only when `SAIL_REDTEAM_CMD` points at a **tool-capable** backend (a `claude`/`codex` CLI that can Read/Grep); it is invoked with `cwd` set to the target so its exploration resolves against the repo. With `SAIL_REDTEAM_CMD` unset, a high-stakes diff **degrades cleanly to the single-lens review** (logged, not an error) — so #66 changes nothing unless you opt in (mirrors `--dual-lens`/`SAIL_REVIEW_CMD2`).
- **Findings merge into the convergence stream.** Evidenced findings union into the correctness `findings` (each tagged `lens: "redteam"`), so CRITICAL/HIGH ones block via the same `has_blocking` path the loop already consumes — no separate, divergent handling. Audit metadata (and the dropped unevidenced findings) is recorded under a `red_team` key in `review.json`. This is kept **distinct from the tidiness/code-health lens** (#63/#80): the red-team is correctness-side; tidiness is cleanup-side.
- **STRIDE-lite, same gate.** When the high-stakes diff is **security-relevant**, the red-team prompt folds in a **STRIDE-lite** block — ~6 per-changed-element threat questions (spoofing / tampering / repudiation / information-disclosure / DoS / elevation). It rides the **same** high-stakes gate (full per-PR STRIDE is overkill; gate it like AWS's PR-time threat modeling) and never runs on a low-stakes or non-security diff.
- **Fails closed.** A red-team backend error (bad rc / unparseable) sets `review.json` `status: error` and blocks (never-mask) — a high-stakes diff whose red-team could not complete must not pass as if reviewed (mirrors the `--dual-lens` lens2 contract).

```bash
SAIL_REDTEAM_CMD="claude -p" \
  python3 -m sail run --target . --diff <base-ref> --run-dir "$SESSION_DIR" --round N --red-team
```

**`--tidiness` code-health lens — tiered, marginal-value enforcement (#63, #80).** `/sail` deliberately dropped `/ship`'s simplify step — that omission let non-blocking *messiness* (a redundant line, an `N=9` that should be `N=8`, dead locals) ship even when the correctness review converged at "0 high-severity". Code health *is* code quality, and a non-coder adds ~zero value judging it — so it must be a **machine** lens. `--tidiness` adds a **separate** pass that ports Anthropic's `/code-review` + `/simplify` intent (reuse/de-duplication, simplification, dead code, naming, efficiency, altitude). It is kept **strictly separate** from the correctness review and the cross-family `--dual-lens` (codex = different *bugs*; tidiness = *cleanup*), so it never dilutes the adversarial bug-finding craft — its findings stay under their own `tidiness` key in `review.json` (each tagged `lens: "tidiness"`) and never enter the correctness `findings`/`counts`. The front door passes `--tidiness` by default (above) to close the gap.

Unlike `/ship`'s simplify stage (which runs unconditionally on every change), `/sail` follows a **marginal-value rule**: heavy work fires only when justified. A clean diff pays almost nothing; a genuinely messy/wasteful diff gets `/ship`-grade treatment, but only then. Enforcement is **3-gear**:

- **Gear 1 — generation (always, cheap).** The lens lists candidates, each tagged by `tier`: **`block`** (an EGREGIOUS, high-confidence, low-effort defect — an unambiguous easy win like dead code / a trivial duplicate / an obviously-wrong constant, **or** an egregious efficiency defect with an obvious cheaper alternative on a hot/reachable path) vs **`advisory`** (diminishing-returns polish — the default).
- **Gear 2 — verification (only on a would-block candidate).** A `block`-tier candidate gets teeth **only if an independent cross-family (Codex) lens confirms it** — set `SAIL_TIDINESS_VERIFY_CMD` (falls back to `SAIL_REVIEW_CMD2`, the `--dual-lens` backend). This is a deliberate false-positive filter: an unconfirmed candidate is **demoted to advisory**, never blocked. A clean / all-advisory diff triggers **no verification call at all**. The verifier **must be a different family** from the Gear-1 tidiness lens — that is what makes the confirmation independent. When it resolves to the **same** family (e.g. `SAIL_TIDINESS_VERIFY_CMD` pointed at the same backend as `SAIL_TIDINESS_CMD`), the review emits a `same_family_warning` in `review.json`'s `tidiness` block and an `⚠` decision-log line: the "confirmation" may be rubber-stamping (an integrity gap → **ALERT** per the tone taxonomy below). This is a best-effort, wrapper-aware **warning**, not hard family-enforcement.
- **Gear 3 — fix-and-recheck (only if confirmed).** Confirmed `block`-tier findings surface under a `blocking` key in the `tidiness` block and **fold into the blocking exit code** /sail's convergence loop already runs (alongside CRITICAL/HIGH correctness findings and unmet ACs).

- **Efficiency false-positive guardrail.** A *blocking* efficiency finding must state **(a)** current complexity, **(b)** the concrete cheaper alternative, **(c)** why the path is hot/reachable — else it is demoted to advisory (mirrors the #69 scanner-triage FP filter). The `block` decision is the lens's `tier`, not its `severity` — severity stays `MEDIUM`/`LOW`.
- **Advisory tier never blocks.** Diminishing-returns polish is recorded under `tidiness` for the driver/human to apply and **never changes the exit code** — exactly as the whole lens behaved before #80.
- **Efficient by two knobs.** Point the lens at a cheaper/lower-effort model with `SAIL_TIDINESS_CMD` (falls back to the default review backend when unset), and/or run it only on larger diffs with `SAIL_TIDINESS_MIN_LINES` (default `0` = any non-empty diff; set higher to skip small diffs). Either knob keeps the extra pass cheap.
- **Degrades cleanly.** An empty diff, a size-gated skip, a missing tidiness backend, a missing cross-family verifier, or an unusable response all record `"status": "skipped"` (or demote candidates to advisory) — **never a hard error, never a blocked run**.

```bash
SAIL_TIDINESS_CMD="claude -p" \
SAIL_TIDINESS_VERIFY_CMD="codex exec -m gpt-5.4-mini" \
SAIL_TIDINESS_MIN_LINES=40 \
  python3 -m sail run --target . --diff <base-ref> --run-dir "$SESSION_DIR" --round N --tidiness
```

### Stage 4 — Commit (closing the opening bookend, #65)

**The commit is gated strictly on convergence safety.** Normally that means green: only after the Stage 3 convergence loop reports green — the final `sail run` exited **0** (0 CRITICAL / 0 HIGH and no unmet AC) — commit the change. There are **two** red-but-eligible commit exceptions, each driven by an explicit `sail converge` result, never an eyeball judgment: (1) `proceed-hardening` — the materiality floor may commit after the deferred follow-ups are logged, when the deterministic audit is green and the independent materiality judge ruled each current-round deferred blocking finding immaterial; (2) `proceed-dissent` (#108) — a spec-premise conflict on a mechanically-sound run may commit, then route **immediately to the tracked-dissent terminus** (commit on branch → open the `human-review` issue → land-block the branch; fall back to park-with-handoff if the issue cannot be opened — see § Unattended mode), **not** the normal green land flow. **Never commit on a red review except those two explicit exceptions.** When Stage 0.5 chose to isolate or to stay on a feature branch (`COMMIT=yes`), commit on the branch; when it granted a risk-gated in-place skip (`COMMIT=no`), do not auto-commit (the operator owns the tiny inline fix).

```bash
# Only reachable after the convergence loop confirms `sail run ... ` exited 0.
if [ "$COMMIT" = "yes" ]; then
  TITLE="$(printf '%s' "$RAW" | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])')"
  sail_commit_on_branch "$WORK_DIR" <issue> "$TITLE"   # conventional subject + (#<issue>); no-op on a clean tree
fi
```

**Emit the metrics ledger line at the terminus (#146).** Once this converge CYCLE reaches its
terminus — a green/hardening/dissent commit above, OR a park — append exactly one telemetry record.
Map the `sail converge` decision to `--terminus` and call it here (fail-open, so `|| true` is
belt-and-suspenders; it never blocks the run). The emit is DRIVER-owned and fires exactly once per
cycle — never wire it into the per-round `sail run`:

```bash
# TERMINUS ∈ merged-green (converge=proceed) | proceed-hardening | proceed-dissent | parked+<reason>.
python3 -m sail metrics record --run-dir "$SESSION_DIR" --issue <issue> --terminus "$TERMINUS" || true
```

**Degraded-review visibility at the autonomous commit terminus (#116).** When the codex-family
backend latches off mid-run (#107), the cross-family lenses (red-team, dual-lens lens2) silently
stop running and a *weaker* review can reach green and commit — a change a full-strength review
would have flagged. After the commit, detect whether the committing round's review was **degraded**
(a lens the diff *gated for* did not run) and surface it — **never silently treat it as full
green.** This is a **proceed-but-track** check, not a gate: the work is **accepted** (the maintainer
refinement — not every operator runs a cross-family backend, so single-lens is many users' *normal*
setup; auto-filing every degraded run would be noise). The decision is the tested
`sail degraded-review` (deterministic Python); the shell only logs:

```bash
if [ "$COMMIT" = "yes" ] && { [ "$UNATTENDED" = "1" ] || [ -n "${SURF_RUN:-}" ]; }; then
  SHA="$(git -C "$WORK_DIR" rev-parse HEAD)"
  # Prints "<TONE> <lens:cause,...>" when degraded (empty when full-strength / non-gating) and
  # writes "$SESSION_DIR/degraded-review.md" (SHA + unavailable lens[es]) for the report + #108
  # enrichment to reuse. Freshness-keyed to the committing round/target (a stale prior round is not
  # credited). Always rc 0 — visibility, not a gate.
  DEGRADED="$(python3 -m sail degraded-review --run-dir "$SESSION_DIR" --target . --round "$ROUND" --sha "$SHA")"
  if [ -n "$DEGRADED" ]; then
    TONE="${DEGRADED%% *}"          # ALERT (a configured lens latched off — a real deviation) or INFO (unset backend — expected)
    echo "sail: [$TONE] committed $SHA under a DEGRADED review (${DEGRADED#* }) — a cross-family lens the diff gated for did not run; work ACCEPTED, recorded in the land-comment + \$SESSION_DIR/degraded-review.md. A full-strength re-review is advised when the backend returns." >&2
  fi
fi
```

The degraded fact is **not** itself a reason to open an issue. It rides the **existing #108
termini**: when a `proceed-dissent` (spec-conflict) or a `proceed-hardening` deferred-finding
follow-up *independently* fires on a degraded run, that issue's `--body-file` is **enriched** with
`$SESSION_DIR/degraded-review.md` (the commit SHA + unavailable lens[es]) so the human re-reviewing
knows the commit was single-lens — see § Unattended mode. On a clean degraded green with no such
terminus, the callout above + the land-comment section are the whole story; the work stands.

Supervised runs may show/approve the message first; the autonomous `/surf` path commits without pausing (never break `/surf`). The branch now carries the committed change for the land stage (Stage 5) to close. (Note: a `git commit` here is subject to the global `delivery-gate.sh` hook only when a `~/.ship/ship-state-*.json` exists — `/sail`/`/surf` runs have none, so the gate is inert; see `.ship/domain.md`.)

### Stage 5 — Land (closing the loop, #59)

**The closing git bookend.** Stage 0.5 opened the loop (isolate); Stage 4 committed the green change to `sail/<issue>`; Stage 5 lands it: merge to `main`, auto-close the issue, flip the board to Done, prune the branch, and publish the review evidence as the closing comment. It runs **only after Stage 3 is green** (final `sail run` exited 0). Like #65, the substantive logic lives in the engine and the git/gh mechanics are a thin documented sequence — the **same** sequence `/surf` runs (one source of truth; keep the two in sync).

First, the engine emits the closing artifacts from the **already-produced** review evidence — no re-review, no network:

```bash
# Reachable only after the convergence loop confirms `sail run ...` exited 0.
# Absolutize the run-dir BEFORE any cd (#115): in the default ISOLATED flow $SESSION_DIR is
# relative and the artifacts live INSIDE the linked worktree, but the land mechanics below cd to
# the PRIMARY worktree — a relative run-dir would not resolve there. (Standalone /sail's run-dir is
# its OWN $SESSION_DIR `.sail/runs/sail-<issue>-<ts>`, never /surf's `.surf/runs/<issue>` namespace.)
RD="$(cd "$SESSION_DIR" && pwd -P)"
TITLE="$(printf '%s' "$RAW" | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])')"
python3 -m sail land --run-dir "$RD" --issue <issue> --title "$TITLE"
# writes:  $RD/land-comment.md      (AC verdicts + finding dispositions + gate counts)
#          $RD/land-commit-msg.txt  (merge subject + a `Closes #<issue>` line)
```

**Unattended runs never reach this stage's outward actions (#108).** When `--unattended` is set, the run is **local-only**: it stops after the Stage 4 commit, may emit the local land artifacts (`land-comment.md` / `land-commit-msg.txt`) and the WIP handoff, and performs **no** push/merge/close/board-write/prune (see § Unattended mode). The outward block below runs only on a hands-on `/sail` (or via `/surf`'s own autonomous loop).

**Human-gated terminus (hands-on `/sail` runs only).** Before any outward action, **show what land will do** — print `land-comment.md` and `land-commit-msg.txt` and the exact merge/close/prune commands below — and **pause for approval**. Merge to `main` only after the operator approves. (`/surf` is unattended and does **not** pause — see below.)

**Direct-merge (default).** GitHub auto-closes the issue from the `Closes #<issue>` keyword in the merge commit when it lands on the **default branch (`main`)**; the board's native *Item closed → Done* automation then flips status — **no `gh issue close`, no board API call**. Confirm the merge target is `main` (the auto-close only fires there), then:

```bash
# $RD was absolutized in the artifact-emit block above (#115) — reuse it (each prose block is its
# own shell, but $RD is a /sail session variable in scope for the whole run).
[ -f "$HOME/.claude/lib/sail-git-lifecycle.sh" ] && . "$HOME/.claude/lib/sail-git-lifecycle.sh"  # in scope from Stage 0.5; re-source defensively
# LOCAL mechanics are single-sourced tested code (#82): --no-ff merge onto default + safe prune.
# #115: in the default ISOLATED flow Stage 0.5 cd'd INTO the linked worktree (.claude/worktrees/
# sail-<issue>), but these mechanics MUST run from the PRIMARY worktree — `git checkout main` (inside
# sail_merge_to_default) and `git worktree remove` (inside sail_prune_merged_branch) both FAIL while
# cwd is the linked worktree holding sail/<issue>. Derive the primary robustly and cd there; $RD is
# already absolute so the artifacts stay reachable after the cd. (No-op on the in-place/feature-branch
# paths: sail_primary_worktree returns the only/current worktree.)
cd "$(sail_primary_worktree .)"                              # land runs from the PRIMARY worktree (where `main` is checked out)
sail_merge_to_default . sail/<issue> main "$RD/land-commit-msg.txt"   # checkout main + --no-ff merge; `Closes #<issue>` rides the msg file; prints the merge SHA
git push origin main                                         # REQUIRED: the merge must reach origin's DEFAULT branch — only then does GitHub auto-close the issue and fire the board's Item-closed→Done automation; a local-only merge does neither
git rev-parse HEAD                                            # record the merge SHA
gh issue comment <issue> -F "$RD/land-comment.md"            # publish review evidence (reused, not re-derived)
# Prune the merged branch ONLY after the merge is on origin/main (auto-delete-head-branch is
# PR-only — it won't fire on a direct merge). Order matters TWO ways: (1) `git push origin --delete`
# ignores merge state, so delete the remote branch only AFTER `git push origin main`; (2) prune runs
# LAST, after every read of $RD — sail_prune_merged_branch removes the linked worktree that holds $RD,
# so the merge-msg + land-comment reads above must already be done (#115 ordering hazard).
sail_prune_merged_branch . sail/<issue>                      # removes the branch's linked worktree, then `git branch -d` (never -D): refuses an unmerged branch
git ls-remote --exit-code --heads origin sail/<issue> >/dev/null 2>&1 && git push origin --delete sail/<issue> || true
```

**`--pr` mode (high-stakes changes).** Instead of a direct merge, open a PR — the linked-PR merge then handles close + board + branch-delete **natively**:

```bash
python3 -m sail land --run-dir "$RD" --issue <issue> --title "$TITLE" --pr   # also writes land-pr-body.md (carries `Closes #<issue>`)
gh pr create --base main --head sail/<issue> --title "$TITLE" --body-file "$RD/land-pr-body.md"
```

**Preconditions (document, don't assume).** The merge must be **pushed to origin's default branch** — a local-only merge triggers neither GitHub's auto-close nor the board automation. Board → Done then relies on the repo's *Item closed → Done* Projects automation staying enabled; `Closes #<issue>` auto-closes **only** on the default branch; `git branch -d` refuses an unmerged branch, and the remote delete is guarded on the branch having been pushed **and** sequenced after `git push origin main` so it never drops unmerged work. If any precondition fails, land surfaces it rather than silently no-op'ing.

> **Keep in sync:** the LOCAL git mechanics are now single-sourced as `sail_merge_to_default` / `sail_prune_merged_branch` / `sail_primary_worktree` in `home/lib/sail-git-lifecycle.sh` (tested by `tests/test_sail_82_land_lifecycle.sh` + `tests/test_sail_115_land_orchestration.sh`) — edit there, not inline. The primary-worktree derivation is /sail's #115 fix for the isolated-worktree topology; `/surf` reaches the same primary-worktree-root basis differently — its supervisor never `cd`s into the worktree (it confines any worktree `cd` to a subshell), so its land block already runs from the primary. Only the residual **network sequence** below stays duplicated with `commands/surf.md`'s land step and must be kept identical: `git push origin main` → `git rev-parse HEAD` → `gh issue comment` → the ls-remote-guarded `git push origin --delete` (and `--pr` mode). Both consume the same `sail land` output. Change one, change the other.

## Autonomous-mode convergence rubric (#77)

Both bounded convergence loops above (Stage 1 plan, Stage 3 review) end "ask the user: continue /
abort / proceed-advisory." In the **autonomous `/surf → /sail` path there is no human** to answer
that. This rubric codifies the non-clean-converge judgment a human used to make, so the driver
neither burns its round budget pointlessly nor PARKs sound work. The exit-code contract is
unchanged (**exit 0 = green**); what follows is driver discipline, enforced by tested `sail/` Python
so it cannot drift run-to-run.

**(a) A plan risk the plan itself already mitigates → record the disposition and proceed.** The
free consistency self-check (#58), `--plan-adversary` (#62), and the grounded pass (#93) can each
flag a blocking HIGH/CRITICAL that is the issue's own crux — and the plan's *own approach + ACs
already deliver the remedy* (the documented #55-v2 code-seam escape hatch). Blindly re-running
`sail plan` just regenerates the same self-consistent plan: wasted rounds, or a parked-yet-sound
plan. Instead, when the driver judges a flagged risk **self-mitigated by the plan's own
approach/ACs**, it records that disposition **on the risk** (`"disposition": "self-mitigated"` plus a
non-empty `"rationale"` naming the delivering action) and **proceeds to build**. The `sail plan`
gate then defuses it deterministically via `effective_blocking_risks` (`sail/plan.py`): a validly
self-mitigated risk no longer blocks (exit 0), and is recorded for audit in `plan.json`'s
`self_mitigated` list and the decision log.
  - **Fail-safe (no laundering):** the disposition defuses **only** with a non-empty `rationale`; a
    bare `self-mitigated` tag with no rationale still blocks. The `disposition` field is
    **driver-territory only** — the author/grounded/adversary plan prompts never emit it, so the
    engine never auto-defuses its own first-pass risk (an author cannot clear its own flagged risk;
    that would re-create the self-consistent-plan trap). This is exactly the call a human supervisor
    made; the driver, an independent agent holding the issue context, stands where the human stood.

**(b) `exit 0` is the stop signal — LOWs never block and are not chased past green.** Review LOW
(and MEDIUM) findings are non-blocking by construction (`review.has_blocking` blocks only on
CRITICAL/HIGH), so they never flip the exit code. Once `sail run --diff` exits **0**, the gate is
green — **stop. Do not run another review round to chase LOW/tidiness nits** (a genuine-but-
self-referential LOW chain — e.g. one subsumed-substring grep nit begetting the next — is an
infinite tail otherwise). Green is done.

**(c) The driver consults a deterministic oracle, not its own eyeballs.** At each convergence loop
(plan or review), after a round's `sail …` exits, the driver asks the oracle what to do:

```bash
python3 -m sail converge --rc "$RC" --round "$ROUND" --run-dir "$SESSION_DIR" --target .
# prints exactly one of: proceed | revise | park | proceed-hardening | proceed-dissent
# and surfaces per-run cost (wall-time elapsed) to stderr each call.
```

**Convergence guardrails — trend-stall + cost backstop + hard ceiling (#130).** The old fixed
3-round cap conflated true non-convergence (stop) with a deep-but-converging run (continue) and a
just-introduced regression (continue). It is replaced by a layered guard, evaluated **on a non-green
round only, AFTER the early PARK guards (reappearance / whack-a-mole) and the commit-eligible
floors (spec-conflict / materiality) so a mechanically-sound run still gets to
`proceed-hardening`/`proceed-dissent` rather than being parked:

- **cost-backstop (the PRIMARY runaway guard).** Wall-clock elapsed since the run started —
  `elapsed_seconds(run_dir)` measures from the **later** of `run-state.json` `started_at` and the
  most-recent decision-log resume marker, so a parked-then-resumed run gets a fresh budget instead
  of tripping instantly on a stale start — past `SAIL_COST_CEILING_SECONDS` → `park`. The elapsed
  value is **surfaced to stderr** on every `sail converge` call (the per-run cost line). It
  **fails OPEN**: unset uses the documented 14400s (4h) default; explicit invalid/non-positive values
  still fail open and disable the ceiling, and a missing/unparseable start time never parks (a
  PARK guard must never park on bad data — the hard ceiling below is the guaranteed catch).
  `/sail` cannot observe subagent **token** counts from `sail/` Python (only the harness can), so the
  deterministic backstop and the surfaced per-run cost are **wall-time**; tokens are shown only if
  the driver supplies them.
- **trend-stall (the convergence judgment).** `park` when, for `SAIL_TREND_WINDOW` (default **3**)
  consecutive rounds, the max blocking severity (CRITICAL>HIGH) did **not** drop **AND** no finding
  was `addressed` — i.e. true churn. A round that drops severity **or** addresses a finding resets
  the streak (stays "converging"), so a run that fixes a HIGH and surfaces a smaller/distinct
  finding is **not** parked. The streak is reconstructed from a durable per-round ledger
  (`trend-ledger.jsonl`, hydrated from each round's `review.json` + decision-log under the
  **strong** `review_current_and_clean` freshness check), so a resumed process never resets it.
- **whack-a-mole (the addressed-reappearance PARK).** When a blocking fingerprint keeps reappearing
  while being dispositioned `addressed` each round, the trend ledger's `blocking_fingerprints` and
  `addressed_fingerprints` trail lets `sail converge` detect the churn and park with a distinct
  `whack-a-mole:` stderr callout instead of letting the streak reset forever.
- **same-area saturation (advisory, never a park).** When the same trend ledger shows
  `SAIL_SATURATION_WINDOW` consecutive rounds concentrated on one dominant file area, `sail
  converge` prints a `same-area-saturation:` stderr callout naming the area and streak. This is a
  steer to widen the budget / rethink the design; it never changes the stdout decision or exit
  code and is distinct from the by-id `genuine-oscillation` PARK.
- **hard ceiling (the ULTIMATE backstop).** `round_num >= --max-rounds` (default raised **above 3**,
  overridable via the `SAIL_HARD_ROUND_CEILING` env var when `--max-rounds` is not passed)
  → `park`. Round count is no longer the convergence judgment — only the final, always-available
  backstop for any path the trend/cost guards miss.

- `converged-green` → `proceed` — `rc == 0`; green, stop (rule **b**: never chase non-blocking
  LOWs past green).
- `genuine-oscillation` → `park` — a blocking finding was dispositioned `rejected` or `deferred`
  in a prior round and reappears by id in the current round; **PARK to the WIP handoff** rather
  than loop forever.
- `never-dry-hardening` → `proceed-hardening` — `rc != 0`, the deterministic audit is clean,
  `review.json` is current for the exact `target` / `diff_ref` / `diff_hash` / `plan_hash` /
  `round`, tidiness has no blocking list, every AC is `met`, and every blocking finding is
  dispositioned `deferred` in this round. Materiality is then decided by
  `SAIL_MATERIALITY_CMD`, an independent cross-family second opinion that reads the finding plus
  the full diff and answers material / immaterial; default to material and fail closed.
  Legitimately-skipped deterministic tool gates do not block the hardening floor (assurance then
  rests on the clean+fresh review, the met ACs, and the independent cross-family judge); a missing
  or malformed run-state fails closed. The driver
  logs the deferred ids as follow-ups, then commits the red-but-eligible hardening change instead
  of parking it. With no backend, the floor never fires.
- `spec-premise-conflict` → `proceed-dissent` — `rc != 0`, the deterministic audit is clean
  (same floor as hardening: gates green, review current for the exact `target`/`diff_ref`/
  `diff_hash`/`plan_hash`/`round`, tidiness clear, every AC `met`), and **every** current-round
  blocking finding is validly dispositioned `spec-conflict` (non-empty rationale, driver-territory
  only — see the unattended section below). This is the NEW category the materiality floor does
  **not** cover: a reviewer objecting to the design the issue itself MANDATED. The driver then runs
  the **tracked-dissent terminus** (commit on branch → open a `human-review` issue → land-block the
  branch; fall back to park-with-handoff if the issue cannot be opened). Any other unresolved
  blocking finding keeps the run on `revise`.
- `revise` — `rc != 0` and none of the named stop reasons above apply; fix the surfaced blocking
  findings and re-run. The trend-stall + cost backstop are the primary guards, with the hard
  ceiling (`--max-rounds`) as the ultimate backstop for true non-convergence.

- **Disposition-before-converge ordering is load-bearing.** The driver records current-round
  dispositions before it asks the oracle. The oracle then reads the shared `decision-log.md`/
  `review.json` run-dir in two different ways: current-round dispositions for the hardening floor,
  and strictly prior-round dispositions for oscillation. That split is the sequencing primitive
  that keeps the two decisions distinct.

- **Deferred-only rule.** Hardening counts only when the current round recorded `deferred`. A
  `rejected` finding is not follow-up work, and an `addressed` finding is a fix already done.

- **The deterministic audit is the safety floor.** The hardening floor stays shut unless deterministic gates are green, `review.json` is current for the exact `target` / `diff_ref` / `diff_hash` / `plan_hash` / `round`, tidiness has no blocking list, every AC is `met`, and the current round has current-round `deferred` dispositions for every blocking finding. No backend, backend error, non-zero backend rc, malformed JSON, missing `material` field, or any uncertainty means the floor stays shut. The judge reasons about whether the finding pertains to the edited change itself, not whether a path string overlaps.

- **Lens B — independent judgment.** `SAIL_MATERIALITY_CMD` is the sole materiality decider. It must be a different model family than `SAIL_REVIEW_CMD` / `SAIL_REVIEW_CMD2` (#83) so it does not rubber-stamp the review lens. It reads the blocking finding plus the full diff (`git -C target diff diff_ref`) and answers whether the finding is material in the change itself or immaterial adjacent hardening. Default to material and fail closed. With no backend, the floor never fires and the driver falls back to revise / park as before.

- **Path/location classification is intentionally removed.** The old path-overlap heuristic was fragile and fail-opened; the safety decision now uses the audit plus the independent judge only. A beyond-diff caller break is still a real defect to FIX (`addressed`), never defer. If an AC is stuck `unknown` (#81) the floor stays conservatively shut.

- **What `proceed-hardening` does.** On that result, the driver **commits the branch first** (Stage
  4), then files each stderr-listed deferred finding as a follow-up. The red review is intentional
  and auditable, not a free pass. **#116 enrichment:** if this commit was also made under a DEGRADED
  review, append the degraded note (commit SHA + unavailable lens[es]) to the deferred follow-up's
  `--body-file` — the same file-append the spec-conflict terminus uses, never command-line
  interpolation — so the human working the follow-up knows the commit was single-lens. The order is
  **commit → capture SHA → re-derive note → file**, so the post-commit SHA always exists:
  ```bash
  BODY="$SESSION_DIR/hardening-followup-body.md"   # deferred finding id + detail written here verbatim
  # Self-contained: capture THIS commit's SHA here, then re-derive the degraded note via the
  # idempotent `sail degraded-review` (no dependence on a Stage-4 shell var or ordering); the
  # `[ -f … ]` guard no-ops on a full-strength commit.
  SHA="$(git -C "$WORK_DIR" rev-parse HEAD)"
  python3 -m sail degraded-review --run-dir "$SESSION_DIR" --sha "$SHA" >/dev/null
  [ -f "$SESSION_DIR/degraded-review.md" ] && { printf '\n' >> "$BODY"; cat "$SESSION_DIR/degraded-review.md" >> "$BODY"; }
  gh issue create --label human-review --label surf-pilot \
    --title "deferred hardening follow-up (from #<issue>)" --body-file "$BODY" || true
  ```

Together: `converged-green` and `genuine-oscillation` are the two park/stop reasons for ordinary
convergence, while `never-dry-hardening` is the red-but-eligible commit exception. `sail converge`
still fails closed on malformed or mismatched audit state; the trend-stall + cost backstop (with the
hard `--max-rounds` ceiling as the ultimate backstop) park true non-convergence on any path not
covered by those named reasons.

Together: **(a)** stops the driver burning rounds on a risk the plan already resolves, **(b)** stops
it chasing LOWs past green, and **(c)** the `sail converge` oracle's trend-stall + cost backstop +
hard-ceiling PARK is the deterministic backstop for true non-convergence — keeping the autonomous
path `/surf` depends on from wasting rounds (or, since #130, from parking a genuinely-converging run
at a fixed round count) while still never letting a churning or runaway run loop forever.

## Minor-finding disposition — split by blast radius, never by self-assessed "cheapness" (#113)

When `/sail` (or `/surf`) **catches** a minor issue mid-build that the plan did not call for, "file it
for later" too often means never — but a blanket "fix cheap out-of-scope bugs" rule fights `/sail`'s
trust properties and the standing Surgical-Changes rule (`~/.claude/CLAUDE.md` §3, "every changed
line traces to the request"): an out-of-scope fix has no plan AC (it trips the #47 traceability
reviewer or passes unverified), it muddies revertibility and bisect, it breaks `/sail`-vs-`/ship`
A/B comparability, and "cheap" is self-assessed and often wrong (a one-line change in shared code can
ripple). So the split is by **blast radius**, not by cheapness. This is the inverse of the #103
materiality floor ("is a *deferred* finding material enough to *block*?") — here: "is a *caught*
finding trivial+safe enough to *fix now*?" — and it is a **scoped, guarded exception** to
Surgical-Changes §3, not a repeal of it.

**The policy (three rules):**

1. **Trivial AND inside code already being touched AND zero behavior change → fix inline, logged
   visibly.** This is the blast radius you are already in — craftsmanship, not scope creep. The fix
   is logged in the form **"also corrected X while editing Y"**, recorded durably via
   `DecisionLog.inline_fix_marker(file, summary)` (a narrative marker in `decision-log.md` —
   deliberately **not** a finding disposition, so it never touches the convergence buckets). Visibility
   is the guard against silent diff growth; an unlogged opportunistic hunk is treated by the reviewer
   as a scope finding, not as an explained change.
2. **Genuinely out-of-scope → never expand the diff; capture it cheaply instead.** Record a
   **deferred finding** (the existing #103/#100 `DecisionLog` disposition — the *guaranteed* capture
   floor that survives resume, for both `/sail` and `/surf`) and **optionally** auto-file a one-line
   follow-up issue. Catching-and-recording is the cheap default; *fixing* is not.
3. **The hard ceiling on "inline" is testable** (`sail/disposition.py::inline_fix_eligible`): a
   candidate is inline-eligible only when it stays within **single file, a few lines, no
   public-interface change, no new dependency, no new behavior.** Touch a **second file** or a
   **public interface** (or add a dependency / new behavior, or exceed the few-line budget) → it is
   **not** eligible for inline; it becomes a deferred finding / follow-up issue. The mechanizable
   boundary (file count, dependency, line budget) is the deterministic predicate; the un-mechanizable
   parts ("trivial", "zero behavior change") stay LLM-reviewer judgment (infra-placement). This is
   **not** an auto-classifier of opportunistic-vs-planned hunks — it only answers whether an
   already-identified opportunistic candidate exceeds the ceiling.

**How the driver invokes it (reachable, not dormant).** The ceiling check and the durable visibility
marker are both invocable as a deterministic subcommand (the established `python3 -m sail …`
pattern), so the driver never eyeballs the ceiling or hand-writes the marker:

```bash
# Ceiling check — prints `eligible` (rc 0) or `exceeds-ceiling` (rc 1):
python3 -m sail disposition --files 1            # a single-file candidate is eligible
python3 -m sail disposition --files 2            # a 2nd file exceeds → capture as a deferred finding
python3 -m sail disposition --files 1 --public-interface   # public-interface change → exceeds

# Record the durable inline-fix visibility marker after making a within-ceiling fix:
python3 -m sail disposition --record-inline-fix --run-dir "$SESSION_DIR" \
  --file path/to/edited --summary "also corrected X while editing Y"
```

The marker lands in `decision-log.md` and is surfaced on the Stage-5 land comment under an **Inline
opportunistic fixes** section — the "always logged/surfaced" guarantee reaching the delivery surface.

**Optional auto-file — reuse the #108 safe pattern (never the cheap-but-unsafe path).** If a
follow-up issue is filed: write the body to a tempfile and pass `--body-file` (**never** interpolate
untrusted finding text into a shell argument — OWASP LLM01), use a **fixed** title with only the
trusted issue number interpolated, and **dedup** by a stable finding fingerprint (search for an
existing open follow-up via a structured/sanitized label query before creating, so repeated `/sail`
or `/surf` runs don't spam duplicates). `gh issue create` is **not** blocked by the unattended
delivery-gate (only commit/push/merge/close are), but filing stays optional — the durable deferred
finding is the floor, so a failed/declined file never loses the finding.

**Reporting — INFO-tier per #112, never silent.** Both dispositions are surfaced: an inline fix as
`INFO: also corrected X while editing Y`; an out-of-scope capture as `INFO: out-of-scope Y noted →
filed #N` (when filed) or `→ recorded as deferred finding` (when not). These are expected, designed
behavior → neutral INFO, not ALERT.

## Unattended mode (standalone `/sail --unattended <issue>`, #108)

`/surf` is already autonomous (it drives `/sail` and handles termini in its own loop). The gap #108
closes is the **standalone** `/sail <issue>` invocation run in a headless `claude -p` session: its
plan/review convergence termini and its Land terminus end in `AskUserQuestion`, which cannot render
without an operator — and a *denied* prompt previously fell back to the agent's own recommended
option (a silent auto-proceed). Unattended mode makes the standalone front door finish safely on its
own.

**Signal (explicit flag, never silent auto-detect).** `--unattended` is the sole enabler of
unattended behavior. Auto-detecting a non-interactive session to silently switch behavior is
rejected: it re-introduces the exact silent-auto-proceed class this issue kills. Non-interactivity
is used only as a **fail-loud guard**, never to enable commit-only behavior.

**Front-door argument split (do this first, at the top of the run).** Parse the slash args into the
issue number plus the flags: set `UNATTENDED=1` iff `--unattended` is present (else `0`), and derive
`INTERACTIVE` — `1` for a normal TTY/IDE session, `0` for a headless `claude -p` run (best-effort).
These two variables feed every `python3 -m sail terminus` call in the stage termini below; the
deterministic guard, not improvisation, then decides `auto | ask | park-loud`.

**Every human-facing terminus routes through the tested decision FIRST** — so a non-renderable
prompt is never reached by auto-selecting a default:

```bash
# INTERACTIVE=1 for a normal TTY/IDE session; 0 for a headless `claude -p` run (best-effort).
ACTION="$(python3 -m sail terminus --unattended "$UNATTENDED" --interactive "$INTERACTIVE")"
# prints exactly one of: auto | ask | park-loud
```

- `auto` (**`--unattended`**) → issue **no** `AskUserQuestion`; resolve plan/review convergence via
  the `sail converge` oracle exactly as the `/surf` autonomous path does (honoring `proceed` /
  `revise` / `park` / `proceed-hardening` / `proceed-dissent`).
- `ask` (hands-on, interactive) → present the prompt as today; a human is present.
- `park-loud` (**headless without `--unattended`**) → do **not** prompt. Write a durable handoff and
  stop. This is AC5: a denied/unrenderable prompt never silently auto-proceeds.

**No silent fallback (belt-and-suspenders).** Beyond the `terminus` guard: if an `AskUserQuestion` is
ever issued and comes back **denied/unavailable**, the driver must `sail handoff` + PARK — it must
**never** select the recommended option as a fallback.

**Convergence termini (unattended).** Record current-round dispositions, then consult the oracle (no
prompt). On `proceed` / `proceed-hardening` → commit (Stage 4). On `proceed-dissent` → the
tracked-dissent terminus below. On `park` (oscillation / trend-stall / cost-backstop / hard ceiling) → write the WIP handoff and
stop.

**Spec-premise-conflict → proceed-with-tracked-dissent (the #108 design decision).** When a red-team
finding objects to the design the issue itself MANDATED (e.g. #76's mandated `/ship`-parity
pre-staging), the driver — holding the full issue context — records a `spec-conflict` disposition on
that finding (`sail`'s decision log; **non-empty rationale required**, driver-territory only, never
engine-emitted). When the oracle returns `proceed-dissent`, the driver:

1. **Commits on the branch** (unattended is local-only by construction — see Land below).
2. **Opens a `human-review` issue** capturing the objection + the options. Ensure the label exists
   first (create-if-missing — never a build-time repo mutation), then file it. To keep it out of an
   **automated** whole-board `/surf` run, also apply `/surf`'s charter refinement label (default
   `surf-pilot`), which its anti-regress guard already defers — `human-review` alone is a
   human-legible marker, **not** an automatic `/surf` exclusion:
   Write the body to a tempfile first and pass it via `--body-file` — **never inline the objection
   text into a double-quoted shell argument**: red-team finding text is untrusted free-form input
   (it can carry attacker-influenced diff content — OWASP LLM01) and embedded quotes/`$()` would be
   a shell-injection surface (#108 review):
   ```bash
   gh label create human-review --description "Needs human judgment before automated pickup (e.g. an unattended /sail spec-conflict dissent)" --color D93F0B 2>/dev/null || true
   gh label create surf-pilot --description "Workflow refinement observed during a live /surf board run" --color 1d76db 2>/dev/null || true   # create-if-missing too: standalone /sail may run where /surf never has, so its charter label may not exist yet — else the issue-create would hard-fail and spuriously park (#108 review)
   BODY="$SESSION_DIR/human-review-body.md"   # objection/detail written here verbatim, not interpolated into the command line
   # #116 enrichment: if this run also committed under a DEGRADED review, append the degraded note
   # (commit SHA + unavailable lens[es]) to the SAME body-file so the human re-reviewing knows the
   # commit was single-lens. Self-contained: capture the commit SHA HERE (do NOT rely on a Stage-4
   # shell var surviving into this block) and re-derive the note via the idempotent
   # `sail degraded-review` (removes any stale note, then writes a fresh one carrying THIS SHA only
   # if the committing review was degraded) — so the enriched body always carries the commit SHA and
   # never depends on Stage-4 ordering. The `[ -f … ]` guard no-ops on a full-strength commit.
   # Appending a FILE (not interpolating) preserves the #108 no-untrusted-text-on-the-cmdline rule.
   SHA="$(git -C "$WORK_DIR" rev-parse HEAD)"
   python3 -m sail degraded-review --run-dir "$SESSION_DIR" --sha "$SHA" >/dev/null
   [ -f "$SESSION_DIR/degraded-review.md" ] && { printf '\n' >> "$BODY"; cat "$SESSION_DIR/degraded-review.md" >> "$BODY"; }
   gh issue create --label human-review --label surf-pilot \
     --title "spec-conflict: human review required (from #<issue>)" --body-file "$BODY" \
     || { echo "sail: could not open human-review issue — falling back to park"; FALLBACK_PARK=1; }
   ```
   The `--title` is a **fixed** string with only the numeric `<issue>` (the trusted slash arg)
   interpolated — **no** review/finding text in the title (it would be a second shell-injection
   surface); all untrusted objection text lives only in `$BODY`.
   The body records: the objection (finding `<id>` + detail), the options (park-and-redesign /
   accept-as-mandated / revise-issue), and that `sail/<issue>` is **LAND-BLOCKED** pending this issue.
3. **Land-blocks the branch**: write `wip-handoff.md` (via `sail handoff`) recording the dissent, the
   `human-review` issue number, and that the branch must **not** be landed until that issue is
   resolved.
4. **Fallback:** if the issue cannot be opened (no network/auth in a headless run), do **not** proceed
   silently — fall back to park-with-handoff so the dissent is never lost.

This is strictly scoped to genuine spec-conflicts: ordinary CRITICAL/HIGH correctness findings still
block and are fixed (`addressed`) via the normal convergence loop. `proceed-with-logged-dissent`
without the human-review issue + land-block is **not** the default (it would ship over a serious
objection unattended); the tracked-dissent terminus is the chosen design.

**Land terminus (unattended = local-only).** Unattended runs **commit on the branch and STOP**. They
may emit the local land artifacts (`land-comment.md` / `land-commit-msg.txt` via `sail land`) and the
WIP handoff, but perform **no** outward action — no push, no merge, no `gh issue close`, no board
write, no branch prune. Those stay human-gated (Stage 5's human-gated terminus). Opening the
`human-review` issue is the one permitted tracker write — it is additive, clearly marked for a human,
and the opposite of a destructive outward action; if it fails the run parks rather than proceeding.

**Durable handoff (AC6).** Every park (spec-conflict-fallback / oscillation / never-converged /
headless-without-flag) writes a durable handoff naming the stop reason, the outstanding finding ids,
and the **exact existing resume command** — no new resume command is invented:

```bash
python3 -m sail handoff --run-dir "$SESSION_DIR" --reason "<oscillation|spec-conflict|never-converged|park-loud>" \
  --issue "<issue>" --finding-ids "<id1,id2>" \
  --resume "python3 -m sail run --target . --diff <base-ref> --run-dir $SESSION_DIR --round <N>"
```

**Floor exercised live (#103).** The unattended terminus is where the materiality floor finally runs
end-to-end: to exercise `proceed-hardening`, set `SAIL_MATERIALITY_CMD` to a backend in a family
different from `SAIL_REVIEW_CMD` / `SAIL_REVIEW_CMD2` (#83). With it unset the floor never fires and a
deferred blocking finding safely parks (no new `INSTALL.md` knob — reuses the existing one).

## Status-message tone — INFO vs ALERT (#112)

**Tone tracks severity.** *Expected absence is information; unexpected absence is a warning.* The
facts are the same either way — only the volume changes. This generalizes #108's "park loudly"
instinct to **all** operator-facing status output, interactive runs included: if every line reads as
a caveat, a real event (a model downgrade, a missing-but-required tool, a gate failing red) stops
being noticeable. So calibrate each status line to one of two tiers.

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
right **only** when the target is genuinely absent by design (0 `.py` tests in the repo); point
`/sail` at a repo that *does* carry a pytest suite and a skipping coverage gate is a **real gap →
ALERT**. So: **no-pytest-by-design → INFO; pytest-present-but-skipped → ALERT.** Never dress a real
deviation in calm wording to keep the log quiet.

This is the same two-tier rule the degraded-review `TONE` already encodes at the Stage 4 commit
terminus (`ALERT` when a configured lens latched off — a real deviation; `INFO` when the backend was
simply unset — expected single-lens). Extend it to every status line the run prints.

## Calibration (operator validation — deferred to a live run)

The calibration acceptance criterion — *run looped `/sail` against issues `/ship` already handled (#32/#33 have full artifacts) and confirm the loop surfaces what `/ship`'s multi-round + dual-lens surfaced* — is an **operator validation step**, not a hermetic test: it needs a live LLM review backend (`SAIL_REVIEW_CMD` / `SAIL_REVIEW_CMD2`) and the merged #32/#33 artifacts. Run it once those are available and record the parity result in the ship's log (mirrors the #32 AC#7/#8 trial-runbook precedent). The build above delivers items 1–4 (plan-verification, resolution log, dual-lens, convergence) with hermetic tests; calibration is the live-run demonstration on top.
