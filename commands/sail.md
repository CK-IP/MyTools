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

This runs the deterministic gates (ruff, mypy, pytest, bandit, semgrep, pip-audit — diff-scoped) **and** the blocking single-lens LLM review in one pass. A non-zero exit means a gate failed or the review found CRITICAL/HIGH findings — fix and re-run until clean (the review's own convergence).

## Seams for later work (#47 — not built here)

The shared session run-dir + `plan.json` contract is the discoverability hook for #47:

- **Acceptance-criteria verification** — the review stage reads the plan's `acceptance_criteria` from `plan.json` and records pass/fail per criterion (define-at-plan → verify-at-review traceability spine).
- **`--dual-lens` escalation** — an optional second-lens (e.g. codex) review pass, risk-gated, for high-stakes diffs. Default stays single-lens (industry norm; convergence is the quality mechanism).
- **Per-finding resolution log** — disposition (addressed / deferred / rejected) + rationale per finding.

These are documented seams only — `/sail` today delivers the plan → build → review spine.
