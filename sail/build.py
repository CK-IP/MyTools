from __future__ import annotations

import json
import os
import shlex
import subprocess
import uuid
from datetime import datetime, timezone

from sail import codexlatch


def _backend_argv():
    env = os.environ.get("SAIL_BUILD_CMD")
    if env and env.strip():
        try:
            return shlex.split(env)
        except (ValueError, OSError):
            return None  # #95 / S1.R1.1: malformed command → unusable backend → clean-degrade to inline
    return None


def _argv_runnable(argv):
    return codexlatch.runnable(argv)


def _backend_family(cmd_str):
    # #95 / RT-5: best-effort wrapper peeling for cross-family advisory only.
    if not cmd_str:
        return ""
    try:
        argv = shlex.split(cmd_str)
    except (ValueError, OSError):
        return ""
    if not argv:
        return ""
    prog = os.path.basename(argv[0])
    if prog == "env":
        i = 1
        while i < len(argv) and (argv[i].startswith("-") or ("=" in argv[i] and not argv[i].startswith("-"))):
            i += 1
        return _backend_family(" ".join(argv[i:])) if i < len(argv) else ""
    if prog in ("bash", "sh") and len(argv) >= 3 and argv[1] in ("-lc", "-c"):
        try:
            inner = shlex.split(argv[2])
        except (ValueError, OSError):
            return prog
        return os.path.basename(inner[0]) if inner else prog
    if prog.startswith("python") and len(argv) >= 3 and argv[1] == "-m":
        return os.path.basename(argv[2])
    return prog


def _same_family_warning():
    build_cmd = os.environ.get("SAIL_BUILD_CMD")
    review_cmd = os.environ.get("SAIL_REVIEW_CMD2")
    if not (build_cmd and build_cmd.strip() and review_cmd and review_cmd.strip()):
        return None
    fam = _backend_family(build_cmd)
    if fam and fam == _backend_family(review_cmd):
        return f"shared family '{fam}' may trigger the #83 cross-family-review risk"
    return None


def _invoke(prompt, argv=None, cwd=None):
    argv = list(argv) if argv else _backend_argv()
    env = None
    if cwd is not None:
        env = os.environ.copy()
        env["PWD"] = cwd
    try:
        result = subprocess.run(argv, input=prompt, capture_output=True, text=True, encoding="utf-8", errors="replace", cwd=cwd, env=env)
    except OSError as exc:
        codexlatch.observe(argv, 127, f"backend exec failed: {exc}")
        return 127, "", f"backend exec failed: {exc}"
    codexlatch.observe(argv, result.returncode, result.stderr)
    return result.returncode, result.stdout, result.stderr


def _read_json(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def _write_build_json(run_dir, payload):
    path = os.path.join(run_dir, "build.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)


def build_prompt(target, run_dir, mode="build", round=1):
    parts = [
        "You are a build assistant.",
        "Make the failing test pass, keep the suite green, do NOT weaken or delete the failing test.",
        f"Mode: {mode}",
    ]
    if mode == "fix":
        review_path = os.path.join(run_dir, "review.json")
        findings = []
        review_status = ""
        if os.path.exists(review_path):
            try:
                review = _read_json(review_path)
            except (ValueError, OSError):
                review = None
            if isinstance(review, dict):
                review_status = str(review.get("status", ""))
                for item in review.get("findings", []):
                    if isinstance(item, dict):
                        findings.append(f"- {item.get('id', '')} [{item.get('severity', '')}] {item.get('issue', '')}")
        parts.append(f"Review status: {review_status or 'missing'}")
        if findings:
            parts.append("Live findings:\n" + "\n".join(findings))
        dlog_path = os.path.join(run_dir, "decision-log.md")
        if os.path.exists(dlog_path):
            try:
                with open(dlog_path, "r", encoding="utf-8") as fh:
                    dlog = fh.read()
            except (UnicodeDecodeError, OSError):
                dlog = ""
            if dlog:
                parts.append("Decision log dispositions:\n" + dlog)
        parts.append("Address the live findings in review.json.")
    else:
        plan_path = os.path.join(run_dir, "plan.json")
        if os.path.exists(plan_path):
            try:
                plan = _read_json(plan_path)
            except (ValueError, OSError):
                plan = None
            if isinstance(plan, dict):
                ctx = {
                    "approach": plan.get("approach"),
                    "acceptance_criteria": plan.get("acceptance_criteria"),
                    "test_plan": plan.get("test_plan"),
                }
                parts.append("Plan context:\n" + json.dumps(ctx, indent=2))
    return "\n\n".join(parts)


def run_build(target, run_dir, mode="build", round=1):
    if run_dir is None:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        run_dir = os.path.join(os.getcwd(), ".sail", "runs", f"build-{stamp}-{uuid.uuid4().hex[:8]}")
    os.makedirs(run_dir, exist_ok=True)
    build_cmd = os.environ.get("SAIL_BUILD_CMD")
    backend = _backend_argv()

    # #95 / RT-1: clean-degrade to inline when no runnable build backend exists.
    if not _argv_runnable(backend):
        payload = {
            "status": "inline",
            "mode": mode,
            "reason": "backend-unset" if not (build_cmd and build_cmd.strip()) else "backend-not-runnable",
        }
        _write_build_json(run_dir, payload)
        return 0

    warning = _same_family_warning()
    marker = os.path.join(target, ".sail", "last-test-failed")

    # #95 / RT-1 / RT-4: shared failing-test precondition before any dispatch.
    if not os.path.exists(marker):
        payload = {"status": "error", "mode": mode, "reason": "no failing-test marker"}
        if warning:
            payload["same_family_warning"] = warning
        _write_build_json(run_dir, payload)
        return 1

    if mode == "fix":
        review_path = os.path.join(run_dir, "review.json")
        # #95 / RT-2: fix mode needs a completed review artifact.
        if not os.path.exists(review_path):
            payload = {"status": "error", "mode": mode, "reason": "missing review.json"}
            if warning:
                payload["same_family_warning"] = warning
            _write_build_json(run_dir, payload)
            return 1
        try:
            review = _read_json(review_path)
        except (ValueError, OSError):
            review = None
        if not isinstance(review, dict) or review.get("status") != "completed":
            payload = {"status": "error", "mode": mode, "reason": "review.json not completed"}
            if warning:
                payload["same_family_warning"] = warning
            _write_build_json(run_dir, payload)
            return 1
        dlog_path = os.path.join(run_dir, "decision-log.md")
        # #95 / RT-6: absent decision-log is allowed; undecodable/IO-failed log is not.
        if os.path.exists(dlog_path):
            try:
                open(dlog_path, "r", encoding="utf-8").read()
            except (UnicodeDecodeError, OSError):
                payload = {"status": "error", "mode": mode, "reason": "undecodable decision-log"}
                if warning:
                    payload["same_family_warning"] = warning
                _write_build_json(run_dir, payload)
                return 1

    prompt = build_prompt(target, run_dir, mode=mode, round=round)
    rc, _out, _err = _invoke(prompt, argv=backend, cwd=target)
    if rc != 0:
        payload = {"status": "error", "mode": mode}
        if warning:
            payload["same_family_warning"] = warning
        _write_build_json(run_dir, payload)
        return 1

    payload = {"status": "delegated", "mode": mode}
    if warning:
        payload["same_family_warning"] = warning
    _write_build_json(run_dir, payload)
    return 0
