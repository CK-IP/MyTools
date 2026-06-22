"""sail lifecycle — the isolate-vs-skip decision for /sail's git opening bookend (#65)
and the pure emit half of the closing "land" bookend (#59).

This is the *decision* half of the opening bookend; the git mechanics (worktree creation,
commit) live in `home/lib/sail-git-lifecycle.sh` (plain `git`, mode-agnostic). The decision
lives here, in the engine, for two reasons the plan red-team called out as HIGH:
  - it must REUSE the existing `is_plan_risky` heuristic (single source of truth), and
  - it must be PERSISTED to the decision-log on every path (isolate, in-place, forced).

It is ADDITIVE: a new `sail isolate` subcommand, wired in `__main__.py`, that touches none
of the `run`/`plan`/`review` codepaths. The decision itself (`isolate_decision`) is a pure
function — hermetically testable with no git, no I/O.

The closing bookend (#59) follows the same split: `sail land` reads a run-dir's review.json
(whose `plan_verification` block already carries the per-criterion AC verdicts) plus the
decision-log resolutions, and emits two pure strings — (a) the closing-comment markdown
(per-criterion AC verdicts + finding dispositions + gate counts, reusing that review evidence)
and (b) the merge-commit message carrying a `Closes #<issue>` keyword so the default-branch
merge auto-closes the issue (no separate `gh issue close`). It performs NO git/gh/network —
that orchestration (merge --no-ff, post comment, prune branch, --pr) is documented in the
skill markdown (commands/sail.md + commands/surf.md call the SAME emitted files, keeping one
source of truth), matching /ship's §6e-post convention. The emit is hermetically testable.
"""
from __future__ import annotations

import json
import os
import re
import sys

from sail.plan import is_plan_risky


def isolate_decision(branch, default_branch, force_isolate, force_in_place, plan_risky, concurrent):
    """Pure decision. Returns (decision, commit, reason).

    decision: "isolate" | "in-place";  commit: bool;  reason: str (for the decision-log).

    Precedence (first match wins) — mirrors how --dual-lens/--plan-adversary risk-gate:
      1. --isolate                        -> isolate, commit   (explicit force)
      2. --in-place + plan-risky          -> isolate, commit   (risk overrides the skip)
      3. --in-place + concurrent run      -> isolate, commit   (risk overrides the skip)
      4. --in-place (otherwise)           -> in-place, NO commit (risk-gated skip granted)
      5. on a feature branch (!= default) -> in-place, commit   (already isolated by branch)
      6. on the default branch            -> isolate, commit    (isolate-by-default)
    """
    if force_isolate:
        return ("isolate", True, "forced isolate (--isolate)")
    if force_in_place:
        if plan_risky:
            return ("isolate", True, "plan-risky spec overrides --in-place skip")
        if concurrent:
            return ("isolate", True, "concurrent run overrides --in-place skip")
        return ("in-place", False, "risk-gated skip (--in-place; not plan-risky; no concurrent run)")
    if branch and branch != default_branch:
        # The feature-branch case commits on the CURRENT branch BY DESIGN — it honors the
        # operator/driver's chosen branch (e.g. /surf's `surf/<issue>`). Forcing a
        # `sail/<issue>` checkout here would fight /surf, so the canonical `sail/<issue>`
        # name applies only to the from-default isolate path below.
        return ("in-place", True, f"on feature branch {branch} (already isolated; commit in place)")
    return ("isolate", True, f"isolate-by-default on {default_branch}")


def run_isolate(run_dir, branch, default_branch, force_isolate, force_in_place, concurrent, spec_text):
    """CLI entry: compute the decision (reusing is_plan_risky on the spec), persist it to
    the decision-log, and print `<decision>\\t<commit:yes|no>\\t<reason>` for the shell driver.

    --isolate and --in-place are mutually exclusive (fail closed, rc=2). Always rc=0 on a
    computed decision; the decision-log write is best-effort and never blocks the print.
    """
    if force_isolate and force_in_place:
        print("sail isolate: --isolate and --in-place are mutually exclusive", file=sys.stderr)
        return 2

    plan_risky = is_plan_risky(spec_text)
    decision, commit, reason = isolate_decision(
        branch, default_branch, bool(force_isolate), bool(force_in_place), plan_risky, bool(concurrent)
    )

    if run_dir:
        try:
            from sail.decisionlog import DecisionLog
            DecisionLog(run_dir).isolate_marker(decision, commit, reason)
        except OSError as exc:
            print(f"sail isolate: warning — could not write decision-log: {exc}", file=sys.stderr)

    sys.stdout.write(f"{decision}\t{'yes' if commit else 'no'}\t{reason}\n")
    return 0


# ---------------------------------------------------------------------------
# Closing bookend (#59): the pure emit half of `sail land`.
# ---------------------------------------------------------------------------

