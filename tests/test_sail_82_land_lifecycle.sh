#!/usr/bin/env bash
# test_sail_82_land_lifecycle.sh
# Hermetic tests for /sail's land "closing bookend" LOCAL git mechanics (#82): the shared
# sail_merge_to_default and sail_prune_merged_branch functions extracted from the prose that
# was duplicated in commands/sail.md + commands/surf.md.
#
# Hermetic per the domain rule: every git assertion runs against a THROWAWAY temp repo seeded
# with just the fixture — never against the live working tree / branch / diff. Mirrors
# test_sail_65_lifecycle.sh.
#
# Scope (matches #82's mandate): only the LOCAL mechanics are tested code — the --no-ff merge
# onto the default branch and the safe `git branch -d` prune. The genuinely-network steps
# (git push, gh comment, ls-remote-guarded remote delete, --pr) stay prose and are NOT here.

set -euo pipefail

# Neutralize inherited SAIL_* knobs (hermeticity rule, #97/#102).
unset "${!SAIL_@}" 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/home/lib/sail-git-lifecycle.sh"

TMP_ROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); }
refute() { local msg="$1"; shift; [ "$1" = "--" ] && shift; if "$@" 2>/dev/null; then fail "$msg"; fi; ok; }
# expect_rc <want> <msg> -- cmd...: assert the command exits with EXACTLY <want> (isolates a
# specific rc, e.g. the rc=2 arg-validation contract, instead of any non-zero).
expect_rc() { local want="$1" msg="$2"; shift 2; [ "$1" = "--" ] && shift; local rc=0; "$@" >/dev/null 2>&1 || rc=$?; [ "$rc" -eq "$want" ] || fail "$msg (wanted rc=$want, got $rc)"; ok; }

[ -f "$LIB" ] || fail "sail-git-lifecycle.sh exists at $LIB"
# shellcheck disable=SC1090
. "$LIB"

command -v sail_merge_to_default >/dev/null 2>&1 || fail "sail_merge_to_default is defined"
command -v sail_prune_merged_branch >/dev/null 2>&1 || fail "sail_prune_merged_branch is defined"

# make_repo <dir> <default-branch>: a throwaway repo with one commit on <default-branch>.
make_repo() {
  local dir="$1" def="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q -b "$def"
  git -C "$dir" config user.email t@t.io
  git -C "$dir" config user.name tester
  echo base > "$dir/base.txt"
  git -C "$dir" add -A && git -C "$dir" commit -qm "base"
}

# --- T1: arg validation returns EXACTLY rc=2 (same idiom as the #65 functions) ---
# Use a VALID repo so the only thing that can fail is the bad arg — this genuinely isolates the
# rc=2 validation contract (a nonexistent-repo rc!=0 would not prove which check fired).
R1="$TMP_ROOT/r1"; make_repo "$R1" main
expect_rc 2 "T1a: merge with empty branch must rc=2" -- sail_merge_to_default "$R1" "" main /dev/null
expect_rc 2 "T1b: merge with empty default must rc=2" -- sail_merge_to_default "$R1" feature "" /dev/null
expect_rc 2 "T1c: merge with unreadable msg_file must rc=2" -- sail_merge_to_default "$R1" feature main "$TMP_ROOT/no-such-msg.txt"
expect_rc 2 "T1d: prune with empty branch must rc=2" -- sail_prune_merged_branch "$R1" ""
echo "PASS T1: arg validation returns rc=2 against a valid repo"

