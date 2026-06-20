from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import sys
import uuid
from datetime import datetime, timezone

from sail.decisionlog import DecisionLog

DEFAULT_BACKEND = ["claude", "-p"]

_VALID_SEV = {"CRITICAL", "HIGH", "MEDIUM", "LOW"}


def _backend_argv():
    env = os.environ.get("SAIL_PLAN_CMD")
    if env is not None:
        return shlex.split(env)
    return list(DEFAULT_BACKEND)


def backend_available():
    argv = _backend_argv()
    if not argv:
        return False
    prog = argv[0]
    if shutil.which(prog) is not None:
        return True
    return os.path.isfile(prog) and os.access(prog, os.X_OK)


def build_prompt(spec):
    return (
        "You are a planning assistant. Read the issue/spec below and emit ONE JSON object "
        "matching this schema exactly:\n"
        '{"status":"completed","approach":"...","simpler_alternative":"...",'
        '"acceptance_criteria":[...],"test_plan":[{"behavior":"...","test":"..."}],'
        '"risks":[{"severity":"CRITICAL|HIGH|MEDIUM|LOW","area":"design|security|scope|other",'
        '"issue":"...","mitigation":"..."}],"scope":{"in":[...],"out":[...]},"summary":"..."}\n'
        "Return JSON only.\n\n"
        "=== SPEC ===\n"
        f"{spec}\n"
        "=== END SPEC ==="
    )


def _find_json_objects(text):
    # Intentional duplicate of sail.review._find_json_objects to keep this module decoupled.
    objs = []
    depth = 0
    start = -1
    in_str = False
    esc = False
    for i, ch in enumerate(text or ""):
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            if depth > 0:
                depth -= 1
                if depth == 0 and start != -1:
                    objs.append(text[start:i + 1])
                    start = -1
    return objs


def parse_plan(stdout):
    candidates = []
    for blob in _find_json_objects(stdout or ""):
        try:
            obj = json.loads(blob)
        except (ValueError, TypeError):
            continue
        if isinstance(obj, dict) and isinstance(obj.get("risks"), list):
            candidates.append(obj)
    if len(candidates) != 1:
        return None

    out_risks = []
    for risk in candidates[0]["risks"]:
        if not isinstance(risk, dict):
            return None
        sev = str(risk.get("severity", "")).strip().upper()
        if sev not in _VALID_SEV:
            sev = "HIGH"
        normalized = dict(risk)
        normalized["severity"] = sev
        out_risks.append(normalized)

    parsed = dict(candidates[0])
    parsed["risks"] = out_risks
    return parsed


def has_blocking_risk(risks):
    return any(
        isinstance(risk, dict) and risk.get("severity") in ("CRITICAL", "HIGH")
        for risk in risks
    )


def _invoke(prompt):
    argv = _backend_argv()
    try:
        result = subprocess.run(argv, input=prompt, capture_output=True, text=True)
    except OSError as exc:
        return 127, "", f"backend exec failed: {exc}"
    return result.returncode, result.stdout, result.stderr


def run_plan(target, run_dir=None, advisory=False):
    spec = sys.stdin.read()
    if run_dir is None:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        run_dir = os.path.join(os.getcwd(), ".sail", "runs", f"plan-{stamp}-{uuid.uuid4().hex[:8]}")
    os.makedirs(run_dir, exist_ok=True)
    log = DecisionLog(run_dir)
    artifact_path = os.path.join(run_dir, "plan.json")

    if not spec.strip():
        payload = {"status": "error", "reason": "empty spec"}
        with open(artifact_path, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2)
        log.plan_marker("error: empty spec")
        return 1

    if not backend_available():
        payload = {"status": "skipped", "reason": "no LLM backend available"}
        with open(artifact_path, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2)
        log.plan_marker("skipped: no LLM backend available")
        return 0

    rc, out, _err = _invoke(build_prompt(spec))
    parsed = parse_plan(out)
    backend_error = rc != 0 or parsed is None
    approach = parsed.get("approach") if parsed is not None else None
    unusable_plan = parsed is not None and (not isinstance(approach, str) or not approach.strip())

    if unusable_plan:
        payload = {
            "status": "error",
            "approach": parsed.get("approach", ""),
            "simpler_alternative": parsed.get("simpler_alternative", ""),
            "acceptance_criteria": parsed.get("acceptance_criteria", []),
            "test_plan": parsed.get("test_plan", []),
            "risks": parsed.get("risks", []),
            "scope": parsed.get("scope", {"in": [], "out": []}),
            "summary": parsed.get("summary", ""),
            "reason": "unusable plan: missing approach",
        }
    elif parsed is None:
        payload = {
            "status": "error",
            "approach": "",
            "simpler_alternative": "",
            "acceptance_criteria": [],
            "test_plan": [],
            "risks": [],
            "scope": {"in": [], "out": []},
            "summary": "",
        }
    else:
        payload = {
            "status": "error" if backend_error else "completed",
            "approach": parsed.get("approach", ""),
            "simpler_alternative": parsed.get("simpler_alternative", ""),
            "acceptance_criteria": parsed.get("acceptance_criteria", []),
            "test_plan": parsed.get("test_plan", []),
            "risks": parsed.get("risks", []),
            "scope": parsed.get("scope", {"in": [], "out": []}),
            "summary": parsed.get("summary", ""),
        }

    with open(artifact_path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)

    if payload["status"] == "completed":
        risks = payload.get("risks", [])
        counts = {"CRITICAL": 0, "HIGH": 0, "MEDIUM": 0, "LOW": 0}
        for risk in risks:
            sev = risk.get("severity", "LOW") if isinstance(risk, dict) else "LOW"
            if sev in counts:
                counts[sev] += 1
        summary = (
            f"completed: {len(risks)} risks ({counts['CRITICAL']} CRITICAL, {counts['HIGH']} HIGH, "
            f"{counts['MEDIUM']} MEDIUM, {counts['LOW']} LOW)"
        )
    else:
        if unusable_plan:
            summary = "error: unusable plan: missing approach"
        else:
            summary = (
                f"error: backend response unusable (rc={rc})"
                if rc != 0
                else "error: unparseable backend output"
            )
    log.plan_marker(summary)

    # --advisory suppresses blocking-risk only; backend/parse errors still return 1 (never-mask);
    # a backend-absent skip still returns 0.
    if backend_error or unusable_plan:
        return 1
    if advisory:
        return 0
    return 1 if has_blocking_risk(payload["risks"]) else 0