_AC_MARK = {"met": "✅ met", "unmet": "❌ unmet", "unknown": "❔ unknown"}

# GitHub auto-closes an issue when a commit message carries a closing keyword directly
# before an issue ref (`fixes #50`, `Closes: #50`) — ANYWHERE in the message, not just our
# own line (domain §5a). The author-supplied title is interpolated into the merge subject,
# so a title like "fix regression that fixes #50" would close the wrong issue on merge. Defuse
# any closing-keyword→issue-ref pair in the title by dropping the `#` (the number survives as
# plain text); only our deliberate `Closes #<issue>` line may auto-close.
_CLOSE_KW_REF = re.compile(
    r"\b(close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b(\s*:?\s*)#(\d+)", re.IGNORECASE
)


def _defuse_closing_keywords(text):
    return _CLOSE_KW_REF.sub(lambda m: f"{m.group(1)}{m.group(2)}{m.group(3)}", text)


def _safe_text(value):
    """Render an untrusted/derived string (AC criterion/evidence, finding text, disposition)
    for the closing comment: collapse newlines AND defuse closing keywords. The comment is
    reused as the `--pr`-mode PR body, where GitHub honors closing keywords — so stray
    `fixes #50`-style prose in review evidence must never auto-close an unrelated issue. Only
    the engine's own deliberate `Closes #<issue>` trailer is intentional (domain §5a)."""
    return _defuse_closing_keywords(re.sub(r"[\r\n]+", " ", str(value)).strip())


def _normalize_issue(issue):
    """Return the issue number as a clean numeric string, or raise ValueError.

    Numeric-only is a HARD requirement: the value is interpolated into a `Closes #<issue>`
    keyword that lands in a git commit message / PR body and into shell orchestration, so a
    non-numeric value is both a correctness bug (no auto-close) and an injection surface.
    """
    s = "" if issue is None else str(issue).strip()
    if not s.isdigit():
        raise ValueError(f"issue must be a numeric string, got {issue!r}")
    return s


def land_commit_message(title, issue, prefix="sail"):
    """Merge-commit message for the closing bookend — a pure function (no I/O).

    Shape (preserves the established `merge: <prefix> #<issue> — <title>` convention):
        merge: <prefix> #<issue> — <title>

        Closes #<issue>

    The `Closes #<issue>` keyword sits on its OWN line so GitHub auto-closes the issue when
    the merge lands on the default branch (AC#2 — no separate `gh issue close`). The same
    line serves as the `--pr`-mode PR body's close directive (AC#8). The title is the merge
    subject verbatim, with any trailing ` (#N)` stripped so a re-tagged title never
    double-references. Raises ValueError on a non-numeric issue (fail closed).
    """
    iss = _normalize_issue(issue)
    label = re.sub(r"[\r\n]+", " ", str(prefix or "sail").strip()) or "sail"
    subject = re.sub(r"[\r\n]+", " ", "" if title is None else str(title)).strip()
    subject = re.sub(r"\s*\(#\d+\)\s*$", "", subject)
    subject = _defuse_closing_keywords(subject)
    if not subject:
        subject = "land completion stage"
    return f"merge: {label} #{iss} — {subject}\n\nCloses #{iss}\n"


def _render_acs(plan_verification):
    """Render the per-criterion AC verdict block from review.json's plan_verification.

    Returns (header_suffix, lines). `plan_verification` may be absent/None (review evidence
    unavailable) or carry status no-plan / error / verified. Never raises.
    """
    if not isinstance(plan_verification, dict):
        return "", ["_No plan-verification block in review.json._"]
    status = plan_verification.get("status")
    if status == "no-plan":
        return "", ["_No plan recorded — acceptance criteria were not verified against a plan._"]
    if status == "error":
        return "", ["⚠️ _plan.json was malformed; acceptance criteria could not be verified._"]
    acs = plan_verification.get("acceptance_criteria")
    if not isinstance(acs, list) or not acs:
        return "", ["_No acceptance criteria recorded._"]
    lines = []
    met = 0
    for ac in acs:
        if not isinstance(ac, dict):
            continue
        st = ac.get("status", "unknown")
        if st not in _AC_MARK:
            st = "unknown"
        if st == "met":
            met += 1
        crit = _safe_text(ac.get("criterion", ""))
        lines.append(f"- {_AC_MARK[st]} — {crit}")
        evidence = _safe_text(ac.get("evidence", ""))
        if evidence:
            lines.append(f"  - _evidence:_ {evidence}")
    return f" ({met}/{len(acs)} met)", lines


