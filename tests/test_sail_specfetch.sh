#!/usr/bin/env bash
# test_sail_specfetch.sh — issue #60: `sail spec` assembles the FULL issue (body + comments)
# from `gh issue view --json title,body,comments`, so /sail's plan stage (and is_plan_risky)
# never sees a comments-only or body-only spec. Hermetic; no network, no real gh.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
cd "$REPO_ROOT"
# Hermetic (.ship/domain.md #102): a real shell exports SAIL_* codex knobs (settings.json);
# clear them so each subtest controls its own backend (subtests set theirs via command prefix).
unset "${!SAIL_@}"

fail() { echo "FAIL: $*"; exit 1; }

# --- 1. Assembles BOTH body and comments (the core guard: body is never dropped) ----------
JSON='{"title":"TITLE_MARK","body":"BODY_MARK reconcile the tool list","comments":[{"author":{"login":"alice"},"body":"COMMENT_MARK run ./install.sh"}]}'
SPEC="$(printf '%s' "$JSON" | python3 -m sail spec)" || fail "sail spec exited non-zero on valid JSON"
case "$SPEC" in *TITLE_MARK*) ;; *) fail "assembled spec missing the title";; esac
case "$SPEC" in *BODY_MARK*) ;; *) fail "assembled spec missing the BODY (the #60 regression)";; esac
case "$SPEC" in *COMMENT_MARK*) ;; *) fail "assembled spec missing the comments";; esac
echo "ok: assembled spec contains title + body + comments"

# --- 2. Body is present even when there are NO comments ------------------------------------
JSON_NOCOMMENTS='{"title":"T","body":"BODY_ONLY_MARK","comments":[]}'
SPEC2="$(printf '%s' "$JSON_NOCOMMENTS" | python3 -m sail spec)" || fail "sail spec exited non-zero with empty comments"
case "$SPEC2" in *BODY_ONLY_MARK*) ;; *) fail "assembled spec dropped body when comments empty";; esac
echo "ok: body survives when comments are empty"

# --- 3. Fail closed: empty stdin (e.g. upstream gh failed) -> exit 1 -----------------------
if printf '' | python3 -m sail spec >/dev/null 2>&1; then
  fail "sail spec should exit non-zero on empty input (fail closed)"
fi
echo "ok: fail closed on empty input"

# --- 4. Fail closed: invalid JSON -> exit 1 -----------------------------------------------
if printf 'not json' | python3 -m sail spec >/dev/null 2>&1; then
  fail "sail spec should exit non-zero on invalid JSON (fail closed)"
fi
echo "ok: fail closed on invalid JSON"

# --- 5a. Empty body but substantive comments -> SUCCEEDS (the #60 case: signals in comments) -
JSON_THINBODY='{"title":"T","body":"","comments":[{"author":{"login":"a"},"body":"THINBODY_COMMENT_MARK"}]}'
SPEC5="$(printf '%s' "$JSON_THINBODY" | python3 -m sail spec)" || fail "sail spec should NOT abort on empty body when comments exist (#60)"
case "$SPEC5" in *THINBODY_COMMENT_MARK*) ;; *) fail "assembled spec dropped comments when body empty";; esac
echo "ok: empty body + comments assembles from comments (not aborted)"

# --- 5b. Fail closed: no body AND no comments -> exit 1 (the real empty-issue/gh-fail signal) -
if printf '%s' '{"title":"T","body":"","comments":[]}' | python3 -m sail spec >/dev/null 2>&1; then
  fail "sail spec should exit non-zero when there is no body AND no comments (fail closed)"
fi
echo "ok: fail closed on no body and no comments"

# --- 6. Heuristic guard: the fix is what makes is_plan_risky fire on the #55 shape --------
# remediation signal in COMMENT, reconcile signal in BODY: only the assembled (body+comments)
# spec co-occurs both -> True; comments-only -> False. Pins WHY feeding the full spec matters.
python3 - <<'PY' || fail "is_plan_risky body+comments guard failed"
import sys
from sail.plan import is_plan_risky
from sail.spec import assemble_spec
raw = '{"title":"T","body":"reconcile the tool list across files","comments":[{"author":{"login":"a"},"body":"run ./install.sh to remediate"}]}'
full = assemble_spec(raw)
comments_only = "run ./install.sh to remediate"
assert is_plan_risky(full) is True, "expected risky on assembled body+comments"
assert is_plan_risky(comments_only) is False, "expected NOT risky on comments-only"
PY
echo "ok: is_plan_risky fires on assembled body+comments, not comments-only"

echo "PASS: test_sail_specfetch.sh"
