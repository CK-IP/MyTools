"""Autonomous-mode convergence oracle (#77).

The deterministic loop decision the autonomous `/sail` driver (under `/surf`) consults
instead of eyeballing a "continue / abort / proceed" judgment a human used to make.

Contract: `rc` is the exit code of the gate that just ran (`sail run` / `sail review` /
`sail plan`), whose contract is `0 = green, non-zero = not green`. Any non-zero rc
(1, 127, ...) is treated uniformly as "not green". `round_num` is the 1-based count of
review rounds run so far; `max_rounds` is the genuine-non-convergence backstop (default 3).

This encodes the discipline:
  - exit 0 is the stop signal — LOW/MEDIUM findings never flip the exit code, so a green
    light stays green and the driver never spins another round to chase tidiness ("LOWs
    are non-blocking and are not chased past green").
  - while not green and under the cap, revise and re-review.
  - at the cap with the gate still red, PARK for a human rather than loop forever.
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess

from sail.decisionlog import DecisionLog
from sail import review as review_mod
from sail import codexlatch


_DISPOSITIONED = {"rejected", "deferred"}
_BLOCKING = {"CRITICAL", "HIGH"}


def _read_review_json(run_dir):
    with open(os.path.join(run_dir, "review.json"), encoding="utf-8") as fh:
        data = json.load(fh)
    return data if isinstance(data, dict) else None


def _read_run_state_json(run_dir):
    with open(os.path.join(run_dir, "run-state.json"), encoding="utf-8") as fh:
        data = json.load(fh)
    return data if isinstance(data, dict) else None


def materiality_backend_argv():
    env = os.environ.get("SAIL_MATERIALITY_CMD")
    if not env:
        return None
    argv = shlex.split(env)
    return argv or None


def materiality_independence_note():
    return (
        "SAIL_MATERIALITY_CMD should be a different model family than "
        "SAIL_REVIEW_CMD / SAIL_REVIEW_CMD2 to reduce rubber-stamping (#83)."
    )


def finding_is_immaterial(finding, run_dir, target):
    """Independent cross-family second opinion for the materiality floor.

    SAIL_MATERIALITY_CMD must be a different model family than the review lens
    (SAIL_REVIEW_CMD / SAIL_REVIEW_CMD2) to avoid rubber-stamping. The backend sees the
    finding and the full diff (`git -C target diff diff_ref`) and must answer JSON
    {"material": true|false}. Anything missing, uncertain, malformed, or unavailable fails
    closed to material/block.
    """
    argv = materiality_backend_argv()
    if argv is None:
        return False

    try:
        data = _read_review_json(run_dir)
        if data is None:
            return False
        diff_ref = data.get("diff_ref")
        if not diff_ref:
            return False

        diff = subprocess.run(
            ["git", "-C", target, "diff", diff_ref],
            capture_output=True,
            text=True,
        )
        if diff.returncode != 0:
            return False

        payload = json.dumps(
            {
                "instruction": (
                    "You are an INDEPENDENT reviewer. Decide whether this deferred finding "
                    "is a real defect IN THE CHANGE ITSELF (material) or genuine adjacent "
                    "hardening of code the change did not functionally alter (immaterial). "
                    "Read the diff to judge whether the finding pertains to the edited code. "
                    "Default to MATERIAL if uncertain. Respond with JSON {\"material\": true|false}."
                ),
                "independence_note": materiality_independence_note(),
                "finding": finding,
                "diff": diff.stdout,
            }
        )
        backend = subprocess.run(
            argv,
            input=payload,
            capture_output=True,
            text=True,
            cwd=os.path.abspath(target),
            timeout=60,
        )
        codexlatch.observe(argv, backend.returncode, backend.stderr)
        if backend.returncode != 0:
            return False

        result = json.loads(backend.stdout)
        if not isinstance(result, dict):
            return False
        material = result.get("material")
        if not isinstance(material, bool):
            return False
        return not material
    except Exception:
        return False


def gates_all_green(run_dir):
    try:
        data = _read_run_state_json(run_dir)
        if data is None:
            return False
        gates = data.get("gates")
        if not isinstance(gates, list):
            gates = data.get("checkers")
        if not isinstance(gates, list):
            return False
        # Skipped gates are legitimate when tools are absent in the documented floor path.
        # The assurance then comes from review_current_and_clean() + acs_all_met() + the
        # independent judge; missing/malformed/absent-key run-state data fails closed.
        for gate in gates:
            if not isinstance(gate, dict):
                return False
            status = gate.get("status")
            if status == "failed":
                return False
            if status not in {"passed", "skipped"}:
                return False
            for key in ("new_failures", "new_findings_count"):
                value = gate.get(key)
                if value is None:
                    continue
                if int(value) > 0:
                    return False
        return True
    except Exception:
        return False


def acs_all_met(run_dir):
    try:
        data = _read_review_json(run_dir)
        if data is None:
            return False
        plan_verification = data.get("plan_verification")
        if not isinstance(plan_verification, dict):
            return False
        acs = plan_verification.get("acceptance_criteria")
        if not isinstance(acs, list) or not acs:
            return False
        for ac in acs:
            if not isinstance(ac, dict) or ac.get("status") != "met":
                return False
        return True
    except Exception:
        return False


def tidiness_clear(run_dir):
    try:
        data = _read_review_json(run_dir)
        if data is None:
            return False
        tidiness = data.get("tidiness")
        if tidiness is None:
            return True
        if not isinstance(tidiness, dict):
            return False
        blocking = tidiness.get("blocking")
        if blocking is None:
            return True
        if isinstance(blocking, list):
            return len(blocking) == 0
        return False
    except Exception:
        return False


def review_current_and_clean(run_dir, target, round):
    try:
        data = _read_review_json(run_dir)
        if data is None:
            return False
        if data.get("status") != "completed":
            return False
        if data.get("backend_error") or data.get("plan_error"):
            return False
        review_target = data.get("target")
        diff_ref = data.get("diff_ref")
        if not review_target or not diff_ref:
            return False
        if os.path.abspath(target) != review_target:
            return False
        if int(data.get("round")) != int(round):
            return False
        if data.get("diff_hash") != review_mod.diff_fingerprint(os.path.abspath(target), diff_ref):
            return False
        if data.get("plan_hash") != review_mod.plan_fingerprint(run_dir):
            return False
        return True
    except Exception:
        return False


def materiality_floor(rc, run_dir, target, round):
    """Return the hardening-floor decision and deferred ids.

    The safety floor is the deterministic audit plus current-round deferred dispositions;
    materiality is decided only by the independent judgment lens, and any uncertainty
    fails closed.
    """
    if rc == 0:
        return False, []
    try:
        target_root = os.path.abspath(target)
        if not (
            gates_all_green(run_dir)
            and review_current_and_clean(run_dir, target_root, round)
            and tidiness_clear(run_dir)
            and acs_all_met(run_dir)
        ):
            return False, []
        data = _read_review_json(run_dir)
        if data is None:
            return False, []
        findings = data.get("findings")
        if not isinstance(findings, list):
            return False, []
        blocking = [
            finding for finding in findings
            if isinstance(finding, dict)
            and str(finding.get("severity", "")).strip().upper() in _BLOCKING
        ]
        if not blocking:
            return False, []
        resolutions = DecisionLog(run_dir).read_resolutions(round=round)
        deferred_ids = []
        for finding in blocking:
            finding_id = finding.get("id")
            if not finding_id:
                return False, []
            resolution = resolutions.get(finding_id)
            if not isinstance(resolution, dict) or resolution.get("disposition") != "deferred":
                return False, []
            if not finding_is_immaterial(finding, run_dir, target_root):
                return False, []
            deferred_ids.append(finding_id)
        return True, sorted(set(deferred_ids))
    except Exception:
        return False, []


def reappeared_dispositioned(run_dir, round_num):
    """Return sorted blocking ids that were dispositioned rejected/deferred before.

    [] on any missing, malformed, or unparseable input.
    """
    if not run_dir:
        return []

    try:
        resolutions = DecisionLog(run_dir).read_resolutions(before=round_num)
        dispositioned = {
            finding_id
            for finding_id, resolution in resolutions.items()
            if isinstance(resolution, dict) and resolution.get("disposition") in _DISPOSITIONED
        }
        if not dispositioned:
            return []

        with open(os.path.join(run_dir, "review.json"), encoding="utf-8") as fh:
            data = json.load(fh)
        if not isinstance(data, dict) or data.get("round") != round_num:
            return []
        findings = data.get("findings") if isinstance(data, dict) else []
        if not isinstance(findings, list):
            findings = []

        current_blocking = {
            finding.get("id")
            for finding in findings
            if isinstance(finding, dict)
            and finding.get("id")
            and str(finding.get("severity", "")).strip().upper() in _BLOCKING
        }
        return sorted(current_blocking & dispositioned)
    except Exception:
        return []


PROCEED = "proceed"
REVISE = "revise"
PARK = "park"
PROCEED_DISSENT = "proceed-dissent"

_SPEC_CONFLICT = "spec-conflict"


def _is_spec_conflict(resolution):
    # A blocking review finding is routed to proceed-with-tracked-dissent ONLY when the driver
    # has explicitly recorded a `spec-conflict` disposition WITH a non-empty rationale — the same
    # no-laundering fail-safe as plan-stage self-mitigation (#77): a bare tag with no rationale
    # still blocks. `disposition` is DRIVER-territory only; the review/red-team prompts never emit
    # it, so the engine never auto-classifies its own finding as a spec-conflict.
    if not isinstance(resolution, dict):
        return False
    if str(resolution.get("disposition", "")).strip().lower() != _SPEC_CONFLICT:
        return False
    rationale = resolution.get("rationale")
    return isinstance(rationale, str) and bool(rationale.strip())


def spec_conflict_floor(rc, run_dir, target, round):
    """Return (eligible, finding_ids) for the proceed-with-tracked-dissent terminus (#108).

    A spec-premise conflict is a reviewer objecting to the design the issue itself MANDATED. It is
    NOT covered by the #103 materiality floor (that floor is for immaterial beyond-diff hardening).
    Eligibility is deliberately narrow and fails closed: the run must be mechanically sound — the
    deterministic gate audit green, the review fresh for this exact target/diff/round, tidiness
    clear, every AC met — AND every current-round blocking review finding validly dispositioned
    `spec-conflict`. That bounds the exception to "tests pass, the mandated design's own ACs are
    met, but a reviewer objects to the premise." Any other unresolved blocking finding (a real bug)
    keeps the run on revise.
    """
    if rc == 0:
        return False, []
    try:
        target_root = os.path.abspath(target)
        if not (
            gates_all_green(run_dir)
            and review_current_and_clean(run_dir, target_root, round)
            and tidiness_clear(run_dir)
            and acs_all_met(run_dir)
        ):
            return False, []
        data = _read_review_json(run_dir)
        if data is None:
            return False, []
        findings = data.get("findings")
        if not isinstance(findings, list):
            return False, []
        blocking = [
            finding for finding in findings
            if isinstance(finding, dict)
            and str(finding.get("severity", "")).strip().upper() in _BLOCKING
        ]
        if not blocking:
            return False, []
        resolutions = DecisionLog(run_dir).read_resolutions(round=round)
        ids = []
        for finding in blocking:
            finding_id = finding.get("id")
            if not finding_id:
                return False, []
            if not _is_spec_conflict(resolutions.get(finding_id)):
                return False, []
            ids.append(finding_id)
        return True, sorted(set(ids))
    except Exception:
        return False, []


ASK = "ask"
AUTO = "auto"
PARK_LOUD = "park-loud"


def terminus_action(unattended: bool, interactive: bool) -> str:
    """Decide how a human-facing terminus resolves (#108) — never auto-select a recommended
    option after a denied prompt.

    unattended            -> 'auto'       (consult the `sail converge` oracle; issue no prompt)
    interactive, hands-on -> 'ask'        (a human is present; AskUserQuestion is fine)
    neither               -> 'park-loud'  (headless without --unattended: PARK + write a durable
                                           handoff BEFORE prompting, never fall back to a default)
    """
    if unattended:
        return AUTO
    if interactive:
        return ASK
    return PARK_LOUD


def write_handoff(run_dir, reason, resume_cmd, issue=None, finding_ids=None):
    """Write a durable wip-handoff.md recording why the unattended run stopped, which findings
    are outstanding, and the exact command to resume (#108 AC6). Returns the path written.
    """
    os.makedirs(run_dir, exist_ok=True)
    ids = finding_ids if isinstance(finding_ids, (list, tuple)) else []
    ids = [str(i).strip() for i in ids if str(i).strip()]
    lines = [
        "# /sail WIP handoff",
        "",
        f"- stop reason: {reason}",
    ]
    if issue is not None and str(issue).strip():
        lines.append(f"- issue: #{str(issue).strip().lstrip('#')}")
    if ids:
        lines.append(f"- outstanding finding ids: {', '.join(ids)}")
    lines += [
        "",
        "## Resume",
        "",
        "```",
        str(resume_cmd),
        "```",
        "",
    ]
    path = os.path.join(run_dir, "wip-handoff.md")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    return path


def loop_decision(rc: int, round_num: int, max_rounds: int = 3) -> str:
    """Return the loop decision: 'proceed' | 'revise' | 'park'.

    rc == 0            -> 'proceed' (green; stop — do not chase non-blocking LOWs)
    rc != 0, under cap -> 'revise'
    rc != 0, at cap    -> 'park'   (genuine non-convergence backstop)
    """
    if rc == 0:
        return PROCEED
    if round_num < max_rounds:
        return REVISE
    return PARK
