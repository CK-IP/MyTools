from __future__ import annotations

import ast
import copy
import json
import sys
from pathlib import Path


def _normalize_docstrings(tree: ast.AST) -> None:
    for node in ast.walk(tree):
        body = getattr(node, "body", None)
        if not isinstance(body, list) or not body:
            continue
        if not isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            continue
        first = body[0]
        if not isinstance(first, ast.Expr):
            continue
        value = getattr(first, "value", None)
        if isinstance(value, ast.Constant) and isinstance(value.value, str):
            # A doctest-carrying docstring is executable test material
            # (pytest --doctest-modules): keep it verbatim so any edit to it
            # compares as behavioral. Only doctest-free prose is blanked.
            if ">>>" not in value.value:
                first.value = ast.Constant(value="")


def _parse_tree(src: str) -> ast.AST | None:
    try:
        return ast.parse(src)
    except SyntaxError:
        return None


def is_non_behavioral(old_src: str, new_src: str) -> bool:
    old_tree = _parse_tree(old_src)
    new_tree = _parse_tree(new_src)
    if old_tree is None or new_tree is None:
        return False

    old_tree = copy.deepcopy(old_tree)
    new_tree = copy.deepcopy(new_tree)
    _normalize_docstrings(old_tree)
    _normalize_docstrings(new_tree)
    return ast.dump(old_tree, include_attributes=False) == ast.dump(new_tree, include_attributes=False)


def _load_payload(raw: str) -> dict[str, object]:
    data = json.loads(raw)
    if not isinstance(data, dict):
        raise ValueError("hook input must be a JSON object")
    tool_input = data.get("tool_input")
    if isinstance(tool_input, dict):
        return tool_input
    return data


def _main(argv: list[str] | None = None) -> int:
    del argv
    raw = sys.stdin.read()
    try:
        payload = _load_payload(raw)
        file_path = payload["file_path"]
        old_string = payload["old_string"]
        new_string = payload["new_string"]
    except (KeyError, TypeError, ValueError, json.JSONDecodeError):
        return 2

    if not isinstance(file_path, str) or not isinstance(old_string, str) or not isinstance(new_string, str):
        return 2
    if not file_path or not old_string:
        return 2

    try:
        old_full = Path(file_path).read_text(encoding="utf-8")
    except OSError:
        return 2

    if old_string not in old_full:
        return 2

    replace_all = payload.get("replace_all", False)
    if not isinstance(replace_all, bool):
        return 2
    new_full = old_full.replace(old_string, new_string) if replace_all else old_full.replace(old_string, new_string, 1)
    return 0 if is_non_behavioral(old_full, new_full) else 2


if __name__ == "__main__":
    raise SystemExit(_main())
