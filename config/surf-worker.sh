#!/usr/bin/env bash
# surf-worker.sh — thin helpers for /surf's per-issue headless worker (issue #124).
#
# /surf delegates each issue to a FRESH headless `claude --dangerously-skip-permissions -p`
# process running `/sail <n> --unattended` against a stable per-issue run-dir. The worker is
# BACKGROUNDED BY THE HARNESS, not by bash: the supervisor runs the emitted command via Claude
# Code's own Bash tool with `run_in_background: true`, which keeps the worker alive across turns and
# OWNS its lifecycle/kill. Pure-bash daemonization was removed (#124 final decision) — it fights
# macOS (no `setsid` → no cross-tick survival; cross-shell `wait` returns 127; unsafe process-group
# kill). See surf.md Step 7/8b and docs/surf-convoy-comparison-and-backlog.md §7.
#
# What stays in bash here is only deterministic, side-effect-free glue:
#   - surf_worker_validate_id  : numeric-id injection guard.
#   - surf_worker_command      : EMIT the exact injection-safe worker command (no forking).
#   - surf_worker_result       : the durable-artifact merge contract (fail-CLOSED).
#   - surf_worker_cleanup      : safe per-issue cleanup (git worktree remove WITHOUT --force).
# No judgment lives here (that is the supervisor's job); no log/pane scraping (the result contract
# is the run-dir's durable artifacts).

# Strict mode applies ONLY when this file is executed directly — NOT when sourced. A sourced library
# must never mutate the caller's shell options: under `set -e` a function's by-design non-zero return
# (e.g. the injection-guard rejection) would abort the caller, and under `set -u`/zsh the unbound
# guard below would abort the source. /surf sources this via a `bash -c` subshell, but this keeps it
# safe under any sourcing shell too (#128). The functions handle their own errors explicitly.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then set -euo pipefail; fi

surf_worker_log() {
  printf '%s surf-worker: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2 2>/dev/null || true
}

# surf_worker_validate_id <issue> — succeed iff <issue> is a bare positive integer.
surf_worker_validate_id() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

# surf_worker_command <issue> [answer-file] — validate the id, then EMIT (to stdout) the exact
# worker command for the SUPERVISOR to run via the harness Bash tool with run_in_background:true.
# It does NOT fork anything — the harness owns the process lifecycle/kill.
#
# Injection-safe boundary: <issue> is numeric-validated before it appears anywhere; the emitted
# command embeds only that validated integer; a domain answer, if any, is referenced by FILE PATH
# only (never the answer text), so no user/domain text reaches the command line. Returns non-zero on
# a bad id (the supervisor must not run anything).
surf_worker_command() {
  local issue="${1:-}" answer_file="${2:-}"
  if ! surf_worker_validate_id "$issue"; then
    surf_worker_log "refusing non-numeric issue id: '${issue}'"
    return 2
  fi
  local prompt="/sail ${issue} --unattended"
  if [ -n "$answer_file" ]; then
    # Reference the answer FILE by path only — never inline the answer text. The path rides inside a
    # double-quoted `-p "..."` argument of a command the supervisor runs under
    # --dangerously-skip-permissions, so REFUSE any path with characters outside a safe path charset
    # (a `$(...)`/backtick/`;`/whitespace path would otherwise be a shell-injection surface). Surf
    # only ever passes its own constructed paths (e.g. .surf/open-questions.md), so this never
    # rejects a legitimate path; it just fails closed on a malformed one.
    if ! [[ "$answer_file" =~ ^[A-Za-z0-9._/-]+$ ]]; then
      surf_worker_log "refusing answer-file path with unsafe characters: '${answer_file}'"
      return 2
    fi
    prompt="${prompt} (domain answers in ${answer_file})"
  fi
  # #139 sub-gap B — headless-worker contract. A headless `claude -p` worker EXITS when its turn
  # ends and is NOT re-invoked (no ScheduleWakeup, no harness re-entry), so any /sail stage it
  # backgrounds is LOST: the worker dies mid-build with no run-state.json/review.json/commit. The
  # PROVEN fix (validated on #114 during the 20260629T161030Z board run) is to forbid backgrounding
  # and require the codex build+review stages to run SYNCHRONOUSLY in-turn through the Stage-4 commit
  # terminus. The clause is a FIXED string with NO double-quotes / backticks / `$` so it stays
  # literal — and injection-safe — inside the emitted `-p "..."` double-quoted argument (the numeric
  # issue id is the only interpolated value, and it was validated above).
  local contract='=== HEADLESS-WORKER CONTRACT (overrides any default async behavior) === You are a headless claude -p worker: your process EXITS when this turn ends and you are NOT re-invoked, so any work you background is LOST. Run EVERY /sail stage SYNCHRONOUSLY in this single turn: plan, build (codex), review (codex, all rounds), commit. Do NOT use run_in_background, do NOT background a command with an ampersand, do NOT use ScheduleWakeup, and do NOT background a stage and end your turn expecting to be re-invoked. Instead, BLOCK in-turn: invoke each codex build and review as a foreground call and WAIT for it to return (a blocking foreground wait is correct and required — it is NOT the prohibited behavior), then proceed straight to the next stage in this same turn. A -p worker is NOT bound by any 10-minute tool cap, so long blocking codex calls are expected and fine. Drive all the way to the Stage-4 commit terminus before ending the turn; only end once /sail has committed or genuinely parked with a wip-handoff.md.'
  prompt="${prompt} ${contract}"
  printf '%s\n' "claude --dangerously-skip-permissions -p \"${prompt}\""
}

