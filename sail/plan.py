from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from concurrent.futures import ThreadPoolExecutor

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

# #61: surface design-QUALITY choices the consistency self-check cannot catch. The self-check
# (#58) catches broken promise->action BUGS; it is blind to design decisions with no single right
# answer (the #55 doctor count: N=8 exclude per-project pytest vs N=9 include + split remediation
# — /sloop's plan red-team surfaced the call, autonomous /sail shipped the messier N=9). This
# directive asks the SAME single author pass to populate a structured `design_alternatives` field
# so a reviewer (auto or supervised human) sees the call and the trade-off. It is SURFACED, not
# gated — it never affects the exit code. Phrased conditionally so trivial specs are not forced to
# invent alternatives (review/#58's no-uniform-weight lesson): no genuine choice -> leave it empty.
DESIGN_ALTERNATIVES_DIRECTIVE = (
    "DESIGN ALTERNATIVES (surface, do NOT gate): When the spec carries a genuine design choice "
    "with NO single right answer (e.g. include vs exclude an item from a count, one data shape vs "
    "another, a lean vs a complete approach), populate the `design_alternatives` list with the "
    "leading options — each with its trade-off and a `recommended` boolean on the one you chose — "
    "and make the recommendation's rationale clear. This surfaces the call for an auto or human "
    "reviewer (the class of choice a consistency check cannot catch). If there is NO real design "
    "choice, leave `design_alternatives` as an empty list — do not invent alternatives for a "
    "trivial spec. This is informational and never a blocking risk on its own.\n"
)

