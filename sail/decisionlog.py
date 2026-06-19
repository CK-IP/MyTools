from __future__ import annotations

import os
import re

from sail.runstate import _utc_now_iso


HEADER = "# /sail decision log"


def _sanitize_text(value) -> str:
    return re.sub(r"[\r\n]+", " ", "" if value is None else str(value))


class DecisionLog:
    def __init__(self, run_dir):
        self.run_dir = run_dir
        self.path = os.path.join(run_dir, "decision-log.md")

    def _append_line(self, line: str) -> None:
        fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            payload = (line + "\n").encode("utf-8")
            written = os.write(fd, payload)
            if written != len(payload):
                raise OSError(f"short write to {self.path}")
        finally:
            os.close(fd)

    def _read_lines(self, repair_partial_tail=False):
        try:
            with open(self.path, "rb") as fh:
                data = fh.read()
        except FileNotFoundError:
            return []

        if not data:
            return []

        if data.endswith(b"\n"):
            complete = data
        else:
            newline = data.rfind(b"\n")
            complete = b"" if newline == -1 else data[: newline + 1]
            if repair_partial_tail:
                os.truncate(self.path, len(complete))

        if not complete:
            return []

        return complete.decode("utf-8").splitlines()

    def _ensure_header(self):
        lines = self._read_lines(repair_partial_tail=True)
        if HEADER not in lines:
            self._append_line(HEADER)
            lines = lines + [HEADER]
        return lines

    def _entry_key(self, name, seq) -> str:
        return f"[gate={_sanitize_text(name)} seq={seq}]"

    def _has_record(self, lines, name, seq) -> bool:
        key = self._entry_key(name, seq)
        for line in lines:
            if line.startswith(key):
                return True
        return False

    def append(self, record, decision: str):
        os.makedirs(self.run_dir, exist_ok=True)
        lines = self._ensure_header()
        name = _sanitize_text(record["name"])
        status = _sanitize_text(record["status"])
        artifact = _sanitize_text(record["artifact"])
        decision = _sanitize_text(decision)
        seq = record["seq"]
        if self._has_record(lines, name, seq):
            return

        line = f"{self._entry_key(name, seq)} status={status} rc={record['rc']} artifact={artifact} decision={decision}"
        reason = record.get("reason")
        if reason is not None:
            line += f" reason={_sanitize_text(reason)}"
        self._append_line(line)

    def resume_marker(self):
        os.makedirs(self.run_dir, exist_ok=True)
        self._ensure_header()
        self._append_line(f"- ↺ resume {_utc_now_iso()}")

    def mode_marker(self, mode, ref=None):
        os.makedirs(self.run_dir, exist_ok=True)
        self._ensure_header()
        suffix = f" (base={_sanitize_text(ref)})" if ref else ""
        self._append_line(f"- mode: {_sanitize_text(mode)}{suffix}")