# surf_worker_resolve_run_dir <issue> [repo_root] — print the NEWEST /sail SESSION run-dir for
# <issue> that already holds terminus artifacts, else return non-zero. /sail's front door
# (sail.md Stage 0) ALWAYS names its own run-dir `.sail/runs/sail-<issue>-<UTC-timestamp>/` and
# ignores any external --run-dir, and its isolate path writes that dir INSIDE the per-issue worktree
# `.claude/worktrees/sail-<issue>/`. So /surf cannot hard-code the path — it must DISCOVER /sail's
# ACTUAL run-dir (#136 sub-gap C), searching BOTH the repo root and the worktree.
#
# This stays in /surf's surf-OWNED coordination namespace only as a READER: the durable sentinels
# (`.done`, parked-issues) live under `.surf/runs/<issue>/`; the /sail build artifacts are resolved
# FRESH here on each poll (never cached), so a resume re-run that regenerates a new timestamped dir
# is picked up automatically.
#
# Filtering to dirs that ALREADY contain BOTH run-state.json AND review.json (not merely the newest
# by name) is load-bearing: it prevents handing surf_worker_result an in-flight / half-written dir,
# which would spuriously fail-closed-park a run that is actually still building. When none qualify,
# returns non-zero with no output so the supervisor keeps POLLING rather than parking a live run.
#
# GENERATION GUARD (optional <min_ts>, #136 review HIGH). On a RELAUNCH (resume / domain-answer
# re-launch), a PRIOR run's terminus dir (sail-<issue>-<older-ts>/) is still on disk while the fresh
# worker is only just starting and has not written its own dir yet. Without a guard the resolver
# would return that STALE dir and the supervisor would park/merge on a prior attempt's artifacts.
# Pass <min_ts> = the just-spawned worker's spawn time (a `YYYYMMDDTHHMMSSZ` UTC string, the SAME
# format /sail names its run-dir suffix); a dir whose `<UTC-ts>` suffix sorts BEFORE <min_ts> is
# skipped, so only the current worker generation can resolve. Omit <min_ts> (or pass empty) for the
# un-guarded "newest terminus dir" behavior (a single-shot run with no prior attempt).
# Side-effect-free (read-only); deterministic. rc: 0 (path printed) | 1 (none) | 2 (bad issue id).
surf_worker_resolve_run_dir() {
  local issue="${1:-}" repo_root="${2:-}" min_ts="${3:-}"
  if ! surf_worker_validate_id "$issue"; then
    surf_worker_log "resolve-run-dir: refusing non-numeric issue id: '${issue}'"
    return 2
  fi
  [ -n "$repo_root" ] || repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  # Defense-in-depth: min_ts must be a /sail UTC timestamp. A malformed/garbage value (e.g. a
  # corrupt spawn-ts file) is dropped rather than used as a comparison bound — and the supervisor's
  # read-site validation (surf.md) independently rejects a tampered spawn-ts before it can be spliced
  # into a `bash -c` string. A malformed min_ts here simply disables the guard (logged), never errors.
  if [ -n "$min_ts" ] && ! [[ "$min_ts" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
    surf_worker_log "resolve-run-dir: ignoring malformed min_ts '${min_ts}' (not a UTC timestamp)"
    min_ts=""
  fi
  local newest="" newest_ts="" d base ts _nullglob_was_set=0
  # null-glob so a non-existent location expands to NOTHING — and be safe under BOTH shells: bash
  # uses `shopt -s nullglob`, while under zsh (where the helper may be sourced — see the header)
  # an unmatched glob otherwise ABORTS the function on `nomatch`. `setopt local_options null_glob`
  # is function-scoped in zsh (auto-reverted on return). Under bash we record the caller's prior
  # nullglob state (via the no-output query form `shopt -q`, so no `eval`) and restore it at the end,
  # so we never clobber a caller that had it on/off.
  if [ -n "${ZSH_VERSION:-}" ]; then
    setopt local_options null_glob 2>/dev/null || true
  else
    shopt -q nullglob 2>/dev/null && _nullglob_was_set=1
    shopt -s nullglob 2>/dev/null || true
  fi
  for d in "$repo_root"/.sail/runs/sail-"$issue"-*/ \
           "$repo_root"/.claude/worktrees/sail-"$issue"/.sail/runs/sail-"$issue"-*/ ; do
    [ -d "$d" ] || continue
    # Terminus-bearing = either a PARK marker (wip-handoff.md) OR a completed review pair
    # (run-state.json AND review.json). Including wip-handoff.md is load-bearing: an exited PARKED
    # /sail run may have written ONLY wip-handoff.md (e.g. a plan-stage park, before any
    # run-state.json/review.json), and surf_worker_result parks on wip-handoff.md FIRST — so without
    # this a parked worker would be misread as 'still building' and polled until the wall-clock cap
    # (#136 review). A still-building run (no marker, incomplete pair) is still correctly skipped.
    if [ ! -f "${d}wip-handoff.md" ] && { [ ! -f "${d}run-state.json" ] || [ ! -f "${d}review.json" ]; }; then
      continue
    fi
    base="$(basename "$d")"; ts="${base#sail-"$issue"-}"   # the sortable <UTC-ts> suffix
    # Validate the suffix is a real /sail UTC timestamp (YYYYMMDDThhmmssZ). A corrupt or forged
    # suffix (e.g. `sail-<issue>-z`) would otherwise sort lexically ABOVE every real timestamp AND
    # slip past the min_ts generation guard, letting a bogus dir be chosen and fed to
    # surf_worker_result (#136 review). A non-conforming suffix is skipped.
    case "$ts" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) : ;;
      *) continue ;;
    esac
    # Generation guard + ranking use [[ < ]] / [[ > ]] for the string compare — this works in BOTH
    # bash AND zsh, whereas the bare-`[` `\<`/`\>` operators are NOT portable to zsh's `test`
    # (zsh emits "condition expected", silently failing to filter — #136 review). Skip a dir from a
    # prior worker generation (ts strictly before min_ts).
    if [ -n "$min_ts" ] && [[ "$ts" < "$min_ts" ]]; then
      continue
    fi
    # Rank by the sortable suffix (lexical order == chronological), so the newest terminus-bearing
    # dir wins regardless of which of the two locations it sits in.
    if [ -z "$newest" ] || [[ "$ts" > "$newest_ts" ]]; then
      newest="$d"; newest_ts="$ts"
    fi
  done
  # Restore the caller's prior bash nullglob state (no-op under zsh, where setopt was function-scoped):
  # only turn it back OFF if the caller did not have it on (never clobber a caller that had it set).
  [ "$_nullglob_was_set" -eq 1 ] || shopt -u nullglob 2>/dev/null || true
  [ -n "$newest" ] || { surf_worker_log "resolve-run-dir: no terminus-bearing .sail run-dir for issue ${issue}${min_ts:+ at/after ${min_ts}} (still building?)"; return 1; }
  printf '%s\n' "${newest%/}"
}

