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
