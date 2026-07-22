from __future__ import annotations

import json
import os
import tempfile
from typing import Any

DEFAULT_THRESHOLD = 90
DEFAULT_REFRESH_SECS = 30
DEFAULT_MARGIN_SECS = 120

UNKNOWN = "unknown"
OK = "ok"
BACKOFF = "backoff"


def _env_int(names: tuple[str, ...], default: int) -> int:
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


def default_threshold() -> int:
    return _env_int(("SAIL_USAGE_THRESHOLD",), DEFAULT_THRESHOLD)


def default_refresh_secs() -> int:
    return _env_int(("SAIL_USAGE_REFRESH_SECS",), DEFAULT_REFRESH_SECS)


def default_margin_secs() -> int:
    return _env_int(("SAIL_USAGE_MARGIN_SECS",), DEFAULT_MARGIN_SECS)


def _coerce_percentage(value: object) -> int | float | None:
    if not isinstance(value, (int, float, str)):
        return None
    try:
        numeric = float(value)
    except (TypeError, ValueError):
        return None
    return int(numeric) if numeric.is_integer() else numeric


def _coerce_epoch(value: object) -> int | None:
    if not isinstance(value, (int, float, str)):
        return None
    try:
        epoch = int(value)
    except (TypeError, ValueError):
        return None
    return epoch if epoch >= 0 else None


def _window_payload(payload: dict[str, Any], name: str) -> dict[str, Any] | None:
    rate_limits = payload.get("rate_limits")
    if not isinstance(rate_limits, dict):
        return None
    window = rate_limits.get(name)
    return window if isinstance(window, dict) else None


def _extract_state(payload: dict[str, Any], now: int) -> dict[str, Any] | None:
    if not isinstance(payload, dict):
        return None
    five = _window_payload(payload, "five_hour")
    seven = _window_payload(payload, "seven_day")
    if not five or not seven:
        return None

    five_used = _coerce_percentage(five.get("used_percentage"))
    five_reset = _coerce_epoch(five.get("resets_at"))
    seven_used = _coerce_percentage(seven.get("used_percentage"))
    seven_reset = _coerce_epoch(seven.get("resets_at"))
    if None in (five_used, five_reset, seven_used, seven_reset):
        return None

    return {
        "written_at": now,
        "five_hour": {"used_percentage": five_used, "resets_at": five_reset},
        "seven_day": {"used_percentage": seven_used, "resets_at": seven_reset},
    }


def load_state(path: str) -> dict[str, Any] | None:
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def save_state(path: str, state: dict[str, Any]) -> None:
    directory = os.path.dirname(os.path.abspath(path)) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".usage-state-", suffix=".json", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(state, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def write_usage_state(payload_text: str, out: str, now: int) -> dict[str, Any] | None:
    try:
        payload = json.loads(payload_text)
    except ValueError:
        return None
    state = _extract_state(payload, now)
    if state is None:
        return None
    save_state(out, state)
    return state


def state_is_stale(state: dict[str, Any] | None, now: int, refresh_secs: int) -> bool | None:
    if not isinstance(state, dict):
        return None
    written_at = state.get("written_at")
    if not isinstance(written_at, int):
        return None
    if now < written_at:
        return True
    return (now - written_at) > (2 * refresh_secs)


def _window_used(state: dict[str, Any], name: str) -> int | float | None:
    window = state.get(name)
    if not isinstance(window, dict):
        return None
    used = window.get("used_percentage")
    if not isinstance(used, (int, float)):
        return None
    return used


def _window_reset(state: dict[str, Any], name: str) -> int | None:
    window = state.get(name)
    if not isinstance(window, dict):
        return None
    reset = window.get("resets_at")
    return reset if isinstance(reset, int) else None


def reset_wakeup_epoch(resets_at: int, now: int, margin_secs: int) -> int:
    target = resets_at + margin_secs
    floor = now + margin_secs
    return target if target >= floor else floor


def decide(
    state: dict[str, Any] | None,
    now: int,
    threshold: int,
    refresh_secs: int,
    margin_secs: int,
) -> tuple[str, int | None]:
    stale = state_is_stale(state, now, refresh_secs)
    if stale is None or stale:
        return UNKNOWN, None

    if not isinstance(state, dict):
        return UNKNOWN, None

    triggered: list[tuple[int, str]] = []
    for name in ("five_hour", "seven_day"):
        used = _window_used(state, name)
        reset = _window_reset(state, name)
        if used is None or reset is None:
            continue
        if used >= threshold:
            triggered.append((reset, name))

    if not triggered:
        return OK, None

    reset_at, _window = min(
        triggered,
        key=lambda item: (item[0], 0 if item[1] == "five_hour" else 1),
    )
    return BACKOFF, reset_wakeup_epoch(reset_at, now, margin_secs)
