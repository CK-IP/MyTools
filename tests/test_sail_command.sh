#!/usr/bin/env bash
# test_sail_command.sh
# Asserts that commands/sail.md exists and contains the front-door orchestration contract.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/commands/sail.md"

fail() {
  echo "FAIL: $1"
  exit 1
}

assert_grep() {
  local pattern="$1"
  local description="$2"

  if grep -qiE "$pattern" "$SKILL" 2>/dev/null; then
    return 0
  fi

  fail "$description"
}

if [ ! -f "$SKILL" ]; then
  fail "commands/sail.md exists"
fi

# --- Contract checks ---
assert_grep 'sail plan' "references the auto-firing plan stage"
assert_grep 'converg|loop' "mentions a bounded convergence loop"
assert_grep '3 rounds|max[^[:alnum:]]*3|3[^[:alnum:]]*max' "caps convergence at 3 rounds"
if grep -qi 'skipped' "$SKILL" 2>/dev/null && grep -qiE 'fail|halt|stop' "$SKILL" 2>/dev/null; then
  :
else
  fail "fails closed when the plan is skipped"
fi
assert_grep 'run-dir|run dir|session' "uses a shared session run-dir"
assert_grep 'build' "hands off to build"
assert_grep 'sail run --diff' "references the review stage"

echo "PASS: sail command contract verified"
