# sail

`sail/` is the local runner package used by this repo. Invoke it with:

```bash
python3 -m sail run [--target DIR] [--run-dir DIR]
```

## What `run` does

`python3 -m sail run` orchestrates the built-in gates in this order:

1. `ruff`
2. `mypy`
3. `pytest`
4. `bandit`
5. `semgrep`
6. `pip-audit`

The runner writes its audit trail under `.sail/runs/<run-id>/`:

- `run-state.json`
- `decision-log.md`
- `ruff.sarif`
- `mypy.junit.xml`
- `junit.xml`
- `coverage.xml`
- `bandit.sarif`
- `semgrep.sarif`
- `pip-audit.json`

Availability gating is intentional: if a tool is not installed, that gate skips cleanly instead of failing the run.

Crash-safety and resume are also intentional:

- Re-running with the same `--run-dir` resumes the existing run.
- Finished gates are not redone.
- The decision log keeps appending, including a resume marker.

## What `test` does

`python3 -m sail test` manages the local TDD marker used by the fallback hook.

- `python3 -m sail test -- CMD...` runs the command after `--`.
- If the command fails, it creates `.sail/last-test-failed` in the current working directory.
- If the command succeeds, it removes that marker if present.
- If no command is supplied, sail runs the repo shell tests matching `tests/test_sail_*.sh`.
- The process exit code mirrors the command outcome.

## TDD guard integration

There are two supported hook paths:

- **Production path**: use the real `tdd-guard` package as a `PreToolUse` hook. Install it with:

```bash
npm i -g tdd-guard
```

  Pair that with the `tdd-guard-pytest` reporter in the hook configuration. During the trial, verify the installed CLI flags against the exact versions on your machine before wiring the hook.

- **Local fallback**: use [`hooks/sail-tdd-guard.sh`](../hooks/sail-tdd-guard.sh) plus `python3 -m sail test`. This fallback only checks for the `.sail/last-test-failed` marker and works in the no-pytest/no-npm environment.

The fallback hook allows:

- non-`.py` edits
- edits under `tests/`
- `.py` source edits only when `.sail/last-test-failed` exists
- This guardrail is lexical and workflow-only; it is not a security boundary.

### Settings snippet

This JSON is standalone and valid. It shows the `PreToolUse` block expected by the fallback path:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "_comment": "CK-Skills: soft gate — injects research checklist before edits",
        "matcher": "Edit|Write|Task",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/research-gate.sh"
          }
        ]
      },
      {
        "_comment": "CK-Skills: local TDD guard — requires a failing sail test marker before source edits",
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/sail-tdd-guard.sh"
          }
        ]
      }
    ]
  }
}
```

## AC#7 trial runbook

Run the sail backbone beside `/ship` on one real MassBalance change.

- Capture the findings, wall-clock time, and token cost.
- Verify checker CLI flags against the installed tool versions before the run.
- Kill the run in the middle.
- Re-run it and confirm resume works.
- Confirm finished gates are not redone.

## AC#8 success bar

The AC#8 target is a sail backbone that:

- matches or exceeds `/ship` quality on this slice
- is more compact and faster
- costs no more than a similar `/ship` run
- leaves a complete decision log
- proves kill-and-resume behavior in a real trial

## Diff / baseline scoping mode

By default `python3 -m sail run` reports **whole-repo** findings. On a large codebase this
buries the change's actual contribution under thousands of pre-existing findings. Two opt-in
modes report only the findings a change **introduced** (a finding-level delta, not a
changed-file filter):

```bash
# Compare against a git ref: sail runs the checkers on a worktree of <ref>, then reports
# only findings present now but absent at <ref>.
python3 -m sail run --target DIR --diff <git-ref>

# Compare against a previous run's artifacts (no re-run of the baseline):
python3 -m sail run --target DIR --baseline <prior-run-dir>
```

`--diff` and `--baseline` are mutually exclusive. Whole-repo mode (no flag) is unchanged and
remains the default.

### How the delta works

- Each finding is reduced to a **line-insensitive fingerprint**: SARIF (ruff/bandit/semgrep) →
  `(repo-relative path, ruleId, message)`; JUnit (mypy/pytest) → `(classname, name)`; pip-audit →
  `(package, vuln-id)`. Dropping line numbers means a pre-existing finding that merely shifted
  lines is **not** reported as new.
- The delta is a **multiset** comparison: the new count for a fingerprint is
  `max(0, current_count − baseline_count)`, so a genuinely-added duplicate of an existing finding
  is still surfaced.
- SARIF `file://` URIs are normalized to repo-relative paths (the baseline ran in a different
  worktree), so the same file matches across runs.

