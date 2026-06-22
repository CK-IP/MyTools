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

REPO_ROOT="$(git rev-parse --show-toplevel)"
BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
CONCURRENT=""; sail_concurrent_run "$REPO_ROOT" <issue> && CONCURRENT="--concurrent"
DECISION="$(printf '%s' "$SPEC" | python3 -m sail isolate \
  --run-dir "$SESSION_DIR" --branch "$BRANCH" --default-branch main $CONCURRENT)"
MODE="$(printf '%s' "$DECISION" | cut -f1)"    # isolate | in-place
COMMIT="$(printf '%s' "$DECISION" | cut -f2)"  # yes | no

WORK_DIR="$REPO_ROOT"
if [ "$MODE" = "isolate" ]; then
  WORK_DIR="$(sail_setup_isolation "$REPO_ROOT" <issue>)" \
    || { echo "sail: could not isolate (parallel run holds sail/<issue>?) — falling back to in-place"; WORK_DIR="$REPO_ROOT"; COMMIT="no"; }
  cd "$WORK_DIR"
fi
```

**Decision contract (mirrors `--dual-lens`/`--plan-adversary` risk-gating):**

- **Isolate by default** on the default branch → worktree `.claude/worktrees/sail-<issue>` on a fresh `sail/<issue>` branch.
- **On a feature branch already** (e.g. `/surf`'s `surf/<issue>`) → stay in place and commit on **that** branch — by design (forcing a `sail/<issue>` checkout would fight `/surf`); the `sail/<issue>` name applies only to the from-default isolate path.
- **Risk-gated skip** (`--in-place`): work in place with **no commit** ONLY when not plan-risky AND no concurrent run; either condition flips it back to isolate. `--isolate` forces isolation (the two flags are mutually exclusive).
- **Concurrency-safe:** `sail_setup_isolation` idempotently **reuses** an existing clean `sail/<issue>` worktree (rerun-safe) and never destroys unsaved work — a true parallel-run collision makes it fail, and the driver falls back to in-place rather than clobbering the other run (autonomous `/surf` never pauses).

All of plan → build → review then run **inside `$WORK_DIR`** (`--target .` from there). The mechanism is **plain `git worktree`** so it works in the autonomous/pinned-cwd `/surf` subagent (native `EnterWorktree(create)` is rejected there).

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

The adversary runs as a second independent backend (`SAIL_PLAN_CMD2`); its **explicitly CRITICAL/HIGH risks union into the plan gate** (each tagged `lens: adversary` in `plan.json`), and the gate fails closed (and writes `status: error` to `plan.json`, matching the exit code) if the adversary backend errors. On plan-risky work the adversary runs **even when the author plan is already blocking (#62)** — reversing the earlier skip-when-already-red. The skip saved a call but threw away the adversary's reason for being: a second, independent **design** perspective (the lens most likely to catch a wrong design shape, a materially simpler approach, or a design choice a single author pass misses). When a consistency bug is already flagged the gate is red regardless, but the adversary's job is **design breadth, not adding to the blocking count** — so its independent CRITICAL/HIGH design findings still union into `plan.json` (tagged `lens: adversary`) for the reviewer. Cost stays risk-gated (escalation still requires `--plan-adversary` or `is_plan_risky`), so only the rare risky-and-already-blocking intersection pays one bounded extra call; an adversary backend error fails closed uniformly (`status: error`, exit 1) regardless. `--plan-adversary`/auto-trigger with no `SAIL_PLAN_CMD2` degrades cleanly to single-pass (logged, not an error) — exactly as `--dual-lens` degrades with no `SAIL_REVIEW_CMD2`.

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

**Scanner findings as review triage context (#69).** Within this one pass the order is **series, not parallel**: the deterministic gates run **first**, and each gate's NEW diff-scoped findings (ruff/bandit/semgrep/pip-audit/…) are then fed into the LLM review as **triage context** — the hybrid LLM+SAST approach the literature found strongest (LLM-as-FP-filter over scanner output). Seeing what the scanners already flagged, the reviewer **corroborates** the genuine alarms (and raises confidence on them), **notes likely false positives** in its summary, and spends its own effort on the defects scanners can't catch (authorization/ownership gaps, business logic, design, scope) rather than re-deriving the scanner hits. The scanner block is delimited and marked **untrusted data** (it can carry attacker-influenced diff content — OWASP LLM01), so the reviewer never treats it as instructions. **Crucially, the triage is purely advisory and the deterministic gate stays authoritative:** a new blocking scanner finding still blocks the run on its own, regardless of what the LLM says about it — the LLM verdict never suppresses a gate block. With no diff gate findings (or in whole-repo/baseline mode) no triage block is emitted and behavior is unchanged.

**Test-adequacy probe (#70).** Coverage % alone is a weak proxy — the measured failure mode is a test that passes *even when the code is broken* (research found >99% of some LLM-generated "failing" tests still passed on unmutated code). So the **same single review pass** now carries a cheap mutation-survival probe: for the diff's core behavior change, the reviewer names a plausible mutation (a flipped comparison, off-by-one, dropped guard) and asks whether the diff's new/changed tests would actually FAIL under it. A test that would still pass — it asserts nothing, checks a tautology or only its own mock, re-implements the code it claims to verify, or pins an incidental detail — is flagged as a finding with category **`test-adequacy`** (vacuous/tautological test). It rides the existing finding pipeline: severity stays reviewer-assigned (a NEW feature whose only test is vacuous lands HIGH and blocks via the normal `has_blocking` flow; a weak signal lands MEDIUM/LOW and surfaces without blocking), so there is **no second LLM call and no new exit-code path**. The probe **no-ops on test-free diffs** (a code-only or docs-only change is not a finding — it does not invent missing-test complaints) and stays within the existing >80%-confidence bar. This is a deliberately cheap inline proxy; the gold-standard **full mutation-testing tool run is deferred to the `/fortify` stage** (heavy, run-on-demand), not inline here.

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

### Stage 4 — Commit (closing the opening bookend, #65)

**The commit is gated strictly on GREEN.** Only after the Stage 3 convergence loop reports green — the final `sail run` exited **0** (0 CRITICAL / 0 HIGH and no unmet AC) — commit the change. **Never commit on a red review.** When Stage 0.5 chose to isolate or to stay on a feature branch (`COMMIT=yes`), commit on the branch; when it granted a risk-gated in-place skip (`COMMIT=no`), do not auto-commit (the operator owns the tiny inline fix).

```bash
# Only reachable after the convergence loop confirms `sail run ... ` exited 0.
if [ "$COMMIT" = "yes" ]; then
  TITLE="$(printf '%s' "$RAW" | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])')"
  sail_commit_on_branch "$WORK_DIR" <issue> "$TITLE"   # conventional subject + (#<issue>); no-op on a clean tree