# surf_worker_result <run-dir> [exit-code] — the worker→supervisor RESULT/merge contract.
#
# POLARITY — FAIL-CLOSED (park on ambiguity). This is the merge gate: we must NEVER merge a run
# that is not POSITIVELY CONFIRMED green, so anything missing/garbage/ambiguous → PARK. This is
# DISTINCT from the watchdog/liveness path — owned by the harness (run_in_background + its
# background-task kill), not bash — which is fail-OPEN (don't wedge a healthy run). Two different
# jobs, two opposite safe directions.
#
# CRITICAL (#124 R5-1): the exit code is IGNORED for the decision — it is informational only.
# The `claude -p` process exit code reflects the *claude process*, not /sail's commit-vs-park
# terminus (decided inside the agent turn); worse, on macOS (no `setsid`) the spawn falls back to a
# job-control background and a cross-shell `wait "$pid"` returns 127 even on a clean worker exit. So
# the decision is read SOLELY from /sail's STRUCTURED, DURABLE run-dir artifacts (all written by
# /sail today; no engine change). The optional <exit-code> arg is logged for diagnostics, never
# branched on.
#
# GREEN mirrors /sail's FULL green definition (#124 R3-1, R7-1, R7-2). It reuses /sail's OWN
# predicates as the single source of truth — sail.convergence.acs_all_met and
# sail.convergence.review_current_and_clean (MINUS that function's /sail-internal `round` check,
# which the supervisor cannot know) — so this gate cannot silently diverge from /sail's green.
# ALL of these must hold, else PARK:
#   1. wip-handoff.md absent             → not parked (sail.convergence.write_handoff writes it).
#   2. run-state.json: every gate status in {passed, skipped}; any failed/pending/running → PARK.
#   3. review.json status == "completed" → a skipped/error/absent review → PARK.
#   4. review.json: no CRITICAL/HIGH finding.
#   5. review.json plan_verification.acceptance_criteria: a NON-EMPTY list, every status == "met"
#      (an EMPTY or missing AC list → PARK — mirrors acs_all_met; #47 traceability spine; #124 R7-1).
#   6. review.json tidiness.blocking: empty/absent (a confirmed block-tier finding → PARK).
#   7. review is CURRENT, not stale (#124 R7-2): review.json target/diff_ref present;
#      abspath(target) == review target; diff_hash == sail.review.diff_fingerprint(target,diff_ref);
#      plan_hash == sail.review.plan_fingerprint(run_dir); domain_hash == current domain memory.
#      A clean-but-STALE review (written for an earlier diff or domain state) → PARK, so we never
#      merge a diff that was never actually reviewed.
# Shape guards (#124 R3-2): if findings is not a list, or plan_verification not a dict, or
# acceptance_criteria not a list, or tidiness not a dict → PARK (don't crash, don't pass).
# Anything missing/garbage/ambiguous — including an unimportable sail.review or an uncomputable
# fingerprint — fails CLOSED → PARK.
# Returns 0 = green (safe to merge), non-zero = park.
#
# Args: <run-dir> [exit-code] [target]
#   exit-code : informational ONLY (#124 R5-1) — never a decision input (unreliable across the macOS
#               set-m spawn fallback, where a cross-shell wait returns 127 on a clean exit).
#   target    : the worktree root the worker built in (for the currency check). Optional: when
#               omitted it is derived from review.json's `target` field and verified to be a git
#               worktree root (git -C <target> rev-parse --show-toplevel).
surf_worker_result() {
  local run_dir="${1:-}" exit_code="${2:-}" target="${3:-}"
  [ -n "$exit_code" ] && surf_worker_log "worker process exit ${exit_code} (informational; decision is artifact-based)" || true
  # (1) A parked run leaves a durable wip-handoff.md — never merge over it.
  if [ -e "$run_dir/wip-handoff.md" ]; then
    surf_worker_log "wip-handoff.md present in $run_dir — run PARKED → park"
    return 1
  fi
  local rs="$run_dir/run-state.json" rj="$run_dir/review.json"
  # Repo root so the heredoc can `import sail.review` / `sail.convergence` (the SAME predicates /sail
  # uses) — this script lives at <repo>/config/surf-worker.sh. It is sourced via the
  # ~/.claude/lib/surf-worker.sh SYMLINK (#127), so REALPATH-resolve the source before taking
  # dirname — otherwise dirname lands in ~/.claude/lib and `import sail.review` fails, parking every
  # run (#128). Fall back to the raw path if realpath can't run.
  local _src _repo_root
  _src="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${BASH_SOURCE[0]:-$0}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]:-$0}")"
  _repo_root="$(cd "$(dirname "$_src")/.." 2>/dev/null && pwd || true)"
  # Positively confirm a FULL /sail green from run-state.json (gates) AND review.json (status,
  # findings, non-empty ACs all met, tidiness.blocking, AND review currency). Fail-CLOSED on any
  # parse failure, missing artifact, unexpected shape, non-pass gate, blocking finding, empty/unmet
  # AC, block-tier tidiness, stale fingerprint, or unimportable sail.review → PARK.
  local verdict
  verdict="$(SURF_REPO_ROOT="$_repo_root" python3 - "$rs" "$rj" "$run_dir" "$target" <<'PY' 2>/dev/null || true
