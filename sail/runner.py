from __future__ import annotations

import os
import subprocess
import uuid
from datetime import datetime, timezone
from glob import glob

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


def run(run_dir=None, target=None, cov_fail_under=0, run_id=None):
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

    decision_log = DecisionLog(run_dir)
    if resumed:
        decision_log.resume_marker()

    terminal_statuses = {"passed", "failed", "skipped"}
    gates_by_name = {gate["name"]: gate for gate in state.gates}
    next_seq = max((gate.get("seq") or 0 for gate in state.gates), default=0) + 1

    for checker in registry:
        gate = gates_by_name[checker.name]
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
            gate["finished_at"] = _utc_now_iso()
            state.save()
            decision_log.append(gate, "continue")
            continue

        result = subprocess.run(checker.build_command(target, artifact_path), capture_output=True, text=True)
        status = checker.classify(result.returncode)
        gate["status"] = status
        gate["rc"] = result.returncode
        gate["reason"] = None
        gate["artifact"] = checker.artifact
        gate["finished_at"] = _utc_now_iso()
        state.save()

        decision = "block" if status == "failed" and checker.blocking else "continue"
        decision_log.append(gate, decision)

    blocking_failed = any(
        gate.get("status") == "failed" and checker.blocking
        for checker in registry
        for gate in [gates_by_name[checker.name]]
    )
    return 1 if blocking_failed else 0
