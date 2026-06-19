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

    test_parser = subparsers.add_parser("test")
    test_parser.add_argument("cmd", nargs=argparse.REMAINDER)

    review_parser = subparsers.add_parser("review")
    review_parser.add_argument("--target")
    review_parser.add_argument("--diff", required=True)
    review_parser.add_argument("--run-dir")
    review_parser.add_argument("--advisory", action="store_true")

    args = parser.parse_args()

    if args.command == "run":
        return run(args.run_dir, target=args.target)
    if args.command == "test":
        cmd = list(getattr(args, "cmd", []))
        if cmd and cmd[0] == "--":
            cmd = cmd[1:]
        return run_tests(cmd)
    if args.command == "review":
        from sail.review import run_review
        return run_review(args.target, args.diff, args.run_dir, args.advisory)

    return 1


if __name__ == "__main__":
    sys.exit(main())
