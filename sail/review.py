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

# Appended to REVIEW_PROMPT when the run-dir holds a plan.json with acceptance criteria
# (the plan->review traceability spine, #47). The SAME single LLM pass also verifies each
# acceptance criterion against the diff — no second invocation.
AC_PROMPT = """

Additionally, verify each ACCEPTANCE CRITERION below against the diff. For each, decide whether \
the diff clearly meets it ("met"), clearly does not ("unmet"), or cannot be determined from the \
diff alone ("unknown"). Add this key to the SAME JSON object:
"ac_results": [{{"criterion": "<verbatim criterion>", "status": "met|unmet|unknown", \
"evidence": "<one line>"}}]

=== ACCEPTANCE CRITERIA ===
{acs}
=== END ACCEPTANCE CRITERIA ==="""


def _backend_argv():
    env = os.environ.get("SAIL_REVIEW_CMD")
    if env is not None:
        return shlex.split(env)
    return list(DEFAULT_BACKEND)


def _second_lens_argv():
    # The optional second review lens (--dual-lens, #47). Only SAIL_REVIEW_CMD2 — there is
    # no built-in default, so dual-lens is opt-in and never auto-enables a second backend.
    env = os.environ.get("SAIL_REVIEW_CMD2")
    if env:
        return shlex.split(env)
    return None


def _argv_runnable(argv):
    if not argv:
        return False
    prog = argv[0]
    if shutil.which(prog) is not None:
        return True
    # An explicit path must be an executable file — a non-executable file or a
    # directory is not a runnable backend. Without this, subprocess.run() crashes
    # with a traceback instead of the caller's clean fail-closed / skip path.
    return os.path.isfile(prog) and os.access(prog, os.X_OK)


def backend_available():
    return _argv_runnable(_backend_argv())


def second_lens_available():
    return _argv_runnable(_second_lens_argv())


def build_prompt(diff_text, acs=None):
    prompt = REVIEW_PROMPT.format(diff=diff_text)
    if acs:
        acs_block = "\n".join(f"- {ac}" for ac in acs)
        prompt += AC_PROMPT.format(acs=acs_block)
    return prompt


def load_plan_acs(run_dir):
    # Read <run_dir>/plan.json (written by `sail plan` into the shared session run-dir).
    # Returns (acs, plan_status):
    #   plan_status == "absent"    — no plan.json file (non-blocking "no-plan" verification)
    #   plan_status == "malformed" — file exists but unparseable/garbled (RT-2: fail closed)
    #   plan_status == "ok"        — parsed; `acs` is the acceptance_criteria list (or None
    #                                when status != completed or no usable ACs)
    # Pure, never raises.
    path = os.path.join(run_dir or ".", "plan.json")
    if not os.path.exists(path):
        return None, "absent"
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None, "malformed"
    if not isinstance(data, dict):
        return None, "malformed"
    if data.get("status") != "completed":
        # A skipped/errored plan has no validated ACs to verify against — treat as no-plan
        # (the plan stage itself already failed closed on a real error).
        return None, "ok"
    raw = data.get("acceptance_criteria")
    if not isinstance(raw, list) or not raw:
        return None, "ok"
    acs = [str(ac) for ac in raw if isinstance(ac, (str, int, float)) and str(ac).strip()]
    return (acs or None), "ok"


def _finding_id(finding, lens="lens1"):
    # Content-derived stable id (RT-1): stable across reorderings and the dual-lens union,
    # lens-prefixed to disambiguate lens1 vs lens2. NOT a positional index.
    # Basis includes line + category (Gate F MED-2) so two findings that differ only in
    # line/category do not collapse to the same id.
    basis = "|".join(
        str(finding.get(k, "")) for k in ("issue", "file", "line", "severity", "category")
    )
    return f"{lens}-{_sha256(basis)[:12]}"


