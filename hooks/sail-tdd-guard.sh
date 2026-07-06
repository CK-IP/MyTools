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
file_path_rc=$?
old_string_present="$(printf '%s' "$input" | jq -r '(.tool_input // {}) | has("old_string")' 2>/dev/null)"
old_string_present_rc=$?
new_string_present="$(printf '%s' "$input" | jq -r '(.tool_input // {}) | has("new_string")' 2>/dev/null)"
new_string_present_rc=$?
set -e
if [ "$file_path_rc" -ne 0 ] || [ "$old_string_present_rc" -ne 0 ] || [ "$new_string_present_rc" -ne 0 ]; then
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

if [ "$old_string_present" = "true" ] && [ "$new_string_present" = "true" ]; then
  # Pipe the RAW hook JSON to the helper — the strings are never captured via
  # $(...) (which strips trailing newlines and would let a reconstructed edit
  # phantom-match an earlier occurrence); the helper unwraps .tool_input itself.
  # 2>/dev/null: this hook is globally symlinked and fires on .py edits in
  # EVERY project — where no sail package exists the import failure must
  # fall through to the marker check silently, not leak a traceback.
  if printf '%s' "$input" | PYTHONPATH="$PWD" python3 -m sail.tdd_guard 2>/dev/null; then
    exit 0
  fi
fi

if [ -f "$PWD/.sail/last-test-failed" ]; then
  exit 0
fi

printf '%s\n' "tdd-guard: write a failing test first (python3 -m sail test) - no .sail/last-test-failed under $PWD" >&2
exit 2
