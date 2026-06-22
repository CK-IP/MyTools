#!/usr/bin/env bash
# test_sail_56_docs_impact.sh — issue #56: advisory docs-impact check.
# When a /sail change introduces a NEW external tool dependency or config knob,
# the pipeline must surface that INSTALL.md needs updating — a lightweight,
# advisory 'definition of done' checklist item, NOT a new blocking gate.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

SAIL_MD="commands/sail.md"
[ -f "$SAIL_MD" ] || fail "T0: $SAIL_MD not found"

# Isolate the docs-impact checklist line(s): the prose that names INSTALL.md as the
# update target. Case-insensitive so wording stays flexible.
DOCS_LINES="$(grep -i 'INSTALL\.md' "$SAIL_MD" || true)"

# --- T1: the docs-impact check exists and names INSTALL.md as the source-of-truth target. ---
[ -n "$DOCS_LINES" ] || fail "T1: $SAIL_MD must contain a docs-impact check naming INSTALL.md"
echo "PASS T1: $SAIL_MD names INSTALL.md as the docs-impact target"

# --- T2: the check names BOTH trigger conditions — a new external tool dependency AND a new config knob. ---
# Pull the surrounding context of the INSTALL.md mention so the triggers are checked against the
# actual checklist item, not anywhere in the file.
CONTEXT="$(grep -i -B1 -A3 'INSTALL\.md' "$SAIL_MD" || true)"
echo "$CONTEXT" | grep -qi 'external tool' \
  || fail "T2: docs-impact check must name the 'external tool dependency' trigger near INSTALL.md"
echo "$CONTEXT" | grep -qi 'config knob\|\.ship/domain\.md\|config dependency' \
  || fail "T2: docs-impact check must name the 'config knob' trigger (e.g. .ship/domain.md) near INSTALL.md"
echo "PASS T2: docs-impact check names both trigger conditions (external tool + config knob)"

# --- T3: the check is explicitly ADVISORY — not a new blocking gate / exit code. ---
echo "$CONTEXT" | grep -qi 'advisory\|definition of done\|does not block\|non-blocking\|never blocks' \
  || fail "T3: docs-impact check must be marked advisory / non-blocking (a checklist item, not a new gate)"
echo "PASS T3: docs-impact check is marked advisory (not a new gate)"

# --- T4: scope guard — the change must NOT alter the sail Python package (advisory prose only, no new gate). ---
# A new deterministic gate would mean touching sail/*.py; the issue explicitly excludes that.
if ! git rev-parse --verify main >/dev/null 2>&1; then
  echo "SKIP T4: no main ref to diff against"
else
  # Compare the working tree (staged + unstaged) against main, plus any new untracked
  # files, so the guard bites pre-commit too — `main...HEAD` would only see committed history.
  PY_CHANGED="$(git diff --name-only main -- 'sail/*.py' 2>/dev/null || true)"
  PY_UNTRACKED="$(git ls-files --others --exclude-standard -- 'sail/*.py' 2>/dev/null || true)"
  PY_ALL="$(printf '%s\n%s\n' "$PY_CHANGED" "$PY_UNTRACKED" | grep -v '^$' || true)"
  [ -z "$PY_ALL" ] || fail "T4: docs-impact check must be prose-only — sail/*.py changed: $PY_ALL"
  echo "PASS T4: no sail/*.py changes — advisory prose only, no new gate"
fi

echo "PASS: sail #56 docs-impact advisory check verified"
