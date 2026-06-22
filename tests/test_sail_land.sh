#!/usr/bin/env bash
# test_sail_land.sh
# Hermetic tests for /sail's "land" completion stage — the CLOSING git bookend (#59).
#
# `sail land` is the PURE, network-free emit half of the closing bookend: it reads a
# run-dir's review.json (whose plan_verification block carries the AC verdicts) + decision-log
# and emits (a) the closing-comment markdown (AC verdicts
# + finding dispositions + gate counts, reusing the already-produced review evidence) and
# (b) the merge-commit message containing a `Closes #<issue>` keyword that auto-closes the
# issue when the merge lands on the default branch. The git/gh ORCHESTRATION (merge --no-ff,
# post comment, prune branch, --pr) is documented in the skill markdown, NOT unit-tested
# here (matches /ship §6e-post and AC#8).
#
# Hermetic per the domain rule: every assertion runs against a THROWAWAY temp run-dir seeded
# with hand-written fixture JSON — never against the live repo, working tree, git, or gh. No
# real merge / close / push / network is performed anywhere in this suite. The fixture issue
# number is a non-existent 4242 so no emitted string can reference a real issue.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

TMP_ROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); }

ISSUE=4242

# seed_run <dir> <plan.json contents> <review.json contents|__OMIT__>
seed_run() {
  local dir="$1" plan="$2" review="$3"
  mkdir -p "$dir"
  printf '%s' "$plan" > "$dir/plan.json"
  if [ "$review" != "__OMIT__" ]; then
    printf '%s' "$review" > "$dir/review.json"
  fi
}

# Fixtures -------------------------------------------------------------------
PLAN_OK='{"status":"completed","acceptance_criteria":["AC one","AC two"],"approach":"x"}'

REVIEW_CLEAN='{"status":"completed","parse_ok":true,"rc":0,
"counts":{"CRITICAL":0,"HIGH":0,"MEDIUM":0,"LOW":0},"findings":[],
"plan_verification":{"status":"verified","acceptance_criteria":[
{"criterion":"AC one","status":"met","evidence":"did the thing"},
{"criterion":"AC two","status":"met","evidence":"did the other thing"}]}}'

REVIEW_UNMET='{"status":"completed","parse_ok":true,"rc":1,
"counts":{"CRITICAL":0,"HIGH":0,"MEDIUM":1,"LOW":0},
"findings":[{"id":"lens1-abc","severity":"MEDIUM","category":"scope","file":"sail/x.py","line":10,"issue":"a gap"}],
"plan_verification":{"status":"verified","acceptance_criteria":[
{"criterion":"AC one","status":"unmet","evidence":"missing guard"},
{"criterion":"AC two","status":"unknown","evidence":""}]}}'

# ---------------------------------------------------------------------------
# 1. Clean run: all ACs met, no findings → comment lists every criterion met,
#    includes gate results, commit message contains `Closes #<issue>`.
# ---------------------------------------------------------------------------
RD="$TMP_ROOT/clean"
seed_run "$RD" "$PLAN_OK" "$REVIEW_CLEAN"
python3 -m sail land --run-dir "$RD" --issue "$ISSUE" --title "feat(sail): land stage" >/dev/null \
  || fail "sail land rc=0 on a clean run"; ok
[ -f "$RD/land-comment.md" ]    || fail "clean: land-comment.md emitted"; ok
[ -f "$RD/land-commit-msg.txt" ] || fail "clean: land-commit-msg.txt emitted"; ok

# Every criterion rendered as met (both ACs present, both marked met).
grep -qF "AC one" "$RD/land-comment.md" || fail "clean: comment names AC one"; ok
grep -qF "AC two" "$RD/land-comment.md" || fail "clean: comment names AC two"; ok
# No unmet/unknown markers leak into an all-met comment.
grep -qiE "unmet|unknown" "$RD/land-comment.md" && fail "clean: all-met comment must not show unmet/unknown"; ok
# Gate results present — assert the RENDERED counts, not just the static header (a header-only
# check would survive a mutation that broke _render_gates).
grep -qF "CRITICAL: 0" "$RD/land-comment.md" || fail "clean: comment renders gate count CRITICAL: 0"; ok
grep -qF "LOW: 0" "$RD/land-comment.md" || fail "clean: comment renders gate count LOW: 0"; ok
# Commit message has the auto-close keyword for the right issue.
grep -qF "Closes #$ISSUE" "$RD/land-commit-msg.txt" || fail "clean: commit msg contains Closes #$ISSUE"; ok
# Title is carried into the merge subject.
grep -qF "feat(sail): land stage" "$RD/land-commit-msg.txt" || fail "clean: commit msg carries title"; ok

# ---------------------------------------------------------------------------
# 2. Unmet-AC run: the comment renders unmet/unknown explicitly (not dropped).
# ---------------------------------------------------------------------------
RD="$TMP_ROOT/unmet"
seed_run "$RD" "$PLAN_OK" "$REVIEW_UNMET"
python3 -m sail land --run-dir "$RD" --issue "$ISSUE" --title "feat: x" >/dev/null \
  || fail "sail land rc=0 on an unmet-AC run"; ok
