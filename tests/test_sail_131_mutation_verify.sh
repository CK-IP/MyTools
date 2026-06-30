#!/usr/bin/env bash
# test_sail_131_mutation_verify.sh — #131: build-side, EXECUTABLE mutation-verification of new
# regression tests (catch vacuous/tautological tests before review). Complements (does not replace)
# the #70 inline LLM test-adequacy probe: this is a deterministic confirmation that reverts the fix
# and proves each new/changed regression test actually FAILS without it.
#
# Repo is SHELL-TEST-ONLY (no pytest suite), so the deterministic Python predicates are unit-tested
# INLINE via python3 (the established test_sail_95 pattern), and the end-to-end revert->rerun->restore
# is exercised on throwaway git-repo fixtures.
#
# shellcheck disable=SC2016,SC1091
# SC2016 (single-quoted $(...)): the mkfix/printf bodies are LITERAL fixture-test source — the
#   $(compute) must expand when the GENERATED throwaway test runs, never in this script.
# SC1091 (can't follow source): `. ./lib/source.sh` sources a per-test temp fixture that does not
#   exist at lint time; following it is neither possible nor meaningful.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
unset "${!SAIL_@}" || true   # hermetic: a real shell exports SAIL_* codex knobs — clear them
cd "$REPO_ROOT"
fail() { echo "FAIL: $*"; exit 1; }

jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2]) if d.get(sys.argv[2]) is not None else "")' "$1" "$2"; }
nfind() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("findings",[])))' "$1"; }

# ============================================================================
# Part A — deterministic predicates (pure, hermetic; no git, no LLM)
# ============================================================================

# T1: is_bug_fix_title — conventional-commit fix detector (risk 2: deterministic, no-op on ambiguity)
python3 - <<'PY' || fail "T1: is_bug_fix_title contract"
from sail.mutation_verify import is_bug_fix_title as f
assert f("fix(sail): x") is True
assert f("fix: x") is True
assert f("bugfix: x") is True
assert f("hotfix!: x") is True
assert f("FIX(scope): x") is True            # case-insensitive
assert f("feat(sail): x") is False
assert f("docs: x") is False
assert f("refactor: x") is False
assert f("") is False
assert f(None) is False
assert f("fixes the thing") is False          # not a conventional-commit type prefix
print("T1 ok")
PY
echo "PASS T1: is_bug_fix_title"

# T2: file classification + partition (tests vs source vs docs)
python3 - <<'PY' || fail "T2: partition_changed / is_test_file"
from sail.mutation_verify import is_test_file, is_doc_file, partition_changed
assert is_test_file("tests/test_foo.sh") is True
assert is_test_file("test_foo.py") is True
assert is_test_file("pkg/foo_test.py") is True
assert is_test_file("sail/mutation_verify.py") is False
assert is_doc_file("README.md") is True
assert is_doc_file("docs/x.rst") is True
assert is_doc_file("sail/build.py") is False
tests, sources = partition_changed([
    "tests/test_regress.sh", "lib/source.sh", "README.md", "sail/x.py", "foo_test.py",
])
assert sorted(tests) == ["foo_test.py", "tests/test_regress.sh"], tests
assert sorted(sources) == ["lib/source.sh", "sail/x.py"], sources   # README.md excluded (doc)
print("T2 ok")
PY
echo "PASS T2: partition_changed"

# T3: should_mutation_verify eligibility predicate (the three no-op conditions)
python3 - <<'PY' || fail "T3: should_mutation_verify"
from sail.mutation_verify import should_mutation_verify as g
assert g(True,  ["t"], ["s"]) is True       # bug-fix + test + source -> fire
assert g(False, ["t"], ["s"]) is False      # not a bug-fix -> no-op
assert g(True,  [],    ["s"]) is False       # no new tests -> no-op
assert g(True,  ["t"], [])    is False       # no source to revert -> no-op
print("T3 ok")
PY
echo "PASS T3: should_mutation_verify"