def parse_ac_results(stdout, acs):
    # Extract ac_results from the single findings-object. Tolerant: a missing/garbled
    # ac_results records every criterion as "unknown" (never raises, never blocks on its own
    # absence). When present, only met|unmet|unknown are honored; anything else -> "unknown".
    for blob in _find_json_objects(stdout or ""):
        try:
            obj = json.loads(blob)
        except (ValueError, TypeError):
            continue
        if isinstance(obj, dict) and isinstance(obj.get("findings"), list):
            raw = obj.get("ac_results")
            if isinstance(raw, list):
                by_crit = {}
                for item in raw:
                    if isinstance(item, dict) and isinstance(item.get("criterion"), str):
                        st = str(item.get("status", "")).strip().lower()
                        if st not in ("met", "unmet", "unknown"):
                            st = "unknown"
                        by_crit[item["criterion"].strip()] = {
                            "status": st,
                            "evidence": str(item.get("evidence", "")),
                        }
                out = []
                for ac in acs:
                    rec = by_crit.get(str(ac).strip(), {"status": "unknown", "evidence": ""})
                    out.append({"criterion": str(ac), "status": rec["status"], "evidence": rec["evidence"]})
                return out
            break
    return [{"criterion": str(ac), "status": "unknown", "evidence": ""} for ac in acs]


def _reconcile_ac_results(acs, ac_results_by_lens):
    # Merge per-lens ac_results into one verdict per criterion (HIGH-2, Gate F):
    # "unmet" if ANY lens reports unmet (the spine's fail-closed property — either lens blocks);
    # else "met" if any lens reports met; else "unknown". Lenses that returned None (errored /
    # no ACs) contribute nothing. Evidence is carried from the lens whose verdict was chosen.
    out = []
    for ac in acs:
        crit = str(ac)
        chosen = {"criterion": crit, "status": "unknown", "evidence": ""}
        for lens_results in ac_results_by_lens:
            if not lens_results:
                continue
            for item in lens_results:
                if item.get("criterion") != crit:
                    continue
                st = item.get("status", "unknown")
                if st == "unmet":
                    chosen = {"criterion": crit, "status": "unmet", "evidence": item.get("evidence", "")}
                    break
                if st == "met" and chosen["status"] != "met":
                    chosen = {"criterion": crit, "status": "met", "evidence": item.get("evidence", "")}
            if chosen["status"] == "unmet":
                break
        out.append(chosen)
    return out


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


def plan_fingerprint(run_dir):
    # SHA-256 of the plan's acceptance criteria for this run-dir (HIGH-1, Gate F). The reuse
    # gate compares this against the value stored in review.json so a CHANGED plan (new/edited
    # ACs in the shared run-dir) forces a fresh review instead of reusing a stale one — mirrors
    # the #45 diff-content fingerprint reuse gate. Absent plan / no ACs → stable sentinel hash.
    acs, _status = load_plan_acs(run_dir)
    return _sha256(json.dumps(acs or [], sort_keys=True))


def _invoke(prompt, argv=None):
    argv = list(argv) if argv else _backend_argv()
    try:
        result = subprocess.run(argv, input=prompt, capture_output=True, text=True)
    except OSError as exc:
        # Backend passed the availability preflight but could not actually be executed
        # (bad shebang, missing interpreter, noexec mount, removed after the probe).
        # Signal an unusable backend (non-zero rc) so callers fail closed via the
        # backend_error path instead of crashing with a traceback.
        return 127, "", f"backend exec failed: {exc}"
    return result.returncode, result.stdout, result.stderr


def review(target, diff_ref, advisory=False, acs=None, lens="lens1", argv=None):
    diff_text = _git_diff(target, diff_ref)
    diff_hash = _sha256(diff_text)
    if not diff_text.strip():
        return {"findings": [], "raw": "", "rc": 0, "parse_ok": True, "empty_diff": True,
                "diff_hash": diff_hash, "ac_results": None}
    rc, out, err = _invoke(build_prompt(diff_text, acs=acs), argv=argv)
    findings = parse_findings(out)
    if findings is not None:
        for finding in findings:
            # Overwrite (not setdefault) so a backend-supplied id/lens can't make the
            # identifier scheme attacker-controlled (Gate F MED-1). Compute id from the
            # finding's OWN content BEFORE stamping lens, so id is content-stable.
            finding["id"] = _finding_id(finding, lens)
            finding["lens"] = lens
    return {
        "findings": findings or [],
        "raw": out,
        "rc": rc,
        "parse_ok": findings is not None,
        "empty_diff": False,
        "stderr": err,
        "diff_hash": diff_hash,
        "ac_results": parse_ac_results(out, acs) if (acs and findings is not None) else None,
    }


