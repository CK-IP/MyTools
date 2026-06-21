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

# AC#1 (#58): a FREE consistency self-check folded into the SAME single plan pass — no extra
# agent. Targets the broken promise->action failure class (#55's "unresolvable loop": doctor
# promised "Run ./install.sh" for a tool install.sh could not install). The author must name
# the concrete delivered action for every user-facing promise, surfacing the gap at plan-time.
CONSISTENCY_SELF_CHECK = (
    "CONSISTENCY SELF-CHECK (mandatory): For every user-facing instruction or remediation the "
    "change introduces (e.g. a message telling the user to run a command, a documented fix, a "
    "counted tool/list), name in the plan the EXACT action in the change that fulfills it. If a "
    "promise has no matching delivered action — or the action it points to cannot actually "
    "satisfy the promise (an unresolvable loop) — that is a blocking (HIGH or CRITICAL) "
    "consistency risk; record it in the risks list.\n"
)

# AC#2/#4 (#58): markers of a plan-risky spec, in two families:
#   (A) REMEDIATION  — the change adds a user-facing instruction/remediation (the broken
#                      promise->action class), and
#   (B) RECONCILE    — the change reconciles multiple files/lists (the unreconciled-list class).
# To preserve AC#4 (no uniform weight) the heuristic does NOT fire on a single broad token
# (review R1 HIGH, both lenses: bare substrings like "run the"/"error message" matched ordinary
# specs and made the adversary near-always-on). It fires only on:
#   - CO-OCCURRENCE: a family-A signal AND a family-B signal in the same spec (the #55 shape:
#     "doctor says run install.sh" [A] + "reconcile the tool list across both files" [B]), or
#   - an UNAMBIGUOUS phrase that is itself the failure pattern (no ordinary spec says these).
# Tokens are deliberately specific phrases, not generic verbs, so common prose ("run the tests",
# "improve the error message", "keep docs consistent with code") stays a single pass.
_RISK_REMEDIATION = (
    "remediat", "instruct the user", "tell the user to", "run ./install", "run install.sh",
    "the user to run", "fix it by running", "user-facing instruction", "prompt the user to",
)
_RISK_RECONCILE = (
    "reconcile", "tool list", "across both files", "across the files", "two files",
    "multiple files", "keep in sync", "kept in sync", "list of tools",
)
# Unambiguous single-signal phrases — each IS the promise->action / unreconciled-loop pattern,
# so it escalates on its own (no ordinary, non-risky spec contains these).
_RISK_UNAMBIGUOUS = (
    "unresolvable loop", "broken promise", "promise->action", "promise -> action",
    "remediation loop", "no matching action", "reconcile the tool list",
)


def _backend_argv():
    env = os.environ.get("SAIL_PLAN_CMD")
    if env is not None:
        return shlex.split(env)
    return list(DEFAULT_BACKEND)


def _adversary_argv():
    # The optional one-shot plan adversary backend (#58 AC#2), mirroring review's
    # SAIL_REVIEW_CMD2. Only SAIL_PLAN_CMD2 — no built-in default, so the adversary is
    # opt-in and never auto-enables a second backend.
    env = os.environ.get("SAIL_PLAN_CMD2")
    if env:
        return shlex.split(env)
    return None


def _argv_runnable(argv):
    if not argv:
        return False
    prog = argv[0]
    if shutil.which(prog) is not None:
        return True
    return os.path.isfile(prog) and os.access(prog, os.X_OK)


def backend_available():
    return _argv_runnable(_backend_argv())


def adversary_available():
    return _argv_runnable(_adversary_argv())


def is_plan_risky(spec):
    # AC#2/#4 (#58): auto-trigger heuristic for the risk-gated plan adversary. To keep the
    # default single-pass (no uniform weight — review R1 HIGH), it fires ONLY on the strong
    # signals that distinguish the #55 "unresolvable loop" failure shape from ordinary specs:
    #   - co-occurrence of a remediation/instruction signal AND a file/list-reconciliation
    #     signal (the promise [A] + the unreconciled list [B] together), OR
    #   - a single unambiguous phrase that is itself the failure pattern.
    # A spec that merely mentions one broad term (e.g. "run the tests") does NOT escalate.
    # Lowercased substring match; never raises.
    text = (spec or "").lower()
    if any(kw in text for kw in _RISK_UNAMBIGUOUS):
        return True
    has_remediation = any(kw in text for kw in _RISK_REMEDIATION)
    has_reconcile = any(kw in text for kw in _RISK_RECONCILE)
    return has_remediation and has_reconcile


def build_prompt(spec):
    return (
        "You are a planning assistant. Read the issue/spec below and emit ONE JSON object "
        "matching this schema exactly:\n"
        '{"status":"completed","approach":"...","simpler_alternative":"...",'
        '"acceptance_criteria":[...],"test_plan":[{"behavior":"...","test":"..."}],'
        '"risks":[{"severity":"CRITICAL|HIGH|MEDIUM|LOW","area":"design|security|scope|other",'
        '"issue":"...","mitigation":"..."}],"scope":{"in":[...],"out":[...]},"summary":"..."}\n'
        + CONSISTENCY_SELF_CHECK
        + "Return JSON only.\n\n"
        "=== SPEC ===\n"
        f"{spec}\n"
        "=== END SPEC ==="
    )