### Gate semantics in diff/baseline mode

- A gate **passes** when it introduces **zero** new findings (even if the whole repo has many
  pre-existing ones); it **fails** (and blocks, if blocking) when it introduces new findings.
- **Safety:** if the *current* artifact is missing or unparseable (a checker crashed), the gate is
  marked `failed` — it is never silently treated as clean. A missing/unparseable *baseline* is
  treated as empty, so all current findings count as new (errors over-report, never mask).
- An invalid `--diff` ref fails loudly rather than silently degrading to whole-repo.

### Audit trail

`run-state.json` records each gate's `mode` (`whole-repo` / `baseline` / `diff`) and
`new_findings_count`; the run's top-level `target` and `mode` are recorded too. `decision-log.md`
gets a `- mode: <mode>` marker line. (Unix-focused: Windows path case-folding is not implemented.)

## Planning layer (`sail plan`)

`python3 -m sail plan` does one LLM pass over a spec on stdin and writes `plan.json` in the
run-dir.

- **Spec feed (`sail spec`, #60):** the front door fetches the issue with
  `gh issue view <n> --json title,body,comments` and pipes it through `python3 -m sail spec`,
  which assembles title + body + comments into the plain-text spec on stdin. Feeding the **full**
  issue (not body-only or `--comments`-only, which varies by `gh` version) is what lets
  `is_plan_risky` see signals that live in different parts of the issue. It **fails closed**
  (exit 1) on empty/invalid input or a missing body, so an upstream `gh` failure can't feed a
  partial spec.
- **Backend:** `SAIL_PLAN_CMD` supplies the planner command. If no backend is available, the
  stage skips cleanly instead of attempting a plan.
- **Exit semantics:** exits `0` for a clean, usable plan; exits `1` when the plan is blocking,
  empty, or otherwise unusable.
- **Consistency self-check (#58):** the single plan pass also requires the author to name the
  exact action that fulfills every user-facing instruction/remediation the change adds — a
  promise with no matching delivered action (an unresolvable loop) becomes a blocking risk.
  Free; no extra agent.
- **Design-alternatives surfacing (#61):** the same single pass also populates a
  `design_alternatives` list (`option` / `tradeoff` / `recommended`) whenever the spec carries a
  genuine design choice with no single right answer (the #55 doctor count: N=8 vs N=9). This
  surfaces the call — and the trade-off — for an auto or human reviewer; the consistency
  self-check catches *bugs* but is blind to design-*quality* choices. It is **informational, never
  blocking** (it does not change the exit code) and is left an empty list for trivial specs (no
  invented alternatives — the no-uniform-weight discipline of #58).
- **`--plan-adversary` risk-gated escalation (#58):** for a plan-risky spec, `/sail` escalates to
  a one-shot adversarial plan pass — an independent second pass over the same spec via a second
  backend `SAIL_PLAN_CMD2` (like `--dual-lens`'s second lens), unioning its **explicitly**
  CRITICAL/HIGH risks into the gate (tagged `lens: adversary`). Fires on `--plan-adversary` **or**
  the `is_plan_risky` auto-trigger — which requires the strong #55 failure shape (a remediation
  signal **and** a reconciliation signal co-occurring, or an unambiguous failure phrase), so
  ordinary specs stay single-pass (no uniform weight). Skipped when the author plan is already
  blocking. An adversary backend error fails closed (exit 1 **and** `plan.json` `status: error`).
  No `SAIL_PLAN_CMD2` degrades cleanly to single-pass.

`/sail` is the front door: it auto-fires plan -> build -> review for one issue end to end.

## LLM-reviewer layer (`sail review`)

The deterministic gates catch mechanical hygiene (lint/type/security/dep). They do **not** catch
design/correctness/scope defects (the kind a human red-team finds). `sail review` adds that
judgment layer: a **single** code-reviewer (an LLM, invoked via a CLI) that adversarially reviews
the **diff-scoped** change and returns structured findings.

```bash
python3 -m sail review --target DIR --diff <git-ref> [--run-dir DIR] [--advisory] [--dual-lens]
```

- **Single-agent by default** (no multi-agent / dual-model panel — per the sail research, that is
  unproven and costs 3–10× the tokens). A risk-gated second lens is opt-in via `--dual-lens` (below).
- **Diff-scoped:** reviews only `git -C DIR diff <git-ref>`, never the whole repo.
- **Backend:** defaults to `claude -p` (Anthropic headless). Override with the env var
  **`SAIL_REVIEW_CMD`** (e.g. `codex exec ...`, or a mock for tests) — parsed with `shlex` and run
  as an argv list (no shell); the prompt + diff are passed on **stdin**, never on a command line.
  **Availability-gated:** if the backend is not installed, the review skips cleanly (exit 0).
- **Findings** (`severity` ∈ CRITICAL/HIGH/MEDIUM/LOW, `category` ∈
  design/correctness/security/scope/test-adequacy/other, `file`, `line`, `issue`,
  `recommendation`) are written to `review.json` in the run-dir and summarized in `decision-log.md`.
- **Test-adequacy probe (#70):** the same review pass also asks whether a plausible mutation of the
  diff's core behavior change would be caught by the new/changed tests, flagging a vacuous/tautological
  test as a `category: test-adequacy` finding (severity reviewer-assigned; no second LLM call). It
  no-ops on test-free diffs. The heavyweight mutation-testing tool run is deferred to `/fortify`.
- **Build-side mutation verification (#131):** `python3 -m sail mutation-verify` is the executable
  complement to the inline #70 probe. It is a no-op unless the diff is a bug-fix, has at least one
  new/changed test file, and has at least one non-test source change. When it fires, it reverts only
  the source hunks with `git apply -R`, reruns the new/changed tests, restores the tree in
  `try/finally`, and records vacuous tests as `category: test-adequacy` findings tagged
  `lens: mutation-verify` in `review.json`.
- **Gate semantics:** exits **1** when any CRITICAL/HIGH finding is present (or when the backend
  response is unusable on a non-empty diff — errors never silently pass); exits **0** under
  `--advisory` (findings still recorded) or when there are no blocking findings.

This is the judgment layer the deterministic backbone lacks — the piece that makes /sail a
candidate **replacement** for `/ship`'s adversarial review, not just a fast hygiene complement.

### Plan↔review traceability spine (#47)

When the review's run-dir also holds a `plan.json` (written by `sail plan` into a **shared session
run-dir** — see the `/sail` driver), `sail review` reads its `acceptance_criteria` and verifies each
against the diff in the **same single LLM pass** (no second invocation). Results land in
`review.json` under `plan_verification`:

- `status: "verified"` — each AC recorded `met` / `unmet` / `unknown` (with one-line evidence). An
  **unmet** AC blocks the gate (exit 1) — the define-at-plan → verify-at-review spine has teeth.
- `status: "no-plan"` — no `plan.json` in the run-dir; verification is skipped and **non-blocking**
  (the spine is additive — gates-only review is unaffected).
- `status: "error"` — `plan.json` exists but is unparseable/truncated; **fails closed** (exit 1).
  A corrupt plan is never silently downgraded to no-plan.

### Per-finding resolution log (#47)

Each finding in `review.json` carries a **content-derived stable `id`** (`lens1-<hash>` /
`lens2-<hash>` — stable across reorderings and the dual-lens union) plus any backend-supplied
`disposition` / `rationale`. Across the driver's convergence loop, the disposition of each finding
(`addressed` / `deferred` / `rejected` + a one-line rationale) is appended to `decision-log.md` via
`DecisionLog.finding_resolution(id, disposition, rationale)` — a compact, auditable resolution trail
(no /fortify-style report ceremony).

### `--dual-lens` risk-gated escalation (#47)

Default review is **single-lens** (industry norm; the convergence loop is the quality mechanism).
For a high-stakes diff — or any time you want a cross-family second opinion — pass `--dual-lens` and
point `SAIL_REVIEW_CMD2` at a second backend:

```bash
SAIL_REVIEW_CMD2="codex exec -m gpt-5.4-mini" \
  python3 -m sail review --target DIR --diff <git-ref> --dual-lens
```

Both lenses review independently; findings are unioned (each tagged `lens1`/`lens2`), `review.json`
records `lenses: ["lens1","lens2"]`, and the gate blocks if **either** lens blocks or returns an
unusable response (never-mask, per lens). `--dual-lens` with no `SAIL_REVIEW_CMD2` degrades cleanly
to single-lens (logged, not a hard error). The same flag is available on `sail run --diff`.

### Calibration (operator validation — deferred)

The #47 calibration AC — *looped `/sail` vs `/ship` parity on #32/#33* — is an operator validation
step requiring a live review backend + the merged #32/#33 artifacts, not a hermetic test. Run it once
those are available and record the parity result in the ship's log (mirrors the #32 AC#7/#8 runbook
precedent).

### One-pass mode: `sail run --diff` does gates + review

`sail run --diff <ref>` is the drop-in `/ship` replacement entry point: it runs the deterministic
gates (diff-scoped) **and then** the blocking LLM review over the same diff, into the **same**
run-dir and `decision-log.md`, with a single combined exit code.

```bash
python3 -m sail run --target DIR --diff <git-ref>              # gates + blocking review, one pass
python3 -m sail run --target DIR --diff <git-ref> --no-review  # gates only (fast path, opt out of review)
python3 -m sail run --target DIR --diff <git-ref> --dual-lens  # gates + dual-lens review (needs SAIL_REVIEW_CMD2)
```

- **Auto-on with `--diff` only.** Review activates exactly when there is a change scope to review.
  Whole-repo runs (no `--diff`) and `--baseline` mode never trigger it (there is no git ref to review).
- **Blocking & combined:** the run exits **1** if any blocking gate failed **or** the review blocked
  (CRITICAL/HIGH findings, or an unusable backend response); exits **0** only when both are clean.
- **No backend → fail closed.** Unlike standalone `sail review` (which skips cleanly), a review
  *requested* via `sail run --diff` that has no backend **fails the run** (exit 1) and logs the
  reason to `decision-log.md` — a green result never hides that the review didn't run. Install
  `claude` / set `SAIL_REVIEW_CMD`, or pass `--no-review` to deliberately run gates only.

## Build delegation layer (`sail build`)

`/sail`'s Stage-2 build (writing the failing test then the minimum code) and its per-round convergence fixes are **inline only when `SAIL_BUILD_CMD` is unset** — done by the orchestrating session. When `SAIL_BUILD_CMD` is set, `sail build` invokes the configured subprocess backend by default, mirroring the plan/review backend pattern.

```bash
SAIL_BUILD_CMD="claude -p" \
  python3 -m sail build --target . --run-dir "$RUN_DIR"            # build mode (default)
SAIL_BUILD_CMD="claude -p" \
  python3 -m sail build --target . --run-dir "$RUN_DIR" --mode fix --round N   # per-round fixes
python3 -m sail build --target . --run-dir "$RUN_DIR" --change-class prose     # prose/spec-heavy changes
```

- **Backend:** `SAIL_BUILD_CMD` supplies the command (parsed with `shlex`, run with `cwd=target`). No built-in default — **unset means inline** (the orchestrator builds, logged not errored); when it is set, `python3 -m sail build` dispatches to that backend by default.
- **`build.json` status:** `delegated` (INFO: backend wrote the change → proceed to review), `inline` (`reason=backend-unset` is INFO; `reason=backend-not-runnable` with `SAIL_BUILD_CMD` set is ALERT), or `error` (fail closed). Exit code: 0 for delegated/inline, 1 for error.
- **TDD enforced:** both `build` and `fix` modes fail closed unless `<target>/.sail/last-test-failed` exists — the failing test is authored first (leadsman-owned); only code-writing is delegated. The backend is instructed never to weaken the failing test.
- **fix-mode contract:** reads `review.json` (stable finding ids) + decision-log dispositions from the run-dir; fails closed if `review.json` is missing / unparseable / not `status: completed`, or the decision-log is present but undecodable. An absent decision-log is fine (a round-1 fix has no prior dispositions).
- **Prose/spec routing (#133):** doc-dominated changes (`.md` / `.rst`, via `checkers._DOC_SUFFIXES`) classify as `prose`; everything else is `code`. `--change-class prose|code` overrides the deterministic backstop, and when omitted the runner derives the class from `plan.json`'s `scope.in`. Prose changes prefer `SAIL_BUILD_CMD_PROSE` over `SAIL_BUILD_CMD`. If the selected prose builder shares a family with `SAIL_REVIEW_CMD` or `SAIL_REVIEW_CMD2`, `build.json` records `cross_family: "lost"` plus a `same_family_warning` and the run still proceeds as `delegated` (treat as ALERT per #112). Code-class routing is unchanged.
- **Backend choice (#83):** `claude -p` (Sonnet 4.6) keeps the implementer in a different family from a codex review lens, preserving cross-family review; `codex exec …` is cheapest but collides with a codex `SAIL_REVIEW_CMD2`. If `SAIL_BUILD_CMD` is set, `SAIL_REVIEW_CMD` is the single-lens `claude` reviewer, and `build.json` comes back `inline` with `reason=backend-not-runnable`, raise an **ALERT** because builder=reviewer=claude and cross-family review was lost. `sail build` emits an advisory `same_family_warning` (best-effort, wrapper-aware, non-blocking) when the selected build backend and an active review lens share a family. Inline stays the default/fallback only when `SAIL_BUILD_CMD` is unset.
