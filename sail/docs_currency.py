from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Iterable, Optional


_ENV_RE = re.compile(
    r"""(?x)
    \b(?:os\.environ(?:\.get)?|os\.getenv)\(
        \s*["'](?P<token>(?:SAIL|SURF)_[A-Z0-9_]+)["']
    """
)
_ENV_INDEX_RE = re.compile(
    r"""(?x)
    \bos\.environ\[\s*["'](?P<token>(?:SAIL|SURF)_[A-Z0-9_]+)["']\s*\]
    """
)
_CLI_SHUTIL_RE = re.compile(r"""(?x)\bshutil\.which\(\s*["'](?P<token>[^"']+)["']\s*\)""")
_CLI_LIST_RE = re.compile(
    r"""(?x)
    \bsubprocess\.(?:run|call|check_call|check_output|Popen)\(
        \s*\[
            (?P<first>[^,\]]+)
    """
)
_STRING_LITERAL_RE = re.compile(r"""^\s*["'](?P<token>[^"']+)["']\s*$""")
_FLAG_RE = re.compile(r"""(?x)(?<![\w-])(?P<token>--[A-Za-z0-9][A-Za-z0-9_-]*)""")

_COMMON_CLIS = {
    "bash",
    "cat",
    "cp",
    "echo",
    "env",
    "false",
    "git",
    "grep",
    "jq",
    "ls",
    "mkdir",
    "mv",
    "node",
    "npm",
    "python",
    "python3",
    "printf",
    "rm",
    "sed",
    "sh",
    "sort",
    "test",
    "touch",
    "true",
    "wget",
    "which",
    "zsh",
}


@dataclass(frozen=True)
class _Line:
    file: str
    line: int
    text: str


@dataclass
class _FileDiff:
    path: str
    added: list[_Line]
    removed: list[str]


def _is_docs_surface(path: str) -> bool:
    norm = path.replace("\\", "/")
    base = norm.rsplit("/", 1)[-1]
    return base == "INSTALL.md" or base.startswith("README") or (
        norm.startswith("commands/") and norm.endswith(".md")
    )


def _is_command_doc(path: str) -> bool:
    norm = path.replace("\\", "/")
    return norm.startswith("commands/") and norm.endswith(".md")


_LEADING_MARKER_RE = re.compile(r"^\s*(?:[-*|]\s+|>\s*|#{1,6}\s*|`+)")
_DOC_KEYWORDS = (
    "use", "using", "enable", "enabled", "configure", "config", "document", "docs",
    "mention", "support", "supported", "add", "added", "install", "requires", "require",
    "option", "flag", "env", "environment", "set",
)


def _looks_like_docs_mention(path: str, text: str, token: str = "") -> bool:
    lower = text.lower()
    if not _is_command_doc(path):
        return True
    # Loop-strip leading markdown markers (bullet/pipe/blockquote/heading/inline-code) — a
    # STACKED marker line (e.g. "- `--newflag`" = bullet + inline-code, or a table row
    # "| `--newflag` | ...") needs more than one pass. The bullet/pipe forms require trailing
    # whitespace, so this never eats a flag token's own leading "--" (no space after the dash).
    core = lower
    while True:
        stripped = _LEADING_MARKER_RE.sub("", core)
        if stripped == core:
            break
        core = stripped
    core = core.strip()
    if not core:
        return False
    # Bare usage/example lines (with no other prose) are not documentation mentions.
    if core.startswith(("usage:", "example:", "examples:")):
        return False
    if any(word in core for word in _DOC_KEYWORDS):
        return True
    # Generalize beyond the fixed keyword list: a line that mentions the token PLUS other
    # prose/content (a table cell's description column, an unlisted verb) still counts as a
    # genuine mention — only a bare repeat of the token itself (no surrounding content) does not.
    if token:
        residual = core.replace(token.lower(), " ")
        residual = re.sub(r"[`|]+", " ", residual).strip(" -:,")
        if residual:
            return True
    return False


