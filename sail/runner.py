from __future__ import annotations

import inspect
import json
import os
import shutil
import subprocess
import uuid
from datetime import datetime, timezone
from glob import glob

from sail import delta
from sail import checkers as checkers_mod
from sail.checkers import build_registry, CheckerContext
from sail.decisionlog import DecisionLog
from sail.runstate import RunState, _utc_now_iso


def _default_run_id() -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"{stamp}-{uuid.uuid4().hex[:8]}"


def _marker_path() -> str:
    return os.path.join(os.getcwd(), ".sail", "last-test-failed")


def _write_failure_marker() -> None:
    marker_path = _marker_path()
    os.makedirs(os.path.dirname(marker_path), exist_ok=True)
    with open(marker_path, "w", encoding="utf-8") as fh:
        fh.write(f"failed {_utc_now_iso()}\n")


def _clear_failure_marker() -> None:
    try:
        os.remove(_marker_path())
    except FileNotFoundError:
        pass


def _run_command(argv):
    try:
        result = subprocess.run(argv, check=False)
    except FileNotFoundError:
        return 127
    return result.returncode


def run_tests(cmd=None) -> int:
    cmd = list(cmd or [])
    if cmd:
        rc = _run_command(cmd)
        if rc != 0:
            _write_failure_marker()
            return rc
        _clear_failure_marker()
        return 0

    test_paths = sorted(glob(os.path.join("tests", "test_sail_*.sh")))
    rc = 0
    for test_path in test_paths:
        rc = _run_command(["bash", test_path])
        if rc != 0:
            break

    if rc != 0:
        _write_failure_marker()
    else:
        _clear_failure_marker()
    return rc


def _build_command(checker, target, artifact_path, ctx):
    # Call checker.build_command, passing the optional ctx ONLY when the (possibly overridden)
    # build_command accepts a third parameter. A legacy 2-arg override (e.g. a test double or a
    # checker that ignores ctx) is invoked unchanged — the contract extension is non-breaking.
    try:
        params = inspect.signature(checker.build_command).parameters
    except (TypeError, ValueError):
        params = {}
    if len(params) >= 3:
        return checker.build_command(target, artifact_path, ctx)
    return checker.build_command(target, artifact_path)


def _run_checker(checker, target, artifact_path, ctx=None):
    # Run one checker, return its return code. Shared by the primary run and
    # diff-mode baseline generation.
    result = subprocess.run(
        _build_command(checker, target, artifact_path, ctx),
        cwd=checker.cwd(target),
        capture_output=True, text=True,
    )
    if checker.stdout_artifact:
        # The tool emits its findings to stdout (no file flag, e.g. shellcheck -f json),
        # so persist the captured stdout to the artifact BEFORE returning — this runs for
        # diff-mode baseline generation too (it routes through _run_checker). Write stdout
        # verbatim: a genuinely empty stdout (tool crash) must yield an unreadable artifact
        # that fails closed downstream — never mask it as "[]".
        os.makedirs(os.path.dirname(artifact_path), exist_ok=True)
        with open(artifact_path, "w", encoding="utf-8") as fh:
            fh.write(result.stdout)
    return result.returncode


def _remove_worktree(target, path):
    subprocess.run(
        ["git", "-C", target, "worktree", "remove", "--force", path],
        capture_output=True, text=True,
    )
    if os.path.exists(path):
        shutil.rmtree(path, ignore_errors=True)


