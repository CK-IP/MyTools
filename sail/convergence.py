"""Autonomous-mode convergence oracle (#77).

The deterministic loop decision the autonomous `/sail` driver (under `/surf`) consults
instead of eyeballing a "continue / abort / proceed" judgment a human used to make.

Contract: `rc` is the exit code of the gate that just ran (`sail run` / `sail review` /
`sail plan`), whose contract is `0 = green, non-zero = not green`. Any non-zero rc
(1, 127, ...) is treated uniformly as "not green". `round_num` is the 1-based count of
review rounds run so far; `max_rounds` is the genuine-non-convergence backstop (default 10).

This encodes the discipline:
  - exit 0 is the stop signal — LOW/MEDIUM findings never flip the exit code, so a green
    light stays green and the driver never spins another round to chase tidiness ("LOWs
    are non-blocking and are not chased past green").
  - while not green and under the cap, revise and re-review.
  - at the cap with the gate still red, PARK for a human rather than loop forever.
"""

from __future__ import annotations

import json
import math
import os
import shlex
import subprocess
from collections import Counter
from datetime import datetime, timezone
from typing import Any

from sail.decisionlog import DecisionLog
from sail import review as review_mod
from sail import codexlatch


_DISPOSITIONED = {"rejected", "deferred"}
_BLOCKING = {"CRITICAL", "HIGH"}
_TREND_LEDGER = "trend-ledger.jsonl"


def _read_review_json(run_dir):
    with open(os.path.join(run_dir, "review.json"), encoding="utf-8") as fh:
        data = json.load(fh)
    return data if isinstance(data, dict) else None


def _read_run_state_json(run_dir):
    with open(os.path.join(run_dir, "run-state.json"), encoding="utf-8") as fh:
        data = json.load(fh)
    return data if isinstance(data, dict) else None


def _parse_iso_utc(value: object) -> datetime | None:
    if value is None:
        return None
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def max_blocking_severity_rank(findings: object) -> int:
    if not isinstance(findings, list):
        return 0
    saw_high = False
    for finding in findings:
        if not isinstance(finding, dict):
            continue
        severity = str(finding.get("severity", "")).strip().upper()
        if severity == "CRITICAL":
            return 2
        if severity == "HIGH":
            saw_high = True
    return 1 if saw_high else 0


def dominant_area_for_findings(findings: object) -> str | None:
    if not isinstance(findings, list) or not findings:
        return None
    counts: Counter[str] = Counter()
    for finding in findings:
        if not isinstance(finding, dict):
            continue
        severity = str(finding.get("severity", "")).strip().upper()
        if severity not in _BLOCKING:
            continue
        area = finding.get("file")
        if not isinstance(area, str):
            continue
        area = area.strip()
        if not area:
            continue
        counts[area] += 1
    if not counts:
        return None
    top_count = max(counts.values())
    top_areas = [area for area, count in counts.items() if count == top_count]
    return top_areas[0] if len(top_areas) == 1 else None


def _normalized_fingerprint(value: object) -> str | None:
    if value is None:
        return None
    fingerprint = str(value).strip()
    return fingerprint if fingerprint else None


def _normalized_fingerprint_list(values: object) -> list[str]:
    if not isinstance(values, list):
        return []
    out: list[str] = []
    seen: set[str] = set()
    for value in values:
        fingerprint = _normalized_fingerprint(value)
        if fingerprint is None or fingerprint in seen:
            continue
        seen.add(fingerprint)
        out.append(fingerprint)
    return out


def _finding_fingerprint(finding: object) -> str | None:
    if not isinstance(finding, dict):
        return None
    finding_id = _normalized_fingerprint(finding.get("id"))
    if finding_id is None:
        return None
    file_name = _normalized_fingerprint(finding.get("file")) or ""
    return f"{file_name}::{finding_id}"


def _blocking_fingerprints_for_findings(findings: object) -> list[str]:
    if not isinstance(findings, list):
        return []
    fingerprints: list[str] = []
    seen: set[str] = set()
    for finding in findings:
        if not isinstance(finding, dict):
            continue
        severity = str(finding.get("severity", "")).strip().upper()
        if severity not in _BLOCKING:
            continue
        fingerprint = _finding_fingerprint(finding)
        if fingerprint is None or fingerprint in seen:
            continue
        seen.add(fingerprint)
        fingerprints.append(fingerprint)
    return fingerprints


