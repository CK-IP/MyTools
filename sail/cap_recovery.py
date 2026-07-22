from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from typing import Optional

try:
    from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
except Exception:  # pragma: no cover - Python < 3.9 fallback path.
    ZoneInfo = None  # type: ignore[assignment,misc]

    class ZoneInfoNotFoundError(Exception):  # type: ignore[no-redef]
        pass


DEFAULT_TAIL_LINES = 3
DEFAULT_MIN_BACKOFF_SECS = 300
DEFAULT_DEFAULT_BACKOFF_SECS = 5 * 60 * 60
DEFAULT_WALL_CLOCK_CEILING_SECS = 8 * 24 * 60 * 60
# Timing rule 5 (#163): retry a few minutes PAST the reported reset so the first attempt after the
# reset actually clears instead of racing the reset boundary. Default to 120s; jitter stays 0 by
# default (a single supervisor/watcher does not need de-sync spread, but the knob exists).
DEFAULT_POST_RESET_MARGIN_SECS = 120
DEFAULT_POST_RESET_JITTER_SECS = 0

WEEKDAY_TO_INDEX = {
    "monday": 0,
    "tuesday": 1,
    "wednesday": 2,
    "thursday": 3,
    "friday": 4,
    "saturday": 5,
    "sunday": 6,
}

MONTHS = {
    "january": 1,
    "february": 2,
    "march": 3,
    "april": 4,
    "may": 5,
    "june": 6,
    "july": 7,
    "august": 8,
    "september": 9,
    "october": 10,
    "november": 11,
    "december": 12,
}

# A genuine subscription usage cap ALWAYS carries an explicit cap PHRASE (the reset time is
# auxiliary). Classification keys ONLY off this allowlist — never off a bare parseable date/clock —
# so a benign line that merely mentions a date (e.g. "next run scheduled 8pm") can never be mistaken
# for a cap (the false-positive the retired bash CAP_NOTICE_RE tail-anchoring guarded against). The
# `\d+[- ]?hour limit` alt covers a "5-hour limit reached" wording; bare "limit reached" is
# deliberately NOT here (it matches benign "max retries limit reached").
CAP_PHRASE_RE = re.compile(
    r"(?ix)"
    r"\b("
    r"session\s+limit|"
    r"usage\s+limit|"
    r"weekly\s+limit|"
    r"usage\s+cap|"
    r"\d+[-\s]?hour\s+limit|"
    r"limit\s+will\s+reset|"
    r"try\s+again\s+later|"
    r"hit\s+your\s+.*limit"
    r")\b"
)

TIME_RE = re.compile(r"(?i)\b(\d{1,2})(?::(\d{2}))?\s*([ap]m)\b")
RFC3339_RE = re.compile(r"\b(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\b")
TZ_RE = re.compile(r"\(([A-Za-z_]+/[A-Za-z_]+)\)")


def _read_env_int(*names, default):
    for name in names:
        raw = os.environ.get(name)
        if raw is None:
            continue
        try:
            value = int(raw)
        except (TypeError, ValueError):
            continue
        if value > 0:
            return value
    return default


def ceiling_seconds() -> int:
    return _read_env_int(
        "SAIL_CAP_RECOVERY_WALL_CLOCK_CEILING_SECS",
        "SURF_CAP_RECOVERY_WALL_CLOCK_CEILING_SECS",
        "SURF_RESUME_WALL_CLOCK_CEILING_SECS",
        default=DEFAULT_WALL_CLOCK_CEILING_SECS,
    )


def min_backoff_seconds() -> int:
    return _read_env_int(
        "SAIL_CAP_RECOVERY_MIN_BACKOFF_SECS",
        "SURF_CAP_RECOVERY_MIN_BACKOFF_SECS",
        "SURF_RESUME_MIN_BACKOFF",
        default=DEFAULT_MIN_BACKOFF_SECS,
    )


def default_backoff_seconds() -> int:
    return _read_env_int(
        "SAIL_CAP_RECOVERY_DEFAULT_BACKOFF_SECS",
        "SURF_CAP_RECOVERY_DEFAULT_BACKOFF_SECS",
        "SURF_RESUME_DEFAULT_BACKOFF",
        default=DEFAULT_DEFAULT_BACKOFF_SECS,
    )


