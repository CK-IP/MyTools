from __future__ import annotations

import argparse
import os
import sys

from sail.runner import run, run_tests


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
    converge_parser.add_argument("--max-rounds", type=int, default=3)
    converge_parser.add_argument("--run-dir")
    converge_parser.add_argument("--target")

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
        return run_build(args.target or ".", args.run_dir, mode=args.mode, round=args.round)
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
            PARK,
            loop_decision,
            materiality_floor,
            reappeared_dispositioned,
        )

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
        print(decision)
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
