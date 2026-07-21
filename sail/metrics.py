from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from typing import Any

from sail.decisionlog import DecisionLog
from sail.runstate import _utc_now_iso
from sail.review import degraded_lenses, degraded_tone


_SHIPPED_TERMINI = {"merged-green", "proceed-hardening", "proceed-dissent"}
_KNOWN_SEVERITIES = {"CRITICAL", "HIGH", "MEDIUM", "LOW"}


def _read_json_file(path: str) -> Any:
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def _maybe_int(value: object) -> int | None:
    try:
        if value is None or value == "":
            return None
        if not isinstance(value, (int, float, str)):
            return None
        return int(value)
    except (TypeError, ValueError):
        return None


def _maybe_float(value: object) -> float | None:
    try:
        if value is None or value == "":
            return None
        if not isinstance(value, (int, float, str)):
            return None
        return float(value)
    except (TypeError, ValueError):
        return None


def _text(value: object) -> str:
    return "" if value is None else str(value)


def _normalise_mapping(value: object) -> dict[str, Any]:
    return dict(value) if isinstance(value, dict) else {}


def _coerce_backend_map(value: object) -> dict[str, Any]:
    if isinstance(value, dict):
        return {
            "build": value.get("build"),
            "review": value.get("review"),
            "review2": value.get("review2"),
            "redteam": value.get("redteam"),
        }
    return {"build": None, "review": None, "review2": None, "redteam": None}


def _env_backends() -> dict[str, Any]:
    # The backends the run actually used, read from the SAIL_* env. Deterministic and keeps the CLI
    # shim thin (AC: no logic in the shim): the driver just calls `sail metrics record` with its run
    # environment already set — no per-backend flags to thread through the shell. Used ONLY as a
    # last-resort fallback when no explicit backends arg and no review-recorded backends are present,
    # so a hermetic test that clears SAIL_* (and passes backends explicitly) is unaffected.
    return {
        "build": os.environ.get("SAIL_BUILD_CMD"),
        "review": os.environ.get("SAIL_REVIEW_CMD"),
        "review2": os.environ.get("SAIL_REVIEW_CMD2"),
        "redteam": os.environ.get("SAIL_REDTEAM_CMD"),
    }