def _render_findings(findings, resolutions):
    """Render the findings block, annotating each with its decision-log disposition.

    `findings` is review.json's findings list; `resolutions` maps finding id -> {disposition,
    rationale} (from DecisionLog.read_resolutions). Never raises.
    """
    if not isinstance(findings, list) or not findings:
        return ["_No findings._"]
    lines = []
    for f in findings:
        if not isinstance(f, dict):
            continue
        sev = str(f.get("severity", "?"))
        cat = str(f.get("category", "?"))
        loc = f"{f.get('file', '?')}:{f.get('line', '?')}"
        issue_text = _safe_text(f.get("issue", ""))
        lines.append(f"- **{sev}** {cat} — `{loc}` — {issue_text}")
        res = resolutions.get(str(f.get("id", ""))) if isinstance(resolutions, dict) else None
        if res:
            disp = _safe_text(res.get("disposition", ""))
            rat = _safe_text(res.get("rationale", ""))
            lines.append(f"  - _resolution:_ {disp} — {rat}")
    return lines or ["_No findings._"]


def _render_gates(counts):
    if not isinstance(counts, dict):
        return "_Gate results unavailable._"
    order = ["CRITICAL", "HIGH", "MEDIUM", "LOW"]
    return " · ".join(f"{k}: {counts.get(k, 0)}" for k in order)


def land_comment(issue, review_data, resolutions, review_state="ok"):
    """Build the closing-comment markdown — a pure function (no I/O).

    Reuses the already-produced review evidence (AC verdicts + findings + gate counts); it
    does NOT re-run an LLM acceptance review (AC#4). `review_state` is "ok" | "missing" |
    "malformed"; on a degraded state it emits a clear warning rather than crashing (AC#1).
    """
    iss = _normalize_issue(issue)
    out = [f"## /sail land — review evidence for #{iss}", ""]

    if review_state == "missing":
        out += ["⚠️ **Review evidence unavailable** — `review.json` was missing from the "
                "run-dir. Verify the acceptance criteria manually before relying on this close.", ""]
    elif review_state == "malformed":
        out += ["⚠️ **Review evidence unavailable** — `review.json` was malformed/unparseable. "
                "Verify the acceptance criteria manually before relying on this close.", ""]
    else:
        pv = review_data.get("plan_verification") if isinstance(review_data, dict) else None
        suffix, ac_lines = _render_acs(pv)
        out += [f"### Acceptance criteria{suffix}"] + ac_lines + [""]
        findings = review_data.get("findings") if isinstance(review_data, dict) else None
        out += ["### Findings"] + _render_findings(findings, resolutions) + [""]
        counts = review_data.get("counts") if isinstance(review_data, dict) else None
        out += ["### Gate results", _render_gates(counts), ""]

    out += ["---",
            f"_Auto-generated by `sail land` from `review.json` (no re-review). The issue is "
            f"closed by the merge commit's `Closes #{iss}` keyword on the default branch._"]
    return "\n".join(out) + "\n"


def _load_review(run_dir):
    """Read review.json -> (data, state). state: "ok" | "missing" | "malformed". Never raises."""
    path = os.path.join(run_dir, "review.json")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh), "ok"
    except FileNotFoundError:
        return None, "missing"
    except (ValueError, OSError):
        return None, "malformed"


def run_land(run_dir, issue, title, pr_mode=False, prefix="sail"):
    """CLI entry for the closing bookend: read the run-dir's review.json + decision-log,
    emit the closing-comment markdown and the merge-commit message (and, in --pr mode, a PR
    body carrying the close keyword), and write them into the run-dir for the documented git/
    gh orchestration to consume. Performs NO git/gh/network. Prints a one-line status.

    rc: 0 (emitted) | 2 (non-numeric issue — fail closed).
    """
    try:
        iss = _normalize_issue(issue)
    except ValueError as exc:
        print(f"sail land: {exc}", file=sys.stderr)
        return 2

    review_data, review_state = _load_review(run_dir)

    resolutions = {}
    try:
        from sail.decisionlog import DecisionLog
        resolutions = DecisionLog(run_dir).read_resolutions()
    except (ValueError, OSError):
        # Fail-graceful (matches _load_review): a corrupt/undecodable decision-log must not
        # crash the unattended /surf land step — degrade to no dispositions, never raise.
        pass

    comment = land_comment(iss, review_data, resolutions, review_state)
    commit_msg = land_commit_message(title, iss, prefix)

    os.makedirs(run_dir, exist_ok=True)
    comment_path = os.path.join(run_dir, "land-comment.md")
    msg_path = os.path.join(run_dir, "land-commit-msg.txt")
    with open(comment_path, "w", encoding="utf-8") as fh:
        fh.write(comment)
    with open(msg_path, "w", encoding="utf-8") as fh:
        fh.write(commit_msg)

    status = f"land: issue=#{iss} review={review_state} comment={comment_path} commit-msg={msg_path}"
    if pr_mode:
        pr_path = os.path.join(run_dir, "land-pr-body.md")
        with open(pr_path, "w", encoding="utf-8") as fh:
            fh.write(comment + f"\nCloses #{iss}\n")
        status += f" pr-body={pr_path}"

    print(status)
    return 0
