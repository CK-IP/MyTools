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
    if created.returncode != 0:
        raise ValueError(
            "sail --diff: cannot create baseline worktree for ref "
            f"{diff_ref!r}: {created.stderr.strip()}"
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


def run(run_dir=None, target=None, cov_fail_under=0, run_id=None, diff_ref=None, baseline_dir=None, review=True, dual_lens=False):
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

    next_seq = max((gate.get("seq") or 0 for gate in state.gates), default=0) + 1

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
        prior = _completed_review(run_dir) if scope_match else None
        if prior is not None and prior.get("diff_hash") != review_mod.diff_fingerprint(target_root, diff_ref):
            # Same target+ref, but the diff CONTENT changed under a moving ref (e.g. HEAD): the
            # recorded review is stale. Drop it so the run re-reviews the current diff (#45).
            prior = None
            decision_log.review_marker("prior review stale (diff content changed under same ref); re-reviewing")
        if prior is not None and prior.get("plan_hash") != review_mod.plan_fingerprint(run_dir):
            # HIGH-1 (Gate F): the plan's acceptance criteria changed in the shared run-dir since
            # the cached review. A stale review would skip the new ACs — drop it and re-review
            # (mirrors the #45 diff-content reuse gate, applied to the plan->review spine).
            prior = None
            decision_log.review_marker("prior review stale (plan acceptance criteria changed); re-reviewing")
        if prior is not None and review_mod.load_plan_acs(run_dir)[1] == "malformed":
            # HIGH-4 (Gate F): plan.json is now malformed. The fingerprint can't distinguish a
            # malformed plan from absent/no-AC (both hash []), so a stale completed review could
            # be reused instead of failing closed. Refuse reuse → re-review fails closed (RT-2).
            prior = None
            decision_log.review_marker("prior review stale (plan.json now malformed); re-reviewing (fail-closed)")
        if prior is not None and dual_lens and "lens2" not in (prior.get("lenses") or []):
            # HIGH-3 (Gate F): a --dual-lens resume must not reuse a single-lens cached review —
            # lens2 would never run. Invalidate when the requested mode needs a lens the cache lacks.
            prior = None
            decision_log.review_marker("prior review stale (--dual-lens requested but cache is single-lens); re-reviewing")
        if prior is not None:
            # Resume of the same scope: reuse the completed review rather than re-invoking the
            # backend, but recompute blocking from its findings AND its recorded plan_verification
            # (an unmet AC still blocks on reuse) so a prior blocking review still blocks.
            prior_unmet = any(
                ac.get("status") == "unmet"
                for ac in prior.get("plan_verification", {}).get("acceptance_criteria", [])
            )
            review_rc = 1 if (review_mod.has_blocking(prior["findings"]) or prior_unmet) else 0
            decision_log.review_marker("reused prior completed review (resumed)")
        else:
            if review_mod.backend_available():
                review_rc = review_mod.run_review(target_root, diff_ref, run_dir=run_dir, advisory=False, dual_lens=dual_lens)
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