def post_reset_margin_seconds() -> int:
    return _read_env_int(
        "SAIL_CAP_RECOVERY_POST_RESET_MARGIN_SECS",
        "SURF_CAP_RECOVERY_POST_RESET_MARGIN_SECS",
        "SURF_RESUME_POST_RESET_MARGIN_SECS",
        default=DEFAULT_POST_RESET_MARGIN_SECS,
    )


def post_reset_jitter_seconds() -> int:
    return _read_env_int(
        "SAIL_CAP_RECOVERY_POST_RESET_JITTER_SECS",
        "SURF_CAP_RECOVERY_POST_RESET_JITTER_SECS",
        "SURF_RESUME_POST_RESET_JITTER_SECS",
        default=DEFAULT_POST_RESET_JITTER_SECS,
    )


def _read_text(text=None, text_file=None) -> str:
    if text_file:
        with open(text_file, "r", encoding="utf-8") as fh:
            return fh.read()
    if text is not None:
        return text
    return sys.stdin.read()


def _nonempty_tail_lines(text: str, limit: int = DEFAULT_TAIL_LINES):
    lines = [line for line in text.splitlines() if line.strip()]
    return lines[-limit:]


def _tail_text(text: str) -> str:
    return "\n".join(_nonempty_tail_lines(text))


def _utc_datetime(now_epoch: int) -> datetime:
    return datetime.fromtimestamp(now_epoch, timezone.utc)


def _epoch_from_datetime(value: datetime) -> int:
    return int(value.timestamp())


