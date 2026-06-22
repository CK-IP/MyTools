#!/usr/bin/env bash
# test_sail_65_lifecycle.sh
# Hermetic tests for /sail's git "opening bookend" (#65): the isolate-vs-skip decision,
# branch/worktree naming, commit-message format, worktree creation with the #125
# orphan-safety guard, idempotent reuse, and decision-log persistence.
#
# Hermetic per the domain rule: every git assertion runs against a THROWAWAY temp repo
# seeded with just the fixture — never against the live working tree / branch / diff.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/home/lib/sail-git-lifecycle.sh"
SAFETY_LIB="$REPO_ROOT/home/lib/ship-resume-safety.sh"
# ship-resume-safety.sh is an org-level (cc-dotfiles) lib; fall back to the installed copy.
[ -f "$SAFETY_LIB" ] || SAFETY_LIB="$HOME/.claude/lib/ship-resume-safety.sh"

TMP_ROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); }
# refute <message> -- <cmd...>: assert the command FAILS (non-zero); pass otherwise.
refute() {
  local msg="$1"; shift; [ "$1" = "--" ] && shift
  if "$@" 2>/dev/null; then fail "$msg"; fi
  ok
}

[ -f "$LIB" ] || fail "sail-git-lifecycle.sh exists at $LIB"
[ -f "$SAFETY_LIB" ] || fail "ship-resume-safety.sh found (cc-dotfiles or ~/.claude/lib)"

# shellcheck disable=SC1090
. "$SAFETY_LIB"
# shellcheck disable=SC1090
. "$LIB"

# ---------------------------------------------------------------------------
# 1. Naming
# ---------------------------------------------------------------------------
[ "$(sail_branch_name 65)" = "sail/65" ] || fail "sail_branch_name 65 → sail/65"; ok
[ "$(sail_worktree_path /repo 65)" = "/repo/.claude/worktrees/sail-65" ] \
  || fail "sail_worktree_path /repo 65"; ok
[ "$(sail_worktree_path /repo/ 65)" = "/repo/.claude/worktrees/sail-65" ] \
  || fail "sail_worktree_path tolerates trailing slash"; ok
refute "sail_branch_name rejects empty issue" -- sail_branch_name ""
refute "sail_branch_name rejects non-numeric issue" -- sail_branch_name "1; rm -rf /"
refute "sail_worktree_path rejects non-numeric issue" -- sail_worktree_path /repo "../evil"

# ---------------------------------------------------------------------------
# 2. Commit-message format
# ---------------------------------------------------------------------------
[ "$(sail_commit_message 65 'feat(sail): add opening bookend')" \
  = "feat(sail): add opening bookend (#65)" ] || fail "commit-message appends (#65)"; ok
# De-dupes an existing issue suffix (no double-tag on rerun).
[ "$(sail_commit_message 65 'feat(sail): add opening bookend (#65)')" \
  = "feat(sail): add opening bookend (#65)" ] || fail "commit-message de-dupes (#65) suffix"; ok
# Trims surrounding whitespace.
[ "$(sail_commit_message 65 '  fix: thing  ')" = "fix: thing (#65)" ] \
  || fail "commit-message trims whitespace"; ok
# Empty title → safe conventional fallback.
[ "$(sail_commit_message 65 '')" = "chore(sail): update (#65)" ] \
  || fail "commit-message empty-title fallback"; ok
refute "commit-message rejects non-numeric issue" -- sail_commit_message abc 'x'

# ---------------------------------------------------------------------------
# 3. Isolate-vs-skip decision (Python engine, pure) — full matrix
#    `python3 -m sail isolate` prints  <decision>\t<commit>\t<reason>
# ---------------------------------------------------------------------------
cd "$REPO_ROOT"
decide() {
  # args: branch default flags...   spec on stdin via $SPEC
  printf '%s' "${SPEC:-some ordinary spec}" | python3 -m sail isolate "$@"
}

# 3a. default branch, no flags, ordinary spec → isolate, commit
out="$(decide --branch main --default-branch main)"
[ "$(printf '%s' "$out" | cut -f1)" = "isolate" ] || fail "default-branch → isolate"; ok
[ "$(printf '%s' "$out" | cut -f2)" = "yes" ] || fail "default-branch → commit yes"; ok

