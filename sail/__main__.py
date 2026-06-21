from __future__ import annotations

import argparse
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
    review_parser.add_argument("--round", type=int, default=1)

    plan_parser = subparsers.add_parser("plan")
    plan_parser.add_argument("--target")
    plan_parser.add_argument("--run-dir")
    plan_parser.add_argument("--advisory", action="store_true")
    plan_parser.add_argument("--plan-adversary", action="store_true")

    args = parser.parse_args()

    if args.command == "run":
        if args.diff and args.baseline:
            parser.error("--diff and --baseline are mutually exclusive")
        return run(args.run_dir, target=args.target, diff_ref=args.diff, baseline_dir=args.baseline, review=not args.no_review, dual_lens=args.dual_lens, round=args.round, tidiness=args.tidiness)
    if args.command == "test":
        cmd = list(getattr(args, "cmd", []))
        if cmd and cmd[0] == "--":
            cmd = cmd[1:]
        return run_tests(cmd)
    if args.command == "review":
        from sail.review import run_review
        return run_review(args.target, args.diff, args.run_dir, args.advisory, dual_lens=args.dual_lens, round=args.round, tidiness=args.tidiness)
    if args.command == "plan":
        from sail.plan import run_plan
        return run_plan(args.target or ".", args.run_dir, args.advisory, plan_adversary=args.plan_adversary)

    return 1


if __name__ == "__main__":
    sys.exit(main())