grep -qiE "unmet" "$RD/land-comment.md"   || fail "unmet: comment shows the unmet criterion"; ok
grep -qiE "unknown" "$RD/land-comment.md" || fail "unmet: comment shows the unknown criterion"; ok
# The finding is surfaced.
grep -qF "a gap" "$RD/land-comment.md" || fail "unmet: comment surfaces the finding"; ok
# Gate counts are the ACTUAL rendered values from this review (MEDIUM:1), not the header.
grep -qF "MEDIUM: 1" "$RD/land-comment.md" || fail "unmet: comment renders the real gate count MEDIUM: 1"; ok

# ---------------------------------------------------------------------------
# 3. Missing review.json: graceful degraded comment + commit msg still has Closes.
# ---------------------------------------------------------------------------
RD="$TMP_ROOT/missing"
seed_run "$RD" "$PLAN_OK" "__OMIT__"
python3 -m sail land --run-dir "$RD" --issue "$ISSUE" --title "feat: x" >/dev/null \
  || fail "sail land rc=0 when review.json is missing"; ok
grep -qiE "unavailable|missing" "$RD/land-comment.md" || fail "missing: comment notes review evidence unavailable"; ok
grep -qF "Closes #$ISSUE" "$RD/land-commit-msg.txt" || fail "missing: commit msg still contains Closes #$ISSUE"; ok

# ---------------------------------------------------------------------------
# 4. Malformed review.json: engine does not crash; degraded-but-valid output.
# ---------------------------------------------------------------------------
RD="$TMP_ROOT/malformed"
seed_run "$RD" "$PLAN_OK" '{"status":"completed", this is not valid json'
python3 -m sail land --run-dir "$RD" --issue "$ISSUE" --title "feat: x" >/dev/null \
  || fail "sail land rc=0 (no crash) on malformed review.json"; ok
grep -qiE "unavailable|malformed" "$RD/land-comment.md" || fail "malformed: comment notes degraded evidence"; ok
grep -qF "Closes #$ISSUE" "$RD/land-commit-msg.txt" || fail "malformed: commit msg still contains Closes #$ISSUE"; ok

# ---------------------------------------------------------------------------
# 5. Issue-number propagation: emitted Closes number matches --issue exactly.
# ---------------------------------------------------------------------------
RD="$TMP_ROOT/prop"
seed_run "$RD" "$PLAN_OK" "$REVIEW_CLEAN"
python3 -m sail land --run-dir "$RD" --issue 777 --title "feat: x" >/dev/null
grep -qF "Closes #777" "$RD/land-commit-msg.txt" || fail "prop: Closes uses the --issue value"; ok
grep -qF "Closes #$ISSUE" "$RD/land-commit-msg.txt" && fail "prop: must not leak a different issue number"; ok

# ---------------------------------------------------------------------------
# 6. Non-numeric / empty issue → fail closed (rc=2), no shell-injection surface.
# ---------------------------------------------------------------------------
RD="$TMP_ROOT/badissue"
seed_run "$RD" "$PLAN_OK" "$REVIEW_CLEAN"
if python3 -m sail land --run-dir "$RD" --issue "1; rm -rf /" --title x >/dev/null 2>&1; then
  fail "non-numeric --issue must fail closed (rc!=0)"
fi
ok
if python3 -m sail land --run-dir "$RD" --issue "" --title x >/dev/null 2>&1; then
  fail "empty --issue must fail closed (rc!=0)"
fi
ok

# ---------------------------------------------------------------------------
# 7. --pr mode: emits a PR body that carries the Closes keyword + the evidence.
# ---------------------------------------------------------------------------
RD="$TMP_ROOT/pr"
seed_run "$RD" "$PLAN_OK" "$REVIEW_CLEAN"
python3 -m sail land --run-dir "$RD" --issue "$ISSUE" --title "feat: x" --pr >/dev/null \
  || fail "sail land --pr rc=0"; ok
[ -f "$RD/land-pr-body.md" ] || fail "--pr: land-pr-body.md emitted"; ok
grep -qF "Closes #$ISSUE" "$RD/land-pr-body.md" || fail "--pr: PR body contains Closes #$ISSUE"; ok
grep -qF "AC one" "$RD/land-pr-body.md" || fail "--pr: PR body carries the review evidence"; ok

# 7b. SAFETY (domain §5a, --pr path): a closing keyword inside DERIVED review evidence (a
#     finding's prose, an AC criterion/evidence) must be defused — GitHub honors closing
#     keywords in PR descriptions, so a stray "fixes #50" in evidence would auto-close #50.
RD="$TMP_ROOT/pr_evidence"
EVIL_REVIEW='{"status":"completed","parse_ok":true,"rc":0,
"counts":{"CRITICAL":0,"HIGH":0,"MEDIUM":0,"LOW":1},
"findings":[{"id":"x","severity":"LOW","category":"x","file":"a.py","line":1,"issue":"a title containing fixes #50 is a hazard"}],
"plan_verification":{"status":"verified","acceptance_criteria":[
{"criterion":"closes #51 must not fire","status":"met","evidence":"resolves #52 either"}]}}'
seed_run "$RD" "$PLAN_OK" "$EVIL_REVIEW"
python3 -m sail land --run-dir "$RD" --issue "$ISSUE" --title "feat: x" --pr >/dev/null
# The only #<n> that may survive in the PR body is our own intended close (#4242).
if grep -qE '#(50|51|52)\b' "$RD/land-pr-body.md"; then
  fail "--pr: stray closing-keyword issue refs in evidence must be defused (no #50/#51/#52)"
