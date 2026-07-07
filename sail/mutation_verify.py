from __future__ import annotations

import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
from datetime import datetime, timezone


def _sha256(text: str) -> str:
    import hashlib

    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _finding_id(finding, lens="mutation-verify"):
    basis = "|".join(
        str(finding.get(k, "")) for k in ("issue", "file", "line", "severity", "category")
    )
    return f"{lens}-{_sha256(basis)[:12]}"


def _git(target, argv, *, input_text=None):
    result = subprocess.run(
        ["git", "-C", target, *argv],
        input=input_text,
        capture_output=True,
        text=True,
    )
    return result.returncode, result.stdout, result.stderr


def _git_or_raise(target, argv, *, input_text=None, label="git"):
    rc, out, err = _git(target, argv, input_text=input_text)
    if rc != 0:
        raise ValueError(f"{label} failed (rc={rc}): {err.strip()}")
    return out


def _default_run_dir():
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return os.path.join(os.getcwd(), ".sail", "runs", f"mutation-verify-{stamp}")


def is_doc_file(path):
    norm = (path or "").replace("\\", "/")
    base = os.path.basename(norm).lower()
    if not base:
        return False
    parts = [part.lower() for part in norm.split("/") if part]
    if "docs" in parts[:-1]:
        return True
    if base.startswith(("readme", "changelog", "changes", "license", "copying", "contributing")):
        return True
    if base in {"readme", "license", "copying"}:
        return True
    return os.path.splitext(base)[1] in {".md", ".rst", ".txt", ".adoc", ".org", ".man"}


def is_test_file(path):
    norm = (path or "").replace("\\", "/")
    if is_doc_file(norm):
        return False
    parts = [part.lower() for part in norm.split("/") if part]
    if not parts:
        return False
    base = parts[-1]
    if "tests" in parts[:-1]:
        return True
    return (
        base.startswith("test_")
        or base.endswith("_test.py")
        or base.endswith("_test.sh")
        or base.endswith("_test.bash")
        or base.endswith("_spec.py")
    )


def partition_changed(paths):
    tests = []
    sources = []
    seen = set()
    for raw in paths or []:
        path = str(raw or "").strip()
        if not path or path in seen:
            continue
        seen.add(path)
        if is_test_file(path):
            tests.append(path)
            continue
        if is_doc_file(path):
            continue
        sources.append(path)
    return tests, sources


_FIX_RE = re.compile(
    r"^(?:fix|bugfix|hotfix)(?:\([^)]+\))?(?:!)?:\s+",
    re.IGNORECASE,
)


def is_bug_fix_title(title):
    return bool(_FIX_RE.match(str(title or "").strip()))


def should_mutation_verify(is_bug_fix, test_paths, source_paths):
    return bool(is_bug_fix and test_paths and source_paths)


def classify_rc(rc, kind):
    if kind == "py":
        if rc == 0:
            return "pass"
        if rc in {2, 3, 4, 5}:
            return "inconclusive"
        return "fail"
    return "pass" if rc == 0 else "fail"


def collective_verdict(statuses):
    clean = [status for status in statuses if status not in {"skipped", None, ""}]
    if any(status == "fail" for status in clean):
        return "genuine"
    if any(status == "pass" for status in clean):
        return "vacuous"
    if any(status == "inconclusive" for status in clean):
        return "inconclusive"
    return "no-runnable-tests"


def _changed_paths(target, diff_ref):
    tracked_rc, tracked_out, tracked_err = _git(
        target, ["diff", "--no-renames", "--name-only", "-z", diff_ref]
    )
    if tracked_rc != 0:
        raise ValueError(
            f"git diff --name-only failed (rc={tracked_rc}): {tracked_err.strip()}"
        )
    untracked_rc, untracked_out, untracked_err = _git(
        target, ["ls-files", "--others", "--exclude-standard", "-z"]
    )
    if untracked_rc != 0:
        raise ValueError(
            f"git ls-files --others failed (rc={untracked_rc}): {untracked_err.strip()}"
        )
    tracked = [p for p in tracked_out.split("\0") if p]
    untracked = [p for p in untracked_out.split("\0") if p]
    merged = []
    seen = set()
    for path in tracked + untracked:
        if path in seen:
            continue
        seen.add(path)
        merged.append(path)
    return tracked, untracked, merged


def _source_patch(target, diff_ref, paths):
    if not paths:
        return ""
    return _git_or_raise(
        target,
        ["diff", "--binary", "--no-ext-diff", diff_ref, "--", *paths],
        label="git diff",
    )