# AC#1 (#80): a FREE code-health item folded into the SAME single plan pass (no new plan lens —
# it rides the existing self-check + the #62 cross-family plan-adversary). Shift-left on the two
# code-health axes the review-time tidiness lens (#63/#80) enforces: simplicity (a materially
# simpler shape) and efficiency (an obviously-worse algorithm/data-structure). Marginal-value rule:
# ONLY an EGREGIOUS case becomes a blocking risk — a quadratic where linear is obvious on a
# reachable path, or a needlessly roundabout shape when a materially simpler one is at hand.
# Diminishing-returns polish is NOT a risk (mirrors the review-time advisory tier), so trivial
# specs stay 1-pass and unblocked.
CODE_HEALTH_SELF_CHECK = (
    "CODE-HEALTH CHECK (mandatory, marginal-value): assess whether the planned approach picks an "
    "obviously-worse algorithm or data-structure (e.g. a quadratic scan where a linear/hashed pass "
    "is the obvious shape, on a reachable path), or whether a materially simpler shape achieves the "
    "same result. Only an EGREGIOUS case — a clear, large, reachable defect — is a blocking (HIGH or "
    "CRITICAL) risk; record it in the risks list with the concrete cheaper/simpler alternative. "
    "Diminishing-returns polish (a marginal micro-optimization, a stylistic preference) is NOT a "
    "risk — do not invent one for a sound, simple plan.\n"
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
        '"design_alternatives":[{"option":"...","tradeoff":"...","recommended":true}],'
        '"acceptance_criteria":[...],"test_plan":[{"behavior":"...","test":"..."}],'
        '"risks":[{"severity":"CRITICAL|HIGH|MEDIUM|LOW","area":"design|security|scope|other",'
        '"issue":"...","mitigation":"..."}],"scope":{"in":[...],"out":[...]},"summary":"..."}\n'
        + CONSISTENCY_SELF_CHECK
        + CODE_HEALTH_SELF_CHECK
        + DESIGN_ALTERNATIVES_DIRECTIVE
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
        "Design breadth (#62) — even if a consistency bug is already obvious, do NOT stop there: this pass exists to widen the DESIGN lens. Probe whether the spec picks the wrong design shape, misses a materially simpler approach, or commits to a design choice with a better-fitting alternative — surface those as findings too, not just the first defect.\n"
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

    # Concurrent dispatch (#89): the author plan pass and the risk-gated --plan-adversary pass are
    # mutually INDEPENDENT — the adversary re-derives risks from the SAME spec (build_adversary_prompt
    # consumes `spec`, not the author's output), so neither consumes the other's result. Dispatch them
    # CONCURRENTLY and join on the slowest, dropping plan-stage wall-clock from author+adversary to the
    # slower of the two. The union below is UNCHANGED ("union as today").
    #
    # The adversary's escalation is gated by SPEC-derived predicates (plan_adversary or
    # is_plan_risky(spec)) — knowable upfront — so ordinary (non-risky) work still never dispatches it
    # (the "no uniform weight" property, AC#4 of #58, is preserved). The adversary is unioned ONLY when
    # the author plan is usable, exactly as today (escalate = spec_escalate and not (backend_error or
    # unusable_plan)); on the degenerate author backend-error / unusable-plan path the run already fails
    # closed (status=error, exit 1) and the speculatively-dispatched adversary result is DISCARDED, so
    # gate semantics are identical. The only token-cost difference from the serial path is that one rare
    # already-failing path pays for a discarded adversary call; the common (usable-author) path is
    # token-identical and pure latency.
    spec_escalate = plan_adversary or is_plan_risky(spec)
    run_adversary = spec_escalate and adversary_available()
    with ThreadPoolExecutor(max_workers=2) as _ex:
        _f_author = _ex.submit(_invoke, build_prompt(spec))
        _f_adv = _ex.submit(
            _invoke, build_adversary_prompt(spec), argv=_adversary_argv()) if run_adversary else None
    rc, out, _err = _f_author.result()
    adv_result = _f_adv.result() if _f_adv is not None else None
    parsed = parse_plan(out)
    backend_error = rc != 0 or parsed is None
    approach = parsed.get("approach") if parsed is not None else None
    unusable_plan = parsed is not None and (not isinstance(approach, str) or not approach.strip())

    if unusable_plan:
        payload = {
            "status": "error",
            "approach": parsed.get("approach", ""),
            "simpler_alternative": parsed.get("simpler_alternative", ""),
            "design_alternatives": parsed.get("design_alternatives", []),
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
            "design_alternatives": [],
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
            "design_alternatives": parsed.get("design_alternatives", []),
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
    # uniform weight). Only run on an otherwise-usable author plan — not on a backend/parse error
    # or unusable plan (already failing closed, no usable plan to adversarially break).
    #
    # #62: the adversary now runs on plan-risky work EVEN WHEN the author plan is ALREADY blocking
    # — reversing #58 review R1 LOW's skip-when-already-red. That skip saved a call but threw away
    # the adversary's reason for being: a SECOND, independent design perspective (the lens most
    # likely to surface design choices / a simpler approach the single author pass misses). When a
    # consistency bug is already flagged, the gate is red regardless — but the adversary's job is
    # design BREADTH, not adding to the blocking count: its independent CRITICAL/HIGH design
    # findings still union into plan.json (tagged lens=adversary) so the reviewer sees the design
    # risks the author missed. Cost stays risk-gated: escalate still requires plan_adversary or
    # is_plan_risky, so ordinary work never pays — only the rare risky-AND-already-blocking
    # intersection adds one bounded one-shot call. An adversary backend error fails closed
    # UNIFORMLY (status=error, exit 1) whether or not the author plan was independently blocking.
    adversary_error = False
    escalate = spec_escalate and not (backend_error or unusable_plan)
    if escalate:
        if adversary_available():
            # adv_result was resolved by the concurrent dispatch above (#89). run_adversary is
            # exactly `spec_escalate and adversary_available()`, and escalate implies spec_escalate,
            # so within this branch adv_result is non-None. On the !escalate path (author error /
            # unusable plan) this block is skipped and any dispatched adv_result is discarded.
            arc, aout, _aerr = adv_result
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