# T4: classify_rc — pytest exit codes 2/3/4/5 are INCONCLUSIVE, not a verdict (risk 3)
python3 - <<'PY' || fail "T4: classify_rc"
from sail.mutation_verify import classify_rc
assert classify_rc(0, "py") == "pass"
assert classify_rc(1, "py") == "fail"
assert classify_rc(2, "py") == "inconclusive"   # collection interrupted
assert classify_rc(3, "py") == "inconclusive"   # internal error
assert classify_rc(4, "py") == "inconclusive"   # usage error
assert classify_rc(5, "py") == "inconclusive"   # no tests collected
assert classify_rc(0, "sh") == "pass"
assert classify_rc(1, "sh") == "fail"
assert classify_rc(2, "sh") == "fail"            # shell: any non-zero is a failure
print("T4 ok")
PY
echo "PASS T4: classify_rc"

# T5: collective_verdict — finding ONLY when NO new test FAILS under revert (risk 1 refinement)
python3 - <<'PY' || fail "T5: collective_verdict"
from sail.mutation_verify import collective_verdict as v
assert v(["fail"]) == "genuine"                  # caught the revert
assert v(["pass"]) == "vacuous"                   # nothing caught it
assert v(["pass", "fail"]) == "genuine"           # a bonus passing test never causes a flag
assert v(["inconclusive"]) == "inconclusive"      # all errored -> no verdict
assert v(["inconclusive", "pass"]) == "vacuous"   # at least one cleanly passed, none failed
assert v([]) == "no-runnable-tests"
print("T5 ok")
PY
echo "PASS T5: collective_verdict"

# ============================================================================
# Part B — end-to-end revert->rerun->restore on git-repo fixtures
# ============================================================================
# mkfix <dir> <test-body> : build a git repo whose BASE commit has a buggy tracked source
# (lib/source.sh: compute()->5) and whose WORKING TREE has the fix (compute()->6) plus a NEW
# untracked regression test tests/test_regress.sh with the given body. Echoes the BASE sha.
mkfix() {
  local d="$1" body="$2"
  mkdir -p "$d/lib" "$d/tests"
  ( cd "$d"
    git init -q; git config user.email t@t; git config user.name t
    printf 'compute() { echo 5; }\n' > lib/source.sh        # BUGGY at base (tracked)
    git add lib/source.sh; git commit -qm base
    printf 'compute() { echo 6; }\n' > lib/source.sh        # THE FIX (tracked modification)
    printf '%s\n' "$body" > tests/test_regress.sh           # NEW regression test (untracked)
    git rev-parse HEAD )
}

# T6: GENUINE regression test — asserts the fixed value; FAILS when source reverted -> no finding.
# The fix lives in the WORKING TREE (uncommitted, as it does at build time), so the source file is
# legitimately ` M` (modified-unstaged) — it is NEVER clean. The correct restore invariant is that
# mutation-verify leaves the tree EXACTLY as it found it (status + content unchanged, and crucially
# the index state un-mutated: it must not `git add` the source), not that the tree is clean.
FIX6="$WORK/fix6"; BASE6="$(mkfix "$FIX6" '. ./lib/source.sh; [ "$(compute)" = 6 ]')"
RD6="$WORK/rd6"
BEFORE6="$(cd "$FIX6" && git status --porcelain)"
python3 -m sail mutation-verify --target "$FIX6" --diff "$BASE6" --run-dir "$RD6" --bug-fix >/dev/null 2>&1 \
  || fail "T6: mutation-verify CLI should exit 0 on a genuine test"
[ "$(jget "$RD6/mutation-verify.json" status)" = completed ] || fail "T6: status should be completed, got '$(jget "$RD6/mutation-verify.json" status)'"
[ "$(jget "$RD6/mutation-verify.json" verdict)" = genuine ] || fail "T6: verdict should be genuine, got '$(jget "$RD6/mutation-verify.json" verdict)'"
[ "$(nfind "$RD6/mutation-verify.json")" = 0 ] || fail "T6: genuine test must produce NO finding"
[ "$(cd "$FIX6" && git status --porcelain)" = "$BEFORE6" ] || fail "T6: tree NOT restored — git status changed (index/working state mutated) after verify"
[ "$(cd "$FIX6" && . ./lib/source.sh; compute)" = 6 ] || fail "T6: source.sh not restored to the fix (compute != 6)"
echo "PASS T6: genuine regression test -> verdict genuine, no finding, tree restored to the fix (unstaged, index un-mutated)"