def _addressed_fingerprints_for_findings(
    findings: object, resolutions: object
) -> list[str]:
    if not isinstance(findings, list) or not isinstance(resolutions, dict):
        return []
    fingerprints: list[str] = []
    seen: set[str] = set()
    for finding in findings:
        if not isinstance(finding, dict):
            continue
        severity = str(finding.get("severity", "")).strip().upper()
        if severity not in _BLOCKING:
            continue
        finding_id = finding.get("id")
        if not finding_id:
            continue
        resolution = resolutions.get(finding_id)
        if not isinstance(resolution, dict):
            continue
        if str(resolution.get("disposition", "")).strip().lower() != "addressed":
            continue
        fingerprint = _finding_fingerprint(finding)
        if fingerprint is None or fingerprint in seen:
            continue
        seen.add(fingerprint)
        fingerprints.append(fingerprint)
    return fingerprints


def read_trend(run_dir: str | None) -> list[dict[str, Any]]:
    if not run_dir:
        return []
    path = os.path.join(run_dir, _TREND_LEDGER)
    rows: dict[int, dict[str, Any]] = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    item = json.loads(line)
                except (TypeError, ValueError):
                    continue
                if not isinstance(item, dict):
                    continue
                raw_round = item.get("round")
                raw_rank = item.get("max_blocking_severity_rank")
                raw_addressed = item.get("addressed_count")
                if raw_round is None or raw_rank is None or raw_addressed is None:
                    continue
                try:
                    round_num = int(raw_round)
                    max_rank = int(raw_rank)
                    addressed_count = int(raw_addressed)
                except (TypeError, ValueError):
                    continue
                rows[round_num] = {
                    "round": round_num,
                    "max_blocking_severity_rank": max_rank,
                    "addressed_count": addressed_count,
                    "area": item.get("area"),
                    "blocking_fingerprints": _normalized_fingerprint_list(
                        item.get("blocking_fingerprints")
                    ),
                    "addressed_fingerprints": _normalized_fingerprint_list(
                        item.get("addressed_fingerprints")
                    ),
                }
    except OSError:
        return []
    return [rows[key] for key in sorted(rows)]


def record_trend_row(
    run_dir: str | None,
    round_num: int,
    max_rank: int,
    addressed_count: int,
    area: str | None = None,
    blocking_fingerprints: object = None,
    addressed_fingerprints: object = None,
) -> bool:
    if not run_dir:
        return False
    os.makedirs(run_dir, exist_ok=True)
    try:
        round_num = int(round_num)
        max_rank = int(max_rank)
        addressed_count = int(addressed_count)
    except (TypeError, ValueError):
        return False
    if any(row.get("round") == round_num for row in read_trend(run_dir)):
        return False
    path = os.path.join(run_dir, _TREND_LEDGER)
    payload = {
        "round": round_num,
        "max_blocking_severity_rank": max_rank,
        "addressed_count": addressed_count,
        "area": area,
        "blocking_fingerprints": _normalized_fingerprint_list(blocking_fingerprints),
        "addressed_fingerprints": _normalized_fingerprint_list(addressed_fingerprints),
    }
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(payload) + "\n")
    return True


def trend_no_progress_streak(rows: Any) -> int:
    try:
        if isinstance(rows, (str, bytes)):
            return 0
        iterable = list(rows)
    except TypeError:
        return 0
    normalized = {}
    for row in iterable:
        if not isinstance(row, dict):
            continue
        raw_round = row.get("round")
        if raw_round is None:
            continue
        try:
            round_num = int(raw_round)
            max_rank = int(row.get("max_blocking_severity_rank", 0))
            addressed_count = int(row.get("addressed_count", 0))
        except (TypeError, ValueError):
            continue
        normalized[round_num] = {
            "round": round_num,
            "max_blocking_severity_rank": max_rank,
            "addressed_count": addressed_count,
        }
    ordered = [normalized[key] for key in sorted(normalized)]
    if not ordered:
        return 0
    streak = 0
    prev_rank = ordered[0]["max_blocking_severity_rank"]
    for row in ordered[1:]:
        rank = row["max_blocking_severity_rank"]
        addressed_count = row["addressed_count"]
        if rank < prev_rank or addressed_count > 0:
            streak = 0
        else:
            streak += 1
        prev_rank = rank
    return streak


def trend_window() -> int:
    raw = os.environ.get("SAIL_TREND_WINDOW", "3")
    try:
        window = int(raw)
    except (TypeError, ValueError):
        return 3
    return window if window > 0 else 3


def saturation_window() -> int:
    raw = os.environ.get("SAIL_SATURATION_WINDOW", "3")
    try:
        window = int(raw)
    except (TypeError, ValueError):
        return 3
    return window if window > 0 else 3


