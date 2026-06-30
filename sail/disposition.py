"""Minor-finding disposition — the hard ceiling for an inline opportunistic fix (#113).

When /sail or /surf *catches* a minor issue mid-build, the policy splits by **blast radius**,
not by self-assessed "cheapness" (which is unreliable):

  1. Trivial AND inside code already being touched AND zero behavior change → fix inline, logged
     visibly ("also corrected X while editing Y"). Visibility is the guard against silent creep.
  2. Genuinely out-of-scope → never expand the diff; capture it as a deferred finding (always) plus
     an OPTIONAL auto-filed one-line follow-up issue.

This module owns ONLY the **mechanizable** half of the ceiling — the part the issue's AC#4 requires
to be *testable* ("a fix touching a second file or a public interface is NOT eligible for inline").
The un-mechanizable half ("trivial", "zero behavior change") is genuine judgment and stays with the
LLM reviewer (infra-placement: judgment→LLM, deterministic decisions→tested Python). This is NOT an
auto-classifier of opportunistic-vs-planned hunks (that is not mechanizable from the diff alone) —
it only answers, for a candidate the reviewer has already identified as opportunistic, whether it
stays within the hard ceiling.
"""

from __future__ import annotations

import sys

# Default "a few lines" budget for an inline fix. Documented and overridable, never silently magic:
# callers that have a real changed-line count pass it with their own max_lines; the boundary itself
# is judgment-adjacent, so it is a soft default, not a hard constant baked across the codebase.
DEFAULT_MAX_INLINE_LINES = 10


def _file_count(files_touched) -> int:
    """Normalize files_touched to a count. Accepts an int (already a count), a single path str
    (counts as 1 file — NOT len(path) characters), or any sized/iterable collection of paths.
    Unknown/None is treated as 0 (not eligible — never grow the diff on uncertainty)."""
    if isinstance(files_touched, bool):  # guard: bool is an int subclass
        return 1 if files_touched else 0
    if isinstance(files_touched, int):
        return files_touched
    if isinstance(files_touched, str):
        # A bare path string is ONE file. Without this guard a str is sized+iterable, so it would
        # fall through to len() and count CHARACTERS — silently filename-length-dependent (redteam).
        return 1 if files_touched.strip() else 0
    try:
        return len(files_touched)
    except TypeError:
        try:
            return sum(1 for _ in files_touched)
        except TypeError:
            return 0


def inline_fix_eligible(
    files_touched,
    *,
    touches_public_interface: bool = False,
    adds_dependency: bool = False,
    adds_behavior: bool = False,
    changed_lines=None,
    max_lines: int = DEFAULT_MAX_INLINE_LINES,
) -> bool:
    """Return True only when a candidate opportunistic fix stays within the hard inline ceiling.

    The ceiling (ANY one trips it → NOT eligible → must become a deferred finding / follow-up issue):
      - touches the change beyond a single file (>= 2 distinct files) — AC#4's own example
      - changes a public interface (exported signature / API surface; reviewer-judged, passed in)
      - introduces a new dependency
      - introduces new behavior (reviewer-judged, passed in)
      - exceeds the "few lines" budget when a concrete changed_lines count is supplied

    A zero/empty candidate is NOT eligible — there is nothing to fix inline, and "eligible" must
    never be the answer that grows the diff on uncertainty (fail-safe toward capture, not inline).
    """
    n_files = _file_count(files_touched)
    if n_files < 1 or n_files >= 2:
        return False
    if touches_public_interface or adds_dependency or adds_behavior:
        return False
    if changed_lines is not None and max_lines is not None and int(changed_lines) > int(max_lines):
        return False
    return True


def run_disposition(args) -> int:
    """CLI entry so the markdown driver can REACH these deterministic decisions (every other
    deterministic decision in sail/ is invocable via `python3 -m sail <subcommand>`).

    Two jobs, one subcommand:
      - default — ceiling check: prints `eligible` (rc 0) or `exceeds-ceiling` (rc 1) for a
        candidate, from the mechanizable inputs (file count / public-interface / dependency /
        behavior / line budget). The driver consults this instead of eyeballing the ceiling.
      - --record-inline-fix — append the durable inline-fix visibility marker to the run-dir's
        decision-log (rc 0). The "also corrected X while editing Y" narrative record.
    """
    if getattr(args, "record_inline_fix", False):
        if not args.run_dir or not args.file or args.summary is None:
            print("sail disposition: --record-inline-fix requires --run-dir, --file, --summary",
                  file=sys.stderr)
            return 2
        if not args.summary.strip():
            # An empty/whitespace summary defeats the visibility guard the feature exists for —
            # a marker with no "also corrected X while editing Y" explanation. Reject it.
            print("sail disposition: --summary must be a non-empty explanation "
                  "(\"also corrected X while editing Y\")", file=sys.stderr)
            return 2
        from sail.decisionlog import DecisionLog
        DecisionLog(args.run_dir).inline_fix_marker(args.file, args.summary)
        return 0

    eligible = inline_fix_eligible(
        args.files,
        touches_public_interface=args.public_interface,
        adds_dependency=args.adds_dependency,
        adds_behavior=args.adds_behavior,
        changed_lines=args.changed_lines,
        max_lines=args.max_lines if args.max_lines is not None else DEFAULT_MAX_INLINE_LINES,
    )
    print("eligible" if eligible else "exceeds-ceiling")
    return 0 if eligible else 1