# 3b. on a feature branch → in-place, commit (honors current branch by design)
out="$(decide --branch surf/65 --default-branch main)"
[ "$(printf '%s' "$out" | cut -f1)" = "in-place" ] || fail "feature-branch → in-place"; ok
[ "$(printf '%s' "$out" | cut -f2)" = "yes" ] || fail "feature-branch → commit yes"; ok

# 3c. --in-place on default branch, ordinary spec, no concurrency → in-place, NO commit (risk-gated skip)
out="$(decide --branch main --default-branch main --in-place)"
[ "$(printf '%s' "$out" | cut -f1)" = "in-place" ] || fail "--in-place skip → in-place"; ok
[ "$(printf '%s' "$out" | cut -f2)" = "no" ] || fail "--in-place skip → commit no"; ok

# 3d. --in-place but concurrent run → isolate (risk overrides skip)
out="$(decide --branch main --default-branch main --in-place --concurrent)"
[ "$(printf '%s' "$out" | cut -f1)" = "isolate" ] || fail "--in-place + concurrent → isolate"; ok

# 3e. --in-place but plan-risky spec → isolate (risk overrides skip).
#     is_plan_risky fires on an unambiguous failure phrase: build a spec that trips it.
out="$(SPEC='this is an unresolvable remediation loop with an unreconciled file list' \
  decide --branch main --default-branch main --in-place)"
[ "$(printf '%s' "$out" | cut -f1)" = "isolate" ] || fail "--in-place + plan-risky → isolate"; ok

# 3f. --isolate forces isolate even on a feature branch
out="$(decide --branch surf/65 --default-branch main --isolate)"
[ "$(printf '%s' "$out" | cut -f1)" = "isolate" ] || fail "--isolate forces isolate"; ok

# 3g. --isolate + --in-place is mutually exclusive → rc=2
if printf 'x' | python3 -m sail isolate --branch main --isolate --in-place >/dev/null 2>&1; then
  fail "--isolate + --in-place must be mutually exclusive (rc!=0)"
fi
ok

# ---------------------------------------------------------------------------
# 4. Decision is PERSISTED to the decision-log on every path (HIGH risk)
# ---------------------------------------------------------------------------
RUN_DIR="$TMP_ROOT/run"
printf 'ordinary spec' | python3 -m sail isolate --run-dir "$RUN_DIR" --branch main --default-branch main >/dev/null
grep -qE '^- isolate: isolate \(commit=yes\) — ' "$RUN_DIR/decision-log.md" \
  || fail "decision-log records the isolate decision + rationale"; ok
printf 'ordinary spec' | python3 -m sail isolate --run-dir "$RUN_DIR" --branch main --default-branch main --in-place >/dev/null
grep -qE '^- isolate: in-place \(commit=no\) — ' "$RUN_DIR/decision-log.md" \
  || fail "decision-log records the in-place skip decision"; ok

# ---------------------------------------------------------------------------
# 5. Worktree creation against a THROWAWAY repo (hermetic) + commit
# ---------------------------------------------------------------------------
mkrepo() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  echo seed > "$d/seed.txt"
  git -C "$d" add -A; git -C "$d" commit -qm "seed"
}

REPO="$TMP_ROOT/repo1"; mkrepo "$REPO"
wt="$(sail_setup_isolation "$REPO" 65)" || fail "sail_setup_isolation succeeds on a clean repo"
[ "$wt" = "$REPO/.claude/worktrees/sail-65" ] || fail "isolation prints the canonical worktree path"; ok
[ -d "$wt" ] || fail "worktree dir created"; ok
[ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = "sail/65" ] || fail "worktree is on branch sail/65"; ok

# Build + commit inside the worktree.
echo change > "$wt/feature.txt"
sail_commit_on_branch "$wt" 65 'feat(sail): opening bookend' || fail "commit-on-branch succeeds"
git -C "$wt" log -1 --pretty=%s | grep -qx 'feat(sail): opening bookend (#65)' \
  || fail "commit subject matches the conventional format"; ok
