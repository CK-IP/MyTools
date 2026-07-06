from __future__ import annotations

import os
import shlex


def peel_argv(argv):
    if not argv:
        return ""
    if isinstance(argv, str):
        try:
            argv = shlex.split(argv)
        except (ValueError, OSError):
            return ""
    else:
        argv = list(argv)
    if not argv:
        return ""
    prog = os.path.basename(argv[0])
    if prog == "env":
        i = 1
        while i < len(argv) and (argv[i].startswith("-") or ("=" in argv[i] and not argv[i].startswith("-"))):
            i += 1
        return peel_argv(argv[i:]) if i < len(argv) else ""
    if prog in ("bash", "sh") and len(argv) >= 3 and argv[1] in ("-lc", "-c"):
        try:
            inner = shlex.split(argv[2])
        except (ValueError, OSError):
            return prog
        return peel_argv(inner) if inner else prog
    if prog.startswith("python") and len(argv) >= 3 and argv[1] == "-m":
        return os.path.basename(argv[2])
    return prog