def _rfc3339_from_epoch(epoch: int) -> str:
    return datetime.fromtimestamp(epoch, timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def _resolve_zone(name: Optional[str]):
    if not name:
        return timezone.utc
    if ZoneInfo is None:
        raise ZoneInfoNotFoundError(name)
    return ZoneInfo(name)


def _parse_clock(token: str):
    match = TIME_RE.fullmatch(token.strip())
    if not match:
        return None
    hour = int(match.group(1)) % 12
    if match.group(3).lower() == "pm":
        hour += 12
    minute = int(match.group(2) or 0)
    return hour, minute


def _combine_local(zone, year: int, month: int, day: int, hour: int = 0, minute: int = 0) -> datetime:
    return datetime(year, month, day, hour, minute, tzinfo=zone)


def _next_weekday(now: datetime, weekday: int, hour: int = 0, minute: int = 0) -> datetime:
    local_now = now
    delta_days = (weekday - local_now.weekday()) % 7
    candidate = _combine_local(
        local_now.tzinfo,
        local_now.year,
        local_now.month,
        local_now.day,
        hour,
        minute,
    ) + timedelta(days=delta_days)
    if candidate <= local_now:
        candidate += timedelta(days=7)
    return candidate


def _parse_month_day(text: str, now: datetime, zone):
    cleaned = re.sub(r"(?i)\bresets?\b", "", text).strip(" \t:;,-·—")
    for fmt in ("%B %d %Y", "%b %d %Y", "%B %d", "%b %d"):
        try:
            parsed = datetime.strptime(cleaned, fmt)
        except ValueError:
            continue
        year = parsed.year if "%Y" in fmt else now.year
        candidate = _combine_local(zone, year, parsed.month, parsed.day)
        if "%Y" not in fmt and candidate <= now:
            try:
                candidate = _combine_local(zone, year + 1, parsed.month, parsed.day)
            except ValueError:
                return None
        return candidate
    return None


def _parse_iso_date(text: str, zone, now: datetime):
    match = re.search(r"\b(\d{4})-(\d{2})-(\d{2})\b", text)
    if not match:
        return None
    year, month, day = map(int, match.groups())
    try:
        candidate = _combine_local(zone, year, month, day)
    except ValueError:
        return None
    if candidate <= now and zone == timezone.utc:
        try:
            candidate = _combine_local(zone, year + 1, month, day)
        except ValueError:
            return None
    return candidate


def _parse_reset_line(line: str, now: datetime):
    raw = line.strip()
    lower = raw.lower()
    if "reset" not in lower and "limit" not in lower and "cap" not in lower:
        return None, None

    rfc = RFC3339_RE.search(raw)
    if rfc:
        try:
            epoch = int(datetime.strptime(rfc.group(1), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())
        except ValueError:
            return None, None
        return epoch, "explicit"

    in_days = re.search(r"(?i)\bin\s+(\d+)\s+days?\b", raw)
    if in_days:
        days = int(in_days.group(1))
        return _epoch_from_datetime(now + timedelta(days=days)), "weekly"

    tz_name = None
    tz_match = TZ_RE.search(raw)
    if tz_match:
        tz_name = tz_match.group(1)
    zone = None
    try:
        zone = _resolve_zone(tz_name)
    except ZoneInfoNotFoundError:
        return None, None

    remainder = raw
    reset_match = re.search(r"(?i)\bresets?\b", raw)
    if reset_match:
        remainder = raw[reset_match.end() :].strip()
    remainder = remainder.lstrip(" \t:;,-·—")

    weekday_match = re.search(
        r"(?i)\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b", remainder
    )
    clock_match = TIME_RE.search(remainder)
    iso_candidate = _parse_iso_date(remainder, zone, now)
    if iso_candidate is not None:
        clock = _parse_clock(clock_match.group(0)) if clock_match else None
        if clock:
            return (
                _epoch_from_datetime(
                    _combine_local(zone, iso_candidate.year, iso_candidate.month, iso_candidate.day, *clock)
                ),
                "weekly",
            )
        return _epoch_from_datetime(iso_candidate), "weekly"

    month_day_candidate = _parse_month_day(remainder, now, zone)
    if month_day_candidate is not None:
        clock = _parse_clock(clock_match.group(0)) if clock_match else None
        if clock:
            return (
                _epoch_from_datetime(
                    _combine_local(
                        zone,
                        month_day_candidate.year,
                        month_day_candidate.month,
                        month_day_candidate.day,
                        *clock,
                    )
                ),
                "weekly",
            )
        return _epoch_from_datetime(month_day_candidate), "weekly"

    if weekday_match:
        weekday = WEEKDAY_TO_INDEX[weekday_match.group(1).lower()]
        clock = _parse_clock(clock_match.group(0)) if clock_match else (0, 0)
        candidate = _next_weekday(now.astimezone(zone), weekday, *clock)
        return _epoch_from_datetime(candidate.astimezone(timezone.utc)), "weekly"

    if clock_match and tz_name:
        clock = _parse_clock(clock_match.group(0))
        if clock is None:
            return None, None
        local_now = now.astimezone(zone)
        candidate = _combine_local(zone, local_now.year, local_now.month, local_now.day, *clock)
        if candidate <= local_now:
            candidate += timedelta(days=1)
        return _epoch_from_datetime(candidate.astimezone(timezone.utc)), "5h"

    if clock_match and not tz_name:
        clock = _parse_clock(clock_match.group(0))
        if clock is None:
            return None, None
        local_now = now.astimezone(timezone.utc)
        candidate = _combine_local(
            timezone.utc, local_now.year, local_now.month, local_now.day, *clock
        )
        if candidate <= local_now:
            candidate += timedelta(days=1)
        return _epoch_from_datetime(candidate), "5h"

    return None, None


def _parse_reset(text: str, now_epoch: int):
    now = _utc_datetime(now_epoch)
    for line in _nonempty_tail_lines(text):
        epoch, limit_type = _parse_reset_line(line, now)
        if epoch is not None:
            return epoch, limit_type
    return None, None


def classify_cap_text(text: str) -> bool:
    # Cap iff the terminal tail carries an explicit cap phrase. A parseable reset time alone is NOT a
    # cap signal (precision: never arm a spurious multi-hour backoff off a benign date mention).
    tail = _tail_text(text)
    if not tail:
        return False
    return bool(CAP_PHRASE_RE.search(tail))


def parse_reset_text(text: str, now_epoch: int):
    tail = _tail_text(text)
    return _parse_reset(tail, now_epoch)


# ---------------------------------------------------------------------------------------------------
# #168 — the AUTHORITATIVE cap/reset signal: the worker's stream-json `rate_limit_event` lines.
#
# A convoy `ship-tide.py` port (`_parse_resets_at` / `_find_last_event_by_type` /
# `_usage_limit_decision`). The event carries `status` / `rateLimitType` / `utilization` / `resetsAt`
# and is fresher + authoritative than the minutes-stale statusline (#166) and the false-positive-prone
# cap-text regex (#126). It supersedes the #126 regex on the /surf WORKER path (which now emits
# stream-json); the regex (classify_cap_text/parse_reset_text above) stays only for the supervisor
# self-relinquish path, which has no worker stream.
#
# five_hour and seven_day are INDEPENDENT limit windows evaluated separately (convoy #469 — a single
# "last event wins" scan would let one window mask the other); the LONGEST-wait held window dominates
# the single wake target. Fields are parsed as JSON DATA only (never shell-interpolated) so the input
# is injection-safe. Returns the RAW resetsAt epoch — `arm` adds the post-reset margin + floor +
# ceiling, keeping that math single-sourced.

RLE_WINDOWS = ("five_hour", "seven_day")
# Per-window utilization thresholds for an `allowed_warning` hold (convoy live values). A `rejected`
# status is a hard block regardless of window/utilization.
RLE_UTIL_THRESHOLD = {"five_hour": 0.90, "seven_day": 0.98}


def _parse_resets_at(value: object) -> Optional[int]:
    # Epoch-seconds / epoch-milliseconds / ISO-8601 → epoch SECONDS (int), else None (fail to absence).
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        v = float(value)
    elif isinstance(value, str):
        s = value.strip()
        if not s:
            return None
        try:
            v = float(s)
        except ValueError:
            try:
                iso = s[:-1] + "+00:00" if s.endswith("Z") else s
                dt = datetime.fromisoformat(iso)
            except (ValueError, TypeError):
                return None
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return int(dt.timestamp())
    else:
        return None
    if not math.isfinite(v):
        return None
    if v > 1e12:  # epoch-milliseconds → seconds
        v /= 1000.0
    return int(v)


def _find_last_event_by_type(lines, rate_limit_type: str) -> Optional[dict]:
    last = None
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(obj, dict) or obj.get("type") != "rate_limit_event":
            continue
        info = obj.get("rate_limit_info")
        if not isinstance(info, dict):
            continue
        if info.get("rateLimitType") == rate_limit_type:
            last = obj
    return last


def _rle_hold_reset(event: Optional[dict], now_epoch: int) -> Optional[int]:
    # Return the RAW resetsAt epoch iff `event` is a hold-worthy, non-elapsed cap for a known window;
    # else None (fail-open — never fabricate a wake target on an ambiguous/advisory/allowed event).
    if not isinstance(event, dict):
        return None
    info = event.get("rate_limit_info")
    info = info if isinstance(info, dict) else {}
    status = info.get("status", "")
    window = info.get("rateLimitType", "")
    if window not in RLE_WINDOWS or not status or status == "allowed":
        return None
    if status == "rejected":
        pass  # hard block — window-agnostic, no utilization gate
    elif status == "allowed_warning":
        threshold = RLE_UTIL_THRESHOLD.get(window)
        util = info.get("utilization")
        if threshold is None or not isinstance(util, (int, float)) or isinstance(util, bool):
            return None
        if util < threshold:
            return None
    else:
        return None  # unknown status → fail-open
    reset = _parse_resets_at(info.get("resetsAt"))
    if reset is None or reset <= now_epoch:  # unparseable, or window already reset (elapsed) → no hold
        return None
    return reset


def parse_rate_limit_event(text: str, now_epoch: int):
    # Evaluate both windows independently; the LONGEST-wait held window dominates. Returns
    # (raw_reset_epoch, limit_type) or (None, None) when no window is a hold-worthy, non-elapsed cap.
    lines = text.splitlines()
    best_epoch: Optional[int] = None
    best_window: Optional[str] = None
    for window in RLE_WINDOWS:
        reset = _rle_hold_reset(_find_last_event_by_type(lines, window), now_epoch)
        if reset is None:
            continue
        if best_epoch is None or reset > best_epoch:
            best_epoch, best_window = reset, window
    return best_epoch, best_window


def saw_rate_limit_event(text: str) -> bool:
    # True iff the stream carried at least one rate_limit_event for a known window — regardless of
    # hold-worthiness. Lets `arm` distinguish "a fresh event said NOT-capped" (authoritative → do NOT
    # fall back to cap-text) from "no event at all" (fall back to cap-text). Kills the #126 FP class:
    # a stale cap-text tail can never arm once a structured event has spoken (even to say `allowed`).
    lines = text.splitlines()
    return any(_find_last_event_by_type(lines, w) is not None for w in RLE_WINDOWS)


def _load_json(path: str):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def _write_json(path: str, payload) -> None:
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)


def _validate_issue(issue) -> Optional[str]:
    # issue is optional: None/"" -> the GLOBAL cap-state (used by the whole-board launchd watcher,
    # which is issue-agnostic). A present issue must be numeric (no path traversal / injection).
    if issue is None or str(issue) == "":
        return None
    if not re.fullmatch(r"\d+", str(issue)):
        raise ValueError(f"issue must be numeric, got {issue!r}")
    return str(issue)


def _issue_root(surf_dir: str, issue: str) -> str:
    return os.path.join(surf_dir, "runs", str(_validate_issue(issue)))


def _resume_after_path(surf_dir: str) -> str:
    return os.path.join(surf_dir, "resume-after")


def _cap_state_path(surf_dir: str, issue) -> str:
    normalized = _validate_issue(issue)
    if normalized is None:
        # Whole-board (issue-agnostic) cap-state, e.g. the launchd watcher's own re-cap.
        return os.path.join(surf_dir, "cap-state.json")
    return os.path.join(surf_dir, "runs", normalized, "cap-state.json")


def _capped_marker_path(surf_dir: str) -> str:
    return os.path.join(surf_dir, "capped")


def _read_resume_after_epoch(surf_dir: str):
    path = _resume_after_path(surf_dir)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            value = fh.read().strip()
    except OSError:
        return None, None
    try:
        epoch, _ = parse_rfc3339(value)
    except ValueError:
        return None, value
    return epoch, value


def parse_rfc3339(value: str) -> tuple[int, str]:
    text = value.strip()
    if not text:
        raise ValueError("empty timestamp")
    dt = datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    return int(dt.timestamp()), text


def _load_state(surf_dir: str, issue: Optional[str]):
    path = _cap_state_path(surf_dir, issue)
    state = _load_json(path)
    if not isinstance(state, dict):
        return None, path
    return state, path


def _merge_floor(existing, new_epoch: int, new_limit_type: str):
    if not existing:
        return new_epoch, new_limit_type

    existing_epoch = existing.get("reset-after")
    existing_type = str(existing.get("limit-type") or "unknown")
    try:
        existing_epoch_int = int(existing_epoch)
    except (TypeError, ValueError):
        return new_epoch, new_limit_type

    existing_default = existing_type in {"default", "unknown"}
    new_default = new_limit_type in {"default", "unknown"}

    if existing_default and not new_default:
        return new_epoch, new_limit_type
    if not existing_default and new_default:
        return existing_epoch_int, existing_type
    if new_epoch > existing_epoch_int:
        return new_epoch, new_limit_type
    return existing_epoch_int, existing_type


def arm(
    surf_dir: str,
    issue,
    text: str,
    now_epoch: int,
    ceiling_secs: Optional[int] = None,
    reset_epoch: Optional[int] = None,
    limit_type_override: Optional[str] = None,
    event_text: Optional[str] = None,
):
    # issue is optional (None -> the whole-board GLOBAL cap-state, used by the launchd watcher). This
    # is the SINGLE arming path for BOTH layers (supervisor Layer-1 and watcher) so they can never
    # drift: it owns the never-hot-loop floor, the wall-clock ceiling, the post-reset margin, the
    # forward-only merge, and the anomaly-count.
    #
    # #168 SOURCE PRECEDENCE (single-sourced + tested here, never scattered across bash):
    #   1. reset_epoch  — an explicit raw resetsAt epoch (already parsed by the caller).
    #   2. event_text   — a worker's stream-json log; the AUTHORITATIVE rate_limit_event is parsed and,
    #                     if a hold-worthy window is present, wins over the cap-text (the #126 regex is
    #                     RETIRED wherever an event stream is provided).
    #   3. text         — the legacy #126 cap-text (self-relinquish / watcher fallback ONLY, when no
    #                     structured event is available).
    # Downstream (post-reset margin, never-hot-loop floor, wall-clock ceiling, forward-only merge) is
    # applied identically for every source, so a replayed/older signal can never move the floor back.
    normalized_issue = _validate_issue(issue)
    ceiling = ceiling_secs if ceiling_secs and ceiling_secs > 0 else ceiling_seconds()
    os.makedirs(surf_dir, exist_ok=True)
    if normalized_issue is not None:
        os.makedirs(_issue_root(surf_dir, normalized_issue), exist_ok=True)

    if reset_epoch is None and event_text:
        ev_epoch, ev_type = parse_rate_limit_event(event_text, now_epoch)
        if ev_epoch is not None:
            reset_epoch = ev_epoch
            if not limit_type_override:
                limit_type_override = ev_type
        elif saw_rate_limit_event(event_text):
            # A structured event was present but is NOT a hold-worthy cap (e.g. status: allowed). The
            # event is AUTHORITATIVE, so do NOT fall through to the FP-prone #126 cap-text — that is
            # exactly the false positive #168 retires. Not a cap.
            return {"armed": False, "reason": "not-cap"}

    if reset_epoch is not None:
        # An event/explicit epoch is a REAL, typed reset (five_hour/seven_day) — never the "weekly"
        # text-parser placeholder. Fall back to "unknown" (a recognized _merge_floor placeholder) only
        # when the window is genuinely unknown, never mislabel it "weekly".
        parsed_epoch: Optional[int] = int(reset_epoch)
        limit_type = limit_type_override or "unknown"
    elif not classify_cap_text(text):
        return {"armed": False, "reason": "not-cap"}
    else:
        parsed_epoch, limit_type = parse_reset_text(text, now_epoch)
    if parsed_epoch is None:
        chosen_epoch = now_epoch + default_backoff_seconds()
        limit_type = "default"
    else:
        chosen_epoch = parsed_epoch + post_reset_margin_seconds() + post_reset_jitter_seconds()
        limit_type = limit_type or "weekly"

    # Never hot-loop: wait at least MIN_BACKOFF even if a parsed reset is imminent/past; never wait
    # beyond the wall-clock ceiling. (min_backoff << ceiling, so the two bounds never conflict.)
    chosen_epoch = max(chosen_epoch, now_epoch + min_backoff_seconds())
    chosen_epoch = min(chosen_epoch, now_epoch + ceiling)

    state, path = _load_state(surf_dir, normalized_issue)
    anomaly_count = int(state.get("anomaly-count", 0)) if isinstance(state, dict) else 0
    if state and isinstance(state, dict):
        try:
            prior_epoch: Optional[int] = int(state.get("reset-after"))  # type: ignore[arg-type]
        except (TypeError, ValueError):
            prior_epoch = None
        if prior_epoch is not None and now_epoch >= prior_epoch:
            anomaly_count += 1

    # _merge_floor owns the whole floor decision: forward-only for real resets, and the
    # default/unknown -> real correction (replace a placeholder floor with a parsed reset).
    merged_epoch, merged_type = _merge_floor(state, chosen_epoch, limit_type)
    payload = {
        "reset-after": int(merged_epoch),
        "limit-type": merged_type,
        "anomaly-count": anomaly_count,
    }
    _write_json(path, payload)
    with open(_resume_after_path(surf_dir), "w", encoding="utf-8") as fh:
        fh.write(_rfc3339_from_epoch(int(merged_epoch)) + "\n")
    return {
        "armed": True,
        "reset-after": int(merged_epoch),
        "limit-type": merged_type,
        "anomaly-count": anomaly_count,
    }


def gate(surf_dir: str, now_epoch: int):
    resume_epoch, _ = _read_resume_after_epoch(surf_dir)
    if resume_epoch is not None and now_epoch < resume_epoch:
        return False
    return True


def clear(surf_dir: str, issue=None):
    # A clean (uncapped) relaunch clears the shared gate + cap-state AND the self-relinquish marker,
    # so stale state never gates a later run and a healthy live session is never mis-read as
    # recoverable (the redteam stuck-`.surf/capped` bug). issue optional -> clears global cap-state.
    normalized_issue = _validate_issue(issue)
    for target in (
        _resume_after_path(surf_dir),
        _cap_state_path(surf_dir, normalized_issue),
        _capped_marker_path(surf_dir),
    ):
        try:
            os.unlink(target)
        except OSError:
            pass
    return 0


def relinquish(surf_dir: str, text: str, now_epoch: int, ceiling_secs: Optional[int] = None):
    # Supervisor self-relinquish (scenario 5): arm the SAME shared, forward-only, ceiling-bounded
    # floor the watcher reads, then write the durable `.surf/capped` marker so the watcher — which
    # otherwise stands down for a live pid + fresh heartbeat — treats this live-but-cap-blocked pid as
    # recoverable and takes over. Single-sourced here (not a raw `touch` in surf.md) so the write and
    # the watcher's consume can never drift.
    result = arm(surf_dir, None, text, now_epoch, ceiling_secs)
    if result.get("armed"):
        with open(_capped_marker_path(surf_dir), "w", encoding="utf-8") as fh:
            fh.write(_rfc3339_from_epoch(now_epoch) + "\n")
    return result


def status(surf_dir: str, issue: str, now_epoch: int):
    state, _ = _load_state(surf_dir, issue)
    resume_epoch, resume_text = _read_resume_after_epoch(surf_dir)
    return {
        "issue": str(issue),
        "resume-after": resume_text,
        "resume-after-epoch": resume_epoch,
        "ready": gate(surf_dir, now_epoch),
        "cap-state": state,
    }


def apikey_preflight(source: str) -> tuple[int, str]:
    # #163 AC6 / convoy `_convoy_check_apikeysource`: apiKeySource=="none" means NO API key is in
    # use — i.e. a subscription, the account type whose usage caps reset on a schedule and that this
    # cap-recovery model is built for. That is the EXPECTED, healthy case → stay quiet (#112: don't
    # cry wolf on every normal run). Any other source (or unknown/empty) means the run is on an API
    # key, where the reset-based recovery does not apply and billing/rate-limits differ → WARN at
    # ALERT tier so the real deviation stays scannable.
    if str(source).strip().lower() == "none":
        return 0, ""
    return 1, (
        f"ALERT: apiKeySource={source!r} — this /surf run appears to be on an API key, not a "
        "subscription; the cap-recovery reset model does not apply. Run on a subscription "
        "(apiKeySource=none) for auto-resume across usage caps."
    )


def _read_now(value: Optional[str]) -> int:
    if value is None:
        return int(datetime.now(timezone.utc).timestamp())
    return int(value)


def run_cap_recovery(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="sail cap-recovery")
    subparsers = parser.add_subparsers(dest="command", required=True)

    classify_parser = subparsers.add_parser("classify")
    classify_parser.add_argument("--text-file")

    parse_parser = subparsers.add_parser("parse-reset")
    parse_parser.add_argument("--now", required=True)
    parse_parser.add_argument("--text-file")

    arm_parser = subparsers.add_parser("arm")
    arm_parser.add_argument("--surf-dir", required=True)
    arm_parser.add_argument("--issue", default=None)  # optional: omit for the whole-board watcher
    arm_parser.add_argument("--now", required=True)
    arm_parser.add_argument("--ceiling-secs", type=int, default=None)
    arm_parser.add_argument("--text-file")
    # #168: the AUTHORITATIVE-event path. `--log-file` points at a worker's stream-json log; arm parses
    # its rate_limit_event and, if hold-worthy, uses it over --text-file cap-text (precedence lives in
    # arm(), not scattered across bash). `--reset-epoch` supplies an already-parsed raw epoch directly;
    # `--limit-type` carries the window (five_hour/seven_day) for the forward-only merge.
    arm_parser.add_argument("--reset-epoch", type=int, default=None)
    arm_parser.add_argument("--limit-type", default=None)
    arm_parser.add_argument("--log-file", default=None)

    rle_parser = subparsers.add_parser("rate-limit-event")
    rle_parser.add_argument("--now", required=True)
    rle_parser.add_argument("--log-file")

    relinquish_parser = subparsers.add_parser("relinquish")
    relinquish_parser.add_argument("--surf-dir", required=True)
    relinquish_parser.add_argument("--now", required=True)
    relinquish_parser.add_argument("--ceiling-secs", type=int, default=None)
    relinquish_parser.add_argument("--text-file")

    gate_parser = subparsers.add_parser("gate")
    gate_parser.add_argument("--surf-dir", required=True)
    gate_parser.add_argument("--now", required=True)

    clear_parser = subparsers.add_parser("clear")
    clear_parser.add_argument("--surf-dir", required=True)
    clear_parser.add_argument("--issue", default=None)  # optional: omit to clear the global state

    status_parser = subparsers.add_parser("status")
    status_parser.add_argument("--surf-dir", required=True)
    status_parser.add_argument("--issue", default=None)
    status_parser.add_argument("--now", default=None)

    subparsers.add_parser("ceiling-seconds")

    apikey_parser = subparsers.add_parser("apikey-preflight")
    apikey_parser.add_argument("--source", required=True)

    args = parser.parse_args(argv)

    if args.command == "classify":
        text = _read_text(text_file=args.text_file)
        if classify_cap_text(text):
            print("cap")
            return 0
        print("not-cap")
        return 1

    if args.command == "parse-reset":
        text = _read_text(text_file=args.text_file)
        epoch, _kind = parse_reset_text(text, _read_now(args.now))
        if epoch is not None:
            print(_rfc3339_from_epoch(epoch))
        return 0

    if args.command == "arm":
        # Source resolution for the single arming path (precedence itself lives in arm()):
        #   --reset-epoch  → explicit epoch; no text/stream read.
        #   --log-file     → AUTHORITATIVE stream-json (fail-OPEN on a missing/unreadable stream so arm
        #                    falls through, never crashes). --text-file, if ALSO given, is the cap-text
        #                    fallback (watcher path); with --log-file alone the cap-text is retired
        #                    (worker path — event-only).
        #   neither        → legacy cap-text from --text-file or stdin (self-relinquish path).
        event_text: Optional[str] = None
        if args.reset_epoch is None and args.log_file is not None:
            try:
                event_text = _read_text(text_file=args.log_file)
            except (OSError, UnicodeDecodeError):
                # Fail-OPEN on a missing/unreadable OR non-UTF-8 stream (UnicodeDecodeError is a
                # ValueError, NOT an OSError — convoy _read_lines catches both). arm then falls through.
                event_text = None
        def _read_cap_text(text_file) -> str:
            # Fail-OPEN on a missing/unreadable/non-UTF-8 cap-text file too (the watcher passes the
            # SAME persisted stream as --log-file AND --text-file, so a non-UTF-8 byte must not crash
            # the fallback read after the event read already failed open). Legacy stdin (text_file
            # None) is left to raise as before — an interactive self-relinquish always supplies text.
            try:
                return _read_text(text_file=text_file)
            except (OSError, UnicodeDecodeError):
                return ""

        if args.reset_epoch is not None:
            text = ""
        elif args.log_file is not None:
            # Event mode: read cap-text ONLY if an explicit --text-file fallback was provided (never
            # block on stdin in event mode).
            text = _read_cap_text(args.text_file) if args.text_file else ""
        else:
            text = _read_text(text_file=args.text_file)  # legacy: --text-file or stdin
        result = arm(
            args.surf_dir, args.issue, text, _read_now(args.now), args.ceiling_secs,
            reset_epoch=args.reset_epoch, limit_type_override=args.limit_type,
            event_text=event_text,
        )
        if result.get("armed"):
            print(_rfc3339_from_epoch(int(result["reset-after"])))
        return 0

    if args.command == "rate-limit-event":
        # Parse the AUTHORITATIVE cap/reset signal from a worker's stream-json log (file-fed, never
        # shell-interpolated). Prints "<raw_reset_epoch>\t<limit_type>" and rc 0 on a hold-worthy,
        # non-elapsed cap event; rc 1 with no output otherwise (so the #166/#163 fallback engages).
        # Fail-OPEN on a missing/unreadable OR non-UTF-8 stream (a worker that never wrote one, or a
        # stream with a stray non-UTF-8 byte): rc 1, no output, no traceback — the /surf branch then
        # records the fail-closed build park (convoy _read_lines catches OSError+UnicodeDecodeError).
        # Never fabricate a wake target from an absent/unreadable stream.
        try:
            text = _read_text(text_file=args.log_file)
        except (OSError, UnicodeDecodeError):
            return 1
        epoch, limit_type = parse_rate_limit_event(text, _read_now(args.now))
        if epoch is None:
            return 1
        print(f"{epoch}\t{limit_type}")
        return 0

    if args.command == "relinquish":
        text = _read_text(text_file=args.text_file)
        result = relinquish(args.surf_dir, text, _read_now(args.now), args.ceiling_secs)
        if result.get("armed"):
            print(_rfc3339_from_epoch(int(result["reset-after"])))
        return 0

    if args.command == "gate":
        return 0 if gate(args.surf_dir, _read_now(args.now)) else 1

    if args.command == "clear":
        return clear(args.surf_dir, args.issue)

    if args.command == "status":
        payload = status(args.surf_dir, args.issue, _read_now(args.now))
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0

    if args.command == "ceiling-seconds":
        print(ceiling_seconds())
        return 0

    if args.command == "apikey-preflight":
        rc, message = apikey_preflight(args.source)
        if message:
            print(message, file=sys.stderr)
        return rc

    return 1