# T7: VACUOUS test — tautology that passes regardless of the fix -> test-adequacy finding (HIGH)
FIX7="$WORK/fix7"; BASE7="$(mkfix "$FIX7" '. ./lib/source.sh; [ 1 = 1 ]')"   # never depends on compute
RD7="$WORK/rd7"
BEFORE7="$(cd "$FIX7" && git status --porcelain)"
python3 -m sail mutation-verify --target "$FIX7" --diff "$BASE7" --run-dir "$RD7" --bug-fix >/dev/null 2>&1 \
  || fail "T7: mutation-verify CLI should still exit 0 on a vacuous test (finding rides the pipeline, not the rc)"
[ "$(jget "$RD7/mutation-verify.json" verdict)" = vacuous ] || fail "T7: verdict should be vacuous, got '$(jget "$RD7/mutation-verify.json" verdict)'"
[ "$(nfind "$RD7/mutation-verify.json")" = 1 ] || fail "T7: vacuous test must produce exactly one finding"
python3 - "$RD7/mutation-verify.json" <<'PY' || fail "T7: finding shape"
import json,sys
f=json.load(open(sys.argv[1]))["findings"][0]
assert f.get("severity")=="HIGH", f
assert f.get("category")=="test-adequacy", f
assert f.get("lens")=="mutation-verify", f
assert "vacuous" in (f.get("issue","").lower()) or "revert" in (f.get("issue","").lower()), f
print("T7 finding ok")
PY
[ "$(cd "$FIX7" && git status --porcelain)" = "$BEFORE7" ] || fail "T7: tree NOT restored after a vacuous verdict — git status changed"
echo "PASS T7: vacuous test -> HIGH test-adequacy finding, tree restored"

# T8: NON-bug-fix diff (no --bug-fix) -> no-op skip, no revert, no finding
FIX8="$WORK/fix8"; BASE8="$(mkfix "$FIX8" '. ./lib/source.sh; [ 1 = 1 ]')"
RD8="$WORK/rd8"
python3 -m sail mutation-verify --target "$FIX8" --diff "$BASE8" --run-dir "$RD8" >/dev/null 2>&1 \
  || fail "T8: non-bug-fix mutation-verify should exit 0"
[ "$(jget "$RD8/mutation-verify.json" status)" = skipped ] || fail "T8: status should be skipped on non-bug-fix"
[ "$(nfind "$RD8/mutation-verify.json")" = 0 ] || fail "T8: non-bug-fix must produce no finding"
echo "PASS T8: non-bug-fix -> skipped no-op"

# T9: bug-fix but NO new test in the diff -> no-op skip
FIX9="$WORK/fix9"
mkdir -p "$FIX9/lib"; ( cd "$FIX9"; git init -q; git config user.email t@t; git config user.name t
  printf 'compute() { echo 5; }\n' > lib/source.sh; git add lib/source.sh; git commit -qm base
  printf 'compute() { echo 6; }\n' > lib/source.sh )                # fix only, no test added
BASE9="$(cd "$FIX9" && git rev-parse HEAD)"; RD9="$WORK/rd9"
python3 -m sail mutation-verify --target "$FIX9" --diff "$BASE9" --run-dir "$RD9" --bug-fix >/dev/null 2>&1 \
  || fail "T9: code-only bug-fix mutation-verify should exit 0"
[ "$(jget "$RD9/mutation-verify.json" status)" = skipped ] || fail "T9: status should be skipped when no new tests"
echo "PASS T9: bug-fix with no new tests -> skipped no-op"