def trend_stalled(rows: object, window: int | None = None) -> bool:
    try:
        if window is None:
            window = trend_window()
        return trend_no_progress_streak(rows) >= int(window)
    except (TypeError, ValueError):
        return False


def addressed_reappearance_streak(rows: Any) -> int:
    try:
        if isinstance(rows, (str, bytes)):
            return 0
        iterable = list(rows)
    except TypeError:
        return 0

    normalized: dict[int, dict[str, Any]] = {}
    for row in iterable:
        if not isinstance(row, dict):
            continue
        raw_round = row.get("round")
        if raw_round is None:
            continue
        try:
            round_num = int(raw_round)
        except (TypeError, ValueError):
            continue
        normalized[round_num] = {
            "round": round_num,
            "blocking_fingerprints": _normalized_fingerprint_list(
                row.get("blocking_fingerprints")
            ),
            "addressed_fingerprints": _normalized_fingerprint_list(
                row.get("addressed_fingerprints")
            ),
        }
    ordered = [normalized[key] for key in sorted(normalized)]
    if not ordered:
        return 0

    latest_blocking = set(ordered[-1]["blocking_fingerprints"])
    if not latest_blocking:
        return 0

    best_streak = 0
    for fingerprint in latest_blocking:
        streak = 0
        for row in reversed(ordered):
            if fingerprint not in row["blocking_fingerprints"]:
                break
            if fingerprint not in row["addressed_fingerprints"]:
                break
            streak += 1
        if streak > best_streak:
            best_streak = streak
    return best_streak - 1 if best_streak > 0 else 0


def same_area_saturation_streak(rows: Any) -> int:
    try:
        if isinstance(rows, (str, bytes)):
            return 0
        iterable = list(rows)
    except TypeError:
        return 0
    normalized: dict[int, dict[str, Any]] = {}
    for row in iterable:
        if not isinstance(row, dict):
            continue
        raw_round = row.get("round")
        if raw_round is None:
            continue
        try:
            round_num = int(raw_round)
        except (TypeError, ValueError):
            continue
        normalized[round_num] = {
            "round": round_num,
            "area": row.get("area"),
        }
    ordered = [normalized[key] for key in sorted(normalized)]
    if not ordered:
        return 0
    latest_area = ordered[-1].get("area")
    if latest_area is None:
        return 0
    streak = 1
    for row in reversed(ordered[:-1]):
        area = row.get("area")
        if area is None or area != latest_area:
            break
        streak += 1
    return streak


def area_saturated(rows: Any, window: int | None = None) -> bool:
    try:
        if window is None:
            window = saturation_window()
        window = int(window)
        if window <= 0:
            return False
        return same_area_saturation_streak(rows) >= window
    except (TypeError, ValueError):
        return False


def last_resume_at(run_dir: str | None) -> str | None:
    if not run_dir:
        return None
    try:
        lines = DecisionLog(run_dir)._read_lines()
    except Exception:
        return None
    prefix = "- ↺ resume "
    latest: str | None = None
    for line in lines:
        if not isinstance(line, str):
            continue
        if not line.startswith(prefix):
            continue
        candidate = line[len(prefix):].strip()
        if not candidate:
            continue
        if latest is None or candidate > latest:
            latest = candidate
    return latest


_UNKNOWN_SESSION = "_nosession"  # mirrors codexlatch.session_token()'s no-session sentinel


def is_cross_session_resume(
    resumed: bool, prior_session: str | None, current_session: str | None
) -> bool:
    """Should this `sail run` invocation write a cost-clock-resetting resume marker?

    A resume marker resets the cost-backstop's wall-clock window (so a parked-then-resumed
    run gets a fresh budget). It must fire ONLY on a genuine cross-session re-entry — the run
    was parked and a NEW session picked it up — NOT on a same-session convergence-round re-run
    into the same run-dir, which would otherwise collapse the cumulative cost window to the
    current round and defeat the PRIMARY runaway guard (#130 review r3 HIGH).

    Conservative: a reset fires only when BOTH sessions are KNOWN and differ. When either side
    is unknown (the `_nosession` sentinel, or unrecorded), re-entry cannot be reliably detected,
    so we do NOT reset — the clock keeps measuring cumulatively from started_at, the safe
    direction for a runaway guard.
    """
    if not resumed:
        return False
    if not prior_session or prior_session == _UNKNOWN_SESSION:
        return False
    if not current_session or current_session == _UNKNOWN_SESSION:
        return False
    return prior_session != current_session


