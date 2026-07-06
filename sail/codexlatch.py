from __future__ import annotations

import json
import os
import re
import shutil
import sys
import tempfile
import time
from datetime import datetime, timezone

from sail.argvpeel import peel_argv

# Per-process dedupe: the always-on stderr notice prints at most once per kind per process,
# so the many probe/invoke calls in one phase don't spam the log.
_TRIP_NOTICED = False
_SKIP_NOTICED = False


def state_dir():
    return os.environ.get("SAIL_STATE_DIR") or os.path.expanduser("~/.sail")


def marker_path():
    return os.path.join(state_dir(), "codex-down")


def session_token():
    # Read LIVE each call so a test changing the env mid-process is observed.
    for key in ("SAIL_SESSION_ID", "CLAUDE_CODE_SESSION_ID"):
        val = os.environ.get(key)
        if val:
            return val
    return "_nosession"


def now_epoch():
    return int(time.time())


def trip_latch(reason, reset_epoch=None):
    # First-write-wins: if an ACTIVE marker for the same session already exists, leave it
    # (do not clobber tripped_at/reason). Atomic write (tmp + os.replace).
    if latch_active():
        try:
            data = _read_marker()
        except (OSError, ValueError):
            data = None
        if isinstance(data, dict) and data.get("session") == session_token():
            return
    payload = {
        "session": session_token(),
        "reason": reason,
        "reset_epoch": reset_epoch,
        "tripped_at": datetime.now(timezone.utc).isoformat(),
    }
    sd = state_dir()
    os.makedirs(sd, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=sd, prefix=".codex-down-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
        os.replace(tmp, marker_path())
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def clear_latch():
    try:
        os.unlink(marker_path())
    except FileNotFoundError:
        pass


def _read_marker():
    with open(marker_path(), encoding="utf-8") as fh:
        return json.load(fh)


def latch_active(now=None):
    if now is None:
        now = now_epoch()
    try:
        data = _read_marker()
    except (FileNotFoundError, OSError, ValueError):
        return False
    if not isinstance(data, dict):
        return False
    # Stale cleanup: a marker from a different session must not leak into this one.
    if data.get("session") != session_token():
        clear_latch()
        return False
    reset_epoch = data.get("reset_epoch")
    if reset_epoch is not None:
        try:
            if now >= int(reset_epoch):
                clear_latch()
                return False
        except (TypeError, ValueError):
            return True
    return True


def is_codex_family(argv):
    return "codex" in peel_argv(argv).lower()


_AVAILABILITY_PATTERNS = (
    r"rate limit",
    r"quota",
    r"insufficient",
    r"out of credit",
    r"credit balance",
    r"credit limit",
    r"usage limit",
    r"too many requests",
    r"\b429\b",
    r"\b401\b",
    r"\b403\b",
    r"unauthorized",
    r"forbidden",
    r"authentication",
    r"auth (expired|failed)",
    r"network",
    r"connection (error|refused|reset)",
    r"timed? ?out",
    r"temporarily unavailable",
    r"\b503\b",
    r"service unavailable",
    r"try again",
)

_AVAILABILITY_RE = re.compile("|".join(_AVAILABILITY_PATTERNS), re.IGNORECASE)


def classify_failure(rc, stderr):
    # rc == 0 means codex ran; any failure is content (e.g. malformed JSON) — AC3, never trips.
    if rc == 0:
        return False
    return bool(_AVAILABILITY_RE.search(stderr or ""))


_TRY_AGAIN_RE = re.compile(
    r"try again in\s+(\d+)\s*(second|minute|hour)s?", re.IGNORECASE
)
_RESETS_AT_RE = re.compile(
    r"resets at\s+(\S+)", re.IGNORECASE
)


def parse_reset_epoch(stderr, now):
    # Best-effort; depends on codex's error-string format staying stable.
    text = stderr or ""
    m = _TRY_AGAIN_RE.search(text)
    if m:
        n = int(m.group(1))
        unit = m.group(2).lower()
        scale = {"second": 1, "minute": 60, "hour": 3600}[unit]
        return now + n * scale
    m = _RESETS_AT_RE.search(text)
    if m:
        iso = m.group(1).rstrip(".,;")
        if iso.endswith("Z"):
            iso = iso[:-1] + "+00:00"
        try:
            dt = datetime.fromisoformat(iso)
        except ValueError:
            return None
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp())
    return None


def observe(argv, rc, stderr, decision_log=None, now=None):
    # Side-effecting detector: trips the latch on a codex availability failure. MUST NOT raise —
    # a logging/marker error never breaks the pipeline (AC4).
    try:
        if not is_codex_family(argv):
            return False
        if not classify_failure(rc, stderr):
            return False
        if latch_active(now):
            return False
        reset = parse_reset_epoch(stderr, now if now is not None else now_epoch())
        reason = _summarize_reason(stderr)
        trip_latch(reason, reset)
        when = "until session end" if reset is None else f"until epoch {reset}"
        # Always-on, non-blocking, deduped stderr notice — the only channel a live /sail run
        # surfaces (every call site passes decision_log=None). Never blocks (AC4).
        global _TRIP_NOTICED
        if not _TRIP_NOTICED:
            _TRIP_NOTICED = True
            short = reason if len(reason) <= 80 else reason[:77] + "..."
            print(f"[sail] codex unavailable — latched ({short}); skipping codex {when}",
                  file=sys.stderr)
        if decision_log is not None:
            try:
                decision_log.codex_marker(f"availability failure latched ({reason}); skipping codex {when}")
            except Exception:
                pass
        return True
    except Exception:
        return False


def _summarize_reason(stderr):
    text = " ".join((stderr or "").split())
    return text[:200] if text else "codex unavailable"


def runnable(argv, decision_log=None, now=None):
    # which(prog) OR (isfile+X_OK) gate first (same as the prior _argv_runnable), then suppress a
    # latched codex backend. Never raises on the latch consultation.
    if not argv:
        return False
    prog = argv[0]
    gate = shutil.which(prog) is not None or (os.path.isfile(prog) and os.access(prog, os.X_OK))
    if not gate:
        return False
    try:
        if is_codex_family(argv) and latch_active(now):
            # Deduped stderr notice — probe/invoke calls are many per phase, print once.
            global _SKIP_NOTICED
            if not _SKIP_NOTICED:
                _SKIP_NOTICED = True
                print("[sail] codex skipped — latched (codex unavailable this session)",
                      file=sys.stderr)
            if decision_log is not None:
                try:
                    decision_log.codex_marker("codex skipped — latched")
                except Exception:
                    pass
            return False
    except Exception:
        return gate
    return True