import hashlib, json, sys, os

rs_path, rj_path, run_dir, target_arg = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

# run-state.json is REQUIRED to positively confirm green. Missing/garbage → PARK (fail-closed).
if not os.path.exists(rs_path):
    print("PARK"); raise SystemExit(0)
try:
    rs = json.load(open(rs_path))
except Exception:
    print("PARK"); raise SystemExit(0)

gates = rs.get("gates")
if not isinstance(gates, list) or not gates:
    print("PARK"); raise SystemExit(0)
PASS_STATES = {"passed", "skipped"}
for g in gates:
    if not isinstance(g, dict) or str(g.get("status", "")).lower() not in PASS_STATES:
        print("PARK"); raise SystemExit(0)

# review.json must POSITIVELY confirm a FULL /sail green. An absent/garbage review, or any field
# whose shape is unexpected, fails CLOSED (PARK) — we never merge an unconfirmed run.
def park():
    print("PARK"); raise SystemExit(0)

if not os.path.exists(rj_path):
    park()
try:
    rj = json.load(open(rj_path))
except Exception:
    park()
if not isinstance(rj, dict):
    park()

# (3) review completed (a skipped/error/absent status → PARK).
if rj.get("status") != "completed":
    park()

# (4) no CRITICAL/HIGH correctness finding. Shape guard: findings must be a list.
findings = rj.get("findings", [])
if not isinstance(findings, list):
    park()
