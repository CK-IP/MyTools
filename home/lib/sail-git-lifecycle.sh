#!/usr/bin/env bash
# home/lib/sail-git-lifecycle.sh — source-only library for /sail's git "opening bookend" (#65)
#
# /sail's opening bookend: by default isolate a run on its own git worktree
# (`.claude/worktrees/sail-<issue>`) + `sail/<issue>` branch and commit there, so a /sail
# run never collides with a separate ongoing run in the shared working tree. Risk-gated
# skip: work in place (no worktree) only for an explicit tiny/low-risk inline fix, and
# never when the change is plan-risky or a concurrent run is detected.
#
# This library is ADDITIVE — it does NOT touch the `sail run`/`sail plan` engine. The
# isolate *decision* (and its decision-log entry) lives in the Python engine
# (`python3 -m sail isolate`, which reuses `is_plan_risky`); this shell library carries
# only the git mechanics — naming, the commit-message format, plain-`git worktree`
# creation, and the commit — because those must work in BOTH supervised and
# autonomous/pinned-cwd-subagent modes (native EnterWorktree(create) is rejected from a
# pinned-cwd subagent, so it cannot serve /sail's autonomous `/surf` mode).
#
# Orphan/collision handling REUSES /ship's #125 data-loss guard
# (`ship_safe_cleanup_orphan_dir`) rather than reinventing it — source
# home/lib/ship-resume-safety.sh first. Sourcing a non-existent file with `set -e` fails
# rc=127 — guard with `[ -f ... ] && . ...`.

# ---------------------------------------------------------------------------
# sail_branch_name <issue>  ->  sail/<issue>   (rc=2 on non-numeric/empty issue)
# ---------------------------------------------------------------------------
sail_branch_name() {
  local issue="$1"
  case "$issue" in
    ""|*[!0-9]*) echo "sail-git-lifecycle: invalid issue '$issue'" >&2; return 2 ;;
  esac
  printf 'sail/%s\n' "$issue"
}

# ---------------------------------------------------------------------------
# sail_worktree_path <repo_root> <issue>  ->  <repo_root>/.claude/worktrees/sail-<issue>
# rc=2 on non-numeric/empty issue. Tolerant of a trailing slash on repo_root.
# ---------------------------------------------------------------------------
sail_worktree_path() {
  local repo_root="$1" issue="$2"
  case "$issue" in
    ""|*[!0-9]*) echo "sail-git-lifecycle: invalid issue '$issue'" >&2; return 2 ;;
  esac
  repo_root="${repo_root%/}"
  printf '%s/.claude/worktrees/sail-%s\n' "$repo_root" "$issue"
}

# ---------------------------------------------------------------------------
# sail_commit_message <issue> <title>
# ---------------------------------------------------------------------------
# A conventional-commit subject referencing the issue. The issue title is the subject
# verbatim (sail issue titles are already conventional, e.g. "feat(sail): ..."); a
# trailing ` (#<n>)` is appended, de-duplicating any existing `(#<n>)` suffix so re-runs
# never double-tag. Empty title falls back to a safe conventional default.
# rc=2 on non-numeric/empty issue.
sail_commit_message() {
  local issue="$1" title="$2"
  case "$issue" in
    ""|*[!0-9]*) echo "sail-git-lifecycle: invalid issue '$issue'" >&2; return 2 ;;
  esac
  # Trim leading/trailing whitespace.
  title="${title#"${title%%[![:space:]]*}"}"
  title="${title%"${title##*[![:space:]]}"}"
  # Drop a trailing ` (#NN)` if the title already carries one.
  title="$(printf '%s' "$title" | sed -E 's/[[:space:]]*\(#[0-9]+\)[[:space:]]*$//')"
  [ -n "$title" ] || title="chore(sail): update"
  printf '%s (#%s)\n' "$title" "$issue"
}

# ---------------------------------------------------------------------------
# sail_concurrent_run <repo_root> <issue>
# ---------------------------------------------------------------------------
# Detect a prior/parallel run of the SAME issue: rc=0 (concurrent) if branch
# `sail/<issue>` is checked out in any worktree, or the canonical worktree dir already
# exists; rc=1 otherwise. rc=2 on non-numeric/empty issue. Feeds `sail isolate
# --concurrent` (which gates the --in-place skip) and is the signal `sail_setup_isolation`
# resolves into safe-reuse vs. true-conflict.
sail_concurrent_run() {
  local repo_root="$1" issue="$2" branch wt
  branch="$(sail_branch_name "$issue")" || return 2
  wt="$(sail_worktree_path "$repo_root" "$issue")" || return 2
  if git -C "$repo_root" worktree list --porcelain 2>/dev/null \
       | grep -qx "branch refs/heads/$branch"; then
    return 0
  fi
  [ -d "$wt" ] && return 0
  return 1
}

