from __future__ import annotations

import json
import os
import shlex
import subprocess
import uuid
from datetime import datetime, timezone

from sail.argvpeel import peel_argv
from sail import codexlatch
from sail.checkers import _DOC_SUFFIXES


def classify_change(changed_files):
    files = [f for f in (changed_files or []) if f]
    if not files:
        return "code"
    if all(any(str(path).endswith(suffix) for suffix in _DOC_SUFFIXES) for path in files):
        return "prose"
    return "code"


def _env_argv(name):
    env = os.environ.get(name)
    if env and env.strip():
        try:
            return shlex.split(env)
        except (ValueError, OSError):
            return None  # #95 / S1.R1.1: malformed command → unusable backend → clean-degrade to inline
    return None


def _backend_argv():
    return _env_argv("SAIL_BUILD_CMD")


def _argv_runnable(argv):
    return codexlatch.runnable(argv)


def _backend_family(cmd):
    # #95 / RT-5: best-effort wrapper peeling for cross-family advisory only.
    if not cmd:
        return ""
    if isinstance(cmd, (list, tuple)):
        argv = list(cmd)
    else:
        try:
            argv = shlex.split(cmd)
        except (ValueError, OSError, AttributeError):
            return ""
    return peel_argv(argv)


def _review_families():
    fams = []
    for env_name in ("SAIL_REVIEW_CMD", "SAIL_REVIEW_CMD2"):
        cmd = os.environ.get(env_name)
        if cmd and cmd.strip():
            fam = _backend_family(cmd)
            if fam:
                fams.append((env_name, fam))
    return fams


def _same_family_warning(build_cmd, is_prose=False):
    # #133: the cross-family collision is decided by the CHANGE CLASS, not by which env var
    # supplied the colliding backend. A prose-classified build whose selected backend (whether
    # SAIL_BUILD_CMD_PROSE or the SAIL_BUILD_CMD fallback) shares the active reviewer's family has
    # lost cross-family review either way — so the ALERT (naming the SAIL_BUILD_CMD_PROSE
    # remediation) fires for either source. A code-class collision keeps the #95 advisory wording.
    if not build_cmd:
        return None
    fam = _backend_family(build_cmd)
    if not fam:
        return None
    for _env_name, review_fam in _review_families():
        if fam == review_fam:
            if is_prose:
                return (
                    f"ALERT: shared family '{fam}' collapses cross-family review on this prose "
                    "build; set SAIL_BUILD_CMD_PROSE to a different-family backend"
                )
            return f"shared family '{fam}' may trigger the #83 cross-family-review risk"
    return None


def _plan_scope_changed_files(run_dir):
    if not run_dir:
        return []
    plan_path = os.path.join(run_dir, "plan.json")
    if not os.path.exists(plan_path):
        return []
    try:
        plan = _read_json(plan_path)
    except (ValueError, OSError):
        return []
    if not isinstance(plan, dict):
        return []
    scope = plan.get("scope")
    if not isinstance(scope, dict):
        return []
    changed = scope.get("in", [])
    return list(changed) if isinstance(changed, list) else []


def _build_backend_for_change(change_class):
    prose_cmd = _env_argv("SAIL_BUILD_CMD_PROSE")
    build_cmd = _env_argv("SAIL_BUILD_CMD")

    if change_class == "prose":
        if _argv_runnable(prose_cmd):
            return prose_cmd, "SAIL_BUILD_CMD_PROSE", None
        if _argv_runnable(build_cmd):
            return build_cmd, "SAIL_BUILD_CMD", None
        configured = any(
            os.environ.get(name) and os.environ.get(name).strip()
            for name in ("SAIL_BUILD_CMD_PROSE", "SAIL_BUILD_CMD")
        )
        return None, None, "backend-not-runnable" if configured else "backend-unset"

    if _argv_runnable(build_cmd):
        return build_cmd, "SAIL_BUILD_CMD", None
    configured = os.environ.get("SAIL_BUILD_CMD")
    return None, None, "backend-not-runnable" if configured and str(configured).strip() else "backend-unset"


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


def build_prompt(target, run_dir, mode="build", round=1, change_class=None):
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
    parts.append(f"Change class: {change_class or classify_change(_plan_scope_changed_files(run_dir))}")
    return "\n\n".join(parts)


def run_build(target, run_dir, mode="build", round=1, change_class=None):
    if run_dir is None:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        run_dir = os.path.join(os.getcwd(), ".sail", "runs", f"build-{stamp}-{uuid.uuid4().hex[:8]}")
    os.makedirs(run_dir, exist_ok=True)
    resolved_change_class = change_class or classify_change(_plan_scope_changed_files(run_dir))
    backend, _backend_env_name, backend_reason = _build_backend_for_change(resolved_change_class)
    warning = _same_family_warning(backend, is_prose=resolved_change_class == "prose")

    # #95 / RT-1: clean-degrade to inline when no runnable build backend exists.
    if not _argv_runnable(backend):
        payload = {
            "status": "inline",
            "mode": mode,
            "reason": backend_reason,
            "change_class": resolved_change_class,
        }
        _write_build_json(run_dir, payload)
        return 0

    marker = os.path.join(target, ".sail", "last-test-failed")

    # #95 / RT-1 / RT-4: shared failing-test precondition before any dispatch.
    if not os.path.exists(marker):
        payload = {"status": "error", "mode": mode, "reason": "no failing-test marker", "change_class": resolved_change_class}
        if resolved_change_class == "prose" and warning:
            payload["cross_family"] = "lost"
        if warning:
            payload["same_family_warning"] = warning
        _write_build_json(run_dir, payload)
        return 1

    if mode == "fix":
        review_path = os.path.join(run_dir, "review.json")
        # #95 / RT-2: fix mode needs a completed review artifact.
        if not os.path.exists(review_path):
            payload = {"status": "error", "mode": mode, "reason": "missing review.json", "change_class": resolved_change_class}
            if resolved_change_class == "prose" and warning:
                payload["cross_family"] = "lost"
            if warning:
                payload["same_family_warning"] = warning
            _write_build_json(run_dir, payload)
            return 1
        try:
            review = _read_json(review_path)
        except (ValueError, OSError):
            review = None
        if not isinstance(review, dict) or review.get("status") != "completed":
            payload = {"status": "error", "mode": mode, "reason": "review.json not completed", "change_class": resolved_change_class}
            if resolved_change_class == "prose" and warning:
                payload["cross_family"] = "lost"
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
                payload = {"status": "error", "mode": mode, "reason": "undecodable decision-log", "change_class": resolved_change_class}
                if resolved_change_class == "prose" and warning:
                    payload["cross_family"] = "lost"
                if warning:
                    payload["same_family_warning"] = warning
                _write_build_json(run_dir, payload)
                return 1

    prompt = build_prompt(target, run_dir, mode=mode, round=round, change_class=resolved_change_class)
    rc, _out, _err = _invoke(prompt, argv=backend, cwd=target)
    if rc != 0:
        payload = {"status": "error", "mode": mode, "change_class": resolved_change_class}
        if resolved_change_class == "prose" and warning:
            payload["cross_family"] = "lost"
        if warning:
            payload["same_family_warning"] = warning
        _write_build_json(run_dir, payload)
        return 1

    payload = {"status": "delegated", "mode": mode, "change_class": resolved_change_class}
    if resolved_change_class == "prose" and warning:
        payload["cross_family"] = "lost"
    if warning:
        payload["same_family_warning"] = warning
    _write_build_json(run_dir, payload)
    return 0
