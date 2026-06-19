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
        "_comment": "CK-Skills: redirects eligible /ship substeps to Codex CLI",
        "matcher": "Agent",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/codex-redirect.sh"
          }
        ]
      },
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

## LLM-reviewer layer (`sail review`)

The deterministic gates catch mechanical hygiene (lint/type/security/dep). They do **not** catch
design/correctness/scope defects (the kind a human red-team finds). `sail review` adds that
judgment layer: a **single** code-reviewer (an LLM, invoked via a CLI) that adversarially reviews
the **diff-scoped** change and returns structured findings.

```bash
python3 -m sail review --target DIR --diff <git-ref> [--run-dir DIR] [--advisory]
```

- **Single-agent** by design (no multi-agent / dual-model panel — per the sail research, that is
  unproven and costs 3–10× the tokens).
- **Diff-scoped:** reviews only `git -C DIR diff <git-ref>`, never the whole repo.
- **Backend:** defaults to `claude -p` (Anthropic headless). Override with the env var
  **`SAIL_REVIEW_CMD`** (e.g. `codex exec ...`, or a mock for tests) — parsed with `shlex` and run
  as an argv list (no shell); the prompt + diff are passed on **stdin**, never on a command line.
  **Availability-gated:** if the backend is not installed, the review skips cleanly (exit 0).
- **Findings** (`severity` ∈ CRITICAL/HIGH/MEDIUM/LOW, `category`, `file`, `line`, `issue`,
  `recommendation`) are written to `review.json` in the run-dir and summarized in `decision-log.md`.
- **Gate semantics:** exits **1** when any CRITICAL/HIGH finding is present (or when the backend
  response is unusable on a non-empty diff — errors never silently pass); exits **0** under
  `--advisory` (findings still recorded) or when there are no blocking findings.

This is the judgment layer the deterministic backbone lacks — the piece that makes /sail a
candidate **replacement** for `/ship`'s adversarial review, not just a fast hygiene complement.

### One-pass mode: `sail run --diff` does gates + review

`sail run --diff <ref>` is the drop-in `/ship` replacement entry point: it runs the deterministic
gates (diff-scoped) **and then** the blocking LLM review over the same diff, into the **same**
run-dir and `decision-log.md`, with a single combined exit code.

```bash
python3 -m sail run --target DIR --diff <git-ref>              # gates + blocking review, one pass
python3 -m sail run --target DIR --diff <git-ref> --no-review  # gates only (fast path, opt out of review)
```

- **Auto-on with `--diff` only.** Review activates exactly when there is a change scope to review.
  Whole-repo runs (no `--diff`) and `--baseline` mode never trigger it (there is no git ref to review).
- **Blocking & combined:** the run exits **1** if any blocking gate failed **or** the review blocked
  (CRITICAL/HIGH findings, or an unusable backend response); exits **0** only when both are clean.
- **No backend → fail closed.** Unlike standalone `sail review` (which skips cleanly), a review
  *requested* via `sail run --diff` that has no backend **fails the run** (exit 1) and logs the
  reason to `decision-log.md` — a green result never hides that the review didn't run. Install
  `claude` / set `SAIL_REVIEW_CMD`, or pass `--no-review` to deliberately run gates only.