# T9b: the bug-fix DECISION is a deterministic Python predicate, not an orchestrator judgment call
# (CLAUDE.md infra-placement). The CLI accepts --title and gates internally via is_bug_fix_title, so
# the orchestrator passes the raw issue title and cannot misfire by always passing --bug-fix. A
# "fix:" --title (no --bug-fix flag) must FIRE; a "feat:" --title must NO-OP.
FIX9B="$WORK/fix9b"; BASE9B="$(mkfix "$FIX9B" '. ./lib/source.sh; [ "$(compute)" = 6 ]')"
RD9B="$WORK/rd9b"
python3 -m sail mutation-verify --target "$FIX9B" --diff "$BASE9B" --run-dir "$RD9B" --title "fix(core): off-by-one" >/dev/null 2>&1 \
  || fail "T9b: --title fix: must run (exit 0)"
[ "$(jget "$RD9B/mutation-verify.json" status)" = completed ] || fail "T9b: a 'fix:' --title must FIRE (status completed), got '$(jget "$RD9B/mutation-verify.json" status)'"
FIX9C="$WORK/fix9c"; BASE9C="$(mkfix "$FIX9C" '. ./lib/source.sh; [ "$(compute)" = 6 ]')"
RD9C="$WORK/rd9c"
python3 -m sail mutation-verify --target "$FIX9C" --diff "$BASE9C" --run-dir "$RD9C" --title "feat(core): add thing" >/dev/null 2>&1 \
  || fail "T9c: --title feat: must exit 0 (no-op)"
[ "$(jget "$RD9C/mutation-verify.json" status)" = skipped ] || fail "T9c: a 'feat:' --title must NO-OP (status skipped), got '$(jget "$RD9C/mutation-verify.json" status)'"
echo "PASS T9b/T9c: --title gates the run via the deterministic is_bug_fix_title predicate"

# T10: CRASH-SAFE restore — force a raise after the revert; the try/finally MUST restore the tree
FIX10="$WORK/fix10"; BASE10="$(mkfix "$FIX10" '. ./lib/source.sh; [ "$(compute)" = 6 ]')"
RD10="$WORK/rd10"
BEFORE10="$(cd "$FIX10" && git status --porcelain)"
set +e
SAIL_MUTVERIFY_FORCE_RAISE=after-revert \
  python3 -m sail mutation-verify --target "$FIX10" --diff "$BASE10" --run-dir "$RD10" --bug-fix >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 1 ] || fail "T10: a forced crash must fail closed (rc 1), got $rc"
[ "$(jget "$RD10/mutation-verify.json" status)" = error ] || fail "T10: status should be error on a forced crash"
[ "$(cd "$FIX10" && git status --porcelain)" = "$BEFORE10" ] || fail "T10: CRASH-SAFE restore FAILED — git status changed (tree left mutated after a crash)"
[ "$(cd "$FIX10" && . ./lib/source.sh; compute)" = 6 ] || fail "T10: source not restored to the fix after a crash"
echo "PASS T10: crash after revert -> fail closed, tree fully restored (try/finally)"

# T10b: RESTORE-ROBUST to a NON-HERMETIC test. A new test that itself mutates the tracked source
# under cwd while the fix is reverted must NOT defeat the restore: the tree must come back to the
# exact fix. (A fragile forward `git apply` would re-apply the fix patch ONTO the test's junk,
# leaving a corrupted source; a snapshot-bytes restore is immune.) redteam-3800ffad92be.
FIX10B="$WORK/fix10b"
BASE10B="$(mkfix "$FIX10B" '. ./lib/source.sh; echo "compute() { echo 99; }" >> ./lib/source.sh; [ "$(compute)" = 6 ]')"
RD10B="$WORK/rd10b"
BEFORE10B="$(cd "$FIX10B" && git status --porcelain)"
python3 -m sail mutation-verify --target "$FIX10B" --diff "$BASE10B" --run-dir "$RD10B" --bug-fix >/dev/null 2>&1 \
  || fail "T10b: mutation-verify should exit 0 (the test is genuine — it fails under revert)"