# ---------------------------------------------------------------------------
# sail_setup_isolation <repo_root> <issue>
# ---------------------------------------------------------------------------
# Create (or idempotently re-attach to) the worktree
# `<repo_root>/.claude/worktrees/sail-<issue>` on branch `sail/<issue>` using plain
# `git worktree`. Prints the worktree path on success.
#
# Concurrency-safe / never destroys unsaved work — splits "existing checkout" into
# safe-reuse vs. active-conflict (adversary HIGH):
#   - SAFE REUSE: if `sail/<issue>` is already checked out at the canonical path, reuse it
#     as-is (idempotent rerun — no churn of a valid checkout).
#   - Otherwise CLEAR the path first WITHOUT destroying work: `git worktree remove` (no
#     --force, so it REFUSES a worktree with uncommitted changes), then hand any surviving
#     dir to `ship_safe_cleanup_orphan_dir` (#125) — it renames a dir holding any non-noise
#     file to `<dir>.orphan-<epoch>` (preserving unsaved work) and only `rm`s pure noise.
#   - ACTIVE CONFLICT: if `sail/<issue>` exists and is checked out in another live worktree
#     (a true parallel run), `git worktree add` fails and this returns non-zero — the caller
#     must NOT destroy it (autonomous: log + fall back to in-place).
#
# Requires `ship_safe_cleanup_orphan_dir` in scope (source ship-resume-safety.sh).
# rc: 0 (path printed) | 2 (bad issue) | 1 (git/worktree failure).
sail_setup_isolation() {
  local repo_root="$1" issue="$2"
  case "$issue" in
    ""|*[!0-9]*) echo "sail-git-lifecycle: invalid issue '$issue'" >&2; return 2 ;;
  esac
  local branch wt existing
  branch="$(sail_branch_name "$issue")" || return 2
  wt="$(sail_worktree_path "$repo_root" "$issue")" || return 2

  mkdir -p "$(dirname "$wt")"

  # Idempotent safe-reuse: canonical path already a worktree on our branch? Compare
  # REALPATH-canonicalized paths, not byte-identical strings — `git worktree list`
  # realpath-resolves its paths, so on darwin a `/var/...` worktree is listed as
  # `/private/var/...` (/var → /private/var) and a string compare would always miss,
  # defeating reuse and dropping into the destructive remove+recreate path.
  existing="$(git -C "$repo_root" worktree list --porcelain 2>/dev/null \
    | awk -v b="branch refs/heads/$branch" '
        /^worktree /{cur=substr($0,10)}
        $0==b{print cur}')"
  if [ -n "$existing" ] && [ -d "$wt" ]; then
    if [ "$(cd "$existing" 2>/dev/null && pwd -P)" = "$(cd "$wt" 2>/dev/null && pwd -P)" ]; then
      printf '%s\n' "$wt"; return 0
    fi
  fi

  # Clear a prior occupant of the path without ever destroying unsaved work.
  git -C "$repo_root" worktree remove "$wt" 2>/dev/null || true
  if [ -d "$wt" ]; then
    if command -v ship_safe_cleanup_orphan_dir >/dev/null 2>&1; then
      ship_safe_cleanup_orphan_dir "$wt"
    else
      echo "sail-git-lifecycle: ship_safe_cleanup_orphan_dir unavailable; refusing to touch $wt" >&2
      return 1
    fi
  fi
  git -C "$repo_root" worktree prune 2>/dev/null || true

  # Re-attach to an existing branch (prior run) or create a fresh one. A branch checked
  # out in another live worktree makes `git worktree add` fail → return 1 (never destroy).
  if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$repo_root" worktree add "$wt" "$branch" >&2 || return 1
  else
    git -C "$repo_root" worktree add "$wt" -b "$branch" >&2 || return 1
  fi
  printf '%s\n' "$wt"
}

# ---------------------------------------------------------------------------
# sail_commit_on_branch <work_dir> <issue> <title>
# ---------------------------------------------------------------------------
# Stage all changes in <work_dir> and commit with the `sail_commit_message` subject.
# No-op (rc=0) when the tree is clean — never errors on an empty commit. The CALLER must
# only invoke this AFTER review is green (0 CRITICAL/0 HIGH); this function does not (and
# cannot) re-check the gate. rc: 0 (committed or clean) | 2 (bad issue) | 1 (git failure).
sail_commit_on_branch() {
  local work_dir="$1" issue="$2" title="$3"
  case "$issue" in
    ""|*[!0-9]*) echo "sail-git-lifecycle: invalid issue '$issue'" >&2; return 2 ;;
  esac
  local msg
  msg="$(sail_commit_message "$issue" "$title")" || return 2
  git -C "$work_dir" add -A || return 1
  if git -C "$work_dir" diff --cached --quiet; then
    return 0  # nothing to commit
  fi
  git -C "$work_dir" commit -m "$msg" || return 1
}