def _apply_patch(target, patch_text, reverse=False):
    if not patch_text.strip():
        return
    argv = ["apply", "--binary"]
    if reverse:
        argv.append("-R")
    rc, _out, err = _git(target, argv, input_text=patch_text)
    if rc != 0:
        direction = "reverse apply" if reverse else "apply"
        raise ValueError(f"git {direction} failed (rc={rc}): {err.strip()}")


def _snapshot_files(target, paths):
    snapshots = {}
    for path in paths:
        full = os.path.join(target, path)
        if not os.path.exists(full):
            snapshots[path] = {"exists": False}
            continue
        with open(full, "rb") as fh:
            data = fh.read()
        mode = stat.S_IMODE(os.stat(full).st_mode)
        snapshots[path] = {"exists": True, "data": data, "mode": mode}
    return snapshots


def _restore_files(target, snapshots):
    for path, snap in snapshots.items():
        full = os.path.join(target, path)
        if not snap.get("exists"):
            try:
                os.remove(full)
            except FileNotFoundError:
                pass
            continue
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as fh:
            fh.write(snap["data"])
        os.chmod(full, snap["mode"])


def _run_test_file(target, path):
    if path.endswith(".py"):
        if shutil.which("pytest") is None:
            return {
                "file": path,
                "runner": "pytest",
                "rc": 127,
                "status": "skipped",
                "reason": "pytest unavailable",
                "skip_kind": "runner-absent",
            }
        result = subprocess.run(
            ["pytest", path],
            cwd=target,
            capture_output=True,
            text=True,
        )
        return {
            "file": path,
            "runner": "pytest",
            "rc": result.returncode,
            "status": classify_rc(result.returncode, "py"),
        }
    if path.endswith((".sh", ".bash")):
        result = subprocess.run(
            ["bash", path],
            cwd=target,
            capture_output=True,
            text=True,
        )
        return {
            "file": path,
            "runner": "bash",
            "rc": result.returncode,
            "status": classify_rc(result.returncode, "sh"),
        }
    return {
        "file": path,
        "runner": "unsupported",
        "rc": 0,
        "status": "skipped",
        "reason": "unsupported test file type",
        "skip_kind": "unsupported-type",
    }


def _vacuous_findings(test_results):
    findings = []
    for result in test_results:
        if result.get("status") != "pass":
            continue
        path = result.get("file", "")
        findings.append(
            {
                "severity": "HIGH",
                "category": "test-adequacy",
                "file": path,
                "line": None,
                "issue": "vacuous regression test: it still passes with the fix reverted",
                "recommendation": "assert behavior that fails when the fix is removed",
                "lens": "mutation-verify",
                "id": _finding_id(
                    {
                        "severity": "HIGH",
                        "category": "test-adequacy",
                        "file": path,
                        "line": None,
                        "issue": "vacuous regression test: it still passes with the fix reverted",
                    },
                    "mutation-verify",
                ),
            }
        )
    return findings


def _write_artifact(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False, dir=os.path.dirname(path)) as fh:
            tmp_path = fh.name
            json.dump(payload, fh, indent=2)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_path, path)
    finally:
        if tmp_path is not None and os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass


def _runner_absent(test_results):
    return any(
        isinstance(result, dict) and result.get("skip_kind") == "runner-absent"
        for result in (test_results or [])
    )


def runner_absent_alert(payload):
    if not isinstance(payload, dict) or not payload.get("runner_absent"):
        return None
    return "[ALERT] mutation-verify: tests were not actually run — pytest runner was absent"