[ "$(jget "$RD10B/mutation-verify.json" verdict)" = genuine ] || fail "T10b: verdict should be genuine"
[ "$(cd "$FIX10B" && git status --porcelain)" = "$BEFORE10B" ] || fail "T10b: tree NOT restored after a non-hermetic test mutated the source"
[ "$(cd "$FIX10B" && . ./lib/source.sh; compute)" = 6 ] || fail "T10b: source NOT cleanly restored to the fix (a non-hermetic test corrupted it through the restore)"
echo "PASS T10b: restore is robust to a non-hermetic test that mutates the tracked source"

# T10c: INDEX-NEUTRAL with a PRE-STAGED source. The fix is `git add`-ed before mutation-verify runs;
# the check must leave the index state EXACTLY as found (it must never `git add` or unstage the
# source). lens1-2096357e51a8 (the AC↔mechanism reconciliation: index preserved by NOT using --index).
FIX10C="$WORK/fix10c"
mkdir -p "$FIX10C/lib" "$FIX10C/tests"
( cd "$FIX10C"; git init -q; git config user.email t@t; git config user.name t
  printf 'compute() { echo 5; }\n' > lib/source.sh; git add lib/source.sh; git commit -qm base
  printf 'compute() { echo 6; }\n' > lib/source.sh; git add lib/source.sh          # FIX, STAGED
  printf '%s\n' '. ./lib/source.sh; [ "$(compute)" = 6 ]' > tests/test_regress.sh )
BASE10C="$(cd "$FIX10C" && git rev-parse HEAD)"; RD10C="$WORK/rd10c"
BEFORE10C="$(cd "$FIX10C" && git status --porcelain)"   # 'M  lib/source.sh' (staged) + '?? tests/'
python3 -m sail mutation-verify --target "$FIX10C" --diff "$BASE10C" --run-dir "$RD10C" --bug-fix >/dev/null 2>&1 \
  || fail "T10c: mutation-verify should exit 0 on a staged-source genuine test"
[ "$(jget "$RD10C/mutation-verify.json" verdict)" = genuine ] || fail "T10c: verdict should be genuine"
[ "$(cd "$FIX10C" && git status --porcelain)" = "$BEFORE10C" ] || fail "T10c: index state mutated — staged source no longer matches before (the run must not git-add/unstage)"
echo "PASS T10c: pre-staged source -> index state preserved (before == after)"

# ============================================================================
# Part C — review.json union (rides the existing finding pipeline)
# ============================================================================

# T11: merge_mutation_verify_findings unions the build-side finding into review's findings list,
# tagged lens='mutation-verify' with a stable id, ONLY when the artifact's diff_hash matches.
python3 - "$WORK" <<'PY' || fail "T11: merge_mutation_verify_findings"
import json, os, sys
from sail.review import merge_mutation_verify_findings
rd = os.path.join(sys.argv[1], "rd11"); os.makedirs(rd, exist_ok=True)
art = {"status":"completed","verdict":"vacuous","diff_hash":"DH",
       "findings":[{"severity":"HIGH","category":"test-adequacy","file":"tests/t.sh",
                    "issue":"passes with the fix reverted (vacuous)","recommendation":"strengthen"}]}
json.dump(art, open(os.path.join(rd,"mutation-verify.json"),"w"))
base=[{"id":"lens1-abc","severity":"LOW","issue":"x"}]
merged = merge_mutation_verify_findings(list(base), rd, "DH")
mv=[f for f in merged if f.get("lens")=="mutation-verify"]
assert len(mv)==1, merged
assert mv[0].get("id"), "mutation-verify finding must get a stable id"
assert mv[0]["severity"]=="HIGH"
# stale diff_hash -> NOT unioned (freshness guard)
merged2 = merge_mutation_verify_findings(list(base), rd, "OTHER")
assert not any(f.get("lens")=="mutation-verify" for f in merged2), "stale diff_hash must not union"
# missing artifact -> returns findings unchanged (fail-safe)
empty=os.path.join(sys.argv[1],"rd11empty"); os.makedirs(empty, exist_ok=True)
assert merge_mutation_verify_findings(list(base), empty, "DH")==base
print("T11 ok")
PY
echo "PASS T11: merge_mutation_verify_findings unions tagged finding (freshness-gated, fail-safe)"