def build_adversary_prompt(spec):
    # The one-shot risk-gated plan adversary (#58 AC#2). It is an INDEPENDENT second pass over
    # the same spec with adversarial framing (it does not see the author's plan.json — exactly
    # like review's dual-lens lens2, which reviews the diff independently rather than grading
    # lens1's output). It re-derives the gaps a careless author would miss in the broken
    # promise->action consistency class. Emits a risks-bearing JSON object; only its EXPLICITLY
    # CRITICAL/HIGH risks union into the plan gate (see _explicit_blocking_risks).
    return (
        "You are an ADVERSARIAL plan reviewer. Your job is to BREAK the plan a careless author "
        "would write for the spec below — find the gaps that author would miss. Focus on the "
        "promise->action consistency failure class: every user-facing instruction or remediation "
        "the change introduces MUST have a concrete action in the change that fulfills it. Flag "
        "any promise with no matching delivered action (a broken promise, an unresolvable "
        "remediation loop, an unreconciled file/list). Be specific and skeptical.\n"
        "Apply this adversarial-review craft:\n"
        "Bias self-guards — resist verification avoidance (confirming the plan is fine instead of trying to break it), being seduced by the first 80%, anchoring to the spec or plan as if it were correct, and reasoning-only conclusions; cite the specific spec text behind every finding.\n"
        "Confidence threshold — only report a finding when you are >80% confident it is a real defect. Do NOT flag style preferences, \"could be more efficient\" without concrete impact, error handling for impossible states, or theoretical issues with no practical failure mode.\n"
        "Required adversarial probes — probe the design for concurrency hazards, boundary conditions (empty, missing, or corrupt inputs), idempotency violations, and injection vectors, in addition to the promise-to-action consistency class.\n"
        "Emit ONE JSON object with a risks list of this shape (each genuine defect is a "
        "CRITICAL or HIGH risk):\n"
        '{"risks":[{"severity":"CRITICAL|HIGH|MEDIUM|LOW","area":"design|security|scope|other",'
        '"issue":"...","mitigation":"..."}],"summary":"..."}\n'
        "If the plan is sound, return {\"risks\":[],\"summary\":\"no adversarial findings\"}.\n"
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


def _explicit_blocking_risks(stdout):
    # Adversary union filter (#58, review R1 MEDIUM lens1): unlike the author plan, an adversary
    # risk only blocks when its severity is EXPLICITLY "CRITICAL"/"HIGH". This deliberately does
    # NOT reuse parse_plan's fail-closed unknown->HIGH normalization: a sloppy adversary response
    # with a typo'd/missing severity must not be promoted into a spurious blocking HIGH that
    # fails an otherwise-clean plan. Returns the list of explicitly-blocking risks, or None when
    # the adversary output is unparseable (no single risks-bearing object) so the caller fails
    # closed. Never raises.
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
    blocking = []
    for risk in candidates[0]["risks"]:
        if not isinstance(risk, dict):
            continue
        sev = str(risk.get("severity", "")).strip().upper()
        if sev in ("CRITICAL", "HIGH"):
            normalized = dict(risk)
            normalized["severity"] = sev
            blocking.append(normalized)
    return blocking


def _invoke(prompt, argv=None):
    argv = list(argv) if argv else _backend_argv()
    try:
        result = subprocess.run(argv, input=prompt, capture_output=True, text=True)
    except OSError as exc:
        return 127, "", f"backend exec failed: {exc}"
    return result.returncode, result.stdout, result.stderr


def run_plan(target, run_dir=None, advisory=False, plan_adversary=False):
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

    # Risk-gated plan adversary (#58 AC#2): a ONE-SHOT adversarial second pass, escalated only
    # when the change is plan-risky (--plan-adversary forces it, OR the auto-trigger heuristic
    # fires). Mirrors review's --dual-lens: an opt-in INDEPENDENT second backend (SAIL_PLAN_CMD2)
    # re-derives risks from the same spec with adversarial framing, union its BLOCKING risks into
    # the plan gate, fail closed if it errors. A non-risky change never escalates (AC#4: no
    # uniform weight). Only run on an otherwise-usable author plan that is not ALREADY blocking
    # (review R1 LOW: when the author plan already has a blocking risk the gate is already exit 1
    # — the adversary call would be wasted) — and not on a backend/parse error (already failing
    # closed, no usable plan to adversarially break).
    adversary_error = False
    escalate = (
        (plan_adversary or is_plan_risky(spec))
        and not (backend_error or unusable_plan)
        and not has_blocking_risk(payload.get("risks", []))
    )
    if escalate:
        if adversary_available():
            arc, aout, _aerr = _invoke(build_adversary_prompt(spec), argv=_adversary_argv())
            blocking = _explicit_blocking_risks(aout)
            if arc != 0 or blocking is None:
                adversary_error = True
                # Persist the failure on-disk too (review R1 HIGH, lens2): the artifact's status
                # must match the exit code so a downstream `sail run` reuse can't treat a
                # failed-closed adversary run as a valid completed plan.
                payload["status"] = "error"
                payload["reason"] = "plan-adversary backend error"
                log.plan_marker("plan-adversary: backend error (failing closed)")
            else:
                for r in blocking:
                    tagged = dict(r)
                    tagged["lens"] = "adversary"
                    payload["risks"].append(tagged)
                log.plan_marker(f"plan-adversary: ran ({len(blocking)} blocking risk(s) unioned)")
        else:
            log.plan_marker("plan-adversary requested/triggered but no second backend (SAIL_PLAN_CMD2) — single-pass")

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
    # a backend-absent skip still returns 0. An adversary backend error fails closed too (#58):
    # an unusable adversary pass must not silently pass the gate (mirrors dual-lens never-mask).
    if backend_error or unusable_plan or adversary_error:
        return 1
    if advisory:
        return 0
    return 1 if has_blocking_risk(payload["risks"]) else 0
