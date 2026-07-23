"""Parked-issue aging — the orphaned-park guard for `/surf resume` (#153).

A `/surf` run parks any issue it cannot merge (branch + worktree left intact, recorded in
`.surf/parked-issues.md` and the journal). Those parks are meant to be re-worked, but a run that is
resumed many times can leave a park sitting untouched for weeks — an *orphaned* park nobody notices.

This module owns the deterministic, unit-tested **aging predicate**: given a park's last-activity
timestamp and "now", is it stale (>7 days, no activity)? It is a **report-only** guard — it surfaces
aged parks for a human on `/surf resume`; it never merges, closes, files, or otherwise touches them
(infra-placement: judgment→LLM, deterministic decisions→tested Python; the *decision* to age is the
only mechanizable part). The un-mechanizable "should this park be dropped / re-worked / escalated?"
stays with the operator reading the report.

Last-activity is read from the `.surf/runs/<issue>/` coordination-namespace dir mtime — the durable
per-issue signal `/surf` already maintains (poll/journal writes touch it). A parked issue with no
run-dir cannot be aged (no activity record) and is skipped rather than reported as a false orphan.
"""

from __future__ import annotations

import argparse
import os
import sys

# ">7 days with no activity" is the issue's chosen orphaned-park threshold.
STALE_PARK_THRESHOLD_DAYS = 7
_SECONDS_PER_DAY = 86400


def is_stale_park(last_activity_epoch, now_epoch, threshold_days: int = STALE_PARK_THRESHOLD_DAYS) -> bool:
    # True only when a park's last activity is STRICTLY more than `threshold_days` days before now.
    # Fail-SAFE and quiet on bad data — a report-only guard must never manufacture a false orphan:
    # a None/zero/negative or future last-activity returns False (cannot be aged). The boundary is
    # exclusive: exactly `threshold_days` old is NOT yet stale (matches ">7 days").
    if last_activity_epoch is None or now_epoch is None:
        return False
    try:
        age = float(now_epoch) - float(last_activity_epoch)
    except (TypeError, ValueError):
        return False
    if last_activity_epoch <= 0 or age <= 0:
        return False
    return age > threshold_days * _SECONDS_PER_DAY


def _last_activity_epoch(runs_dir: str, issue: str):
    # Last activity = the NEWEST mtime across the `.surf/runs/<issue>/` dir AND everything under it.
    # A dir's own mtime only advances when an ENTRY is added/removed/renamed — appending to an
    # existing file (e.g. a journal / worker-stream) does NOT touch it. So the directory mtime alone
    # would under-count activity and falsely age a still-active park; we take the max over the dir +
    # its contents instead (#153 review MEDIUM). Missing/unreadable dir -> None (cannot age ->
    # skipped, never a false orphan).
    path = os.path.join(runs_dir, str(issue))
    try:
        newest = os.stat(path).st_mtime
    except OSError:
        return None
    for root, dirs, files in os.walk(path):
        for name in dirs + files:
            try:
                mtime = os.lstat(os.path.join(root, name)).st_mtime
            except OSError:
                continue
            if mtime > newest:
                newest = mtime
    return newest


def find_stale_parks(runs_dir: str, issues, now_epoch,
                     threshold_days: int = STALE_PARK_THRESHOLD_DAYS):
    # For each parked issue the caller supplies, resolve its last-activity from the run-dir mtime and
    # apply is_stale_park. Returns a list of (issue, age_days) for the stale ones, in the caller's
    # order. Age is reported in whole days (floored). An issue with no run-dir is skipped.
    stale = []
    for issue in issues:
        last = _last_activity_epoch(runs_dir, issue)
        if last is None:
            continue
        if is_stale_park(last, now_epoch, threshold_days):
            age_days = int((float(now_epoch) - float(last)) // _SECONDS_PER_DAY)
            stale.append((str(issue), age_days))
    return stale


def run_parked_aging(args) -> int:
    # Thin CLI glue for `/surf resume` — report-only, ALWAYS exits 0. The prompt supplies the parked
    # set (the issues it reconstructed as parked) and the current epoch; this prints the orphaned
    # ones for a human. No auto-action.
    issues = [i.strip() for i in (args.issues or "").split(",") if i.strip()]
    try:
        now = float(args.now) if args.now is not None else None
    except (TypeError, ValueError):
        now = None
    if now is None:
        now = _time_now()
    stale = find_stale_parks(args.runs_dir, issues, now, args.threshold_days)
    if not stale:
        print(f"no orphaned parks (>{args.threshold_days}d with no activity)")
        return 0
    print(f"⚠ orphaned parks (>{args.threshold_days}d with no activity) — REPORT ONLY, no auto-action:")
    for issue, age_days in stale:
        print(f"  #{issue} — parked ~{age_days}d with no activity")
    return 0


def _time_now() -> float:
    # Isolated so the deterministic predicate/scanner never call the clock directly; the CLI reads it
    # only as a fallback when --now is omitted.
    import time
    return time.time()


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="sail parked-aging")
    parser.add_argument("--runs-dir", required=True)
    parser.add_argument("--issues", default="")
    parser.add_argument("--now")
    parser.add_argument("--threshold-days", type=int, default=STALE_PARK_THRESHOLD_DAYS)
    return parser


def main(argv=None) -> int:
    args = _build_parser().parse_args(argv if argv is not None else sys.argv[1:])
    return run_parked_aging(args)
