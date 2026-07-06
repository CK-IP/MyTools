#!/usr/bin/env bash
# test_sail_tdd_guard.sh
# Issue #137: sail-tdd-guard exempts comment/docstring/blank-line-only .py edits.
# Pins the pure decision (`sail/tdd_guard.py::is_non_behavioral`) plus the hook
# wiring: a non-behavioral Edit passes with NO .sail/last-test-failed marker,
# while any executable-line change (or anything unprovable) still fails closed
# to the existing marker requirement (exit 2).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Hermetic (.ship/domain.md #102): a real shell exports SAIL_* knobs; clear them.
unset "${!SAIL_@}"
TMP_ROOT="$(mktemp -d)"
WORKDIR="$TMP_ROOT/work"
HOOK_SCRIPT="$REPO_ROOT/hooks/sail-tdd-guard.sh"
HOOK_LOG="$TMP_ROOT/hook.log"

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() {
  echo "FAIL: $1" >&2
  if [ -s "$HOOK_LOG" ]; then
    echo "---- hook output ----" >&2
    sed 's/^/  /' "$HOOK_LOG" >&2 || true
    echo "---------------------" >&2
  fi
  FAIL=$((FAIL + 1))
}

mkdir -p "$WORKDIR"
# The hook consults the helper via the sail package importable from its $PWD
# (in real use $PWD is the CK-Skills repo/worktree root, which carries sail/).
ln -s "$REPO_ROOT/sail" "$WORKDIR/sail"

# Build the hook Edit JSON safely (jq handles all quoting/newlines).
hook_json() {
  # $1=file_path $2=old_string $3=new_string [$4=replace_all]
  jq -n --arg fp "$1" --arg old "$2" --arg new "$3" --argjson ra "${4:-false}" \
    '{tool_input: {file_path: $fp, old_string: $old, new_string: $new, replace_all: $ra}}'
}

run_hook() {
  # stdin JSON in $1; cwd in $2 (default WORKDIR). Returns the hook's rc.
  local input="$1"
  local cwd="${2:-$WORKDIR}"
  (
    cd "$cwd"
    printf '%s' "$input" | bash "$HOOK_SCRIPT"
  ) >"$HOOK_LOG" 2>&1
}

FIXTURE="$WORKDIR/mod.py"
write_fixture() {
  cat > "$FIXTURE" <<'PYEOF'
"""Module docstring."""


def add(a, b):
    """Return the sum."""
    # add the two operands
    total = a + b
    return total


class Greeter:
    """Greets."""

    def greet(self):
        """Say hi."""
        return "hi"
PYEOF
}

# ---------------------------------------------------------------------------
# (1) Pure helper: is_non_behavioral verdicts
# ---------------------------------------------------------------------------
helper_check() {
  # $1=old_src $2=new_src ; prints True/False. cd first: a stdin script resolves
  # `sail` from cwd BEFORE PYTHONPATH, so a caller's cwd must not shadow it.
  (
    cd "$REPO_ROOT"
    PYTHONPATH="$REPO_ROOT${PYTHONPATH:+:$PYTHONPATH}" python3 - "$1" "$2" <<'PYEOF'
import sys
from sail.tdd_guard import is_non_behavioral
print(is_non_behavioral(sys.argv[1], sys.argv[2]))
PYEOF
  )
}

guard_cli() {
  # $1=JSON payload for sail.tdd_guard stdin (same cwd pinning as helper_check)
  local input="$1"
  (
    cd "$REPO_ROOT"
    PYTHONPATH="$REPO_ROOT${PYTHONPATH:+:$PYTHONPATH}" python3 -m sail.tdd_guard <<<"$input"
  )
}

if [ "$(helper_check 'x = 1  # old note' 'x = 1  # new note')" = "True" ]; then
  pass "is_non_behavioral: comment-only change is non-behavioral"
else
  fail "is_non_behavioral: comment-only change is non-behavioral"
fi

