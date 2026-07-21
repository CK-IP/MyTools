#!/usr/bin/env bash
# test_sail_149_mutation_widen.sh — #149: widen mutation-verify beyond bug-fix diffs + harden
# tree-restore. Pins: (W1) the eligibility predicate no longer requires bug-fix-ness — any diff
# with >=1 new/changed test file AND >=1 non-test source change qualifies; (W2) an end-to-end
# FEATURE diff (feat: title, no --bug-fix) fires; (W3) the wall-clock runtime budget
# (SAIL_MUTVERIFY_BUDGET_SECONDS) skips remaining test re-runs over budget with a logged note and
# never a false red; (W4) a restore failure is LOUD — exit 1 + a message naming the file and
# stating the tree is partially reverted, never a silent partially-reverted tree; (W5) --bug-fix
# flag semantics are preserved.
#
# Repo is SHELL-TEST-ONLY (no pytest suite): deterministic predicates are unit-tested inline via
# python3 and the end-to-end paths run on throwaway git-repo fixtures (the test_sail_131 pattern).
#
# shellcheck disable=SC2016,SC1091
# SC2016: single-quoted $(...) bodies are LITERAL fixture-test source — they must expand when the
#   generated throwaway test runs, never in this script.
# SC1091: `. ./lib/source.sh` sources a per-fixture temp file that does not exist at lint time.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
unset "${!SAIL_@}" || true   # hermetic: a real shell exports SAIL_* knobs — clear them
cd "$REPO_ROOT"
fail() { echo "FAIL: $*"; exit 1; }

jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2]) if d.get(sys.argv[2]) is not None else "")' "$1" "$2"; }
nfind() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("findings",[])))' "$1"; }

# mkfix <dir> <test-body>: throwaway git repo with a committed base (lib/source.sh compute -> 5),
# then a working-tree "change": source fix (compute -> 6) + a NEW shell regression test whose body
# is $2. Prints the base SHA. (Mirrors test_sail_131's fixture.)
mkfix() {
  local dir="$1" body="$2"
  mkdir -p "$dir/lib" "$dir/tests"
  ( cd "$dir"
    git init -q; git config user.email t@t; git config user.name t
    printf 'compute() { echo 5; }\n' > lib/source.sh
    git add lib/source.sh; git commit -qm base
    printf 'compute() { echo 6; }\n' > lib/source.sh
    printf '#!/usr/bin/env bash\nset -e\ncd "$(dirname "$0")/.."\n%s\n' "$body" > tests/test_regress.sh
    chmod +x tests/test_regress.sh
    git rev-parse HEAD )
}

# ============================================================================
# W1 — the eligibility predicate is widened: tests+source qualifies, bug-fix-ness not required
# ============================================================================
python3 - <<'PY' || fail "W1: widened should_mutation_verify contract"
from sail.mutation_verify import should_mutation_verify as g
assert g(["t"], ["s"]) is True     # >=1 test + >=1 source -> fire (no bug-fix requirement)
assert g([], ["s"]) is False       # no new/changed tests -> no-op
assert g(["t"], []) is False       # no source to revert -> no-op
assert g([], []) is False
print("W1 ok")
PY
echo "PASS W1: widened eligibility predicate"

# ============================================================================
# W2 — end-to-end: a FEATURE diff (feat: title, no --bug-fix) with test+source FIRES
# ============================================================================
FIXW2="$WORK/w2"; BASEW2="$(mkfix "$FIXW2" '. ./lib/source.sh; [ "$(compute)" = 6 ]')"
RDW2="$WORK/rdw2"
python3 -m sail mutation-verify --target "$FIXW2" --diff "$BASEW2" --run-dir "$RDW2" --title "feat(core): add thing" >/dev/null 2>&1 \
  || fail "W2: feature-diff mutation-verify should exit 0"
[ "$(jget "$RDW2/mutation-verify.json" status)" = completed ] \
  || fail "W2: a feature diff with test+source must FIRE (status completed), got '$(jget "$RDW2/mutation-verify.json" status)'"
[ "$(jget "$RDW2/mutation-verify.json" verdict)" = genuine ] \
  || fail "W2: the regression test fails under revert -> verdict genuine, got '$(jget "$RDW2/mutation-verify.json" verdict)'"
[ "$(cd "$FIXW2" && git status --porcelain -uall | sort)" = "$(printf ' M lib/source.sh\n?? tests/test_regress.sh' | sort)" ] \
  || fail "W2: tree not restored after feature-diff run"