fi
ok
grep -qF "Closes #$ISSUE" "$RD/land-pr-body.md" || fail "--pr: our own Closes #$ISSUE survives the defuse"; ok

# ---------------------------------------------------------------------------
# 8. Finding dispositions: a decision-log resolution renders in the comment.
# ---------------------------------------------------------------------------
RD="$TMP_ROOT/disp"
seed_run "$RD" "$PLAN_OK" "$REVIEW_UNMET"
python3 - "$RD" <<'PY'
import sys
from sail.decisionlog import DecisionLog
DecisionLog(sys.argv[1]).finding_resolution("lens1-abc", "addressed", "added the guard")
PY
python3 -m sail land --run-dir "$RD" --issue "$ISSUE" --title "feat: x" >/dev/null
grep -qiE "addressed" "$RD/land-comment.md" || fail "disp: comment renders the finding disposition"; ok
grep -qF "added the guard" "$RD/land-comment.md" || fail "disp: comment renders the disposition rationale"; ok

# ---------------------------------------------------------------------------
# 9. Pure-function contract — land_commit_message (no run-dir/IO).
# ---------------------------------------------------------------------------
python3 - <<'PY' || exit 1
from sail.lifecycle import land_commit_message
m = land_commit_message("feat(sail): land stage", "4242")
assert "Closes #4242" in m, m
# Subject preserves the established `merge: <prefix> #<issue> — <title>` convention.
assert m.splitlines()[0] == "merge: sail #4242 — feat(sail): land stage", m
assert land_commit_message("t", "4242", "surf").splitlines()[0] == "merge: surf #4242 — t"
# Closes keyword on its own line (GitHub auto-close convention).
assert any(l.strip() == "Closes #4242" for l in m.splitlines()), m
# subject carries the title; de-dupes a trailing (#N).
m2 = land_commit_message("feat: x (#4242)", "4242")
assert m2.count("(#4242)") == 0, "trailing (#N) should be stripped from the subject: %r" % m2
# SAFETY (domain §5a): a closing keyword + issue ref in the AUTHOR's title must be defused so
# only our own `Closes #4242` line auto-closes — a stray "fixes #50" must NOT survive verbatim.
for kw in ("fixes #50", "Closes #50", "resolves #50", "Fixed: #50"):
    m3 = land_commit_message("feat: thing that %s on merge" % kw, "4242")
    assert "#50" not in m3, "closing-keyword issue ref must be defused: %r -> %r" % (kw, m3)
    assert "50" in m3, "the issue number should survive as plain text: %r" % m3
    assert "Closes #4242" in m3, "our own close keyword must remain: %r" % m3
# A bare cross-reference (no closing keyword) is harmless and left intact.
m4 = land_commit_message("feat: handle #50 edge case", "4242")
assert "#50" in m4, "a bare #50 cross-ref (no closing keyword) is not a close hazard: %r" % m4
# non-numeric issue fails closed.
for bad in ("", "abc", "1; rm -rf /"):
    try:
        land_commit_message("t", bad)
        raise SystemExit("land_commit_message must reject non-numeric issue %r" % bad)
    except ValueError:
        pass
print("pure-fn ok")
PY
ok

# ---------------------------------------------------------------------------
# 10. Doc contract — sail.md documents the closing land terminus (human-gated),
#     surf.md calls the same shared land logic, and both keep the Closes keyword
#     as a SAFE `<issue>` placeholder (never a literal real issue number).
# ---------------------------------------------------------------------------
SAILMD="$REPO_ROOT/commands/sail.md"
SURFMD="$REPO_ROOT/commands/surf.md"
grep -qiE 'sail land' "$SAILMD" || fail "sail.md documents the sail land terminus"; ok
grep -qiE 'closing bookend|land' "$SAILMD" || fail "sail.md names the closing bookend"; ok
grep -qiE 'pause|approval|human-gated|approve' "$SAILMD" || fail "sail.md: terminus is human-gated (pauses for approval)"; ok
grep -qF 'Closes #<issue>' "$SAILMD" || fail "sail.md uses the safe Closes #<issue> placeholder"; ok
grep -qiE 'sail land' "$SURFMD" || fail "surf.md calls the shared sail land logic"; ok
# Safety: no literal `Closes #<number>` may be committed (would auto-close a real issue on merge).
if grep -rEn 'Closes #[0-9]' "$SAILMD" "$SURFMD" "$REPO_ROOT/sail/lifecycle.py" 2>/dev/null; then
  fail "no committed file may contain a literal Closes #<number> (auto-close hazard)"
fi
ok

echo "PASS: sail #59 land completion stage — $PASS assertions"
