#!/usr/bin/env bash
# test_sail_115_land_orchestration.sh
# Hermetic tests for /sail's land ORCHESTRATION wiring (#115).
#
# The bug (#115): in /sail's default ISOLATED flow the build runs in a LINKED worktree
# (.claude/worktrees/sail-<issue>) and Stage 0.5 `cd`s INTO it. The pre-#115 land prose then
# called `sail_merge_to_default . sail/<issue> main …` with `.` = the linked-worktree cwd, so the
# function's first action `git checkout main` FAILED — `main` is already checked out in the primary
# worktree and git refuses the same branch in two worktrees. Pruning likewise failed while cwd was
# inside the worktree being removed. The functions themselves (#82) are correct + worktree-aware;
# #115 is the ORCHESTRATION wiring: derive the PRIMARY worktree, absolutize the run-dir before the
# cd (so the land artifacts survive), then run the local mechanics from the primary.
#
# Hermetic per the domain rule: every git assertion runs against a THROWAWAY temp repo seeded with
# just the fixture — never against the live tree / branch / diff. Mirrors test_sail_82_land_lifecycle.sh.

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
expect_rc() { local want="$1" msg="$2"; shift 2; [ "$1" = "--" ] && shift; local rc=0; "$@" >/dev/null 2>&1 || rc=$?; [ "$rc" -eq "$want" ] || fail "$msg (wanted rc=$want, got $rc)"; ok; }

make_repo() {  # <dir> <default-branch>
  local dir="$1" def="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q -b "$def"
  git -C "$dir" config user.email t@t.io
  git -C "$dir" config user.name tester
  echo base > "$dir/base.txt"
  # Mirror production: .sail/ is gitignored (CK-Skills .gitignore), so the in-worktree run-dir
  # artifacts are IGNORED, not untracked — `git worktree remove` (no --force) removes a worktree
  # whose only dirty content is ignored files, but REFUSES on untracked/modified ones (#115).
  printf '.sail/\n' > "$dir/.gitignore"
  git -C "$dir" add -A && git -C "$dir" commit -qm "base"
}

abspath() { (cd "$1" && pwd -P); }

[ -f "$LIB" ] || fail "sail-git-lifecycle.sh exists at $LIB"
# shellcheck disable=SC1090
. "$LIB"

command -v sail_primary_worktree >/dev/null 2>&1 || fail "sail_primary_worktree is defined"

# --- T1: sail_primary_worktree resolves the PRIMARY from inside a LINKED worktree cwd ---
R1="$TMP_ROOT/r1"; make_repo "$R1" main
WT1="$R1/.claude/worktrees/sail-115"; mkdir -p "$(dirname "$WT1")"
git -C "$R1" worktree add -q "$WT1" -b sail/115
GOT="$(cd "$WT1" && sail_primary_worktree .)" || fail "T1: sail_primary_worktree failed from linked worktree"
[ "$(abspath "$GOT")" = "$(abspath "$R1")" ] || fail "T1: expected primary $R1, got $GOT (linked path leaked?)"
expect_rc 2 "T1: empty repo arg must rc=2 (sibling convention)" -- sail_primary_worktree ""
echo "PASS T1: sail_primary_worktree resolves the primary from inside a linked worktree (+ rc=2 guard)"
ok

# --- T2: the naive pre-#115 path is genuinely broken (the cd to primary is load-bearing) ---
# Documents the failure the fix avoids: `git checkout main` from the linked worktree refuses,
# because `main` is checked out in the primary. If this ever STOPS failing, the fix is moot.
R2="$TMP_ROOT/r2"; make_repo "$R2" main
WT2="$R2/.claude/worktrees/sail-115"; mkdir -p "$(dirname "$WT2")"
git -C "$R2" worktree add -q "$WT2" -b sail/115
if git -C "$WT2" checkout main >/dev/null 2>&1; then
  fail "T2: 'git checkout main' from the linked worktree unexpectedly SUCCEEDED — the #115 bug premise is gone"
fi
echo "PASS T2: 'git checkout main' from a linked worktree fails (the bug the primary-cd avoids)"
ok