# Commit landed on sail/65, NOT on the repo's main/master.
if git -C "$REPO" log --oneline main 2>/dev/null | grep -q 'opening bookend'; then
  fail "commit must NOT land on the default branch"
fi
ok

# 5b. Clean tree → commit is a no-op (no error, no empty commit).
before="$(git -C "$wt" rev-parse HEAD)"
sail_commit_on_branch "$wt" 65 'feat(sail): opening bookend' || fail "commit-on-branch no-ops on a clean tree"
[ "$(git -C "$wt" rev-parse HEAD)" = "$before" ] || fail "clean tree must not create an empty commit"; ok

# ---------------------------------------------------------------------------
# 6. Idempotent safe-reuse — second setup re-attaches the SAME worktree, no churn.
#    A sentinel untracked file proves reuse-as-is: a remove+recreate path would wipe it
#    (so this also guards the realpath-canonicalization fix — a string-compare miss would
#    drop into recreate and delete the sentinel).
# ---------------------------------------------------------------------------
echo "do-not-delete" > "$wt/.reuse-sentinel"
wt2="$(sail_setup_isolation "$REPO" 65)" || fail "second sail_setup_isolation reuses cleanly"
[ "$wt2" = "$wt" ] || fail "reuse returns the same canonical path"; ok
[ -f "$wt/.reuse-sentinel" ] || fail "reuse did NOT tear down the worktree (sentinel survived)"; ok
grep -qx "do-not-delete" "$wt/.reuse-sentinel" || fail "reuse preserved the sentinel content"; ok
git -C "$wt" log -1 --pretty=%s | grep -qx 'feat(sail): opening bookend (#65)' \
  || fail "reuse preserved the prior commit (no churn/loss)"; ok
rm -f "$wt/.reuse-sentinel"

# ---------------------------------------------------------------------------
# 7. Concurrency detection
# ---------------------------------------------------------------------------
sail_concurrent_run "$REPO" 65 || fail "concurrent-run detected when sail/65 worktree exists"; ok
REPO2="$TMP_ROOT/repo2"; mkrepo "$REPO2"
refute "no concurrent run on a fresh repo" -- sail_concurrent_run "$REPO2" 65

# ---------------------------------------------------------------------------
# 8. Orphan-safety reuse (#125): a dir with unsaved work is PRESERVED, not destroyed
# ---------------------------------------------------------------------------
REPO3="$TMP_ROOT/repo3"; mkrepo "$REPO3"
orphan="$REPO3/.claude/worktrees/sail-77"
mkdir -p "$orphan"
echo "precious unsaved work" > "$orphan/wip.txt"   # not a registered worktree, just a stray dir
wt77="$(sail_setup_isolation "$REPO3" 77)" || fail "setup proceeds past an orphan dir"
[ -d "$wt77" ] || fail "new worktree created after orphan handling"; ok
# The stray dir's content must survive somewhere as a preserved .orphan-* sibling.
ls -d "$REPO3"/.claude/worktrees/sail-77.orphan-* >/dev/null 2>&1 \
  || fail "orphan dir with unsaved work was preserved (not destroyed)"; ok
grep -qx "precious unsaved work" "$REPO3"/.claude/worktrees/sail-77.orphan-*/wip.txt \
  || fail "preserved orphan retains its unsaved content"; ok

# ---------------------------------------------------------------------------
# 9. Doc contract — commands/sail.md documents the opening isolate stage and
#    gates the commit strictly on a GREEN review (HIGH risk #1 mitigation).
# ---------------------------------------------------------------------------
SAILMD="$REPO_ROOT/commands/sail.md"
grep -qiE 'isolat' "$SAILMD" || fail "sail.md documents the opening isolate stage"; ok
grep -qiE 'sail_setup_isolation|sail-git-lifecycle' "$SAILMD" || fail "sail.md references the git-lifecycle lib"; ok
grep -qiE 'gated strictly on GREEN|Never commit on a red|gated on .*green' "$SAILMD" \
  || fail "sail.md gates the commit on a green review (no commit on red)"; ok

echo "PASS: sail #65 git lifecycle — $PASS assertions"