def run_mutation_verify(target, diff_ref, run_dir=None, bug_fix=False, title=None):
    target = os.path.abspath(target or ".")
    # The bug-fix decision is a DETERMINISTIC, tested predicate (is_bug_fix_title), not an
    # orchestrator judgment call (CLAUDE.md infra-placement: deterministic decisions live in tested
    # Python, never the markdown prompt). Prefer deriving it from the issue --title; --bug-fix stays
    # an explicit operator override for the rare bug-fix that lacks a conventional-commit title.
    is_fix = bool(bug_fix) or is_bug_fix_title(title)
    if run_dir is None:
        run_dir = _default_run_dir()
    os.makedirs(run_dir, exist_ok=True)
    artifact_path = os.path.join(run_dir, "mutation-verify.json")
    payload = None
    diff_hash = ""
    try:
        diff_text = _git_or_raise(target, ["diff", diff_ref], label="git diff")
        diff_hash = _sha256(diff_text)
        tracked, untracked, changed = _changed_paths(target, diff_ref)
        test_paths, source_paths = partition_changed(changed)
        if not should_mutation_verify(is_fix, test_paths, source_paths):
            payload = {
                "status": "skipped",
                "verdict": "skipped",
                "reason": (
                    "non-bug-fix diff"
                    if not is_fix
                    else "no new/changed test files or no non-test source changes"
                ),
                "diff_hash": diff_hash,
                "findings": [],
            }
            return 0, payload, artifact_path

        tracked_source_paths = [path for path in source_paths if path in tracked]
        untracked_source_paths = [path for path in source_paths if path in untracked]
        patch_text = _source_patch(target, diff_ref, tracked_source_paths)
        # Snapshot the exact pre-revert working bytes of EVERY source file (tracked + untracked) so
        # restore is a deterministic byte-for-byte rewrite, not a fragile forward `git apply`. A
        # forward re-apply can fail or misapply if a non-hermetic test mutated a tracked source under
        # cwd while the fix was reverted — re-applying the fix patch onto that junk corrupts the tree
        # (redteam-3800ffad92be). Writing the captured bytes back is immune to that.
        tracked_snapshots = _snapshot_files(target, tracked_source_paths)
        untracked_snapshots = _snapshot_files(target, untracked_source_paths)
        reverted = False

        try:
            _apply_patch(target, patch_text, reverse=True)
            reverted = True
            for path in untracked_source_paths:
                try:
                    os.remove(os.path.join(target, path))
                except FileNotFoundError:
                    pass

            if os.environ.get("SAIL_MUTVERIFY_FORCE_RAISE") == "after-revert":
                raise RuntimeError("forced mutation-verify crash after revert")

            test_results = [_run_test_file(target, path) for path in test_paths]
            statuses = [result.get("status") for result in test_results]
            verdict = collective_verdict(statuses)
            if verdict == "no-runnable-tests":
                payload = {
                    "status": "skipped",
                    "verdict": verdict,
                    "reason": "no runnable new/changed tests",
                    "diff_hash": diff_hash,
                    "findings": [],
                    "tests": test_results,
                    "runner_absent": _runner_absent(test_results),
                }
                return 0, payload, artifact_path

            findings = _vacuous_findings(test_results) if verdict == "vacuous" else []
            payload = {
                "status": "completed",
                "verdict": verdict,
                "diff_hash": diff_hash,
                "findings": findings,
                "tests": test_results,
                "runner_absent": _runner_absent(test_results),
            }
            return 0, payload, artifact_path
        finally:
            # Restore the tree to EXACTLY the pre-check state by rewriting the captured working
            # bytes — never `git apply`. This touches only the working tree (never the index), so a
            # file that was modified-but-unstaged before stays modified-but-unstaged after, and a
            # pre-staged file keeps its staged state: mutation-verify must not `git add`/unstage the
            # source (the #131 T6/T7/T10/T10c index-neutral invariant). Byte-rewrite is also robust
            # to a non-hermetic test that mutated a tracked source mid-run (T10b / redteam-3800).
            if reverted:
                _restore_files(target, tracked_snapshots)
                _restore_files(target, untracked_snapshots)
    except Exception as exc:
        payload = {
            "status": "error",
            "verdict": "error",
            "reason": str(exc),
            "diff_hash": diff_hash,
            "findings": [],
        }
        return 1, payload, artifact_path
    finally:
        if payload is not None:
            _write_artifact(artifact_path, payload)


def merge_mutation_verify_findings(findings, run_dir, diff_hash):
    merged = list(findings or [])
    path = os.path.join(run_dir or "", "mutation-verify.json")
    try:
        with open(path, encoding="utf-8") as fh:
            artifact = json.load(fh)
    except (OSError, ValueError):
        return merged
    if not isinstance(artifact, dict):
        return merged
    if artifact.get("status") != "completed":
        return merged
    if artifact.get("diff_hash") != diff_hash:
        return merged
    vacuous = artifact.get("findings")
    if not isinstance(vacuous, list):
        return merged
    for finding in vacuous:
        if not isinstance(finding, dict):
            continue
        normalized = dict(finding)
        normalized["id"] = _finding_id(normalized, "mutation-verify")
        normalized["lens"] = "mutation-verify"
        merged.append(normalized)
    return merged
