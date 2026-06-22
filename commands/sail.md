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

### Stage 1 — Plan (auto-fires; bounded convergence loop)

Fetch the issue, **checking `gh`'s exit code before feeding the planner** (a bare pipe would not), then run the plan stage:

```bash
RAW=$(gh issue view <issue> --json title,body,comments) || { echo "sail: gh failed to fetch issue <issue> — aborting"; exit 1; }
SPEC=$(python3 -m sail spec <<< "$RAW") || { echo "sail: issue <issue> spec is empty or has no body — aborting"; exit 1; }
python3 -m sail plan --target . --run-dir "$SESSION_DIR" <<< "$SPEC"
```

**Why `--json title,body,comments | sail spec` (#60):** the planner — and `is_plan_risky` — must see the **full** issue (body **and** comments), because the #55 failure shape needs a remediation signal and a reconcile/list signal that often live in *different* parts of the issue. A bare `gh issue view <issue>` is body-only, and `gh issue view <issue> --comments` is comments-only on some `gh` versions; either feeds a partial spec and the heuristic under-fires. The two statements above keep `gh`'s exit code genuinely checked (not swallowed by a pipe): `gh` is captured first, then `sail spec` assembles title + body + comments and **fails closed** (exit 1) on an empty fetch or an issue with no body. Note: comment bodies are now part of the LLM-trusted spec, so in the autonomous `/surf → /sail` path a third-party comment is planner-visible input — keep that trust boundary in mind.

`sail plan` does ONE LLM pass and writes `plan.json` (approach, acceptance criteria, test plan, a lightweight design/security risk check, and scope). The pass also runs a **free consistency self-check (#58):** for every user-facing instruction or remediation the change introduces, the plan must name the exact action in the change that fulfills it — a promise with no matching delivered action (an unresolvable remediation loop, an unreconciled file/list) is recorded as a blocking risk. This catches the broken promise→action failure class at plan-time, in the same single pass (no extra agent). The same pass also **surfaces design alternatives (#61):** when the spec carries a genuine design choice with no single right answer (the #55 doctor count: N=8 vs N=9), it populates a `design_alternatives` list (`option` / `tradeoff` / `recommended`) so a reviewer — auto or supervised human — sees the call and the trade-off the consistency check is blind to. This is **informational, never blocking** (it does not affect the exit code), and stays empty for trivial specs (no invented alternatives). Its exit code is the convergence signal:

- **exit 0** — no blocking (CRITICAL/HIGH) risks → the plan is clean, proceed.
- **exit 1** — blocking risks present (or an unusable backend on a non-empty spec, or an empty spec) → revise and re-run.

**Bounded convergence loop (single lens, max 3 rounds):** while `sail plan` exits 1, present the plan + its blocking risks to the user, revise the spec/approach, and re-run — up to **3 rounds**. If still blocking after 3 rounds, present `plan.json` and its risks and ask the user: continue / abort / proceed-advisory (`--advisory`). Do not loop unbounded.

**`--plan-adversary` risk-gated escalation (#58).** Default plan is **single-pass** (the self-check above is free; most plans stay 1-pass — no uniform weight). When the change is **plan-risky** — it touches user-facing instructions/remediation, or reconciles multiple files/lists — `/sail` escalates to a **one-shot adversarial plan pass**: an independent second pass over the same spec with adversarial framing (it re-derives the gaps a careless author would miss; like `--dual-lens`'s second lens, it reviews independently rather than grading the first pass's output). The auto-trigger fires only on the strong #55 failure shape — a remediation/instruction signal **and** a file/list-reconciliation signal co-occurring, or an unambiguous failure phrase — so ordinary specs ("run the tests", "improve the error message") stay single-pass. Escalation fires when `--plan-adversary` is passed **or** the auto-trigger heuristic (`is_plan_risky`) detects a plan-risky spec, mirroring the review stage's `--dual-lens` escalation:

```bash
SAIL_PLAN_CMD2="codex exec -m gpt-5.4-mini" \
  python3 -m sail plan --target . --run-dir "$SESSION_DIR" --plan-adversary <<< "$SPEC"
```

The adversary runs as a second independent backend (`SAIL_PLAN_CMD2`); its **explicitly CRITICAL/HIGH risks union into the plan gate** (each tagged `lens: adversary` in `plan.json`), and the gate fails closed (and writes `status: error` to `plan.json`, matching the exit code) if the adversary backend errors. The adversary is skipped when the author plan is already blocking (the gate is already red). `--plan-adversary`/auto-trigger with no `SAIL_PLAN_CMD2` degrades cleanly to single-pass (logged, not an error) — exactly as `--dual-lens` degrades with no `SAIL_REVIEW_CMD2`.

**Fail closed on a skipped plan:** before proceeding to build, read `plan.json`. If `status == "skipped"` (no LLM backend was available), do **not** silently proceed — halt with: "no LLM backend — the plan stage did not validate; install `claude` or set `SAIL_PLAN_CMD`, then re-run." This mirrors how `sail run --diff` fails closed when a requested review has no backend.

### Stage 2 — Build (TDD, guided)

With a clean `plan.json` as the agreed baseline, build the change test-first: write a failing test that pins each acceptance criterion, then the minimum code to pass it, keeping the suite green at each step. The `sail-tdd-guard` hook (if installed) enforces a failing-test marker before source edits.

**Prove hermeticity — don't assume it (advisory, #64).** When a test claims to be *hermetic* / *isolated*, the autonomous author must **prove** the isolation, not assert it in the docstring and move on — an isolation that is a silent no-op flakes the same way the host-coupled test it replaced would. Concretely: a test that pins behavior under a scrubbed/empty `PATH` (or any cleared env/state) must confirm the **code under test does not silently re-derive** that state behind the test's back. The canonical failure (#55-v2): a "hermetic" `PATH` test was defeated because `doctor.sh` **re-augmented `PATH` internally**, so the scrubbed-environment check passed while the test still read the host — caught only at review, costing a round. The fix was a `CK_DOCTOR_NO_PATH_AUGMENT` test seam that lets the code skip its own augmentation under test. **The rule, with its escape hatch in the same breath:** scrubbing the *caller's* environment is **not sufficient** when the code re-derives state internally — so if a test cannot be made genuinely hermetic without a code seam, **add that seam in the same change** (the `CK_DOCTOR_NO_PATH_AUGMENT` pattern) rather than ship a test whose isolation silently does nothing. This is a **prompt-level reminder, not a new gate** — it adds no exit code and never blocks convergence; it just keeps `/sail`'s own autonomous TDD from manufacturing the review churn it exists to avoid.

### Stage 3 — Review (deterministic gates + blocking LLM review)

Run the existing one-pass gate + review over the change, into the **same** session run-dir:

```bash
python3 -m sail run --target . --diff <base-ref> --run-dir "$SESSION_DIR" --round N --tidiness
```

This runs the deterministic gates (ruff, mypy, pytest, bandit, semgrep, pip-audit — diff-scoped) **and** the blocking single-lens LLM review in one pass. The `--tidiness` flag adds the advisory tidiness/simplify lens (below).

**Plan↔review traceability spine (#47).** Because Stage 0 put `plan.json` in this same run-dir, the review stage reads its `acceptance_criteria` and records per-criterion `met / unmet / unknown` in `review.json`'s `plan_verification` block (the define-at-plan → verify-at-review spine). An **unmet** AC blocks (the spine has teeth); an absent plan is non-blocking (`no-plan`); a malformed `plan.json` **fails closed** (`status: error`, blocks) — it is never silently treated as no-plan.

**Bounded convergence loop (review stage; max 3 rounds — driver-owned).** A non-zero exit means a gate failed, the review found CRITICAL/HIGH findings, or an AC is unmet. Mirror the plan stage's loop: fix the surfaced findings, **record a per-finding disposition each round** (`addressed` / `deferred` / `rejected` + a one-line rationale, keyed by the finding's stable `id` from `review.json`), and re-run `sail run --diff` — up to **3 rounds**. If still blocking after 3 rounds, present `review.json`'s findings + `plan_verification` and ask the user: continue / abort / proceed-advisory. The single-invocation exit code is unchanged; the driver owns the re-run-after-fix loop.

**Docs-impact check (advisory definition-of-done, #56).** Before declaring the change done, run this lightweight checklist item: *does the change add a new **external tool dependency** (a new CLI the gates invoke) or a new **config knob** (e.g. a `.ship/domain.md` setting or an `env` var)? If so, verify `INSTALL.md` — this repo's source-of-truth for setup — and any relevant docs are updated to document it.* This recovers the docs-completeness `/ship`'s heavier planning surfaced (the #52 A/B shipped `diff-cover` + `diff-coverage-threshold:` with no `INSTALL.md` note). It is **purely advisory** — a prompt-level reminder, **not a new gate**: it adds no exit code, no deterministic check, and never blocks convergence. An undocumented dependency = a silently-dormant feature for the next person, so surface it and update the docs in the same change.

**`--round` multi-round discipline.** The driver increments `--round N` on each re-run, starting at 1. Round `N > 1` feeds the reviewer the prior round's findings + resolutions from the shared run-dir and tells it to review only the inter-round diff, so carried items stay stable instead of being re-litigated.

**Per-round model escalation.** Keep early rounds on the cheaper `SAIL_REVIEW_CMD` backend. On later rounds, set `SAIL_REVIEW_CMD_ESCALATED` to a stronger backend and optionally `SAIL_REVIEW_ESCALATE_ROUND` (default 3) to switch over once the round threshold is reached. The active backend is selected per round, so round 1 stays light and later rounds can escalate cleanly.

**`--dual-lens` risk-gated escalation (#47).** Default review is **single-lens** (industry norm; convergence is the quality mechanism). For a high-stakes diff — or when you simply want a cross-family second opinion — pass `--dual-lens` and set `SAIL_REVIEW_CMD2` to a second backend (e.g. a codex CLI):

```bash
SAIL_REVIEW_CMD2="codex exec -m gpt-5.4-mini" \
  python3 -m sail run --target . --diff <base-ref> --run-dir "$SESSION_DIR" --dual-lens
```

Both lenses review independently; their findings are unioned (each tagged `lens1`/`lens2` in `review.json`) and the gate blocks if **either** lens blocks or errors. `--dual-lens` with no `SAIL_REVIEW_CMD2` degrades cleanly to single-lens (logged, not an error).

**`--tidiness` advisory cleanup lens (#63).** `/sail` deliberately dropped `/ship`'s simplify step — that omission let non-blocking *messiness* (a redundant line, an `N=9` that should be `N=8`, dead locals) ship even when the correctness review converged at "0 high-severity". Tidiness *is* code quality, and a non-coder adds ~zero value judging it — so it must be a **machine** lens. `--tidiness` adds a **separate, advisory** pass that ports Anthropic's `/code-review` + `/simplify` intent (reuse/de-duplication, simplification, dead code, naming, efficiency, altitude). It is kept **strictly separate** from the correctness review and the cross-family `--dual-lens` (codex = different *bugs*; tidiness = *cleanup*), so it never dilutes the adversarial bug-finding craft. The front door passes `--tidiness` by default (above) to close the gap.

- **Non-blocking by construction.** Tidiness findings are recorded under their own `tidiness` key in `review.json` (each tagged `lens: "tidiness"`); they never enter the blocking `findings`/`counts` and never change the exit code. They surface for the driver/human to apply — cleanups are not convergence blockers.
- **Efficient by two knobs.** Point the lens at a cheaper/lower-effort model with `SAIL_TIDINESS_CMD` (falls back to the default review backend when unset), and/or run it only on larger diffs with `SAIL_TIDINESS_MIN_LINES` (default `0` = any non-empty diff; set higher to skip small diffs). Either knob keeps the extra pass cheap.
- **Degrades cleanly.** An empty diff, a size-gated skip, a missing backend, or an unusable response all record `"status": "skipped"` in the `tidiness` block — never a hard error, never a blocked run.

```bash
SAIL_TIDINESS_CMD="codex exec -m gpt-5.4-mini -c model_reasoning_effort=low" \
SAIL_TIDINESS_MIN_LINES=40 \
  python3 -m sail run --target . --diff <base-ref> --run-dir "$SESSION_DIR" --round N --tidiness
```

## Calibration (operator validation — deferred to a live run)

The calibration acceptance criterion — *run looped `/sail` against issues `/ship` already handled (#32/#33 have full artifacts) and confirm the loop surfaces what `/ship`'s multi-round + dual-lens surfaced* — is an **operator validation step**, not a hermetic test: it needs a live LLM review backend (`SAIL_REVIEW_CMD` / `SAIL_REVIEW_CMD2`) and the merged #32/#33 artifacts. Run it once those are available and record the parity result in the ship's log (mirrors the #32 AC#7/#8 trial-runbook precedent). The build above delivers items 1–4 (plan-verification, resolution log, dual-lens, convergence) with hermetic tests; calibration is the live-run demonstration on top.