fi
```

Supervised runs may show/approve the message first; the autonomous `/surf` path commits without pausing (never break `/surf`). The branch now carries the committed change for the land stage (Stage 5) to close. (Note: a `git commit` here is subject to the global `delivery-gate.sh` hook only when a `~/.ship/ship-state-*.json` exists — `/sail`/`/surf` runs have none, so the gate is inert; see `.ship/domain.md`.)

### Stage 5 — Land (closing the loop, #59)

**The closing git bookend.** Stage 0.5 opened the loop (isolate); Stage 4 committed the green change to `sail/<issue>`; Stage 5 lands it: merge to `main`, auto-close the issue, flip the board to Done, prune the branch, and publish the review evidence as the closing comment. It runs **only after Stage 3 is green** (final `sail run` exited 0). Like #65, the substantive logic lives in the engine and the git/gh mechanics are a thin documented sequence — the **same** sequence `/surf` runs (one source of truth; keep the two in sync).

First, the engine emits the closing artifacts from the **already-produced** review evidence — no re-review, no network:

```bash
# Reachable only after the convergence loop confirms `sail run ...` exited 0.
TITLE="$(printf '%s' "$RAW" | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])')"
python3 -m sail land --run-dir .surf/runs/<issue> --issue <issue> --title "$TITLE"
# writes:  .surf/runs/<issue>/land-comment.md      (AC verdicts + finding dispositions + gate counts)
#          .surf/runs/<issue>/land-commit-msg.txt  (merge subject + a `Closes #<issue>` line)
```

**Human-gated terminus (hands-on `/sail` runs only).** Before any outward action, **show what land will do** — print `land-comment.md` and `land-commit-msg.txt` and the exact merge/close/prune commands below — and **pause for approval**. Merge to `main` only after the operator approves. (`/surf` is unattended and does **not** pause — see below.)

**Direct-merge (default).** GitHub auto-closes the issue from the `Closes #<issue>` keyword in the merge commit when it lands on the **default branch (`main`)**; the board's native *Item closed → Done* automation then flips status — **no `gh issue close`, no board API call**. Confirm the merge target is `main` (the auto-close only fires there), then:

```bash
RD=.surf/runs/<issue>
git checkout main
git merge sail/<issue> --no-ff -F "$RD/land-commit-msg.txt"   # `Closes #<issue>` lives in the merge message
git push origin main                                         # REQUIRED: the merge must reach origin's DEFAULT branch — only then does GitHub auto-close the issue and fire the board's Item-closed→Done automation; a local-only merge does neither
git rev-parse HEAD                                            # record the merge SHA
gh issue comment <issue> -F "$RD/land-comment.md"            # publish review evidence (reused, not re-derived)
# Prune the merged branch ONLY after the merge is on origin/main (auto-delete-head-branch is
# PR-only — it won't fire on a direct merge). Order matters: `git push origin --delete` ignores
# merge state, so deleting the remote branch before main is pushed could drop unmerged work.
git branch -d sail/<issue>                                    # safe local delete: refuses if not fully merged
git ls-remote --exit-code --heads origin sail/<issue> >/dev/null 2>&1 && git push origin --delete sail/<issue> || true
```

**`--pr` mode (high-stakes changes).** Instead of a direct merge, open a PR — the linked-PR merge then handles close + board + branch-delete **natively**:

```bash
python3 -m sail land --run-dir "$RD" --issue <issue> --title "$TITLE" --pr   # also writes land-pr-body.md (carries `Closes #<issue>`)
gh pr create --base main --head sail/<issue> --title "$TITLE" --body-file "$RD/land-pr-body.md"
```

**Preconditions (document, don't assume).** The merge must be **pushed to origin's default branch** — a local-only merge triggers neither GitHub's auto-close nor the board automation. Board → Done then relies on the repo's *Item closed → Done* Projects automation staying enabled; `Closes #<issue>` auto-closes **only** on the default branch; `git branch -d` refuses an unmerged branch, and the remote delete is guarded on the branch having been pushed **and** sequenced after `git push origin main` so it never drops unmerged work. If any precondition fails, land surfaces it rather than silently no-op'ing.

> **Keep in sync:** this orchestration is intentionally identical to `commands/surf.md`'s post-merge land step — both consume the same `sail land` output. Change one, change the other.

## Calibration (operator validation — deferred to a live run)

The calibration acceptance criterion — *run looped `/sail` against issues `/ship` already handled (#32/#33 have full artifacts) and confirm the loop surfaces what `/ship`'s multi-round + dual-lens surfaced* — is an **operator validation step**, not a hermetic test: it needs a live LLM review backend (`SAIL_REVIEW_CMD` / `SAIL_REVIEW_CMD2`) and the merged #32/#33 artifacts. Run it once those are available and record the parity result in the ship's log (mirrors the #32 AC#7/#8 trial-runbook precedent). The build above delivers items 1–4 (plan-verification, resolution log, dual-lens, convergence) with hermetic tests; calibration is the live-run demonstration on top.
