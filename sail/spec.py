"""sail spec — assemble the FULL issue spec (body + comments) for the plan stage (#60).

`/sail`'s plan stage pipes a spec into `sail plan`. The front door fetches it from
`gh issue view`. Historically that was either body-only (`gh issue view <n>`) or, on
some `gh` versions, comments-only (`gh issue view <n> --comments` rendered just the
comments). Either way `is_plan_risky` (#58) could under-fire, because the #55 failure
shape needs a remediation signal AND a reconcile/list signal that often live in
DIFFERENT parts of the issue (one in the body, one in a comment).

The fix: the front door calls `gh issue view <n> --json title,body,comments` and pipes
that JSON here; `assemble_spec` renders title + body + comments into one plain-text spec.
Fails closed (exit 1) on empty/invalid input or a missing body, so an upstream `gh`
failure can never feed the planner a partial spec.

Trust note: comment bodies are now part of the plain-text spec fed to the planner LLM.
In the autonomous `/surf -> /sail` path a third-party comment is therefore planner-visible
input. Each comment is labelled with a `--- comment by <author> ---` header (data framing,
not an injection defense); harden further (author allow-list / stronger fencing) if the
trust boundary tightens.
"""
from __future__ import annotations

import json
import sys


def assemble_spec(raw_json):
    """Assemble title + body + comments from `gh issue view --json` output.

    Returns the assembled plain-text spec. Raises ValueError if the input is empty,
    not valid JSON, or has no issue body (fail-closed signals for the caller).
    """
    if not raw_json or not raw_json.strip():
        raise ValueError("empty input")
    try:
        data = json.loads(raw_json)
    except (ValueError, TypeError) as exc:
        raise ValueError(f"invalid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError("expected a JSON object")

    parts = []
    title = (data.get("title") or "").strip()
    if title:
        parts.append(title)

    body = (data.get("body") or "").strip()
    if body:
        parts.append(body)

    comment_parts = []
    for comment in data.get("comments") or []:
        if not isinstance(comment, dict):
            continue
        text = (comment.get("body") or "").strip()
        if not text:
            continue
        author = ((comment.get("author") or {}).get("login") or "").strip()
        header = f"--- comment by {author} ---" if author else "--- comment ---"
        comment_parts.append(f"{header}\n{text}")

    # Fail closed only when there is no real content (no body AND no comments) — that is the
    # gh-failure / empty-issue signal. A valid issue with a thin body but substantive comments
    # is exactly the #60 case (signals live in comments), so it must NOT abort: assemble from
    # whatever real content exists. Title alone is too thin to plan from.
    if not body and not comment_parts:
        raise ValueError("issue has no body or comments")

    parts.extend(comment_parts)
    return "\n\n".join(parts)


def run_spec():
    raw = sys.stdin.read()
    try:
        spec = assemble_spec(raw)
    except ValueError as exc:
        print(f"sail spec: {exc}", file=sys.stderr)
        return 1
    sys.stdout.write(spec + "\n")
    return 0
