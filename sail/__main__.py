from __future__ import annotations

import argparse
import os
import sys

from sail.runner import run, run_tests


def _hard_round_ceiling_default() -> int:
    raw = os.environ.get("SAIL_HARD_ROUND_CEILING")
    if raw is None:
        return 10
    try:
        ceiling = int(raw)
    except (TypeError, ValueError):
        return 10
    return ceiling if ceiling > 0 else 10


def main() -> int:
    parser = argparse.ArgumentParser(prog="sail")
    subparsers = parser.add_subparsers(dest="command", required=True)

    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--target")
    run_parser.add_argument("--run-dir")
    run_parser.add_argument("--diff")
    run_parser.add_argument("--baseline")
    run_parser.add_argument("--no-review", action="store_true")
    run_parser.add_argument("--dual-lens", action="store_true")
    run_parser.add_argument("--tidiness", action="store_true")
    run_parser.add_argument("--red-team", action="store_true")
    run_parser.add_argument("--round", type=int, default=1)

    test_parser = subparsers.add_parser("test")
    test_parser.add_argument("cmd", nargs=argparse.REMAINDER)

    review_parser = subparsers.add_parser("review")
    review_parser.add_argument("--target")
    review_parser.add_argument("--diff", required=True)
    review_parser.add_argument("--run-dir")
    review_parser.add_argument("--advisory", action="store_true")
    review_parser.add_argument("--dual-lens", action="store_true")
    review_parser.add_argument("--tidiness", action="store_true")
    review_parser.add_argument("--red-team", action="store_true")
    review_parser.add_argument("--round", type=int, default=1)

    plan_parser = subparsers.add_parser("plan")
    plan_parser.add_argument("--target")
    plan_parser.add_argument("--run-dir")
    plan_parser.add_argument("--advisory", action="store_true")
    plan_parser.add_argument("--plan-adversary", action="store_true")
    plan_parser.add_argument("--grounded-plan", action="store_true")

    build_parser = subparsers.add_parser("build")
    build_parser.add_argument("--target")
    build_parser.add_argument("--run-dir")
    build_parser.add_argument("--mode", choices=["build", "fix"], default="build")
    build_parser.add_argument("--round", type=int, default=1)
    build_parser.add_argument("--change-class", choices=["prose", "code"])

    mutation_parser = subparsers.add_parser("mutation-verify")
    mutation_parser.add_argument("--target")
    mutation_parser.add_argument("--diff", required=True)
    mutation_parser.add_argument("--run-dir")
    mutation_parser.add_argument("--title")
    mutation_parser.add_argument("--bug-fix", action="store_true")

    subparsers.add_parser("spec")

    isolate_parser = subparsers.add_parser("isolate")
    isolate_parser.add_argument("--run-dir")
    isolate_parser.add_argument("--branch", required=True)
    isolate_parser.add_argument("--default-branch", default="main")
    isolate_parser.add_argument("--isolate", action="store_true")
    isolate_parser.add_argument("--in-place", action="store_true")
    isolate_parser.add_argument("--concurrent", action="store_true")

    land_parser = subparsers.add_parser("land")
    land_parser.add_argument("--run-dir", required=True)
    land_parser.add_argument("--issue", required=True)
    land_parser.add_argument("--title", default="")
    land_parser.add_argument("--prefix", default="sail")
    land_parser.add_argument("--pr", action="store_true")

    converge_parser = subparsers.add_parser("converge")
    converge_parser.add_argument("--rc", type=int, required=True)
    converge_parser.add_argument("--round", type=int, required=True)
    converge_parser.add_argument("--max-rounds", type=int, default=_hard_round_ceiling_default())
    converge_parser.add_argument("--run-dir")
    converge_parser.add_argument("--target")

    terminus_parser = subparsers.add_parser("terminus")
    terminus_parser.add_argument("--unattended", type=int, required=True, choices=(0, 1))
    terminus_parser.add_argument("--interactive", type=int, required=True, choices=(0, 1))

    degraded_parser = subparsers.add_parser("degraded-review")
    degraded_parser.add_argument("--run-dir", required=True)
    degraded_parser.add_argument("--target")
    degraded_parser.add_argument("--round", type=int)
    degraded_parser.add_argument("--sha")

    handoff_parser = subparsers.add_parser("handoff")
    handoff_parser.add_argument("--run-dir", required=True)
    handoff_parser.add_argument("--reason", required=True)
    handoff_parser.add_argument("--resume", required=True)
    handoff_parser.add_argument("--issue")
    handoff_parser.add_argument("--finding-ids", default="")

    args = parser.parse_args()

    if args.command == "run":
        if args.diff and args.baseline:
            parser.error("--diff and --baseline are mutually exclusive")
        return run(args.run_dir, target=args.target, diff_ref=args.diff, baseline_dir=args.baseline, review=not args.no_review, dual_lens=args.dual_lens, round=args.round, tidiness=args.tidiness, red_team=args.red_team)
    if args.command == "test":
        cmd = list(getattr(args, "cmd", []))
        if cmd and cmd[0] == "--":
            cmd = cmd[1:]
        return run_tests(cmd)
    if args.command == "review":
        from sail.review import run_review
        return run_review(args.target, args.diff, args.run_dir, args.advisory, dual_lens=args.dual_lens, round=args.round, tidiness=args.tidiness, red_team=args.red_team)
    if args.command == "plan":
        from sail.plan import run_plan
        return run_plan(args.target or ".", args.run_dir, args.advisory, plan_adversary=args.plan_adversary, grounded_plan=args.grounded_plan)
    if args.command == "build":
        from sail.build import run_build
        return run_build(args.target or ".", args.run_dir, mode=args.mode, round=args.round, change_class=args.change_class)
    if args.command == "mutation-verify":
        from sail.mutation_verify import run_mutation_verify

        rc, _payload, _artifact_path = run_mutation_verify(
            args.target or ".", args.diff, args.run_dir, bug_fix=args.bug_fix, title=args.title
        )
        return rc
    if args.command == "spec":
        from sail.spec import run_spec
        return run_spec()
    if args.command == "isolate":
        from sail.lifecycle import run_isolate
        spec_text = sys.stdin.read()
        return run_isolate(
            args.run_dir, args.branch, args.default_branch,
            args.isolate, args.in_place, args.concurrent, spec_text,
        )
    if args.command == "land":
        from sail.lifecycle import run_land
        return run_land(args.run_dir, args.issue, args.title, args.pr, args.prefix)
    if args.command == "converge":
        from sail.convergence import (
            cost_ceiling_seconds,
            cost_exceeded,
            cost_surface_line,
            elapsed_seconds,
            hydrate_trend_row,
            PARK,
            read_trend,
            loop_decision,
            materiality_floor,
            reappeared_dispositioned,
            trend_no_progress_streak,
            trend_window,
            spec_conflict_floor,
        )

        target_root = args.target or os.getcwd()
        elapsed = elapsed_seconds(args.run_dir) if args.run_dir else None
        if args.run_dir:
            hydrate_trend_row(args.run_dir, target_root, args.round)
            if elapsed is not None:
                print(cost_surface_line(elapsed), file=sys.stderr)

        if args.rc == 0:
            print("proceed")
            return 0

        decision = loop_decision(args.rc, args.round, args.max_rounds)
        if args.run_dir:
            reappeared = reappeared_dispositioned(args.run_dir, args.round)
            if reappeared:
                print(
                    "non-convergence: blocking finding re-flagged after rejected/deferred disposition: "
                    + ",".join(reappeared),
                    file=sys.stderr,
                )
                print(PARK)
                return 0
            conflict_ok, conflict_ids = spec_conflict_floor(
                args.rc, args.run_dir, args.target or os.getcwd(), args.round
            )
            if conflict_ok:
                print(
                    "spec-conflict: proceeding with tracked dissent over "
                    f"{len(conflict_ids)} blocking finding(s) objecting to the mandated design — "
                    "commit on branch, open a human-review issue, land-block the branch: "
                    + ",".join(conflict_ids),
                    file=sys.stderr,
                )
                print("proceed-dissent")
                return 0
            eligible, ids = materiality_floor(
                args.rc, args.run_dir, args.target or os.getcwd(), args.round
            )
            if eligible:
                print(
                    f"materiality-floor: committing with {len(ids)} beyond-diff hardening finding(s) logged as follow-ups: "
                    + ",".join(ids),
                    file=sys.stderr,
                )
                print("proceed-hardening")
                return 0
        trend_rows = read_trend(args.run_dir)
        ceiling = cost_ceiling_seconds()
        if cost_exceeded(elapsed, ceiling):
            print(
                f"cost-backstop: elapsed {elapsed:.3f}s exceeded ceiling {ceiling:.3f}s",
                file=sys.stderr,
            )
            print(PARK)
            return 0
        window = trend_window()
        streak = trend_no_progress_streak(trend_rows)
        if streak >= window:
            print(
                f"trend-stall: no-progress streak {streak} >= window {window}",
                file=sys.stderr,
            )
            print(PARK)
            return 0
        if decision == PARK:
            # The hard round ceiling is the ultimate backstop; give it a distinct stderr
            # stop-reason so all three PARK guards are symmetrically observable (AC#5).
            print(
                f"hard-ceiling: round {args.round} reached --max-rounds {args.max_rounds}",
                file=sys.stderr,
            )
        print(decision)
        return 0

    if args.command == "terminus":
        from sail.convergence import terminus_action

        print(terminus_action(bool(args.unattended), bool(args.interactive)))
        return 0

    if args.command == "degraded-review":
        # Detect a commit made under a DEGRADED review (#116) — a cross-family lens the diff gated
        # for did not run. Deterministic decision (tested Python); the thin-shell driver does the
        # ALERT/INFO log + any #108 issue-body enrichment. Prints `<TONE> <lens:cause,...>` when
        # degraded (empty when full-strength / non-gating) and writes a durable `degraded-review.md`
        # note (SHA + lenses) for the report/enrichment to consume. Always exits 0 — visibility, not
        # a gate (the maintainer refinement: degradation alone never blocks or files).
        import json as _json
        from sail.review import degraded_lenses, degraded_tone, format_degraded_note

        # ALWAYS clear any prior note FIRST (before any early return). The note is the issue-body
        # enrichment source, keyed only by file presence; a note left over from an earlier degraded
        # round would otherwise be appended to a LATER clean commit's issue (the round-1 stale-note
        # bug). It is re-derived from scratch below, only when the current round is degraded.
        note_path = os.path.join(args.run_dir, "degraded-review.md")
        try:
            os.unlink(note_path)
        except OSError:
            pass

        try:
            with open(os.path.join(args.run_dir, "review.json"), encoding="utf-8") as fh:
                review = _json.load(fh)
        except (OSError, ValueError):
            return 0
        # Freshness: when the committing round/target are given, refuse to credit a review.json that
        # is not current for THIS exact target/round AND whose stored diff_hash+plan_hash still match
        # the reviewed content (catches reviewed-content drift, not just a round mismatch). This is
        # correct AFTER the commit because the runner pins diff_ref to a base SHA (#87): `git diff
        # <SHA>` is identical before and after the commit lands (verified), so the re-diff does NOT
        # go empty post-commit the way a moving `HEAD` ref would. /sail Stage 3 always diffs against
        # the pinned base, so this never sees a moving ref in the documented flow.
        if args.round is not None and args.target is not None:
            from sail.convergence import review_current_and_clean
            if not review_current_and_clean(args.run_dir, os.path.abspath(args.target), args.round):
                return 0
        degraded = degraded_lenses(review)
        if not degraded:
            return 0
        pairs = ",".join(f"{d['lens']}:{d['cause']}" for d in degraded)
        print(f"{degraded_tone(degraded)} {pairs}")
        try:
            with open(note_path, "w", encoding="utf-8") as fh:
                fh.write(format_degraded_note(degraded, sha=args.sha, round=args.round))
        except OSError:
            pass
        return 0

    if args.command == "handoff":
        from sail.convergence import write_handoff

        ids = [part.strip() for part in args.finding_ids.split(",") if part.strip()]
        path = write_handoff(
            args.run_dir, args.reason, args.resume, issue=args.issue, finding_ids=ids
        )
        print(path)
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