def _primary_worktree_root(path: str) -> str | None:
    path = os.path.abspath(path)
    try:
        result = subprocess.run(
            ["git", "-C", path, "rev-parse", "--git-dir"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None

    gitdir = result.stdout.strip()
    if not gitdir:
        return None
    if not os.path.isabs(gitdir):
        gitdir = os.path.abspath(os.path.join(path, gitdir))

    common_dir = gitdir
    commondir_path = os.path.join(gitdir, "commondir")
    try:
        with open(commondir_path, encoding="utf-8") as fh:
            raw_common = fh.read().strip()
        if raw_common:
            common_dir = raw_common if os.path.isabs(raw_common) else os.path.abspath(
                os.path.join(gitdir, raw_common)
            )
    except OSError:
        pass

    return os.path.abspath(os.path.dirname(common_dir))


def resolve_ledger_path(start: str | None = None) -> str:
    start = os.path.abspath(start or os.getcwd())
    if os.path.basename(start) == "metrics.jsonl":
        return start
    root = _primary_worktree_root(start) or start
    return os.path.join(root, ".sail", "metrics.jsonl")


def _resolve_issue(issue: object, run_dir: str, run_state: dict[str, Any] | None) -> str:
    if issue is not None and str(issue).strip():
        return str(issue).strip().lstrip("#")
    if isinstance(run_state, dict):
        state_issue = run_state.get("issue")
        if state_issue is not None and str(state_issue).strip():
            return str(state_issue).strip().lstrip("#")
    base = os.path.basename(os.path.abspath(run_dir))
    match = re.search(r"(^|[-_])sail-(\d+)(?:[-_].*)?$", base)
    if match:
        return match.group(2)
    match = re.search(r"(\d+)", base)
    if match:
        return match.group(1)
    return ""


def _gate_summary(gates: object) -> dict[str, int]:
    summary = {"passed": 0, "failed": 0, "skipped": 0, "pending": 0, "running": 0}
    if not isinstance(gates, list):
        return summary
    for gate in gates:
        if not isinstance(gate, dict):
            continue
        status = str(gate.get("status", "")).strip().lower()
        if status in summary:
            summary[status] += 1
    return summary


def _finding_counts(findings: object) -> dict[str, dict[str, int]]:
    by_severity: Counter[str] = Counter()
    by_lens: Counter[str] = Counter()
    if isinstance(findings, list):
        for finding in findings:
            if not isinstance(finding, dict):
                continue
            severity = str(finding.get("severity", "")).strip().upper()
            if severity in _KNOWN_SEVERITIES:
                by_severity[severity] += 1
            lens = str(finding.get("lens", "")).strip()
            if lens:
                by_lens[lens] += 1
    return {
        "by_severity": {sev: by_severity.get(sev, 0) for sev in sorted(_KNOWN_SEVERITIES)},
        "by_lens": dict(sorted(by_lens.items())),
    }


def _disposition_mix(run_dir: str) -> dict[str, int]:
    mix: Counter[str] = Counter()
    try:
        resolutions = DecisionLog(run_dir).read_resolutions()
    except Exception:
        return {}
    if isinstance(resolutions, dict):
        for resolution in resolutions.values():
            if not isinstance(resolution, dict):
                continue
            disposition = str(resolution.get("disposition", "")).strip().lower()
            if disposition:
                mix[disposition] += 1
    return dict(sorted(mix.items()))


def _coerce_cost(record: dict[str, Any]) -> None:
    cost = _maybe_float(record.get("cost_usd"))
    record["cost_usd"] = cost
    tokens = _maybe_int(record.get("tokens"))
    record["tokens"] = tokens


def _normalise_record(row: object) -> dict[str, Any] | None:
    if not isinstance(row, dict):
        return None
    record_type = str(row.get("type") or "cycle").strip() or "cycle"
    run_id = _text(row.get("run_id")).strip()
    if not run_id:
        return None

    record: dict[str, Any] = {
        "type": record_type,
        "run_id": run_id,
        "issue": _text(row.get("issue")).strip().lstrip("#"),
        "started_at": row.get("started_at", row.get("started")),
        "finished_at": row.get("finished_at", row.get("finished")),
        "plan_rounds": _maybe_int(row.get("plan_rounds")),
        "review_rounds": _maybe_int(row.get("review_rounds")),
        "gate_summary": _normalise_mapping(row.get("gate_summary") or row.get("gate_outcome_summary")),
        "gate_outcome_summary": _normalise_mapping(
            row.get("gate_outcome_summary") or row.get("gate_summary")
        ),
        "finding_counts": _normalise_mapping(row.get("finding_counts")),
        "disposition_mix": _normalise_mapping(row.get("disposition_mix")),
        "terminus": _text(row.get("terminus")).strip(),
        "degraded": bool(row.get("degraded", False)),
        "degraded_flags": _normalise_mapping(row.get("degraded_flags")),
        "backends": _coerce_backend_map(row.get("backends")),
        "backends_used": _coerce_backend_map(row.get("backends_used") or row.get("backends")),
        "tokens": row.get("tokens"),
        "cost_usd": row.get("cost_usd"),
    }
    _coerce_cost(record)
    record["started"] = record["started_at"]
    record["finished"] = record["finished_at"]
    return record


def read_ledger(ledger_path: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    try:
        with open(ledger_path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    item = json.loads(line)
                except (TypeError, ValueError):
                    continue
                record = _normalise_record(item)
                if record is not None:
                    rows.append(record)
    except FileNotFoundError:
        return []
    except OSError:
        return []
    return rows


def _record_key(record: dict[str, Any]) -> tuple[str, str] | None:
    # Idempotency key for append dedup — CYCLE records ONLY. A resumed/re-entered cycle re-emits the
    # same run_id and must collapse to one line (#146 risk 1). Escapes (and any non-cycle event) are
    # EVENTS, not idempotent-per-run: an escape reuses its LINKED shipped run_id for report linkage,
    # so keying dedup on run_id would silently drop a SECOND distinct defect traced to the same merge.
    # Return None for non-cycle records so they always append.
    record_type = _text(record.get("type") or "cycle").strip() or "cycle"
    if record_type != "cycle":
        return None
    run_id = _text(record.get("run_id")).strip()
    if not run_id:
        return None
    return record_type, run_id


def append_record(record: dict[str, Any], ledger_path: str) -> dict[str, Any]:
    key = _record_key(record)
    if key is not None:
        for existing in read_ledger(ledger_path):
            if _record_key(existing) == key:
                return existing

    parent = os.path.dirname(os.path.abspath(ledger_path))
    if parent:
        os.makedirs(parent, exist_ok=True)

    payload = json.dumps(record).encode("utf-8") + b"\n"
    fd = os.open(ledger_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        written = os.write(fd, payload)
        if written != len(payload):
            raise OSError(f"short write to {ledger_path}")
    finally:
        os.close(fd)
    return record


@dataclass(slots=True)
class MetricRecord:
    type: str
    issue: str
    run_id: str
    started_at: str | None = None
    finished_at: str | None = None
    plan_rounds: int | None = None
    review_rounds: int | None = None
    gate_summary: dict[str, int] = field(default_factory=dict)
    gate_outcome_summary: dict[str, int] = field(default_factory=dict)
    finding_counts: dict[str, dict[str, int]] = field(
        default_factory=lambda: {"by_severity": {}, "by_lens": {}}
    )
    disposition_mix: dict[str, int] = field(default_factory=dict)
    terminus: str = ""
    degraded: bool = False
    degraded_flags: dict[str, Any] = field(default_factory=dict)
    backends: dict[str, Any] = field(default_factory=dict)
    backends_used: dict[str, Any] = field(default_factory=dict)
    tokens: int | None = None
    cost_usd: float | None = None
    mode: str | None = None
    note: str | None = None
    linked_run_id: str | None = None
    linked_finished_at: str | None = None
    started: str | None = None
    finished: str | None = None

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["started"] = data["started_at"]
        data["finished"] = data["finished_at"]
        data["gate_outcome_summary"] = dict(data["gate_outcome_summary"] or data["gate_summary"])
        data["gate_summary"] = dict(data["gate_summary"] or data["gate_outcome_summary"])
        data["backends_used"] = dict(data["backends_used"] or data["backends"])
        data["backends"] = dict(data["backends"] or data["backends_used"])
        data["finding_counts"] = {
            "by_severity": dict((data["finding_counts"] or {}).get("by_severity", {})),
            "by_lens": dict((data["finding_counts"] or {}).get("by_lens", {})),
        }
        data["disposition_mix"] = dict(data["disposition_mix"] or {})
        data["degraded_flags"] = dict(data["degraded_flags"] or {})
        return data


def _cycle_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    # Collapse duplicate cycle run_ids at read time (keep first-by-line-order). append_record's
    # best-effort check-then-act guard cannot be atomic without a file lock, so a concurrent
    # orphan-resume finalize race could slip two lines for one run_id into the ledger; a read-side
    # collapse guarantees no double-counting in any rate regardless (#146 review). Rows without a
    # run_id are kept as-is (they carry no identity to dedup on).
    out: list[dict[str, Any]] = []
    seen: set[str] = set()
    for row in rows:
        if _text(row.get("type") or "cycle").strip() != "cycle":
            continue
        run_id = _text(row.get("run_id")).strip()
        if run_id:
            if run_id in seen:
                continue
            seen.add(run_id)
        out.append(row)
    return out


def _escape_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [row for row in rows if _text(row.get("type")).strip() == "escape"]


def aggregate(rows: list[dict[str, Any]]) -> dict[str, Any]:
    cycles = _cycle_rows(rows)
    escapes = _escape_rows(rows)
    shipped = [row for row in cycles if _text(row.get("terminus")).strip() in _SHIPPED_TERMINI]
    merged = [row for row in cycles if _text(row.get("terminus")).strip() == "merged-green"]
    parked = [row for row in cycles if _text(row.get("terminus")).strip().startswith("parked")]
    degraded_runs = [row for row in cycles if bool(row.get("degraded"))]
    by_severity: Counter[str] = Counter()
    by_lens: Counter[str] = Counter()
    for row in cycles:
        counts = row.get("finding_counts")
        if not isinstance(counts, dict):
            continue
        sev_counts = counts.get("by_severity")
        if isinstance(sev_counts, dict):
            for key, value in sev_counts.items():
                if key in _KNOWN_SEVERITIES:
                    by_severity[key] += int(value or 0)
        lens_counts = counts.get("by_lens")
        if isinstance(lens_counts, dict):
            for key, value in lens_counts.items():
                if key:
                    by_lens[key] += int(value or 0)

    numeric_review_rounds = [row.get("review_rounds") for row in cycles if row.get("review_rounds") is not None]
    numeric_plan_rounds = [row.get("plan_rounds") for row in cycles if row.get("plan_rounds") is not None]
    total_rounds = [
        (row.get("plan_rounds") or 0) + (row.get("review_rounds") or 0)
        for row in cycles
        if row.get("plan_rounds") is not None or row.get("review_rounds") is not None
    ]

    # TOTAL cost is honest across ALL costed runs (incl. parked runs that burned real cost).
    cost_values = [_maybe_float(row.get("cost_usd")) for row in cycles if row.get("cost_usd") is not None]
    total_cost = sum(value for value in cost_values if value is not None)
    runs_with_cost = len(cost_values)
    # cost-per-merged is per SHIPPED run ONLY — the metric names "cost per merged issue", so a
    # parked-but-costed run must NOT dilute the numerator OR the denominator (#146 review HIGH). A
    # parked run that churned many rounds before parking would otherwise silently skew the number the
    # report exists to make trustworthy for tuning.
    shipped_costs = [float(row["cost_usd"]) for row in shipped if row.get("cost_usd") is not None]
    cost_per_merged = sum(shipped_costs) / len(shipped_costs) if shipped_costs else None

    shipped_termini = [str(row.get("terminus")).strip() for row in shipped]
    escape_rate = len(escapes) / len(shipped) if shipped else None

    def _avg(values: list[object]) -> float | None:
        nums = [float(v) for v in values if isinstance(v, (int, float, str))]
        return sum(nums) / len(nums) if nums else None

    return {
        "cycles": len(cycles),
        "run_count": len(cycles),
        "merged": len(merged),
        "shipped": len(shipped),
        "parked": len(parked),
        "merge_rate": len(merged) / len(cycles) if cycles else None,
        "park_rate": len(parked) / len(cycles) if cycles else None,
        "avg_plan_rounds": _avg(numeric_plan_rounds),
        "avg_review_rounds": _avg(numeric_review_rounds),
        "avg_rounds": _avg(total_rounds),
        "avg_plan_plus_review_rounds": _avg(total_rounds),
        "degraded_runs": len(degraded_runs),
        "degraded_rate": len(degraded_runs) / len(cycles) if cycles else None,
        "escapes": len(escapes),
        "escape_rate": escape_rate,
        "review_escape_rate": escape_rate,
        "by_severity": dict(sorted(by_severity.items())),
        "by_lens": dict(sorted(by_lens.items())),
        "cost": {
            "runs_with_cost": runs_with_cost,
            "total_usd": total_cost,
            "cost_per_merged": cost_per_merged,
        },
        "shipped_termini": shipped_termini,
    }


def _escape_note(note: object) -> str:
    return _text(note).strip()


def build_record(
    run_dir: str,
    issue: object = None,
    terminus: object = None,
    backends: object = None,
    now: str | None = None,
    usage: object = None,
) -> dict[str, Any] | None:
    run_state = _read_json_file(os.path.join(run_dir, "run-state.json"))
    if not isinstance(run_state, dict):
        return None

    review = _read_json_file(os.path.join(run_dir, "review.json"))
    if not isinstance(review, dict):
        review = {}
    plan = _read_json_file(os.path.join(run_dir, "plan.json"))
    if not isinstance(plan, dict):
        plan = {}

    run_id = _text(run_state.get("run_id")).strip()
    if not run_id:
        return None

    issue_text = _resolve_issue(issue, run_dir, run_state)
    started_at = _text(run_state.get("started_at")).strip() or None
    finished_at = _text(now).strip() or _utc_now_iso()
    review_rounds = _maybe_int(review.get("round")) or _maybe_int(run_state.get("review_rounds")) or 0
    plan_rounds = _maybe_int(plan.get("round")) or _maybe_int(run_state.get("plan_rounds")) or 1

    gate_summary = _gate_summary(run_state.get("gates"))
    finding_counts = _finding_counts(review.get("findings"))
    disposition_mix = _disposition_mix(run_dir)
    degraded = degraded_lenses(review)
    degraded_flags = {
        "lenses": degraded,
        "tone": degraded_tone(degraded),
        "dual_lens_requested": bool(review.get("dual_lens_requested")),
        "lens2_ran": bool(review.get("lens2_ran")),
        "lens2_configured": bool(review.get("lens2_configured")),
        "lens2_latched": bool(review.get("lens2_latched")),
        "redteam_requested": bool(review.get("redteam_requested")),
        "redteam_ran": bool(review.get("redteam_ran")),
        "redteam_configured": bool(review.get("redteam_configured")),
        "redteam_latched": bool(review.get("redteam_latched")),
    }

    backends_map = _coerce_backend_map(backends)
    if not any(value is not None for value in backends_map.values()):
        backends_map = _coerce_backend_map(review.get("backends") or review.get("backends_used"))
    if not any(value is not None for value in backends_map.values()):
        backends_map = _env_backends()

    usage_map = usage if isinstance(usage, dict) else {}
    if not usage_map and isinstance(review.get("usage"), dict):
        usage_map = review["usage"]

    record = MetricRecord(
        type="cycle",
        issue=issue_text,
        run_id=run_id,
        started_at=started_at,
        finished_at=finished_at,
        plan_rounds=plan_rounds,
        review_rounds=review_rounds,
        gate_summary=gate_summary,
        gate_outcome_summary=dict(gate_summary),
        finding_counts=finding_counts,
        disposition_mix=disposition_mix,
        # Never default an unresolved terminus to the OPTIMISTIC "merged-green" — a direct API caller
        # that omits terminus would silently inflate the merge rate. Record the honest "unknown"
        # bucket, which aggregate() counts in neither merged, parked, nor shipped (#146 review).
        terminus=_text(terminus).strip() or _text(review.get("terminus")).strip() or "unknown",
        degraded=bool(degraded),
        degraded_flags=degraded_flags,
        backends=backends_map,
        backends_used=dict(backends_map),
        tokens=_maybe_int(usage_map.get("tokens") if isinstance(usage_map, dict) else None),
        cost_usd=_maybe_float(
            usage_map.get("cost_usd") if isinstance(usage_map, dict) else None
        ),
        mode=_text(run_state.get("mode")).strip() or None,
    )
    return record.to_dict()


def record_cycle(
    run_dir: str,
    issue: object = None,
    terminus: object = None,
    ledger_path: str | None = None,
    now: str | None = None,
    backends: object = None,
    usage: object = None,
) -> dict[str, Any] | None:
    try:
        record = build_record(run_dir, issue=issue, terminus=terminus, backends=backends, now=now, usage=usage)
        if record is None:
            return None
        path = ledger_path or resolve_ledger_path(run_dir)
        return append_record(record, path)
    except Exception as exc:  # pragma: no cover - fail-open path
        print(f"sail metrics: record skipped ({exc})", file=sys.stderr)
        return None


def record_escape(
    issue: object,
    note: object,
    ledger_path: str | None = None,
    now: str | None = None,
) -> dict[str, Any] | None:
    try:
        path = ledger_path or resolve_ledger_path()
        rows = read_ledger(path)
        issue_text = _text(issue).strip().lstrip("#")
        candidates = []
        for index, row in enumerate(rows):
            if _text(row.get("type")).strip() != "cycle":
                continue
            if _text(row.get("issue")).strip().lstrip("#") != issue_text:
                continue
            if _text(row.get("terminus")).strip() not in _SHIPPED_TERMINI:
                continue
            finished = row.get("finished_at") or row.get("finished")
            parsed = _parse_iso(finished)
            if parsed is None:
                continue
            candidates.append((parsed, index, row))
        if not candidates:
            return None
        _finished, _index, shipped = max(candidates, key=lambda item: (item[0], item[1]))
        record = MetricRecord(
            type="escape",
            issue=issue_text,
            run_id=_text(shipped.get("run_id")).strip(),
            started_at=None,
            finished_at=_text(now).strip() or _utc_now_iso(),
            plan_rounds=0,
            review_rounds=0,
            gate_summary={},
            gate_outcome_summary={},
            finding_counts={"by_severity": {}, "by_lens": {}},
            disposition_mix={},
            terminus="escape",
            degraded=False,
            degraded_flags={},
            backends={},
            backends_used={},
            tokens=None,
            cost_usd=None,
            mode=None,
            note=_escape_note(note),
            linked_run_id=_text(shipped.get("run_id")).strip(),
            linked_finished_at=_text(shipped.get("finished_at") or shipped.get("finished")).strip() or None,
        )
        return append_record(record.to_dict(), path)
    except Exception as exc:  # pragma: no cover - fail-open path
        print(f"sail metrics: escape skipped ({exc})", file=sys.stderr)
        return None


def _parse_iso(value: object) -> datetime | None:
    if value is None:
        return None
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def report(ledger_path: str | None = None) -> dict[str, Any]:
    try:
        path = ledger_path or resolve_ledger_path()
        return aggregate(read_ledger(path))
    except Exception as exc:  # pragma: no cover - fail-open path
        print(f"sail metrics: report skipped ({exc})", file=sys.stderr)
        return aggregate([])


def _format_rate(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.3f}"


def format_report(summary: dict[str, Any]) -> str:
    lines = [
        f"runs={summary.get('cycles', 0)} merged={summary.get('merged', 0)} parked={summary.get('parked', 0)} shipped={summary.get('shipped', 0)}",
        f"merge_rate={_format_rate(summary.get('merge_rate'))} park_rate={_format_rate(summary.get('park_rate'))} degraded_rate={_format_rate(summary.get('degraded_rate'))}",
        f"avg_plan_rounds={_format_rate(summary.get('avg_plan_rounds'))} avg_review_rounds={_format_rate(summary.get('avg_review_rounds'))} avg_total_rounds={_format_rate(summary.get('avg_rounds'))}",
        f"escapes={summary.get('escapes', 0)} escape_rate={_format_rate(summary.get('escape_rate'))}",
    ]
    cost = summary.get("cost") or {}
    if cost:
        lines.append(
            "cost runs_with_cost={runs_with_cost} total_usd={total_usd:.2f} cost_per_merged={cost_per_merged}".format(
                runs_with_cost=cost.get("runs_with_cost", 0),
                total_usd=float(cost.get("total_usd") or 0.0),
                cost_per_merged="n/a" if cost.get("cost_per_merged") is None else f"{float(cost['cost_per_merged']):.2f}",
            )
        )
    by_sev = (summary.get("by_severity") or {})
    if by_sev:
        lines.append("by_severity " + " ".join(f"{k}={v}" for k, v in sorted(by_sev.items())))
    by_lens = (summary.get("by_lens") or {})
    if by_lens:
        lines.append("by_lens " + " ".join(f"{k}={v}" for k, v in sorted(by_lens.items())))
    if summary.get("shipped_termini"):
        lines.append("shipped_termini " + " ".join(summary["shipped_termini"]))
    return "\n".join(lines)