# --- T2: happy-path --no-ff merge onto default, prints the merge SHA, main gets the change ---
R2="$TMP_ROOT/r2"; make_repo "$R2" main
git -C "$R2" checkout -q -b feature
echo feat > "$R2/feat.txt"; git -C "$R2" add -A && git -C "$R2" commit -qm "feat"
git -C "$R2" checkout -q main
MSG2="$TMP_ROOT/msg2.txt"; printf 'land: feature (#82)\n\nCloses #82\n' > "$MSG2"
SHA2="$(sail_merge_to_default "$R2" feature main "$MSG2")" || fail "T2: merge returned non-zero on a clean merge"
printf '%s' "$SHA2" | grep -Eq '^[0-9a-f]{7,40}$' || fail "T2: did not print a merge commit SHA (got: $SHA2)"
[ -f "$R2/feat.txt" ] || fail "T2: main does not contain the merged file"
# --no-ff => the tip is a merge commit with two parents
[ "$(git -C "$R2" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 3 ] || fail "T2: not a --no-ff merge commit (expected 2 parents)"
git -C "$R2" log -1 --pretty=%s | grep -q 'land: feature (#82)' || fail "T2: merge subject not taken from msg file"
echo "PASS T2: --no-ff merge onto default, SHA printed, message from file"

# --- T3: a merge CONFLICT returns non-zero (not swallowed) ---
R3="$TMP_ROOT/r3"; make_repo "$R3" main
echo mainline > "$R3/c.txt"; git -C "$R3" add -A && git -C "$R3" commit -qm "main c"
git -C "$R3" checkout -q -b feat2 HEAD~1 2>/dev/null || git -C "$R3" checkout -q -b feat2
echo feature > "$R3/c.txt"; git -C "$R3" add -A && git -C "$R3" commit -qm "feat c"
git -C "$R3" checkout -q main
MSG3="$TMP_ROOT/msg3.txt"; echo "land conflict" > "$MSG3"
refute "T3: conflicting merge must return non-zero" -- sail_merge_to_default "$R3" feat2 main "$MSG3"
echo "PASS T3: merge conflict surfaces non-zero"

# --- T4: prune uses `git branch -d` — refuses an UNMERGED branch (no data loss) ---
R4="$TMP_ROOT/r4"; make_repo "$R4" main
git -C "$R4" checkout -q -b unmerged
echo wip > "$R4/wip.txt"; git -C "$R4" add -A && git -C "$R4" commit -qm "wip"
git -C "$R4" checkout -q main
refute "T4: prune must refuse an unmerged branch (branch -d, never -D)" -- sail_prune_merged_branch "$R4" unmerged
git -C "$R4" rev-parse --verify unmerged >/dev/null 2>&1 || fail "T4: unmerged branch was destroyed (data loss!)"
echo "PASS T4: prune refuses unmerged branch; branch preserved"

# --- T5: prune succeeds on a MERGED branch ---
R5="$TMP_ROOT/r5"; make_repo "$R5" main
git -C "$R5" checkout -q -b landed
echo landed > "$R5/landed.txt"; git -C "$R5" add -A && git -C "$R5" commit -qm "landed"
git -C "$R5" checkout -q main
MSG5="$TMP_ROOT/msg5.txt"; echo "land done" > "$MSG5"
sail_merge_to_default "$R5" landed main "$MSG5" >/dev/null || fail "T5: merge failed"
sail_prune_merged_branch "$R5" landed || fail "T5: prune of a merged branch should succeed"
refute "T5: merged branch should be gone after prune" -- git -C "$R5" rev-parse --verify landed
echo "PASS T5: prune deletes a merged branch"

# --- T6: PARAMETERIZED — works with a non-'main' default AND a surf/<n>-style branch (no hardcoding) ---
R6="$TMP_ROOT/r6"; make_repo "$R6" trunk
git -C "$R6" checkout -q -b "surf/99"
echo s > "$R6/s.txt"; git -C "$R6" add -A && git -C "$R6" commit -qm "surf work"
git -C "$R6" checkout -q trunk
MSG6="$TMP_ROOT/msg6.txt"; echo "land surf/99 (#99)" > "$MSG6"
SHA6="$(sail_merge_to_default "$R6" "surf/99" trunk "$MSG6")" || fail "T6: merge failed for surf/99 onto trunk (hardcoded branch/default?)"
printf '%s' "$SHA6" | grep -Eq '^[0-9a-f]{7,40}$' || fail "T6: no SHA for parameterized merge"
[ -f "$R6/s.txt" ] || fail "T6: trunk missing the merged surf/99 change"
sail_prune_merged_branch "$R6" "surf/99" || fail "T6: prune failed for surf/99"
echo "PASS T6: parameterized branch + default (surf/99 onto trunk) — no hardcoded sail/<n> or main"

# --- T7: doc-contract — both land docs single-source the mechanics via the shared functions ---
# (#82's whole point: prose must not silently drift back to an inline merge/prune sequence.)
for md in commands/sail.md commands/surf.md; do
  grep -q 'sail_merge_to_default' "$REPO_ROOT/$md" || fail "T7: $md does not reference sail_merge_to_default (drift risk)"
  grep -q 'sail_prune_merged_branch' "$REPO_ROOT/$md" || fail "T7: $md does not reference sail_prune_merged_branch (drift risk)"
  # the inline raw sequence must no longer be the source of truth in the land block
  grep -Eq '^[[:space:]]*git (checkout main && )?merge .* --no-ff' "$REPO_ROOT/$md" \
    && fail "T7: $md still contains a raw inline 'git merge … --no-ff' as source of truth (should call the shared fn)"
done
ok; echo "PASS T7: both sail.md + surf.md single-source the local mechanics via the shared functions"

# --- T8: isolated-worktree land (#82/#115) — merge from primary + worktree-aware prune ---
# Mirrors the real /sail topology: the branch is built+committed in a LINKED worktree (#65), then
# land runs from the PRIMARY worktree (where `main` lives). The merge must succeed while the branch
# stays checked out in its worktree, and prune must remove that worktree before deleting the branch.
R8="$TMP_ROOT/r8"; make_repo "$R8" main
WT8="$TMP_ROOT/wt8"
git -C "$R8" worktree add -q "$WT8" -b sail/test
echo w > "$WT8/w.txt"; git -C "$WT8" add -A && git -C "$WT8" commit -qm "work in linked worktree"
MSG8="$TMP_ROOT/msg8.txt"; echo "land sail/test (#82)" > "$MSG8"
sail_merge_to_default "$R8" sail/test main "$MSG8" >/dev/null || fail "T8: merge from primary failed while branch checked out in a linked worktree"
sail_prune_merged_branch "$R8" sail/test || fail "T8: worktree-aware prune failed"
refute "T8: merged branch should be gone after prune" -- git -C "$R8" rev-parse --verify sail/test
[ ! -d "$WT8" ] || fail "T8: linked worktree was not removed"
echo "PASS T8: land from primary worktree + worktree-aware prune (removes linked worktree, deletes merged branch)"

# --- T9: prune REFUSES a DIRTY linked worktree (no data loss) ---
R9="$TMP_ROOT/r9"; make_repo "$R9" main
WT9="$TMP_ROOT/wt9"
git -C "$R9" worktree add -q "$WT9" -b sail/dirty
echo d > "$WT9/d.txt"; git -C "$WT9" add -A && git -C "$WT9" commit -qm "committed"
MSG9="$TMP_ROOT/msg9.txt"; echo "land sail/dirty" > "$MSG9"
sail_merge_to_default "$R9" sail/dirty main "$MSG9" >/dev/null || fail "T9: merge failed"
echo uncommitted-work > "$WT9/d.txt"   # make the linked worktree DIRTY
refute "T9: prune must refuse to remove a dirty worktree" -- sail_prune_merged_branch "$R9" sail/dirty
git -C "$R9" rev-parse --verify sail/dirty >/dev/null 2>&1 || fail "T9: branch destroyed despite dirty worktree (data loss!)"
[ -d "$WT9" ] || fail "T9: dirty worktree was removed (data loss!)"
echo "PASS T9: prune refuses a dirty linked worktree — work preserved"

echo "ALL PASS ($PASS assertions)"