sev = {str(f.get("severity", "")).upper() for f in findings if isinstance(f, dict)}
if sev & {"CRITICAL", "HIGH"}:
    park()

# (5) acceptance criteria: a NON-EMPTY list, every status == "met" (#124 R7-1 — mirrors
# sail.convergence.acs_all_met, which returns False on an empty/missing list). Shape guards:
# plan_verification must be a dict and acceptance_criteria a non-empty list of dicts.
pv = rj.get("plan_verification", {})
if not isinstance(pv, dict):
    park()
acs = pv.get("acceptance_criteria")
if not isinstance(acs, list) or not acs:   # empty/missing → PARK (no longer fails OPEN)
    park()
for ac in acs:
    if not isinstance(ac, dict) or str(ac.get("status", "")).lower() != "met":
        park()

# (6) no confirmed block-tier tidiness finding. Shape guard: tidiness (when present) must be a
# dict; a non-empty tidiness.blocking → PARK.
tid = rj.get("tidiness", {})
if not isinstance(tid, dict):
    park()
if tid.get("blocking"):
    park()

# (7) review CURRENCY (#124 R7-2): a clean-but-STALE review (written for an earlier diff) must NOT
# read as green, or we'd merge a diff that was never actually reviewed. Reuse /sail's OWN fingerprint
# functions (single source of truth — never reinvent the hashing). Fail-CLOSED on any import or
# compute failure, and MINUS review_current_and_clean's /sail-internal `round` check (the supervisor
# can't know the round).
repo_root = os.environ.get("SURF_REPO_ROOT", "")
if repo_root and repo_root not in sys.path:
    sys.path.insert(0, repo_root)
try:
    from sail.review import diff_fingerprint, plan_fingerprint, domain_fingerprint
except Exception:
    park()   # can't load /sail's hashing → cannot prove currency → PARK

review_target = rj.get("target")
diff_ref = rj.get("diff_ref")
if not review_target or not diff_ref:
    park()

# Resolve the worktree root to compare against: the explicit arg if given, else review.json's
# target — but only after confirming it is a real git worktree root (so a forged/garbage target
# field can't pass the abspath self-comparison trivially).
import subprocess
def _toplevel(path):
    try:
        r = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"],
                           capture_output=True, text=True)
        return os.path.abspath(r.stdout.strip()) if r.returncode == 0 and r.stdout.strip() else None
    except Exception:
        return None