def effective_started_at(run_dir: str | None) -> str | None:
    # The cost clock measures from a durable run-state anchor that resets ONLY on a genuine
    # cross-session resume (set by the runner via is_cross_session_resume) — NOT on same-session
    # convergence-round re-runs, which each append an audit resume marker but must not collapse
    # the cumulative cost window to one round (#130 review r3 HIGH). A hand-seeded run-state with
    # no anchor falls back to the legacy later-of(started_at, most-recent resume marker) behavior.
    anchor = cost_anchor_at(run_dir)
    if anchor is not None:
        return anchor
    started_at = run_started_at(run_dir)
    resume_at = last_resume_at(run_dir)
    if started_at is None:
        return resume_at
    if resume_at is None:
        return started_at

    started = _parse_iso_utc(started_at)
    resumed = _parse_iso_utc(resume_at)
    if started is not None and resumed is not None:
        return resume_at if resumed >= started else started_at
    if resumed is not None:
        return resume_at
    if started is not None:
        return started_at
    return started_at


def elapsed_seconds(run_dir: str | None) -> float | None:
    started_at = effective_started_at(run_dir)
    started = _parse_iso_utc(started_at)
    if started is None:
        return None
    return (datetime.now(timezone.utc) - started).total_seconds()


def cost_surface_line(elapsed: float) -> str:
    return f"sail converge: elapsed {elapsed:.3f}s wall-time (tokens unavailable to sail/)"


def cost_ceiling_seconds() -> float | None:
    """Return the active cost ceiling in seconds.

    Unset uses the documented 14400s (4h) default. Invalid or non-positive values fail open to None.
    """
    raw = os.environ.get("SAIL_COST_CEILING_SECONDS")
    if raw is None:
        return 14400.0
    try:
        ceiling = float(raw)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(ceiling) or ceiling <= 0:
        return None
    return ceiling


def cost_exceeded(elapsed: float | None, ceiling: float | None) -> bool:
    try:
        if elapsed is None or ceiling is None or ceiling <= 0:
            return False
        return elapsed > ceiling
    except (TypeError, ValueError):
        return False


def run_started_at(run_dir: str | None) -> str | None:
    try:
        if not run_dir:
            return None
        data = _read_run_state_json(run_dir)
        if not isinstance(data, dict):
            return None
        started_at = data.get("started_at")
        return started_at if isinstance(started_at, str) and started_at else None
    except Exception:
        return None


def cost_anchor_at(run_dir: str | None) -> str | None:
    """The cost clock's start anchor: run-state `cost_anchor_at`, reset only on a genuine
    cross-session resume. None when absent (legacy/seeded run-state) so the caller falls back."""
    try:
        if not run_dir:
            return None
        data = _read_run_state_json(run_dir)
        if not isinstance(data, dict):
            return None
        anchor = data.get("cost_anchor_at")
        return anchor if isinstance(anchor, str) and anchor else None
    except Exception:
        return None


def addressed_count_for_round(run_dir: str | None, round_num: int) -> int:
    try:
        resolutions = DecisionLog(run_dir).read_resolutions(round=round_num)
        count = 0
        for resolution in resolutions.values():
            if not isinstance(resolution, dict):
                continue
            if str(resolution.get("disposition", "")).strip().lower() == "addressed":
                count += 1
        return count
    except Exception:
        return 0


def hydrate_trend_row(run_dir: str | None, target: str, round_num: int) -> int | None:
    try:
        target_root = os.path.abspath(target)
        if not review_current_and_clean(run_dir, target_root, round_num):
            return None
        data = _read_review_json(run_dir)
        if not isinstance(data, dict):
            return None
        findings = data.get("findings")
        if not isinstance(findings, list):
            return None
        rank = max_blocking_severity_rank(findings)
        area = dominant_area_for_findings(findings)
        addressed = addressed_count_for_round(run_dir, round_num)
        resolutions = DecisionLog(run_dir).read_resolutions(round=round_num)
        record_trend_row(
            run_dir,
            round_num,
            rank,
            addressed,
            area=area,
            blocking_fingerprints=_blocking_fingerprints_for_findings(findings),
            addressed_fingerprints=_addressed_fingerprints_for_findings(findings, resolutions),
        )
        return rank
    except Exception:
        return None


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
        stored_domain_hash = data.get("domain_hash")
        if review_mod.domain_hash_stale(os.path.abspath(target), stored_domain_hash):
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


def loop_decision(rc: int, round_num: int, max_rounds: int = 10) -> str:
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