# --- T3: FULL land SEQUENCE from a linked-worktree topology (the #115 orchestration) ---
# Reproduces the real /sail topology: build+commit in the linked worktree; the run-dir + land
# artifacts live INSIDE the worktree (relative $SESSION_DIR after the Stage 0.5 cd). The
# orchestration absolutizes the run-dir, derives the primary, cd's there, then merge → (read the
# comment file) → prune. The merge MUST NOT hit the checkout-main bug, the artifacts MUST survive
# the cd, and prune (LAST, after every $RD read) MUST remove the worktree + delete the branch.
R3="$TMP_ROOT/r3"; make_repo "$R3" main
WT3="$R3/.claude/worktrees/sail-115"; mkdir -p "$(dirname "$WT3")"
git -C "$R3" worktree add -q "$WT3" -b sail/115
echo change > "$WT3/feature.txt"; git -C "$WT3" add -A && git -C "$WT3" commit -qm "feat in worktree"
# run-dir + land artifacts produced INSIDE the worktree (as the relative $SESSION_DIR resolves there)
SESSION_DIR=".sail/runs/sail-115-T3"; mkdir -p "$WT3/$SESSION_DIR"
printf 'land: feature (#115)\n\nCloses #115\n' > "$WT3/$SESSION_DIR/land-commit-msg.txt"
printf '## land evidence\n' > "$WT3/$SESSION_DIR/land-comment.md"
(
  cd "$WT3"                                       # cwd = the linked worktree, as Stage 0.5 leaves it
  RD="$(cd "$SESSION_DIR" && pwd -P)"             # absolutize BEFORE any cd
  [ -r "$RD/land-commit-msg.txt" ] || fail "T3: absolutized run-dir not readable from worktree cwd"
  PRIMARY="$(sail_primary_worktree .)"            # derive the primary from the linked-worktree cwd
  cd "$PRIMARY"                                   # land mechanics run from the primary worktree
  sail_merge_to_default . sail/115 main "$RD/land-commit-msg.txt" >/dev/null \
    || fail "T3: merge from primary failed (the #115 checkout-main bug)"
  [ -r "$RD/land-comment.md" ] || fail "T3: land-comment.md unreadable post-cd (run-dir not absolutized)"
  sail_prune_merged_branch . sail/115 || fail "T3: worktree-aware prune failed"
)
[ -f "$R3/feature.txt" ] || fail "T3: merged change missing from primary main"
git -C "$R3" log -1 --pretty=%P | grep -q ' ' || fail "T3: main HEAD is not a --no-ff merge commit (no second parent)"
if git -C "$R3" rev-parse --verify sail/115 >/dev/null 2>&1; then fail "T3: sail/115 branch was not pruned"; fi
[ ! -d "$WT3" ] || fail "T3: linked worktree was not removed by prune"
echo "PASS T3: full land sequence from a linked-worktree cwd (absolutize run-dir → derive primary → cd → merge → prune)"
ok

# --- T4: doc-contract — sail.md Stage 5 wires the #115 orchestration, drops the stale .surf/runs run-dir ---
SAILMD="$REPO_ROOT/commands/sail.md"
grep -q 'sail_primary_worktree' "$SAILMD" || fail "T4: sail.md does not derive the primary worktree via sail_primary_worktree (#115 regression)"
# /sail's OWN land block must reference its real build run-dir, not /surf's coordination namespace.
grep -Eq '^\s*python3 -m sail land --run-dir \.surf/runs' "$SAILMD" \
  && fail "T4: sail.md land still calls 'sail land --run-dir .surf/runs/<issue>' (wrong run-dir for standalone /sail)"
grep -Eq '^\s*RD=\.surf/runs/<issue>' "$SAILMD" \
  && fail "T4: sail.md land block still hardcodes 'RD=.surf/runs/<issue>' (stale run-dir; should use the absolutized session run-dir)"
ok
echo "PASS T4: sail.md Stage 5 wires the #115 orchestration and drops the stale .surf/runs run-dir"

echo "ALL PASS ($PASS assertions)"