def _resolve_diff_base(target, diff_ref):
    """Pin a diff ref to the merge-base SHA of (diff_ref, HEAD).

    Called once at run-start so the diff base is immutable for the entire run —
    concurrent main movement cannot enter the diff mid-run (#87). Using merge-base
    (not raw rev-parse) means a moved base ref still resolves to the branch-point
    the run was isolated from, not the new tip.

    Returns the full 40-char SHA. Raises ValueError on an unknown ref.
    """
    result = subprocess.run(
        ["git", "-C", target, "merge-base", diff_ref, "HEAD"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise ValueError(
            f"sail --diff: cannot compute merge-base for {diff_ref!r} "
            f"(rc={result.returncode}): {result.stderr.strip()}"
        )
    return result.stdout.strip()


def _prestage_untracked(target, run_dir=None):
    # Diff-mode pre-stage (#76): `git diff diff_ref` omits untracked files, so a brand-new
    # test/source file the build just created is invisible to the diff-scoped gates and the
    # T6 scope-guard until it is staged. Mirror /ship's precedent — list untracked, non-ignored
    # paths NUL-safe (`-z`) and `git add -N` them, so they appear as zero→full additions in the
    # diff and get scanned. Intent-to-add stages no content; the eventual commit normalizes the
    # index, so no teardown is needed (same as /ship relies on). Best-effort: a non-zero git rc
    # or an OSError (e.g. git absent) must never abort the run — the gates still run on the tracked
    # changes — so failures here are swallowed.
    try:
        listed = subprocess.run(
            ["git", "-C", target, "ls-files", "-z", "--others", "--exclude-standard"],
            capture_output=True, text=True,
        )
        if listed.returncode != 0 or not listed.stdout:
            return
        paths = [p for p in listed.stdout.split("\0") if p]
        # Never pre-stage Sail's own run artifacts (run-state.json, review.json, baseline/, …):
        # they live under run_dir, and if the target repo does NOT ignore that path they would
        # otherwise be intent-to-added into the reviewed diff — polluting gate/review scope and
        # leaking run state / absolute paths to the review backend (#76 round-3). Exclude anything
        # at or under run_dir. Guard: only exclude when run_dir is a STRICT subpath of target —
        # if run_dir IS the target root (a misconfiguration), excluding everything under it would
        # filter out every user file and silently disable the pre-stage, so skip the exclusion.
        if run_dir:
            rd = os.path.abspath(run_dir)
            target_abs = os.path.abspath(target)
            if rd != target_abs and rd.startswith(target_abs + os.sep):
                paths = [
                    p for p in paths
                    if (ap := os.path.abspath(os.path.join(target, p))) != rd
                    and not ap.startswith(rd + os.sep)
                ]
        if not paths:
            return
        # Feed the NUL-delimited path list to `git add -N` via stdin (--pathspec-from-file=-
        # --pathspec-file-nul) rather than as argv. This is genuinely NUL-safe — it handles spaces
        # AND newlines in pathnames (AC#4) — and, crucially, has no ARG_MAX ceiling: a repo with
        # very many untracked files can never overflow the argv and silently skip pre-staging,
        # which would leave new files invisible to the diff-scoped gates (the hole this closes).
        # --literal-pathspecs: each line is a literal path, never Git pathspec magic — a file named
        # e.g. ":(glob)foo.py" must not be parsed as a pathspec signature and silently skipped.
        subprocess.run(
            ["git", "-C", target, "--literal-pathspecs", "add", "-N",
             "--pathspec-from-file=-", "--pathspec-file-nul"],
            input="\0".join(paths) + "\0", capture_output=True, text=True,
        )
    except OSError:
        return


def _sweep_stale_baseline_src(target):
    # Diff-mode only: reap any <target>/.sail/runs/*/baseline-src checkouts before the
    # current-tree gate scan. bandit -r ignores .gitignore, so a stale baseline-src left
    # by an interrupted prior diff run would be scanned as part of the current tree; its
    # files are absent from the clean baseline (checked out at diff_ref) → register as
    # "new" → spurious block (#49). baseline-src is short-lived by design (created and
    # removed within one _generate_baseline call), so any present at scan time is an
    # abandoned remnant. _remove_worktree deregisters the git worktree AND rmtrees the dir.
    # The current run's own baseline artifacts are already captured under <run_dir>/baseline/
    # before this runs, so reaping baseline-src checkouts cannot empty the baseline (no RT-1).
    for path in glob(os.path.join(target, ".sail", "runs", "*", "baseline-src")):
        _remove_worktree(target, path)


def _generate_baseline(registry, target, diff_ref, run_dir):
    # Detached worktree of diff_ref from target's repo; run the available checkers there;
    # write artifacts into <run_dir>/baseline/. Returns (baseline_dir, baseline_root).
    # Raises on an invalid diff_ref (never silently degrades to whole-repo).
    baseline_dir = os.path.join(run_dir, "baseline")
    baseline_src = os.path.join(run_dir, "baseline-src")
    os.makedirs(baseline_dir, exist_ok=True)
    subprocess.run(["git", "-C", target, "worktree", "prune"], capture_output=True, text=True)
    _remove_worktree(target, baseline_src)
    created = subprocess.run(
        ["git", "-C", target, "worktree", "add", "--detach", baseline_src, diff_ref],
        capture_output=True, text=True,
    )
    use_clone = False
    if created.returncode != 0:
        use_clone = True
        shutil.rmtree(baseline_src, ignore_errors=True)
        cloned = subprocess.run(
            ["git", "clone", "--no-checkout", target, baseline_src],
            capture_output=True, text=True,
        )
        if cloned.returncode != 0:
            raise ValueError(
                "sail --diff: cannot create baseline checkout for ref "
                f"{diff_ref!r}: {cloned.stderr.strip()}"
            )
        checked_out = subprocess.run(
            ["git", "-C", baseline_src, "checkout", "--detach", diff_ref],
            capture_output=True, text=True,
        )
        if checked_out.returncode != 0:
            raise ValueError(
                "sail --diff: cannot checkout baseline ref "
                f"{diff_ref!r}: {checked_out.stderr.strip()}"
            )
    baseline_ctx = CheckerContext(diff_ref=diff_ref, mode="diff", target_root=os.path.abspath(baseline_src))
    try:
        for checker in registry:
            if not checker.available():
                continue
            if checker.artifact in delta.DIFF_ONLY_ARTIFACTS:
                # diff-coverage's findings derive from the CURRENT diff-cover report, not a
                # baseline multiset delta — skip it during baseline generation (lens1-9548).
                continue
            artifact_path = os.path.join(baseline_dir, checker.artifact)
            if os.path.exists(artifact_path):
                os.remove(artifact_path)
            try:
                _run_checker(checker, baseline_src, artifact_path, baseline_ctx)
            except Exception:
                pass  # failed baseline checker -> missing artifact -> treated as empty baseline
        return baseline_dir, baseline_src
    finally:
        if use_clone:
            shutil.rmtree(baseline_src, ignore_errors=True)
        else:
            _remove_worktree(target, baseline_src)


def _completed_review(run_dir):
    # Return the prior review.json dict iff a review actually COMPLETED for this run-dir
    # (status "completed"); else None. A missing/errored/unparseable/partial artifact
    # returns None so a resumed run re-runs the review rather than reusing a non-result.
    path = os.path.join(run_dir, "review.json")
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    # Reuse only a well-formed completed result: status "completed" AND a findings LIST.
    # Blocking is recomputed from `findings` (the authoritative signal run_review itself
    # uses) — never from the derived `counts` cache — so a stale/garbled counts value can
    # never downgrade a blocking review on reuse. A malformed artifact (missing/non-list
    # findings) returns None so the review re-runs fresh.
    if not (isinstance(data, dict) and data.get("status") == "completed"):
        return None
    return data if isinstance(data.get("findings"), list) else None


def run(run_dir=None, target=None, cov_fail_under=0, run_id=None, diff_ref=None, baseline_dir=None, review=True, dual_lens=False, round=1, tidiness=False, red_team=False):
    registry = build_registry()

    if run_dir is None:
        if run_id is None:
            run_id = _default_run_id()
        run_dir = os.path.join(os.getcwd(), ".sail", "runs", run_id)

    state_path = os.path.join(run_dir, "run-state.json")
    resumed = os.path.exists(state_path)
    if resumed:
        state = RunState.load(run_dir)
    else:
        state = RunState.init(run_dir, [checker.name for checker in registry])
        if run_id is not None:
            state.run_id = run_id
            state.data["run_id"] = run_id
        state.save()

    # Capture the prior run's review scope (target + diff) before we overwrite it below, so a
    # resumed run that changed --target/--diff does NOT reuse a stale review (see review block).
    prior_target = state.data.get("target")
    prior_diff_ref = state.data.get("diff_ref")

    if target is None:
        target = "."
    target_root = os.path.abspath(target)
    state.data["target"] = target_root

    if diff_ref is not None:
        # Pin to the merge-base SHA so the diff base is immutable for the entire run.
        # Concurrent main movement cannot mutate a SHA; merge-base resolves to the
        # branch-point even after the base ref moves forward (#87).
        # On resume: if --diff is unchanged the resolved SHA equals prior_diff_ref so
        # scope_match stays True and the prior review is reused; if --diff changed the
        # SHA differs and scope_match is False → re-review (T14 regression preserved).
        diff_ref = _resolve_diff_base(target_root, diff_ref)

    mode = "diff" if diff_ref else "baseline" if baseline_dir else "whole-repo"
    state.data["mode"] = mode
    state.data["diff_ref"] = diff_ref
    state.save()

    decision_log = DecisionLog(run_dir)
    if resumed:
        decision_log.resume_marker()

    baseline_root = None
    if mode == "diff":
        decision_log.mode_marker(mode, diff_ref)
        # Pre-stage untracked, non-ignored files (#76) BEFORE the diff is computed — both the
        # current-tree gate scan and review_mod.diff_fingerprint derive scope from `git diff
        # diff_ref`, which omits untracked files. Runs on fresh and resumed --diff invocations
        # (this branch executes every time), so a file created between rounds is picked up next
        # round; it is idempotent, so the re-run is a clean no-op. run_dir is excluded so Sail's
        # own artifacts under it never enter the reviewed diff (matters when the target does not
        # ignore the run-dir path).
        _prestage_untracked(target_root, run_dir)
        baseline_dir, baseline_root = _generate_baseline(registry, target_root, diff_ref, run_dir)
        # Reap any stale .sail/runs/*/baseline-src remnants now that the baseline artifacts
        # are captured — before the current-tree scan, so bandit (which ignores .gitignore)
        # cannot count their files as "new" findings vs the clean baseline (#49).
        _sweep_stale_baseline_src(target_root)
    elif mode == "baseline":
        if os.path.realpath(baseline_dir) == os.path.realpath(run_dir):
            raise ValueError("sail --baseline: baseline dir must differ from --run-dir")
        try:
            with open(os.path.join(baseline_dir, "run-state.json"), encoding="utf-8") as fh:
                baseline_root = json.load(fh).get("target")
        except Exception:
            baseline_root = None
        decision_log.mode_marker(mode, baseline_dir)

    terminal_statuses = {"passed", "failed", "skipped"}
    gates_by_name = {gate["name"]: gate for gate in state.gates}

    # Reconcile the resumed gate set against the current registry: a run-state.json that
    # predates a newly-added checker lacks its gate, which would KeyError at the index sites
    # below (the per-checker loop AND the blocking_failed comprehension). Backfill any missing
    # registry checker as a fresh pending gate (RunState.init shape), in registry order, so the
    # in-loop next_seq logic assigns its seq (monotonic, gap-free).
    backfilled = False
    for checker in registry:
        if checker.name not in gates_by_name:
            gate = {
                "name": checker.name,
                "status": "pending",
                "artifact": None,
                "rc": None,
                "reason": None,
                "seq": None,
                "started_at": None,
                "finished_at": None,
            }
            state.gates.append(gate)
            gates_by_name[checker.name] = gate
            backfilled = True
    if backfilled:
        state.save()

    # #79: a resumed run-dir carries each gate's terminal status from the prior round. In
    # --diff mode that status is valid only for the diff content it was computed against; if
    # the diff changed since (the convergence loop fixed a gate finding), the cached terminal
    # status is stale and would mask the fix. Mirror the review block's reuse gate (below):
    # store the diff fingerprint when gates run, and on resume reset every terminal gate to
    # pending when the diff scope (target/diff_ref) or content changed — or when the fingerprint
    # is missing/uncomputable (fail-safe toward re-running, never toward reusing a stale green).
    # Scoped to diff mode; baseline/whole-repo resume keeps its terminal-preserving behavior.
    if mode == "diff":
        from sail import review as review_mod
        try:
            gate_fp = review_mod.diff_fingerprint(target_root, diff_ref)
        except Exception:
            # diff_fingerprint runs `git diff diff_ref`; an unresolvable comparison ref on
            # resume (deleted branch, rewritten history) would normally abort _generate_baseline
            # above, but if the fingerprint is ever uncomputable here, treat it as None and force
            # a re-run rather than aborting — never reuse a stale green on uncertainty (AC#3).
            gate_fp = None
        # Reset terminal gate status on resume when ANY input the gate results depend on changed:
        # the diff SCOPE (target or resolved diff_ref) OR the diff CONTENT fingerprint — or when
        # the fingerprint is missing/uncomputable. Mirrors the review block's scope_match
        # (prior_target/prior_diff_ref) PLUS its diff_hash reuse gate, so a same-content diff
        # against a different target/base can't preserve a stale gate (redteam-1fd74a2b0c7e).
        stored_fp = state.data.get("gates_diff_hash")
        scope_changed = prior_target != target_root or prior_diff_ref != diff_ref
        stale = gate_fp is None or scope_changed or stored_fp != gate_fp
        if scope_changed:
            reset_reason = "diff scope (target/diff_ref) changed since prior round"
        elif gate_fp is None:
            reset_reason = "diff fingerprint uncomputable (fail-safe re-run)"
        elif stored_fp is None:
            reset_reason = "no stored gate fingerprint (fail-safe re-run)"
        else:
            reset_reason = "diff content changed since prior round"
        if resumed and stale:
            # Assign each reset gate a fresh, strictly-INCREASING seq drawn from the high-water
            # mark of all current seqs — never None. The decision-log keys entries by
            # [gate=<name> seq=<n>] and de-dups, so a re-used seq suppresses the re-run's verdict
            # and leaves the audit log showing the stale (pre-fix) decision. Clearing to None
            # would collapse next_seq back to 1 when every gate is terminal (the normal
            # completed-round case), re-colliding with the prior round's keys — so monotonic
            # high-water seqs are required, not None (redteam-4c2dc5a2a662).
            reset_seq = max((gate.get("seq") or 0 for gate in state.gates), default=0)
            reset_count = 0
            reuse_count = 0
            registry_names = {checker.name for checker in registry}
            checker_by_name = {checker.name: checker for checker in registry}
            # #105 per-gate reuse: when the ONLY stale trigger is a same-scope diff MOVE (scope
            # unchanged AND both fingerprints present), reset only the gates whose dependency
            # file-types appear in the changed-file set; keep the rest green (reused) — the
            # efficiency win. EVERY other stale trigger (scope change / missing / uncomputable
            # fingerprint) is uncertainty -> reset ALL terminal gates (the #79 fail-safe,
            # unchanged). The changed-file list is computed ONCE here, from the same `git diff
            # diff_ref` the gates scan — after _prestage_untracked (line 339) has already
            # hydrated new/untracked files into that diff, so a newly-relevant file is seen.
            selective = (not scope_changed) and gate_fp is not None and stored_fp is not None
            changed = None
            if selective:
                try:
                    changed = review_mod.changed_files(target_root, diff_ref)
                except Exception:
                    # Could not compute the changed set -> fail safe: reset everything.
                    selective = False
            for gate in state.gates:
                # Reset only gates the current registry will actually re-run. A gate left over from a
                # wider prior registry (e.g. a since-narrowed SAIL_CHECKERS) is never visited by the
                # per-checker loop, so resetting it to pending would strand it permanently non-green
                # and inflate the rerun count (lens2-da384f98abcb).
                if gate.get("status") in terminal_statuses and gate["name"] in registry_names:
                    # Reuse ONLY an already-green (passed) gate: a failed gate must re-run to
                    # confirm the fix, and a skipped/tool-unavailable gate is cheap to re-evaluate
                    # and must not preserve a transient skip — so both always reset (#105 review:
                    # the optimization is "skip already-green gates", never "preserve any verdict").
                    if selective and gate.get("status") == "passed":
                        checker = checker_by_name.get(gate["name"])
                        # affected_by fails safe (True) on an empty/unknown changed set, so a None
                        # `changed` here would have flipped selective off above. Reuse ONLY when the
                        # gate's own inputs are provably absent from the diff -> its green verdict
                        # cannot have changed; leave its status/seq intact so the prior verdict and
                        # its decision-log entry still stand.
                        if checker is not None and not checker.affected_by(changed):
                            reuse_count += 1
                            continue
                    gate["status"] = "pending"
                    gate["rc"] = None
                    gate["reason"] = None
                    gate["artifact"] = None
                    gate["new_findings_count"] = None
                    gate["started_at"] = None
                    gate["finished_at"] = None
                    reset_seq += 1
                    gate["seq"] = reset_seq
                    reset_count += 1
            if reset_count:
                decision_log.gate_reset_marker(reset_count, reset_reason)
            if reuse_count:
                decision_log.gate_reuse_marker(reuse_count)
        state.data["gates_diff_hash"] = gate_fp
        state.save()

    next_seq = max((gate.get("seq") or 0 for gate in state.gates), default=0) + 1

    # Scanner-triage context (#69): collect each diff-mode gate's already-computed `new`
    # findings as we go, so they can be fed into the LLM review below as triage context
    # (gates run FIRST, review second — series, not parallel). Advisory only: this never
    # changes the gate decision (blocking_failed stays authoritative); it just lets the
    # reviewer corroborate real alarms / flag false positives instead of re-deriving them.
    scanner_findings = []

    for checker in registry:
        gate = gates_by_name[checker.name]
        gate["mode"] = mode
        status = gate.get("status")

        if status in terminal_statuses:
            decision = "block" if status == "failed" and checker.is_blocking(target_root, mode) else "continue"
            decision_log.append(gate, decision)
            continue

        if gate.get("seq") is None:
            gate["seq"] = next_seq
            next_seq += 1

        gate["status"] = "running"
        gate["started_at"] = _utc_now_iso()
        gate["finished_at"] = None
        state.save()

        artifact_path = os.path.join(run_dir, checker.artifact)
        if mode != "diff" and checker.artifact in delta.DIFF_ONLY_ARTIFACTS:
            # diff-coverage is a diff-mode concept (coverage of CHANGED lines vs a compare ref);
            # in whole-repo mode there is no diff to scope to — record a clean, non-blocking skip
            # instead of invoking diff-cover with no compare ref (lens1-cbde).
            gate["status"] = "skipped"
            gate["rc"] = None
            gate["reason"] = f"not applicable in {mode} mode (diff-only gate)"
            gate["artifact"] = None
            gate["new_findings_count"] = None
            gate["finished_at"] = _utc_now_iso()
            state.save()
            decision_log.append(gate, "continue")
            continue
        if not checker.available():
            gate["status"] = "skipped"
            gate["rc"] = None
            gate["reason"] = f"tool-unavailable: {checker.tool}"
            gate["artifact"] = None
            gate["new_findings_count"] = None
            gate["finished_at"] = _utc_now_iso()
            state.save()
            decision_log.append(gate, "continue")
            continue

        if os.path.exists(artifact_path):
            os.remove(artifact_path)
        run_ctx = CheckerContext(diff_ref=diff_ref, mode=mode, target_root=target_root)
        rc = _run_checker(checker, target_root, artifact_path, run_ctx)
        gate["rc"] = rc
        gate["artifact"] = checker.artifact

        if mode == "whole-repo":
            status = checker.classify(rc)
            gate["status"] = status
            gate["reason"] = checker.reason(rc)
            gate["new_findings_count"] = None
        else:
            kind = delta.KIND_BY_ARTIFACT.get(checker.artifact)
            base_artifact = os.path.join(baseline_dir, checker.artifact)
            if kind == "diffcoverage":
                # diff-coverage is about the CURRENT change's uncovered lines (the diff-cover
                # report already scopes to changed lines vs the compare ref), threshold-gated —
                # not a baseline multiset delta. [] when advisory (no threshold) or coverage
                # >= threshold. A missing report (e.g. no coverage.xml because pytest produced
                # none) fails closed ONLY in threshold mode — in advisory mode it cannot block,
                # so a missing report is a clean [] (lens1-153e/lens2-f5f0).
                threshold = checkers_mod.diff_coverage_threshold(target_root)
                if not os.path.isfile(artifact_path):
                    new = [] if threshold is None else None
                else:
                    new = delta.diffcoverage_records(artifact_path, threshold)
            else:
                new = (
                    delta.new_findings(artifact_path, base_artifact, kind, target_root, baseline_root)
                    if kind
                    else None
                )
            if new is None:
                status = "failed"
                gate["status"] = status
                gate["new_findings_count"] = None
                gate["reason"] = f"mode={mode} artifact=unreadable rc={rc}"
            else:
                n = len(new)
                status = "failed" if n > 0 else "passed"
                gate["status"] = status
                gate["new_findings_count"] = n
                gate["reason"] = f"mode={mode} new={n}"
                if new and mode == "diff" and kind != "diffcoverage" and checker.is_blocking(target_root, mode):
                    # Thread this gate's new findings into the review's triage context (#69).
                    # The triage prompt frames these as real defects to corroborate, so the set
                    # must be exactly "real defect" signals: only BLOCKING gates, and NOT
                    # diff-coverage — an uncovered changed line is the absence of a test, not a
                    # defect, and diff-coverage's gate is blocking in threshold mode (so the
                    # is_blocking check alone would not exclude it). Excluding it by kind keeps
                    # coverage gaps out of the "corroborate as a real defect" framing.
                    scanner_findings.append({
                        "tool": checker.name,
                        "lines": [delta.finding_descriptor(r) for r in new],
                    })

        gate["finished_at"] = _utc_now_iso()
        state.save()

        decision = "block" if status == "failed" and checker.is_blocking(target_root, mode) else "continue"
        decision_log.append(gate, decision)

    blocking_failed = any(
        gate.get("status") == "failed" and checker.is_blocking(target_root, mode)
        for checker in registry
        for gate in [gates_by_name[checker.name]]
    )

    review_rc = 0
    if review and mode == "diff":
        from sail import review as review_mod
        # Reuse a prior review only on a genuine resume of the SAME scope (target + diff).
        # A resume that changed --target/--diff must re-review, never reuse a stale result.
        scope_match = resumed and prior_target == target_root and prior_diff_ref == diff_ref
        reuse_candidate = _completed_review(run_dir) if scope_match else None
        if round > 1:
            reuse_candidate = None
        if reuse_candidate is not None and reuse_candidate.get("diff_hash") != review_mod.diff_fingerprint(target_root, diff_ref):
            # Same target+ref, but the diff CONTENT changed under a moving ref (e.g. HEAD): the
            # recorded review is stale. Drop it so the run re-reviews the current diff (#45).
            reuse_candidate = None
            decision_log.review_marker("prior review stale (diff content changed under same ref); re-reviewing")
        if reuse_candidate is not None and reuse_candidate.get("plan_hash") != review_mod.plan_fingerprint(run_dir):
            # HIGH-1 (Gate F): the plan's acceptance criteria changed in the shared run-dir since
            # the cached review. A stale review would skip the new ACs — drop it and re-review
            # (mirrors the #45 diff-content reuse gate, applied to the plan->review spine).
            reuse_candidate = None
            decision_log.review_marker("prior review stale (plan acceptance criteria changed); re-reviewing")
        if reuse_candidate is not None and review_mod.load_plan_acs(run_dir)[1] == "malformed":
            # HIGH-4 (Gate F): plan.json is now malformed. The fingerprint can't distinguish a
            # malformed plan from absent/no-AC (both hash []), so a stale completed review could
            # be reused instead of failing closed. Refuse reuse → re-review fails closed (RT-2).
            reuse_candidate = None
            decision_log.review_marker("prior review stale (plan.json now malformed); re-reviewing (fail-closed)")
        if reuse_candidate is not None and dual_lens and "lens2" not in (reuse_candidate.get("lenses") or []):
            # HIGH-3 (Gate F): a --dual-lens resume must not reuse a single-lens cached review —
            # lens2 would never run. Invalidate when the requested mode needs a lens the cache lacks.
            reuse_candidate = None
            decision_log.review_marker("prior review stale (--dual-lens requested but cache is single-lens); re-reviewing")
        if reuse_candidate is not None and tidiness and "tidiness" not in reuse_candidate:
            # #63: a --tidiness resume must not reuse a cache that lacks the advisory tidiness block —
            # the tidiness lens would be silently skipped. Mirrors the --dual-lens reuse guard above.
            reuse_candidate = None
            decision_log.review_marker("prior review stale (--tidiness requested but cache has no tidiness block); re-reviewing")
        if reuse_candidate is not None and red_team and "red_team" not in reuse_candidate:
            # #66: a forced --red-team resume must not reuse a cache with no red_team block — the
            # escalation would be silently skipped. (Auto-triggered high-stakes runs are covered by
            # the diff-content reuse gate above: an unchanged diff keeps the same high-stakes verdict
            # and its findings already live in the cached `findings`.) Mirrors the --tidiness guard.
            reuse_candidate = None
            decision_log.review_marker("prior review stale (--red-team requested but cache has no red_team block); re-reviewing")
        if reuse_candidate is not None:
            # Resume of the same scope: reuse the completed review rather than re-invoking the
            # backend, but recompute blocking from its findings AND its recorded plan_verification
            # (an unmet AC still blocks on reuse) so a prior blocking review still blocks.
            prior_unmet = any(
                ac.get("status") == "unmet"
                for ac in reuse_candidate.get("plan_verification", {}).get("acceptance_criteria", [])
            )
            # #80: a confirmed block-tier code-health finding still blocks on reuse — recompute it
            # alongside findings/ACs so a resume can never silently drop a code-health block.
            prior_code_health_block = bool((reuse_candidate.get("tidiness") or {}).get("blocking"))
            review_rc = 1 if (review_mod.has_blocking(reuse_candidate["findings"])
                              or prior_unmet or prior_code_health_block) else 0
            decision_log.review_marker("reused prior completed review (resumed)")
        else:
            if review_mod.active_review_available(round):
                review_rc = review_mod.run_review(target_root, diff_ref, run_dir=run_dir, advisory=False, dual_lens=dual_lens, round=round, tidiness=tidiness, scanner_findings=scanner_findings, red_team=red_team)
            else:
                # never-mask: review was requested but no backend can run it — fail closed,
                # don't let the change pass as if it had been reviewed.
                decision_log.review_marker(
                    "ERROR: review backend unavailable — failed closed (use --no-review for gates-only)"
                )
                print(
                    "sail run: review backend unavailable — failing closed "
                    "(install `claude`/set SAIL_REVIEW_CMD, or pass --no-review for gates-only)"
                )
                review_rc = 1

    return 1 if (blocking_failed or review_rc) else 0
