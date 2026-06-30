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

    def _append_marker(self, marker: str) -> None:
        os.makedirs(self.run_dir, exist_ok=True)
        self._ensure_header()
        self._append_line(marker)

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
        self._append_marker(f"- ↺ resume {_utc_now_iso()}")

    def mode_marker(self, mode, ref=None):
        suffix = f" (base={_sanitize_text(ref)})" if ref else ""
        self._append_marker(f"- mode: {_sanitize_text(mode)}{suffix}")

    def review_marker(self, summary):
        self._append_marker(f"- review: {_sanitize_text(summary)}")

    def isolate_marker(self, decision, commit, reason):
        # Opening-bookend isolate decision (#65): records whether /sail isolated on a
        # worktree+branch or worked in place, whether it will commit, and the rationale —
        # written on EVERY path (isolate, in-place, forced) so the choice is auditable.
        commit_flag = "yes" if commit else "no"
        self._append_marker(
            f"- isolate: {_sanitize_text(decision)} (commit={commit_flag}) "
            f"— {_sanitize_text(reason)}"
        )

    def plan_marker(self, summary):
        self._append_marker(f"- plan: {_sanitize_text(summary)}")

    def codex_marker(self, summary):
        self._append_marker(f"- codex: {_sanitize_text(summary)}")

    def gate_reset_marker(self, count, reason="diff content changed since prior round"):
        # #79: on a resumed run-dir where the gates' inputs changed since they last ran (the
        # convergence loop fixed a gate finding, or the diff scope/fingerprint changed), every
        # terminal gate is reset to pending and re-run so the fix is re-evaluated rather than
        # masked by the stale terminal status. `reason` records the actual trigger (content vs
        # scope vs missing/uncomputable fingerprint) so the audit trail is accurate, not generic.
        self._append_marker(
            f"- gate-reset: {int(count)} terminal gate(s) re-run ({_sanitize_text(reason)})"
        )

    def gate_reuse_marker(self, count, reason="inputs absent from diff (per-gate reuse)"):
        # #105: on a same-scope resume where the diff merely MOVED, an already-green gate whose
        # dependency file-types are absent from the changed-file set is REUSED (skipped), not
        # re-run — the efficiency optimization. Mirrors gate_reset_marker so the audit trail
        # shows exactly how many gates were skipped and why. Reuse is re-decided from the live
        # diff each resume (no stored per-gate cache to go stale); any uncertainty resets instead.
        self._append_marker(
            f"- gate-reuse: {int(count)} already-green gate(s) reused ({_sanitize_text(reason)})"
        )

    def inline_fix_marker(self, file, summary):
        # #113: the DURABLE visibility record for a TRIVIAL in-blast-radius opportunistic fix made
        # inline (the guard against silent diff growth — "also corrected X while editing Y"). It is
        # a NARRATIVE marker, deliberately NOT a finding_resolution: read_resolutions never returns
        # it, so it can never be misread by the convergence buckets (materiality floor keys on
        # `deferred`, oscillation on rejected/deferred). Parallels plan_marker/codex_marker.
        self._append_marker(
            f"- inline-fix: [{_sanitize_text(file)}] {_sanitize_text(summary)}"
        )

    def read_inline_fixes(self):
        # Read the inline-fix narrative markers back as a list of {file, summary} dicts, in log
        # order. Deliberately SEPARATE from read_resolutions (these are author-action notes, not
        # finding dispositions) so the convergence buckets never see them. Consumed by `sail land`
        # to surface inline opportunistic fixes on the closing comment (#113 visibility guard).
        out = []
        prefix = "- inline-fix: ["
        for line in self._read_lines():
            if not line.startswith(prefix):
                continue
            end = line.find("]", len(prefix))
            if end == -1:
                continue
            file = line[len(prefix):end]
            remainder = line[end + 1 :]
            summary = remainder[1:] if remainder.startswith(" ") else remainder
            out.append({"file": file, "summary": summary})
        return out

    def finding_resolution(self, finding_id, disposition, rationale, round=None):
        # Per-finding resolution log (#47): records the driver's disposition of one review
        # finding across the convergence loop. disposition is expected to be one of
        # addressed|deferred|rejected, but is recorded verbatim (sanitized) — never crashes
        # on an unexpected value.
        suffix = f" [round={round}]" if round is not None else ""
        self._append_marker(
            f"- resolution: [{_sanitize_text(finding_id)}] "
            f"{_sanitize_text(disposition)} — {_sanitize_text(rationale)}{suffix}"
        )

    def read_resolutions(self, round=None, before=None):
        # Read the resolution trail back into a dict keyed by finding id. Later markers
        # override earlier ones so the last recorded disposition wins.
        out = {}
        for line in self._read_lines():
            prefix = "- resolution: ["
            if not line.startswith(prefix):
                continue
            end = line.find("]", len(prefix))
            if end == -1:
                continue
            finding_id = line[len(prefix):end]
            remainder = line[end + 1 :]
            if not remainder.startswith(" "):
                continue
            remainder = remainder[1:]
            sep = " — "
            split_at = remainder.find(sep)
            if split_at == -1:
                continue
            disposition = remainder[:split_at]
            rationale = remainder[split_at + len(sep) :]
            parsed_round = None
            round_match = re.match(r"^(.*) \[round=(\d+)\]$", rationale)
            if round_match:
                rationale = round_match.group(1)
                parsed_round = int(round_match.group(2))
            if round is not None:
                if parsed_round != round:
                    continue
            elif before is not None:
                if parsed_round is not None and parsed_round >= before:
                    continue
            out[finding_id] = {
                "disposition": disposition,
                "rationale": rationale,
                "round": parsed_round,
            }
        return out
