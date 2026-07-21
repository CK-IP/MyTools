from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from typing import Iterable, Optional


SOURCE_ROOTS = ("hooks/", "config/", "home/lib/")
ZSH_SOURCE_SNIPPET = 'emulate -L zsh; set -euo pipefail; . "$1"'
DEFAULT_PROBE_SECONDS = 5
# Exact interpreter basenames that make a shebang'd file a POSIX/bourne-sourceable surface.
# csh/tcsh/fish are deliberately excluded — they are not sh-family and sourcing them under zsh
# would false-positive (#145 review LOW).
_SHELL_INTERPRETERS = frozenset({"sh", "bash", "zsh", "ksh", "dash"})
# The zsh probe inherits only these vars — never the full environment. The gate runs unattended
# inside /sail//surf pipelines where the shell may export GH/cloud tokens; a changed sourced lib
# (or anything it transitively sources) must not see inherited secrets (#145 review MEDIUM).
_ENV_ALLOW = ("PATH", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TMPDIR", "USER", "LOGNAME")


def _norm_rel(path: str) -> str:
    return path.replace("\\", "/").lstrip("/")


def is_shell_surface(path: str, first_line: Optional[str]) -> bool:
    rel = _norm_rel(path)
    if rel.endswith((".md", ".markdown", ".rst")):
        return False
    if rel.endswith(".sh"):
        return True
    if any(rel.startswith(root) for root in SOURCE_ROOTS):
        return True
    line = (first_line or "").strip()
    if not line.startswith("#!"):
        return False
    # Match the interpreter BASENAME exactly — a substring test flags `#!/usr/bin/env fish`
    # or `#!/bin/csh` as sh-sourceable (`"sh"` is a substring of fish/csh/tcsh/dash) (#145 review).
    tokens = line[2:].split()
    if not tokens:
        return False
    interp = os.path.basename(tokens[0])
    if interp == "env" and len(tokens) > 1:
        interp = os.path.basename(tokens[1])
    return interp in _SHELL_INTERPRETERS


def discover_shell_surfaces(repo_root: str, changed_files: Iterable[str]) -> list[str]:
    found = []
    for rel in changed_files:
        rel = _norm_rel(rel)
        if not rel:
            continue
        path = os.path.join(repo_root, rel)
        if not os.path.isfile(path):
            continue
        first_line = None
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                first_line = fh.readline()
        except OSError:
            first_line = None
        if is_shell_surface(rel, first_line):
            found.append(rel)
    return sorted(dict.fromkeys(found))


def changed_files_from_git(repo_root: str, diff_ref: Optional[str]) -> list[str]:
    if not diff_ref:
        return []
    result = subprocess.run(
        ["git", "-C", repo_root, "diff", "--name-only", "--diff-filter=ACMRTUXB", diff_ref, "--"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return []
    return [line for line in result.stdout.splitlines() if line]


def _clean_env(home: str) -> dict[str, str]:
    # Allowlist, not passthrough-minus-SAIL: the probe sources changed shell code, so it must not
    # inherit credentials (GH/cloud tokens, API keys) present in the pipeline environment (#145).
    env = {k: os.environ[k] for k in _ENV_ALLOW if k in os.environ}
    env["HOME"] = home
    env.setdefault("PATH", "/usr/bin:/bin")  # zsh + coreutils must resolve
    return env


def _finding(surface: str, probe: str, message: str, **extra) -> dict[str, object]:
    out: dict[str, object] = {
        "surface": surface,
        "probe": probe,
        "detail": message,
    }
    out.update(extra)
    return out


def _run_zsh_source(
    surface: str,
    operand: str,
    probe: str,
    seconds: int = DEFAULT_PROBE_SECONDS,
    home: Optional[str] = None,
) -> Optional[dict[str, object]]:
    with tempfile.TemporaryDirectory(prefix="sail-shell-runtime-") as tmp:
        home = home or os.path.join(tmp, "home")
        cwd = os.path.join(tmp, "cwd")
        os.makedirs(home, exist_ok=True)
        os.makedirs(cwd, exist_ok=True)
        try:
            result = subprocess.run(
                ["zsh", "-f", "-c", ZSH_SOURCE_SNIPPET, "_", operand],
                cwd=cwd,
                env=_clean_env(home),
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=seconds,
                check=False,
            )
        except subprocess.TimeoutExpired:
            return _finding(surface, probe, "probe timed out", path=operand)
        except OSError as exc:
            return _finding(surface, probe, str(exc), path=operand)
    if result.returncode == 0:
        return None
    return _finding(
        surface,
        probe,
        "zsh source failed",
        path=operand,
        rc=result.returncode,
        stdout=result.stdout,
        stderr=result.stderr,
    )


def _lib_sourced_srcs(mappings: dict[str, str]) -> set[str]:
    # The genuine SOURCED-LIBRARY surface = files INSTALL.md installs into ~/.claude/lib/. Those
    # are the libs the zsh Bash-tool / hooks `source`, so they are the only files a zsh-source probe
    # is meaningful for (#127 surf-worker.sh, #128 sail-git-lifecycle.sh). Files installed elsewhere
    # (~/.claude/hooks/, ~/.claude/commands/) are EXECUTED under their own shebang, never sourced
    # under zsh — sourcing them would false-positive on legitimate bash idioms (#145 review).
    lib_root = os.path.abspath(os.path.expanduser("~/.claude/lib"))
    srcs = set()
    for src, dest in mappings.items():
        abs_dest = os.path.abspath(dest)
        if abs_dest == lib_root or abs_dest.startswith(lib_root + os.sep):
            srcs.add(os.path.realpath(src))
    return srcs


def parse_install_symlinks(install_md_path: str, repo_root: str) -> dict[str, str]:
    mappings: dict[str, str] = {}
    try:
        with open(install_md_path, encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        return mappings

    pattern = re.compile(
        r"""^\s*ln\s+-s\s+["']\$\((?:pwd)\)/([^"']+)["']\s+((?:~|\$HOME)/\.claude/\S+)\s*$"""
    )
    home_claude = os.path.abspath(os.path.expanduser("~/.claude"))
    for line in lines:
        match = pattern.match(line)
        if not match:
            continue
        rel_src, raw_dest = match.groups()
        rel_src = rel_src.lstrip("/")
        src = os.path.abspath(os.path.join(repo_root, rel_src))
        dest = raw_dest.replace("$HOME", "~", 1)
        dest = os.path.abspath(os.path.expanduser(dest))
        if dest == home_claude or dest.startswith(home_claude + os.sep):
            mappings[src] = dest
    return mappings


def _symlink_operand(temp_home: str, dest: str) -> str:
    real_home = os.path.abspath(os.path.expanduser("~"))
    abs_dest = os.path.abspath(dest)
    try:
        rel = os.path.relpath(abs_dest, real_home)
    except ValueError:
        rel = os.path.relpath(abs_dest, os.path.abspath(os.path.expanduser("~/.claude")))
        rel = os.path.join(".claude", rel)
    return os.path.join(temp_home, rel)


def _run_symlink_probe(repo_root: str, surfaces: Iterable[str], mappings: dict[str, str], seconds: int) -> list[dict[str, object]]:
    findings = []
    by_src = {os.path.realpath(src): dest for src, dest in mappings.items()}
    with tempfile.TemporaryDirectory(prefix="sail-shell-runtime-links-") as tmp:
        temp_home = os.path.join(tmp, "home")
        os.makedirs(temp_home, exist_ok=True)
        # Mirror the FULL installed layout — every INSTALL.md mapping, not just the changed libs —
        # so a changed lib that resolves an UNCHANGED sibling via its own symlink path (dirname of
        # ${(%):-%x}, the exact #128 pattern) finds the sibling instead of false-failing (#145 review).
        for src, dest in mappings.items():
            operand = _symlink_operand(temp_home, dest)
            os.makedirs(os.path.dirname(operand), exist_ok=True)
            try:
                os.symlink(os.path.realpath(src), operand)
            except FileExistsError:
                pass
            except OSError:
                pass
        # Probe ONLY the changed sourced libs, each through its own symlink operand.
        for rel in surfaces:
            rel_src = os.path.realpath(os.path.join(repo_root, rel))
            mapped_dest = by_src.get(rel_src)
            if not mapped_dest:
                continue
            operand = _symlink_operand(temp_home, mapped_dest)
            finding = _run_zsh_source(rel, operand, "symlink", seconds, home=temp_home)
            if finding is not None:
                findings.append(finding)
    return findings


def run_shell_runtime(
    repo_root: str,
    changed_files: Iterable[str],
    install_md_path: Optional[str] = None,
    seconds: int = DEFAULT_PROBE_SECONDS,
) -> list[dict[str, object]]:
    repo_root = os.path.abspath(repo_root)
    surfaces = discover_shell_surfaces(repo_root, changed_files)

    install_path = install_md_path or os.path.join(repo_root, "INSTALL.md")
    mappings = parse_install_symlinks(install_path, repo_root)
    lib_srcs = _lib_sourced_srcs(mappings)
    # Probe ONLY genuine sourced libraries (INSTALL.md → ~/.claude/lib/). Standalone bash-executed
    # scripts (LaunchAgent targets, Claude Code hooks) and non-shell files (.plist) are never
    # sourced under zsh, so probing them would false-positive (#145 review CRITICAL/HIGH). A lib
    # that is not yet declared in INSTALL.md is not live-sourced anywhere, so it carries no zsh
    # hazard until it is installed — the healthy forcing function (add the mapping to be probed).
    sourced_libs = [
        rel for rel in surfaces
        if os.path.realpath(os.path.join(repo_root, rel)) in lib_srcs
    ]
    findings = []
    for rel in sourced_libs:
        real_path = os.path.realpath(os.path.join(repo_root, rel))
        finding = _run_zsh_source(rel, real_path, "direct", seconds)
        if finding is not None:
            findings.append(finding)

    findings.extend(_run_symlink_probe(repo_root, sourced_libs, mappings, seconds))
    return findings


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True)
    parser.add_argument("--artifact", required=True)
    parser.add_argument("--diff-ref")
    parser.add_argument("--install-md")
    parser.add_argument("--seconds", type=int, default=DEFAULT_PROBE_SECONDS)
    args = parser.parse_args(argv)

    target = os.path.abspath(args.target)
    changed = changed_files_from_git(target, args.diff_ref)
    findings = run_shell_runtime(target, changed, install_md_path=args.install_md, seconds=args.seconds)
    os.makedirs(os.path.dirname(args.artifact), exist_ok=True)
    with open(args.artifact, "w", encoding="utf-8") as fh:
        json.dump(findings, fh, indent=2, sort_keys=True)
        fh.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