# T12: run_review actually CALLS the union (structural pin — hermetic, no backend needed)
grep -q 'merge_mutation_verify_findings' "$REPO_ROOT/sail/review.py" \
  || fail "T12: review.py must invoke merge_mutation_verify_findings in run_review"
grep -A40 'def run_review' "$REPO_ROOT/sail/review.py" | grep -q 'merge_mutation_verify_findings' \
  || python3 - <<'PY' || fail "T12: union not wired into run_review"
import re
src=open("sail/review.py").read()
# crude: union call must appear before review.json is written
i=src.index("def run_review"); j=src.index("merge_mutation_verify_findings", i); k=src.index("severity_counts(findings)", i)
assert i < j < k, "union must run before counts/write"
print("T12 structural ok")
PY
echo "PASS T12: mutation-verify union wired into run_review before counts"

# T13: END-TO-END union — run_mutation_verify WRITES the artifact, then the SAME diff_hash it wrote
# is what merge_mutation_verify_findings keys on. T11 hand-builds the artifact with a literal hash,
# so it cannot catch a `diff_hash` key/format drift between the writer and the reader; T13 closes
# that gap by exercising the real writer→reader path (lens1-00f443bbbefb).
FIX13="$WORK/fix13"; BASE13="$(mkfix "$FIX13" '. ./lib/source.sh; [ 1 = 1 ]')"   # vacuous -> a finding
RD13="$WORK/rd13"
python3 -m sail mutation-verify --target "$FIX13" --diff "$BASE13" --run-dir "$RD13" --bug-fix >/dev/null 2>&1 \
  || fail "T13: mutation-verify should exit 0 on a vacuous fixture"
python3 - "$RD13" "$FIX13" "$BASE13" <<'PY' || fail "T13: end-to-end writer->reader union"
import json, subprocess, sys
from sail.review import merge_mutation_verify_findings
rd, tgt, base = sys.argv[1], sys.argv[2], sys.argv[3]
art = json.load(open(rd + "/mutation-verify.json"))
assert art["verdict"] == "vacuous" and len(art["findings"]) == 1, art
# Recompute the diff_hash exactly as run_review does (git diff <base> on the target).
diff = subprocess.run(["git", "-C", tgt, "diff", base], capture_output=True, text=True).stdout
import hashlib
dh = hashlib.sha256(diff.encode("utf-8")).hexdigest()
assert dh == art["diff_hash"], f"writer/reader diff_hash drift: {dh} != {art['diff_hash']}"
merged = merge_mutation_verify_findings([{"id": "lens1-x", "severity": "LOW"}], rd, dh)
assert any(f.get("lens") == "mutation-verify" for f in merged), "vacuous finding must survive the real writer->reader union"
print("T13 ok")
PY
echo "PASS T13: end-to-end run_mutation_verify -> merge via real diff_hash (catches key drift)"

# ============================================================================
# Part D — docs (#95-style definition-of-done)
# ============================================================================
SAILMD="$REPO_ROOT/commands/sail.md"
pin() { grep -qiE "$1" "$SAILMD" || fail "Part D: sail.md missing pin ($2): $1"; }
pin 'mutation.verify|mutation-verify' "Stage-2 mutation-verify documented"
pin 'vacuous|tautolog' "vacuous-test rationale documented"
pin '#70' "complements (not replaces) the #70 probe"
grep -q 'mutation.verify\|mutation-verify' "$REPO_ROOT/sail/README.md" || fail "Part D: sail/README.md missing mutation-verify docs"
echo "PASS Part D: sail.md + README.md document the mutation-verify step"

echo "ALL PASS: sail #131 mutation-verify contract verified"