if [ "$(helper_check '"""Old module doc."""
def f():
    """old"""
    return 1' '"""New module doc."""
def f():
    """new"""
    return 1')" = "True" ]; then
  pass "is_non_behavioral: module+function docstring-only change is non-behavioral"
else
  fail "is_non_behavioral: module+function docstring-only change is non-behavioral"
fi

if [ "$(helper_check 'class C:
    """old"""
    async def g(self):
        """old g"""
        return 2' 'class C:
    """new"""
    async def g(self):
        """new g"""
        return 2')" = "True" ]; then
  pass "is_non_behavioral: class+async-def docstring-only change is non-behavioral"
else
  fail "is_non_behavioral: class+async-def docstring-only change is non-behavioral"
fi

if [ "$(helper_check 'x = 1
y = 2' 'x = 1


y = 2')" = "True" ]; then
  pass "is_non_behavioral: blank-line-only change is non-behavioral"
else
  fail "is_non_behavioral: blank-line-only change is non-behavioral"
fi

if [ "$(helper_check 'x = 1' 'x = 2')" = "False" ]; then
  pass "is_non_behavioral: executable-line change is behavioral"
else
  fail "is_non_behavioral: executable-line change is behavioral"
fi

if [ "$(helper_check 'msg = "old error"' 'msg = "new error"')" = "False" ]; then
  pass "is_non_behavioral: non-docstring string-literal change is behavioral"
else
  fail "is_non_behavioral: non-docstring string-literal change is behavioral"
fi

if [ "$(helper_check 'x = 1' 'x = = 1')" = "False" ]; then
  pass "is_non_behavioral: SyntaxError on either side fails safe (False)"
else
  fail "is_non_behavioral: SyntaxError on either side fails safe (False)"
fi

# Doctests are executable tests living inside docstrings (pytest --doctest-modules):
# an edit touching a doctest-carrying docstring is behavioral, never exempt.
if [ "$(helper_check 'def f():
    """Doubles.

    >>> f()
    1
    """
    return 1' 'def f():
    """Doubles.

    >>> f()
    2
    """
    return 1')" = "False" ]; then
  pass "is_non_behavioral: doctest-output change inside a docstring is behavioral"
else
  fail "is_non_behavioral: doctest-output change inside a docstring is behavioral"
fi

if [ "$(helper_check 'def f():
    """Old prose."""
    return 1' 'def f():
    """New prose.

    >>> f()
    1
    """
    return 1')" = "False" ]; then
  pass "is_non_behavioral: adding a doctest to a docstring is behavioral"
else
  fail "is_non_behavioral: adding a doctest to a docstring is behavioral"
fi

write_fixture

if guard_cli "$(hook_json "$WORKDIR/mod.py" '# add the two operands' '# sum the two operands')"; then
  pass "guard CLI: comment-only edit exits 0"
else
  fail "guard CLI: comment-only edit exits 0"
fi

if guard_cli "$(hook_json "$WORKDIR/mod.py" 'x = 1' 'x = 2')"; then
  fail "guard CLI: executable-line edit should exit non-zero"
else
  pass "guard CLI: executable-line edit exits non-zero"
fi

# ---------------------------------------------------------------------------
# (2) Hook wiring: non-behavioral Edits pass WITHOUT the marker
# ---------------------------------------------------------------------------
write_fixture
rm -f "$WORKDIR/.sail/last-test-failed"

if run_hook "$(hook_json "$FIXTURE" '# add the two operands' '# sum the two operands')"; then
  pass "hook: comment-only edit exits 0 with no failing-test marker"
else
  fail "hook: comment-only edit exits 0 with no failing-test marker"
fi

if run_hook "$(hook_json "$FIXTURE" '"""Return the sum."""' '"""Return the arithmetic sum."""')"; then
  pass "hook: docstring-only edit exits 0 with no failing-test marker"
else
  fail "hook: docstring-only edit exits 0 with no failing-test marker"
fi

if run_hook "$(hook_json "$FIXTURE" 'total = a + b
    return total' 'total = a + b

    return total')"; then
  pass "hook: blank-line-only edit exits 0 with no failing-test marker"
else
  fail "hook: blank-line-only edit exits 0 with no failing-test marker"
fi

# replace_all on a repeated comment-only target
cat > "$FIXTURE" <<'PYEOF'
x = 1  # note
y = 2  # note
PYEOF
if run_hook "$(hook_json "$FIXTURE" '# note' '# remark' true)"; then
  pass "hook: replace_all comment-only edit exits 0"
else
  fail "hook: replace_all comment-only edit exits 0"
fi

# Trailing newlines must survive the shell glue: a stripped trailing `\n` lets
# the reconstruction phantom-match an EARLIER occurrence (e.g. inside a comment)
# and misclassify a behavioral edit as comment-only.
cat > "$FIXTURE" <<'PYEOF'
x = 1  # retries = 3 comment
retries = 3
PYEOF
rm -f "$WORKDIR/.sail/last-test-failed"
rc=0
run_hook "$(hook_json "$FIXTURE" $'retries = 3\n' $'retries = 5\n')" || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "hook: behavioral edit with trailing-newline old/new strings still blocks (exit 2)"
else
  fail "hook: behavioral edit with trailing-newline old/new strings still blocks (got rc=$rc, want 2)"
fi

if run_hook "$(hook_json "$FIXTURE" $'# retries = 3 comment\n' $'# retry budget comment\n')"; then
  pass "hook: comment-only edit with trailing-newline strings exits 0"
else
  fail "hook: comment-only edit with trailing-newline strings exits 0"
fi

# ---------------------------------------------------------------------------
# (3) Hook wiring: everything unprovable still fails closed (exit 2)
# ---------------------------------------------------------------------------
write_fixture

expect_block() {
  # $1=label $2=json
  local rc=0
  run_hook "$2" || rc=$?
  if [ "$rc" -eq 2 ]; then
    pass "$1"
  else
    fail "$1 (got rc=$rc, want 2)"
  fi
}

expect_block "hook: executable-line edit still blocks (exit 2) without marker" \
  "$(hook_json "$FIXTURE" 'total = a + b' 'total = a * b')"

expect_block "hook: edit producing a SyntaxError blocks (exit 2)" \
  "$(hook_json "$FIXTURE" 'def add(a, b):' 'def add(a, b:')"

expect_block "hook: old_string not found in on-disk file blocks (exit 2)" \
  "$(hook_json "$FIXTURE" 'this text is not in the file' 'whatever')"

expect_block "hook: missing on-disk file blocks (exit 2)" \
  "$(hook_json "$WORKDIR/nope.py" '# a' '# b')"

# Edit JSON with no old/new strings (e.g. a Write-shaped input) keeps marker semantics
expect_block "hook: .py input without old_string/new_string still requires the marker" \
  "$(jq -n --arg fp "$FIXTURE" '{tool_input: {file_path: $fp}}')"

# Marker present still exempts a behavioral edit (unchanged semantics)
mkdir -p "$WORKDIR/.sail"
echo "failed" > "$WORKDIR/.sail/last-test-failed"
if run_hook "$(hook_json "$FIXTURE" 'total = a + b' 'total = a * b')"; then
  pass "hook: failing-test marker still exempts a behavioral edit"
else
  fail "hook: failing-test marker still exempts a behavioral edit"
fi
rm -f "$WORKDIR/.sail/last-test-failed"

# Doctest-carrying docstring edits stay blocked at the hook level too.
write_fixture
expect_block "hook: doctest-only docstring edit still blocks (exit 2)" \
  "$(hook_json "$FIXTURE" '"""Say hi."""' '"""Say hi.

        >>> Greeter().greet()
        '"'"'hi'"'"'
        """')"

# ---------------------------------------------------------------------------
# (3b) Cross-project quiet: in a repo WITHOUT a sail package the helper must
# fall through to the marker check silently (no Python traceback/module noise
# leaking to stderr — the hook is globally symlinked and fires everywhere).
# ---------------------------------------------------------------------------
NOSAIL_DIR="$TMP_ROOT/nosail"
mkdir -p "$NOSAIL_DIR"
cat > "$NOSAIL_DIR/other.py" <<'PYEOF'
x = 1  # note
PYEOF
rc=0
run_hook "$(hook_json "$NOSAIL_DIR/other.py" '# note' '# remark')" "$NOSAIL_DIR" || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "hook: no-sail project falls through to the marker requirement (exit 2)"
else
  fail "hook: no-sail project falls through to the marker requirement (got rc=$rc, want 2)"
fi
if grep -Eq 'ModuleNotFoundError|Traceback' "$HOOK_LOG"; then
  fail "hook: no-sail project leaks Python import noise to stderr"
else
  pass "hook: no-sail project leaks no Python import noise to stderr"
fi

# ---------------------------------------------------------------------------
# (4) Pre-existing exemptions unchanged
# ---------------------------------------------------------------------------
if run_hook "$(hook_json "$WORKDIR/notes.md" 'a' 'b')"; then
  pass "hook: non-.py path stays exempt"
else
  fail "hook: non-.py path stays exempt"
fi

mkdir -p "$WORKDIR/tests"
if run_hook "$(hook_json "$WORKDIR/tests/test_x.py" 'a' 'b')"; then
  pass "hook: tests/ path stays exempt"
else
  fail "hook: tests/ path stays exempt"
fi

# Guard hygiene: hook keeps set -euo pipefail
if head -5 "$HOOK_SCRIPT" | grep -q 'set -euo pipefail'; then
  pass "hook: retains set -euo pipefail"
else
  fail "hook: retains set -euo pipefail"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