echo "PASS W2: feature diff (feat: title) fires end-to-end"

# ============================================================================
# W3 — runtime budget: over-budget -> remaining tests skipped + logged note, exit 0, no false red
# ============================================================================
# Two new test files; the first sleeps past the 1s budget, so the second MUST be skipped
# (skip_kind over-budget), the payload marks budget_exceeded, the CLI logs a note, and the rc is 0.
FIXW3="$WORK/w3"; BASEW3="$(mkfix "$FIXW3" 'sleep 2; . ./lib/source.sh; [ "$(compute)" = 6 ]')"
printf '#!/usr/bin/env bash\nset -e\ncd "$(dirname "$0")/.."\n. ./lib/source.sh; [ "$(compute)" = 6 ]\n' > "$FIXW3/tests/test_regress2.sh"
chmod +x "$FIXW3/tests/test_regress2.sh"
RDW3="$WORK/rdw3"
W3ERR="$WORK/w3.stderr"
SAIL_MUTVERIFY_BUDGET_SECONDS=1 python3 -m sail mutation-verify --target "$FIXW3" --diff "$BASEW3" --run-dir "$RDW3" --title "feat: slow" >/dev/null 2>"$W3ERR" \
  || fail "W3: over-budget run must exit 0 (never a false red)"
[ "$(jget "$RDW3/mutation-verify.json" budget_exceeded)" = True ] \
  || fail "W3: payload must record budget_exceeded"
python3 - "$RDW3/mutation-verify.json" <<'PY' || fail "W3: remaining test must be skipped with skip_kind over-budget"
import json, sys
d = json.load(open(sys.argv[1]))
skipped = [t for t in d.get("tests", []) if t.get("skip_kind") == "over-budget"]
assert skipped, f"no over-budget skip recorded: {d.get('tests')}"
PY
grep -qi "budget" "$W3ERR" || fail "W3: CLI must log an over-budget note to stderr"
[ "$(nfind "$RDW3/mutation-verify.json")" = 0 ] || fail "W3: over-budget must not manufacture findings"
echo "PASS W3: runtime budget skips remaining tests with a logged note"

# ============================================================================
# W4 — restore hardening: a failing restore is LOUD (exit 1, names the file, states tree state)
# ============================================================================
FIXW4="$WORK/w4"; BASEW4="$(mkfix "$FIXW4" '. ./lib/source.sh; [ "$(compute)" = 6 ]')"
RDW4="$WORK/rdw4"
W4ERR="$WORK/w4.stderr"
if SAIL_MUTVERIFY_FORCE_RESTORE_FAIL=1 python3 -m sail mutation-verify --target "$FIXW4" --diff "$BASEW4" --run-dir "$RDW4" --title "feat: x" >/dev/null 2>"$W4ERR"; then
  fail "W4: a restore failure MUST exit non-zero"
fi
[ "$(jget "$RDW4/mutation-verify.json" status)" = error ] || fail "W4: payload status must be error on restore failure"
[ "$(jget "$RDW4/mutation-verify.json" tree_state)" = partially-reverted ] \
  || fail "W4: payload must state tree_state partially-reverted"
python3 - "$RDW4/mutation-verify.json" <<'PY' || fail "W4: error reason must name the file and state the tree is partially reverted"
import json, sys
d = json.load(open(sys.argv[1]))
reason = d.get("reason", "")
assert "lib/source.sh" in reason, f"reason must name the un-restored file: {reason!r}"
assert "partially reverted" in reason.lower(), f"reason must state the tree is partially reverted: {reason!r}"
PY
grep -qi "partially reverted" "$W4ERR" || fail "W4: CLI must surface the partial-revert state loudly on stderr"
echo "PASS W4: restore failure is loud — exit 1, names the file, states tree state"

# ============================================================================
# W5 — --bug-fix flag semantics preserved: a bug-fix diff still fires
# ============================================================================
FIXW5="$WORK/w5"; BASEW5="$(mkfix "$FIXW5" '. ./lib/source.sh; [ "$(compute)" = 6 ]')"
RDW5="$WORK/rdw5"
python3 -m sail mutation-verify --target "$FIXW5" --diff "$BASEW5" --run-dir "$RDW5" --bug-fix >/dev/null 2>&1 \
  || fail "W5: --bug-fix run should exit 0"
[ "$(jget "$RDW5/mutation-verify.json" status)" = completed ] || fail "W5: --bug-fix diff must still fire"
echo "PASS W5: --bug-fix semantics preserved"

echo "ALL PASS (test_sail_149_mutation_widen)"