def run_review(target, diff_ref, run_dir=None, advisory=False, dual_lens=False):
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

    # Plan->review spine (#47): load the plan's acceptance criteria from the shared run-dir.
    acs, plan_status = load_plan_acs(run_dir)

    result = review(target, diff_ref, advisory=advisory, acs=acs, lens="lens1")
    findings = list(result["findings"])
    ac_results_by_lens = [result.get("ac_results")]
    # Backend error = a non-empty diff whose review is unusable: bad exit code OR unparseable.
    # Fail closed (mirrors the never-mask rule) so a crashed/partial backend can't pass the gate.
    backend_error = (not result.get("empty_diff")) and (result["rc"] != 0 or not result["parse_ok"])

    # --dual-lens (#47): risk-gated second-lens escalation. Default is single-lens (industry
    # norm; convergence is the quality mechanism). When --dual-lens is set AND a second backend
    # (SAIL_REVIEW_CMD2) is available, run a second independent pass, union its findings (each
    # tagged lens2), and fail closed if EITHER lens errors or blocks. Set but no second backend
    # → log and degrade to single-lens cleanly (not a hard error).
    lenses = ["lens1"]
    if dual_lens and not result.get("empty_diff"):
        if second_lens_available():
            result2 = review(target, diff_ref, advisory=advisory, acs=acs,
                             lens="lens2", argv=_second_lens_argv())
            findings.extend(result2["findings"])
            ac_results_by_lens.append(result2.get("ac_results"))
            lenses.append("lens2")
            backend_error = backend_error or (result2["rc"] != 0 or not result2["parse_ok"])
            log.review_marker(f"dual-lens: lens2 ran ({len(result2['findings'])} findings)")
        else:
            log.review_marker("dual-lens requested but no second backend (SAIL_REVIEW_CMD2) — single-lens")

    counts = severity_counts(findings)

    # plan_verification (#47): the traceability spine. A malformed plan.json fails closed
    # (RT-2) — never silently degraded to "no-plan". Only a genuinely absent plan is no-plan.
    # HIGH-2 (Gate F): reconcile ac_results across BOTH lenses — any lens reporting "unmet"
    # blocks (preserves the "either lens blocks" property for the AC spine, not just findings).
    if plan_status == "malformed":
        plan_verification = {"status": "error", "reason": "plan.json present but unparseable",
                             "acceptance_criteria": []}
    elif acs:
        plan_verification = {"status": "verified",
                             "acceptance_criteria": _reconcile_ac_results(acs, ac_results_by_lens)}
    else:
        plan_verification = {"status": "no-plan", "acceptance_criteria": []}
    plan_error = plan_verification["status"] == "error"
    unmet_acs = [
        ac for ac in plan_verification.get("acceptance_criteria", [])
        if ac.get("status") == "unmet"
    ]

    with open(artifact_path, "w", encoding="utf-8") as fh:
        json.dump(
            {
                "status": "error" if (backend_error or plan_error) else "completed",
                "parse_ok": result["parse_ok"],
                "rc": result["rc"],
                "counts": counts,
                "findings": findings,
                "diff_hash": result.get("diff_hash"),
                "plan_hash": _sha256(json.dumps(acs or [], sort_keys=True)),
                "plan_verification": plan_verification,
                "lenses": lenses,
            },
            fh,
            indent=2,
        )
    marker = (
        f"{len(findings)} findings ({counts['CRITICAL']} CRITICAL, {counts['HIGH']} HIGH, "
        f"{counts['MEDIUM']} MEDIUM, {counts['LOW']} LOW)"
    )
    if plan_verification["status"] == "verified":
        n_ac = len(plan_verification["acceptance_criteria"])
        marker += f"; plan-verify {n_ac - len(unmet_acs)}/{n_ac} ACs met"
    if plan_error:
        marker = "ERROR: plan.json unparseable (failing closed); " + marker
    if backend_error:
        reason = "unparseable" if not result["parse_ok"] else f"rc={result['rc']}"
        marker = f"ERROR: backend response unusable ({reason}); " + marker
    log.review_marker(marker)
    # Record each unmet AC in the resolution log so the traceability spine is auditable.
    for ac in unmet_acs:
        log.review_marker(f"unmet AC: {ac.get('criterion', '')}")
    print(f"sail review: {marker}")

    if advisory:
        return 0
    if backend_error or plan_error:
        return 1  # never-mask: an unusable review OR an unparseable plan must not pass
    # An unmet acceptance criterion (when a plan with ACs exists) blocks — the spine has teeth.
    return 1 if (has_blocking(findings) or unmet_acs) else 0
