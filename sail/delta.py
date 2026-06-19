from __future__ import annotations

import json
import os
import urllib.parse
import xml.etree.ElementTree as ET
from collections import Counter

# Maps a checker's artifact filename to its delta "kind".
KIND_BY_ARTIFACT = {
    "ruff.sarif": "sarif",
    "bandit.sarif": "sarif",
    "semgrep.sarif": "sarif",
    "mypy.junit.xml": "junit",
    "junit.xml": "junit",
    "pip-audit.json": "pipaudit",
}


def _rel(uri_or_path, root):
    # Normalize a SARIF file:// URI (or raw path) to a repo-relative path so findings
    # match across runs in different worktrees. Strip the scheme, URL-decode, then make
    # relative to root. relpath does not raise for paths outside root (it returns a
    # ".." escape), so fall back to the decoded path when the result escapes root.
    p = uri_or_path or ""
    if p.startswith("file://"):
        p = p[len("file://"):]
    p = urllib.parse.unquote(p)
    if not root:
        return p
    try:
        rel = os.path.relpath(p, root)
    except (ValueError, TypeError):
        return p
    if rel.startswith(".."):
        return p
    return rel


def _load_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def _sarif_records(path, root):
    doc = _load_json(path)
    out = []
    for run in doc.get("runs", []) or []:
        for r in run.get("results", []) or []:
            rule = r.get("ruleId", "") or ""
            msg = ((r.get("message") or {}).get("text")) or ""
            uri = ""
            locs = r.get("locations") or []
            if locs:
                pl = (locs[0] or {}).get("physicalLocation") or {}
                uri = ((pl.get("artifactLocation") or {}).get("uri")) or ""
            rel = _rel(uri, root) if uri else ""
            out.append({"fp": (rel, rule, msg), "record": r})
    return out


def _junit_records(path, root):
    tree = ET.parse(path)
    out = []
    for tc in tree.getroot().iter("testcase"):
        if tc.find("failure") is None and tc.find("error") is None:
            continue
        cls = tc.get("classname", "") or ""
        name = tc.get("name", "") or ""
        out.append({"fp": (cls, name), "record": {"classname": cls, "name": name}})
    return out


def _pipaudit_records(path, root):
    doc = _load_json(path)
    out = []
    for dep in doc.get("dependencies", []) or []:
        name = dep.get("name", "") or ""
        for v in dep.get("vulns", []) or []:
            vid = v.get("id", "") or ""
            out.append({"fp": (name, vid), "record": {"name": name, "id": vid}})
    return out


_EXTRACTORS = {"sarif": _sarif_records, "junit": _junit_records, "pipaudit": _pipaudit_records}


def _records(path, kind, root):
    # Returns a list of {"fp", "record"} dicts, or None when the artifact is missing or
    # unparseable (the tri-state error signal — never raises).
    extractor = _EXTRACTORS.get(kind)
    if extractor is None:
        return None
    if not os.path.isfile(path):
        return None
    try:
        return extractor(path, root)
    except Exception:
        return None


def fingerprints(path, kind, root):
    # Counter of finding fingerprints, or None if the artifact is missing/unparseable.
    recs = _records(path, kind, root)
    if recs is None:
        return None
    return Counter(r["fp"] for r in recs)


def new_findings(current_path, baseline_path, kind, current_root, baseline_root):
    # Multiset delta. Returns:
    #   None  -> current artifact missing/unparseable (checker-error signal; never mask).
    #   []    -> current parses and every current fingerprint is covered by baseline counts.
    #   [..]  -> the current records whose fingerprint count exceeds the baseline count.
    # A missing/unparseable baseline is treated as empty (all current findings are new).
    cur = _records(current_path, kind, current_root)
    if cur is None:
        return None
    base_recs = _records(baseline_path, kind, baseline_root)
    remaining = Counter(r["fp"] for r in base_recs) if base_recs is not None else Counter()
    out = []
    for r in cur:
        fp = r["fp"]
        if remaining.get(fp, 0) > 0:
            remaining[fp] -= 1
        else:
            out.append(r["record"])
    return out