target = target_arg if target_arg else review_target
top = _toplevel(target)
if top is None:
    park()                                   # not a git worktree → can't verify → PARK
target_abs = os.path.abspath(target)
if target_abs != os.path.abspath(review_target):
    park()                                   # building a different tree than was reviewed → PARK
try:
    if rj.get("diff_hash") != diff_fingerprint(target_abs, diff_ref):
        park()                               # diff changed since the review → stale → PARK
    if rj.get("plan_hash") != plan_fingerprint(run_dir):
        park()                               # plan ACs changed since the review → stale → PARK
    current_domain_hash = domain_fingerprint(target_abs)
    stored_domain_hash = rj.get("domain_hash")
    if stored_domain_hash is None:
        if current_domain_hash != hashlib.sha256(b"").hexdigest():
            park()                           # domain memory changed since the review → stale → PARK
    elif stored_domain_hash != current_domain_hash:
        park()                               # domain memory changed since the review → stale → PARK
except Exception:
    park()                                   # fingerprint compute failed → can't prove fresh → PARK

# COMMIT-EXISTENCE backstop (#136 review HIGH): a green+current review.json is written during /sail
# Stage 3, BEFORE the Stage 4 commit. A worker that EXITED after writing it but before committing
# (crash/kill in the Stage3->4 window, or a #139-contract violation that backgrounds the commit)
# would otherwise read GREEN here, and /surf would "merge" a sail/<issue> branch with ZERO commits —
# closing the issue with no code landed (the work LOST). The review's currency check matches on the
# still-uncommitted WORKTREE diff, so it cannot catch this. Add a DETERMINISTIC guard independent of
# the prompt contract: the build branch (HEAD of the worktree) must have >=1 commit ahead of the
# reviewed base (diff_ref). No commit ahead → PARK (fail-closed).
try:
    rv = subprocess.run(["git", "-C", target_abs, "rev-list", "--count", "%s..HEAD" % diff_ref],
                        capture_output=True, text=True)
    if rv.returncode != 0 or not rv.stdout.strip().isdigit() or int(rv.stdout.strip()) < 1:
        park()                               # no commit ahead of base → exited-without-commit → PARK
except Exception:
    park()                                   # can't prove a commit exists → PARK

print("GREEN")
PY
)"
  if [ "$verdict" = "GREEN" ]; then
    return 0
  fi
  surf_worker_log "run-dir $run_dir not positively green (verdict='${verdict:-PARK}') — fail-closed park"
  return 1
}

# surf_worker_cleanup <run-dir> <branch> — safe per-worker cleanup. Never force-deletes a directory
# tree. Removes only what this worker created: if the issue was built in a git worktree,
# `git worktree remove` it WITHOUT --force (so it refuses to drop uncommitted work). The stable
# run-dir (the resume checkpoint) is intentionally LEFT in place — resume reuses it. Mirrors
# convoy's _convoy_safe_cleanup_issue spirit.
#
# Process LIVENESS is the HARNESS's job now (#124 final decision): the worker is a harness
# background task, so do NOT call cleanup until the supervisor's poll sees that task exited (or its
# terminus artifacts present). There is no bash worker.pid live-guard — the harness owns liveness;
# git's own without-`--force` refusal is the remaining safety net against clobbering live work.
surf_worker_cleanup() {
  local run_dir="${1:-}" branch="${2:-}" wt
  [ -n "$branch" ] && surf_worker_log "cleanup for branch ${branch} (run-dir ${run_dir})" || true
  # Remove a per-issue worktree (if one was used) WITHOUT --force; prune dangling admin entries.
  if [ -f "$run_dir/worktree" ]; then
    wt="$(cat "$run_dir/worktree" 2>/dev/null || true)"
    if [ -n "$wt" ]; then
      git worktree remove "$wt" 2>/dev/null || surf_worker_log "worktree remove declined for $wt (uncommitted work?) — leaving intact"
      git worktree prune 2>/dev/null || true
    fi
  fi
  return 0
}

# Sourcing (the runtime + unit test) gets the functions without running anything. ${BASH_SOURCE[0]:-}
# is zsh-safe under `set -u` (zsh leaves BASH_SOURCE unset) — #128.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  surf_worker_log "surf-worker.sh is a function library; source it, don't execute it."
  exit 0
fi
