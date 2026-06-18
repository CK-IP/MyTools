#!/usr/bin/env bash
# test_sail_tddguard.sh
# Red test for Step 6: `sail test` marker management plus tdd-guard wiring.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
WORKDIR="$TMP_ROOT/work"
HOOK_SCRIPT="$REPO_ROOT/hooks/sail-tdd-guard.sh"
SETTINGS_FILE="$REPO_ROOT/home/settings.reference.json"
SAIL_LOG="$TMP_ROOT/sail-test.log"
HOOK_LOG="$TMP_ROOT/sail-hook.log"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  if [ -s "$SAIL_LOG" ]; then
    echo "---- sail output ----" >&2
    sed 's/^/  /' "$SAIL_LOG" >&2 || true
    echo "---------------------" >&2
  fi
  if [ -s "$HOOK_LOG" ]; then
    echo "---- hook output ----" >&2
    sed 's/^/  /' "$HOOK_LOG" >&2 || true
    echo "---------------------" >&2
  fi
  exit 1
}

run_sail_test() {
  local cmd="$1"
  shift || true
  (
    cd "$WORKDIR"
    PYTHONPATH="$REPO_ROOT${PYTHONPATH:+:$PYTHONPATH}" python3 -m sail test -- "$cmd" "$@"
  ) >"$SAIL_LOG" 2>&1
}

run_hook() {
  local input="$1"
  local cwd="${2:-$WORKDIR}"
  (
    cd "$cwd"
    printf '%s' "$input" | bash "$HOOK_SCRIPT"
  ) >"$HOOK_LOG" 2>&1
}

mkdir -p "$WORKDIR"

if run_sail_test false; then
  sail_rc=0
else
  sail_rc=$?
fi

[ "$sail_rc" -ne 0 ] || fail "python3 -m sail test -- false unexpectedly exited 0"
[ -f "$WORKDIR/.sail/last-test-failed" ] || fail "python3 -m sail test -- false did not create $WORKDIR/.sail/last-test-failed"

if run_sail_test true; then
  sail_rc=0
else
  sail_rc=$?
fi

[ "$sail_rc" -eq 0 ] || fail "python3 -m sail test -- true unexpectedly exited $sail_rc"
[ ! -e "$WORKDIR/.sail/last-test-failed" ] || fail "python3 -m sail test -- true did not remove $WORKDIR/.sail/last-test-failed"

[ -f "$HOOK_SCRIPT" ] || fail "missing hook script $HOOK_SCRIPT"

rm -f "$WORKDIR/.sail/last-test-failed"

if run_hook 'not json{' "$WORKDIR"; then
  hook_rc=0
else
  hook_rc=$?
fi

[ "$hook_rc" -eq 2 ] || fail "hook did not fail closed for malformed input"

if run_hook '{"tool_input":{"file_path":"sail/foo.py"}}' "$WORKDIR"; then
  hook_rc=0
else
  hook_rc=$?
fi

[ "$hook_rc" -ne 0 ] || fail "hook allowed a source-file edit while $WORKDIR/.sail/last-test-failed was absent"

mkdir -p "$WORKDIR/.sail"
: >"$WORKDIR/.sail/last-test-failed"

if run_hook '{"tool_input":{"file_path":"sail/foo.py"}}' "$WORKDIR"; then
  hook_rc=0
else
  hook_rc=$?
fi

[ "$hook_rc" -eq 0 ] || fail "hook blocked a source-file edit even though $WORKDIR/.sail/last-test-failed was present"

rm -f "$WORKDIR/.sail/last-test-failed"

if run_hook '{"tool_input":{"file_path":"tests/test_x.sh"}}' "$WORKDIR"; then
  hook_rc=0
else
  hook_rc=$?
fi

[ "$hook_rc" -eq 0 ] || fail "hook blocked a test-file edit"

if run_hook '{"tool_input":{"file_path":"tests/../sail/foo.py"}}' "$WORKDIR"; then
  hook_rc=0
else
  hook_rc=$?
fi

[ "$hook_rc" -eq 2 ] || fail "hook allowed a traversed source-file path"

if run_hook '{"tool_input":{"file_path":"sail/test_helper.py"}}' "$WORKDIR"; then
  hook_rc=0
else
  hook_rc=$?
fi

[ "$hook_rc" -eq 2 ] || fail "hook allowed a source file with a test-like basename outside tests/"

jq . "$SETTINGS_FILE" >/dev/null || fail "$SETTINGS_FILE is not valid JSON"
grep -q 'sail-tdd-guard.sh' "$SETTINGS_FILE" || fail "$SETTINGS_FILE does not reference sail-tdd-guard.sh"

echo "PASS: sail test marker + tdd-guard hook + settings wiring"
