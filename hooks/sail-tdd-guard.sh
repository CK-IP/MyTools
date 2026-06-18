#!/bin/bash
set -euo pipefail

# This is a TDD workflow guardrail for the author's own .py source edits, not
# an adversarial security control. Test-directory classification is lexical
# (normalized path under tests/); deliberate evasion via symlinks or exotic
# paths is out of scope by design.

input="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' 'tdd-guard: jq is required' >&2
  exit 2
fi

set +e
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
jq_rc=$?
set -e
if [ "$jq_rc" -ne 0 ]; then
  printf '%s\n' 'tdd-guard: malformed hook input — failing closed' >&2
  exit 2
fi
[ -z "$file_path" ] && exit 0

norm="$(printf '%s' "$file_path" | python3 -c 'import os,sys; print(os.path.normpath(sys.stdin.read().strip()))')"

case "$norm" in
  *.py) ;;
  *) exit 0 ;;
esac

case "$norm" in
  tests/*|*/tests/*) exit 0 ;;
esac

if [ -f "$PWD/.sail/last-test-failed" ]; then
  exit 0
fi

printf '%s\n' "tdd-guard: write a failing test first (python3 -m sail test) - no .sail/last-test-failed under $PWD" >&2
exit 2