def _extract_git_diff(target: str, diff_ref: str) -> str:
    result = subprocess.run(
        ["git", "-C", target, "diff", "--unified=0", "--no-renames", diff_ref],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ValueError(
            f"sail docs-currency: `git -C {target} diff --unified=0 {diff_ref}` failed "
            f"(rc={result.returncode}): {result.stderr.strip()}"
        )
    return result.stdout


def _parse_diff(diff_text: str) -> list[_FileDiff]:
    files: list[_FileDiff] = []
    current: Optional[_FileDiff] = None
    old_line = 0
    new_line = 0
    in_hunk = False

    def finish_current() -> None:
        nonlocal current, old_line, new_line, in_hunk
        current = None
        old_line = 0
        new_line = 0
        in_hunk = False

    for raw in (diff_text or "").splitlines():
        if raw.startswith("diff --git "):
            finish_current()
            match = re.match(r"^diff --git a/(.+?) b/(.+)$", raw)
            path = match.group(2) if match else ""
            current = _FileDiff(path=path, added=[], removed=[])
            files.append(current)
            continue
        if current is None:
            continue
        if raw.startswith(("@@", "index ", "--- ", "+++ ", "rename ", "similarity ",
                           "new file", "deleted file", "old mode", "new mode")):
            if raw.startswith("@@"):
                m = re.match(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@", raw)
                if m:
                    old_line = int(m.group(1))
                    new_line = int(m.group(2))
                    in_hunk = True
            else:
                in_hunk = False
            continue
        if not in_hunk:
            continue
        if raw.startswith("\\ No newline at end of file"):
            continue
        if raw.startswith("+"):
            current.added.append(_Line(current.path, new_line, raw[1:]))
            new_line += 1
            continue
        if raw.startswith("-"):
            current.removed.append(raw[1:])
            old_line += 1
            continue
        old_line += 1
        new_line += 1
    return files


def _env_tokens(text: str) -> set[str]:
    out = {m.group("token") for m in _ENV_RE.finditer(text)}
    out.update(m.group("token") for m in _ENV_INDEX_RE.finditer(text))
    return out


def _flag_tokens(text: str) -> set[str]:
    return {m.group("token") for m in _FLAG_RE.finditer(text)}


def _cli_literal_tokens(text: str) -> set[str]:
    out = {m.group("token") for m in _CLI_SHUTIL_RE.finditer(text)}
    for match in _CLI_LIST_RE.finditer(text):
        first = (match.group("first") or "").strip()
        literal = _STRING_LITERAL_RE.match(first)
        if literal:
            out.add(literal.group("token"))
    return out


def _cli_advisory_tokens(text: str) -> set[str]:
    out = set()
    for match in _CLI_LIST_RE.finditer(text):
        first = (match.group("first") or "").strip()
        literal = _STRING_LITERAL_RE.match(first)
        if literal:
            token = literal.group("token")
            if token in _COMMON_CLIS:
                out.add(token)
        else:
            out.add(first)
    return out


def _joined_added(file_diff: _FileDiff) -> tuple[str, list[tuple[int, int]]]:
    # Join this file's added lines into one text blob (newline-separated, in diff order) so a
    # call spanning 2-4 lines — e.g. `os.environ.get(\n    "SAIL_X", None\n)` — is still matched
    # by a single-pass regex, not just a genuinely single-line call. `offsets` maps each line's
    # start character offset in the blob back to its original diff line number, for reporting.
    parts = []
    offsets = []
    pos = 0
    for entry in file_diff.added:
        offsets.append((pos, entry.line))
        parts.append(entry.text)
        pos += len(entry.text) + 1  # +1 for the "\n" joiner below
    return "\n".join(parts), offsets


def _line_for_offset(offsets: list[tuple[int, int]], idx: int) -> int:
    result = offsets[0][1] if offsets else 0
    for start, line_no in offsets:
        if start <= idx:
            result = line_no
        else:
            break
    return result


def _docs_mentions_token(file_diff: _FileDiff, token: str) -> bool:
    if not _is_docs_surface(file_diff.path):
        return False
    for line in file_diff.added:
        if token in line.text and _looks_like_docs_mention(file_diff.path, line.text, token):
            return True
    return False


def _baseline_contains(repo_root: Optional[str], diff_ref: Optional[str], token: str) -> bool:
    # Whole-repo pre-diff existence check: a token already present ANYWHERE in the tree at
    # diff_ref was not introduced by this diff — even if this diff's own removed lines don't
    # happen to show it (e.g. it was read/documented in a file this diff doesn't touch). Without
    # this, a genuinely pre-existing (and already-documented) token that merely gains a NEW call
    # site in this diff is misreported as a fresh, undocumented introduction.
    if not repo_root or not diff_ref or not token:
        return False
    try:
        result = subprocess.run(
            ["git", "-C", repo_root, "grep", "-q", "-F", "-e", token, diff_ref, "--"],
            capture_output=True, text=True,
        )
    except OSError:
        return False
    return result.returncode == 0


def _find_env_var_findings(
    files: list[_FileDiff], repo_root: Optional[str] = None, diff_ref: Optional[str] = None
) -> list[dict]:
    removed = set()
    for file_diff in files:
        removed.update(_env_tokens("\n".join(file_diff.removed)))

    findings: list[dict] = []
    for file_diff in files:
        # A production env-var READ is Python source, never a test fixture (a heredoc'd Python
        # snippet inside a *.sh test script matches the same regex text but is not a real read).
        if not file_diff.path.endswith(".py"):
            continue
        joined, offsets = _joined_added(file_diff)
        for match in sorted(_ENV_RE.finditer(joined), key=lambda m: m.start()):
            token = match.group("token")
            _emit_env_finding(findings, files, removed, file_diff, token, match.start(), offsets, repo_root, diff_ref)
        for match in sorted(_ENV_INDEX_RE.finditer(joined), key=lambda m: m.start()):
            token = match.group("token")
            _emit_env_finding(findings, files, removed, file_diff, token, match.start(), offsets, repo_root, diff_ref)
    return findings


def _emit_env_finding(findings, files, removed, file_diff, token, start, offsets, repo_root=None, diff_ref=None):
    if token in removed:
        return
    if any(f.get("kind") == "env-var" and f.get("token") == token and f.get("file") == file_diff.path for f in findings):
        return
    if any(_docs_mentions_token(other, token) for other in files):
        return
    if _baseline_contains(repo_root, diff_ref, token):
        return
    findings.append({
        "kind": "env-var",
        "token": token,
        "file": file_diff.path,
        "line": _line_for_offset(offsets, start),
        "blocking": True,
        "severity": "HIGH",
        "issue": f"New environment read {token} needs a docs mention",
        "recommendation": "Add a mention in INSTALL.md, README.md, or the relevant commands/<name>.md.",
        "message": (
            f"Add a mention of {token} in INSTALL.md, README.md, or the relevant "
            "commands/<name>.md."
        ),
    })


def _find_flag_findings(
    files: list[_FileDiff], repo_root: Optional[str] = None, diff_ref: Optional[str] = None
) -> list[dict]:
    removed = set()
    for file_diff in files:
        if _is_command_doc(file_diff.path):
            removed.update(_flag_tokens("\n".join(file_diff.removed)))

    findings: list[dict] = []
    for file_diff in files:
        if not _is_command_doc(file_diff.path):
            continue
        joined, offsets = _joined_added(file_diff)
        for match in sorted(_FLAG_RE.finditer(joined), key=lambda m: m.start()):
            token = match.group("token")
            if token in removed:
                continue
            if any(f.get("kind") == "flag" and f.get("token") == token and f.get("file") == file_diff.path for f in findings):
                continue
            if any(_docs_mentions_token(other, token) for other in files):
                continue
            if _baseline_contains(repo_root, diff_ref, token):
                continue
            findings.append({
                "kind": "flag",
                "token": token,
                "file": file_diff.path,
                "line": _line_for_offset(offsets, match.start()),
                "blocking": True,
                "severity": "HIGH",
                "issue": f"New command flag {token} needs a docs mention",
                "recommendation": "Add a mention in INSTALL.md, README.md, or the relevant commands/<name>.md.",
                "message": (
                    f"Add a mention of {token} in INSTALL.md, README.md, or the relevant "
                    "commands/<name>.md."
                ),
            })
    return findings


def _find_cli_findings(
    files: list[_FileDiff], repo_root: Optional[str] = None, diff_ref: Optional[str] = None
) -> list[dict]:
    removed = set()
    for file_diff in files:
        joined_removed = "\n".join(file_diff.removed)
        removed.update(_cli_literal_tokens(joined_removed))
        removed.update(_cli_advisory_tokens(joined_removed))

    findings: list[dict] = []
    for file_diff in files:
        if not file_diff.path.endswith(".py"):
            continue
        joined, offsets = _joined_added(file_diff)
        seen_here: set = set()
        for match in _CLI_SHUTIL_RE.finditer(joined):
            _emit_cli_finding(findings, seen_here, removed, file_diff, match.group("token"), match.start(), offsets, repo_root, diff_ref)
        for match in _CLI_LIST_RE.finditer(joined):
            first = (match.group("first") or "").strip()
            literal = _STRING_LITERAL_RE.match(first)
            if literal:
                token = literal.group("token")
                if token in _COMMON_CLIS:
                    _emit_advisory_cli(findings, seen_here, file_diff, token, match.start(), offsets)
                else:
                    _emit_cli_finding(findings, seen_here, removed, file_diff, token, match.start(), offsets, repo_root, diff_ref)
            elif first and first not in removed:
                # Non-literal argv[0] (a variable/expression) — genuinely ambiguous, never
                # blocking; recorded advisory-only so the low-false-positive bar (AC #2) holds.
                _emit_advisory_cli(findings, seen_here, file_diff, first, match.start(), offsets)
    return findings


def _emit_cli_finding(findings, seen_here, removed, file_diff, token, start, offsets, repo_root=None, diff_ref=None):
    if token in removed or token in seen_here:
        return
    seen_here.add(token)
    if token in _COMMON_CLIS:
        _emit_advisory_cli(findings, seen_here, file_diff, token, start, offsets)
        return
    if _baseline_contains(repo_root, diff_ref, token):
        return
    findings.append({
        "kind": "cli",
        "token": token,
        "file": file_diff.path,
        "line": _line_for_offset(offsets, start),
        "blocking": True,
        "severity": "MEDIUM",
        "issue": f"New external CLI dependency {token} needs a docs mention",
        "recommendation": "Add a mention in INSTALL.md, README.md, or the relevant commands/<name>.md.",
        "message": (
            f"Add a mention of {token} in INSTALL.md, README.md, or the relevant "
            "commands/<name>.md."
        ),
    })


def _emit_advisory_cli(findings, seen_here, file_diff, token, start, offsets):
    key = ("advisory", token)
    if key in seen_here:
        return
    seen_here.add(key)
    findings.append({
        "kind": "cli",
        "token": token,
        "file": file_diff.path,
        "line": _line_for_offset(offsets, start),
        "blocking": False,
        "severity": "LOW",
        "issue": f"Ambiguous CLI dependency reference: {token}",
        "recommendation": "Confirm whether this is a real new dependency or just an existing ubiquitous tool.",
        "message": f"Ambiguous CLI dependency reference: {token} (advisory only).",
    })


def _merge_findings(*groups: Iterable[dict]) -> list[dict]:
    merged: list[dict] = []
    seen = set()
    for group in groups:
        for item in group:
            fp = (
                item.get("kind"),
                item.get("token"),
                item.get("file"),
                item.get("line"),
                item.get("blocking"),
            )
            if fp in seen:
                continue
            seen.add(fp)
            merged.append(item)
    return merged


def find_docs_currency_findings(target_or_diff: str, diff_ref: Optional[str] = None) -> list[dict]:
    """Return docs-currency findings from a diff text or from a target + diff ref."""
    repo_root: Optional[str] = None
    if diff_ref is None and "diff --git " in (target_or_diff or ""):
        diff_text = target_or_diff
    elif diff_ref is None:
        return []
    else:
        diff_text = _extract_git_diff(target_or_diff, diff_ref)
        repo_root = target_or_diff
    files = _parse_diff(diff_text)
    return _merge_findings(
        _find_env_var_findings(files, repo_root, diff_ref),
        _find_cli_findings(files, repo_root, diff_ref),
        _find_flag_findings(files, repo_root, diff_ref),
    )


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="python3 -m sail.docs_currency")
    parser.add_argument("--target", required=True)
    parser.add_argument("--diff-ref", required=True)
    args = parser.parse_args(argv)

    findings = find_docs_currency_findings(args.target, args.diff_ref)
    json.dump(findings, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
