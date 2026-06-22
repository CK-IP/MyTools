"""sail lifecycle — the isolate-vs-skip decision for /sail's git opening bookend (#65).

This is the *decision* half of the opening bookend; the git mechanics (worktree creation,
commit) live in `home/lib/sail-git-lifecycle.sh` (plain `git`, mode-agnostic). The decision
lives here, in the engine, for two reasons the plan red-team called out as HIGH:
  - it must REUSE the existing `is_plan_risky` heuristic (single source of truth), and
  - it must be PERSISTED to the decision-log on every path (isolate, in-place, forced).

It is ADDITIVE: a new `sail isolate` subcommand, wired in `__main__.py`, that touches none
of the `run`/`plan`/`review` codepaths. The decision itself (`isolate_decision`) is a pure
function — hermetically testable with no git, no I/O.
"""
from __future__ import annotations

import sys

from sail.plan import is_plan_risky


def isolate_decision(branch, default_branch, force_isolate, force_in_place, plan_risky, concurrent):
    """Pure decision. Returns (decision, commit, reason).

    decision: "isolate" | "in-place";  commit: bool;  reason: str (for the decision-log).

    Precedence (first match wins) — mirrors how --dual-lens/--plan-adversary risk-gate:
      1. --isolate                        -> isolate, commit   (explicit force)
      2. --in-place + plan-risky          -> isolate, commit   (risk overrides the skip)
      3. --in-place + concurrent run      -> isolate, commit   (risk overrides the skip)
      4. --in-place (otherwise)           -> in-place, NO commit (risk-gated skip granted)
      5. on a feature branch (!= default) -> in-place, commit   (already isolated by branch)
      6. on the default branch            -> isolate, commit    (isolate-by-default)
    """
    if force_isolate:
        return ("isolate", True, "forced isolate (--isolate)")
    if force_in_place:
        if plan_risky:
            return ("isolate", True, "plan-risky spec overrides --in-place skip")
        if concurrent:
            return ("isolate", True, "concurrent run overrides --in-place skip")
        return ("in-place", False, "risk-gated skip (--in-place; not plan-risky; no concurrent run)")
    if branch and branch != default_branch:
        # The feature-branch case commits on the CURRENT branch BY DESIGN — it honors the
        # operator/driver's chosen branch (e.g. /surf's `surf/<issue>`). Forcing a
        # `sail/<issue>` checkout here would fight /surf, so the canonical `sail/<issue>`
        # name applies only to the from-default isolate path below.
        return ("in-place", True, f"on feature branch {branch} (already isolated; commit in place)")
    return ("isolate", True, f"isolate-by-default on {default_branch}")


def run_isolate(run_dir, branch, default_branch, force_isolate, force_in_place, concurrent, spec_text):
    """CLI entry: compute the decision (reusing is_plan_risky on the spec), persist it to
    the decision-log, and print `<decision>\\t<commit:yes|no>\\t<reason>` for the shell driver.

    --isolate and --in-place are mutually exclusive (fail closed, rc=2). Always rc=0 on a
    computed decision; the decision-log write is best-effort and never blocks the print.
    """
    if force_isolate and force_in_place:
        print("sail isolate: --isolate and --in-place are mutually exclusive", file=sys.stderr)
        return 2

    plan_risky = is_plan_risky(spec_text)
    decision, commit, reason = isolate_decision(
        branch, default_branch, bool(force_isolate), bool(force_in_place), plan_risky, bool(concurrent)
    )

    if run_dir:
        try:
            from sail.decisionlog import DecisionLog
            DecisionLog(run_dir).isolate_marker(decision, commit, reason)
        except OSError as exc:
            print(f"sail isolate: warning — could not write decision-log: {exc}", file=sys.stderr)

    sys.stdout.write(f"{decision}\t{'yes' if commit else 'no'}\t{reason}\n")
    return 0
