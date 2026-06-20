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
SPEC=$(gh issue view <issue>) || { echo "sail: gh failed to fetch issue <issue> — aborting"; exit 1; }
python3 -m sail plan --target . --run-dir "$SESSION_DIR" <<< "$SPEC"
```

`sail plan` does ONE LLM pass and writes `plan.json` (approach, acceptance criteria, test plan, a lightweight design/security risk check, and scope). Its exit code is the convergence signal:

- **exit 0** — no blocking (CRITICAL/HIGH) risks → the plan is clean, proceed.
- **exit 1** — blocking risks present (or an unusable backend on a non-empty spec, or an empty spec) → revise and re-run.

**Bounded convergence loop (single lens, max 3 rounds):** while `sail plan` exits 1, present the plan + its blocking risks to the user, revise the spec/approach, and re-run — up to **3 rounds**. If still blocking after 3 rounds, present `plan.json` and its risks and ask the user: continue / abort / proceed-advisory (`--advisory`). Do not loop unbounded.

**Fail closed on a skipped plan:** before proceeding to build, read `plan.json`. If `status == "skipped"` (no LLM backend was available), do **not** silently proceed — halt with: "no LLM backend — the plan stage did not validate; install `claude` or set `SAIL_PLAN_CMD`, then re-run." This mirrors how `sail run --diff` fails closed when a requested review has no backend.

### Stage 2 — Build (TDD, guided)

With a clean `plan.json` as the agreed baseline, build the change test-first: write a failing test that pins each acceptance criterion, then the minimum code to pass it, keeping the suite green at each step. The `sail-tdd-guard` hook (if installed) enforces a failing-test marker before source edits.

### Stage 3 — Review (deterministic gates + blocking LLM review)

Run the existing one-pass gate + review over the change, into the **same** session run-dir:

```bash
python3 -m sail run --target . --diff <base-ref> --run-dir "$SESSION_DIR"
```

This runs the deterministic gates (ruff, mypy, pytest, bandit, semgrep, pip-audit — diff-scoped) **and** the blocking single-lens LLM review in one pass.

**Plan↔review traceability spine (#47).** Because Stage 0 put `plan.json` in this same run-dir, the review stage reads its `acceptance_criteria` and records per-criterion `met / unmet / unknown` in `review.json`'s `plan_verification` block (the define-at-plan → verify-at-review spine). An **unmet** AC blocks (the spine has teeth); an absent plan is non-blocking (`no-plan`); a malformed `plan.json` **fails closed** (`status: error`, blocks) — it is never silently treated as no-plan.

**Bounded convergence loop (review stage; max 3 rounds — driver-owned).** A non-zero exit means a gate failed, the review found CRITICAL/HIGH findings, or an AC is unmet. Mirror the plan stage's loop: fix the surfaced findings, **record a per-finding disposition each round** (`addressed` / `deferred` / `rejected` + a one-line rationale, keyed by the finding's stable `id` from `review.json`), and re-run `sail run --diff` — up to **3 rounds**. If still blocking after 3 rounds, present `review.json`'s findings + `plan_verification` and ask the user: continue / abort / proceed-advisory. The single-invocation exit code is unchanged; the driver owns the re-run-after-fix loop.

**`--dual-lens` risk-gated escalation (#47).** Default review is **single-lens** (industry norm; convergence is the quality mechanism). For a high-stakes diff — or when you simply want a cross-family second opinion — pass `--dual-lens` and set `SAIL_REVIEW_CMD2` to a second backend (e.g. a codex CLI):

```bash
SAIL_REVIEW_CMD2="codex exec -m gpt-5.4-mini" \
  python3 -m sail run --target . --diff <base-ref> --run-dir "$SESSION_DIR" --dual-lens
```

Both lenses review independently; their findings are unioned (each tagged `lens1`/`lens2` in `review.json`) and the gate blocks if **either** lens blocks or errors. `--dual-lens` with no `SAIL_REVIEW_CMD2` degrades cleanly to single-lens (logged, not an error).

## Calibration (operator validation — deferred to a live run)

The calibration acceptance criterion — *run looped `/sail` against issues `/ship` already handled (#32/#33 have full artifacts) and confirm the loop surfaces what `/ship`'s multi-round + dual-lens surfaced* — is an **operator validation step**, not a hermetic test: it needs a live LLM review backend (`SAIL_REVIEW_CMD` / `SAIL_REVIEW_CMD2`) and the merged #32/#33 artifacts. Run it once those are available and record the parity result in the ship's log (mirrors the #32 AC#7/#8 trial-runbook precedent). The build above delivers items 1–4 (plan-verification, resolution log, dual-lens, convergence) with hermetic tests; calibration is the live-run demonstration on top.
