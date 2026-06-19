from __future__ import annotations

import json
import os
import shutil
import subprocess
import uuid
from datetime import datetime, timezone
from glob import glob

from sail import delta
from sail.checkers import build_registry
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


def _run_checker(checker, target, artifact_path):
    # Run one checker, return its return code. Shared by the primary run and
    # diff-mode baseline generation.
    return subprocess.run(
        checker.build_command(target, artifact_path),
        cwd=checker.cwd(target),
        capture_output=True, text=True,
    ).returncode


def _remove_worktree(target, path):
    subprocess.run(
        ["git", "-C", target, "worktree", "remove", "--force", path],
        capture_output=True, text=True,
    )
    if os.path.exists(path):
        shutil.rmtree(path, ignore_errors=True)


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
    try:
        for checker in registry:
            if not checker.available():
                continue
            artifact_path = os.path.join(baseline_dir, checker.artifact)
            if os.path.exists(artifact_path):
                os.remove(artifact_path)
            try:
                _run_checker(checker, baseline_src, artifact_path)
            except Exception:
                pass  # failed baseline checker -> missing artifact -> treated as empty baseline
        return baseline_dir, baseline_src
    finally:
        _remove_worktree(target, baseline_src)


def run(run_dir=None, target=None, cov_fail_under=0, run_id=None, diff_ref=None, baseline_dir=None, review=True):
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

    if target is None:
        target = "."
    target_root = os.path.abspath(target)
    state.data["target"] = target_root

    mode = "diff" if diff_ref else "baseline" if baseline_dir else "whole-repo"
    state.data["mode"] = mode
    state.save()

    decision_log = DecisionLog(run_dir)
    if resumed:
        decision_log.resume_marker()

    baseline_root = None
    if mode == "diff":
        decision_log.mode_marker(mode, diff_ref)
        baseline_dir, baseline_root = _generate_baseline(registry, target_root, diff_ref, run_dir)
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
    next_seq = max((gate.get("seq") or 0 for gate in state.gates), default=0) + 1

    for checker in registry:
        gate = gates_by_name[checker.name]
        gate["mode"] = mode
        status = gate.get("status")

        if status in terminal_statuses:
            decision = "block" if status == "failed" and checker.blocking else "continue"
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
        rc = _run_checker(checker, target_root, artifact_path)
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

        decision = "block" if status == "failed" and checker.blocking else "continue"
        decision_log.append(gate, decision)

    blocking_failed = any(
        gate.get("status") == "failed" and checker.blocking
        for checker in registry
        for gate in [gates_by_name[checker.name]]
    )

    review_rc = 0
    if review and mode == "diff":
        from sail import review as review_mod
        if review_mod.backend_available():
            review_rc = review_mod.run_review(target_root, diff_ref, run_dir=run_dir, advisory=False)
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
