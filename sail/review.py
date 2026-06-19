from __future__ import annotations

import hashlib
import json
import os
import shlex
import shutil
import subprocess
import uuid
from datetime import datetime, timezone

from sail.decisionlog import DecisionLog

DEFAULT_BACKEND = ["claude", "-p"]

_VALID_SEV = {"CRITICAL", "HIGH", "MEDIUM", "LOW"}

REVIEW_PROMPT = """You are an adversarial code reviewer. Review the git diff below for genuine \
defects that a linter, type-checker, or security scanner would NOT catch: design flaws, \
correctness bugs, security issues, and scope/spec problems. Be specific and skeptical.

Output a single JSON object (a ```json fenced block is fine) of this shape:
{{"findings": [{{"severity": "CRITICAL|HIGH|MEDIUM|LOW", "category": \
"design|correctness|security|scope|other", "file": "<path or null>", "line": "<int or null>", \
"issue": "<what is wrong>", "recommendation": "<how to fix>"}}], "summary": "<one line>"}}
If there are no issues, return {{"findings": [], "summary": "no issues"}}.

=== DIFF ===
{diff}
=== END DIFF ==="""


def _backend_argv():
    env = os.environ.get("SAIL_REVIEW_CMD")
    if env is not None:
        return shlex.split(env)
    return list(DEFAULT_BACKEND)


def backend_available():
    argv = _backend_argv()
    if not argv:
        return False
    prog = argv[0]
    if shutil.which(prog) is not None:
        return True
    # An explicit path must be an executable file — a non-executable file or a
    # directory is not a runnable backend. Without this, subprocess.run() crashes
    # with a traceback instead of the caller's clean fail-closed / skip path.
    return os.path.isfile(prog) and os.access(prog, os.X_OK)


def build_prompt(diff_text):
    return REVIEW_PROMPT.format(diff=diff_text)


def _find_json_objects(text):
    # Return every top-level balanced {...} substring (brace-depth scan, string-aware).
    objs = []
    depth = 0
    start = -1
    in_str = False
    esc = False
    for i, ch in enumerate(text or ""):
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            if depth > 0:
                depth -= 1
                if depth == 0 and start != -1:
                    objs.append(text[start:i + 1])
                    start = -1
    return objs


def parse_findings(stdout):
    # Robust to a backend that wraps its JSON in prose: find the single top-level JSON
    # object that has a "findings" list. Fail closed (None) on 0 or >1 such objects so a
    # smuggled/injected second findings-object cannot suppress real findings. Never raises.
    candidates = []
    for blob in _find_json_objects(stdout or ""):
        try:
            obj = json.loads(blob)
        except (ValueError, TypeError):
            continue
        if isinstance(obj, dict) and isinstance(obj.get("findings"), list):
            candidates.append(obj)
    if len(candidates) != 1:
        return None
    out = []
    for finding in candidates[0]["findings"]:
        if not isinstance(finding, dict):
            return None
        sev = str(finding.get("severity", "")).strip().upper()
        if sev not in _VALID_SEV:
            sev = "HIGH"  # fail-closed: unknown/injected severity escalates, never downgrades
        normalized = dict(finding)
        normalized["severity"] = sev
        out.append(normalized)
    return out


def severity_counts(findings):
    counts = {"CRITICAL": 0, "HIGH": 0, "MEDIUM": 0, "LOW": 0}
    for finding in findings:
        sev = finding.get("severity", "LOW")
        if sev in counts:
            counts[sev] += 1
    return counts


def has_blocking(findings):
    return any(finding.get("severity") in ("CRITICAL", "HIGH") for finding in findings)


def _git_diff(target, diff_ref):
    result = subprocess.run(
        ["git", "-C", target, "diff", diff_ref], capture_output=True, text=True
    )
    if result.returncode != 0:
        raise ValueError(
            f"sail review: `git -C {target} diff {diff_ref}` failed "
            f"(rc={result.returncode}): {result.stderr.strip()}"
        )
    return result.stdout


def _sha256(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def diff_fingerprint(target, diff_ref):
    # SHA-256 of the diff text for (target, diff_ref). The reuse gate compares this
    # against the fingerprint stored in review.json so a moving ref (e.g. HEAD) whose
    # content changed re-reviews instead of reusing a stale result (#45).
    return _sha256(_git_diff(target, diff_ref))


def _invoke(prompt):
    argv = _backend_argv()
    try:
        result = subprocess.run(argv, input=prompt, capture_output=True, text=True)
    except OSError as exc:
        # Backend passed the availability preflight but could not actually be executed
        # (bad shebang, missing interpreter, noexec mount, removed after the probe).
        # Signal an unusable backend (non-zero rc) so callers fail closed via the
        # backend_error path instead of crashing with a traceback.
        return 127, "", f"backend exec failed: {exc}"
    return result.returncode, result.stdout, result.stderr


def review(target, diff_ref, advisory=False):
    diff_text = _git_diff(target, diff_ref)
    diff_hash = _sha256(diff_text)
    if not diff_text.strip():
        return {"findings": [], "raw": "", "rc": 0, "parse_ok": True, "empty_diff": True, "diff_hash": diff_hash}
    rc, out, err = _invoke(build_prompt(diff_text))
    findings = parse_findings(out)
    return {
        "findings": findings or [],
        "raw": out,
        "rc": rc,
        "parse_ok": findings is not None,
        "empty_diff": False,
        "stderr": err,
        "diff_hash": diff_hash,
    }


def run_review(target, diff_ref, run_dir=None, advisory=False):
    if target is None:
        target = "."
    if run_dir is None:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        run_dir = os.path.join(os.getcwd(), ".sail", "runs", f"review-{stamp}-{uuid.uuid4().hex[:8]}")
    os.makedirs(run_dir, exist_ok=True)
    log = DecisionLog(run_dir)
    artifact_path = os.path.join(run_dir, "review.json")

    if not backend_available():
        with open(artifact_path, "w", encoding="utf-8") as fh:
            json.dump({"status": "skipped", "reason": "no LLM backend available"}, fh, indent=2)
        log.review_marker("skipped: no LLM backend available")
        print("sail review: skipped (no LLM backend available)")
        return 0

    result = review(target, diff_ref, advisory=advisory)
    findings = result["findings"]
    counts = severity_counts(findings)
    # Backend error = a non-empty diff whose review is unusable: bad exit code OR unparseable.
    # Fail closed (mirrors the never-mask rule) so a crashed/partial backend can't pass the gate.
    backend_error = (not result.get("empty_diff")) and (result["rc"] != 0 or not result["parse_ok"])
    with open(artifact_path, "w", encoding="utf-8") as fh:
        json.dump(
            {
                "status": "error" if backend_error else "completed",
                "parse_ok": result["parse_ok"],
                "rc": result["rc"],
                "counts": counts,
                "findings": findings,
                "diff_hash": result.get("diff_hash"),
            },
            fh,
            indent=2,
        )
    marker = (
        f"{len(findings)} findings ({counts['CRITICAL']} CRITICAL, {counts['HIGH']} HIGH, "
        f"{counts['MEDIUM']} MEDIUM, {counts['LOW']} LOW)"
    )
    if backend_error:
        reason = "unparseable" if not result["parse_ok"] else f"rc={result['rc']}"
        marker = f"ERROR: backend response unusable ({reason}); " + marker
    log.review_marker(marker)
    print(f"sail review: {marker}")

    if advisory:
        return 0
    if backend_error:
        return 1  # never-mask: a non-empty diff with an unusable review must not pass
    return 1 if has_blocking(findings) else 0
