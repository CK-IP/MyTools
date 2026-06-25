#!/usr/bin/env bash
# test_sail_56_docs_impact.sh — issue #56: advisory docs-impact check.
# When a /sail change introduces a NEW external tool dependency or config knob,
# the pipeline must surface that INSTALL.md needs updating — a lightweight,
# advisory 'definition of done' checklist item, NOT a new blocking gate.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# Hermetic (.ship/domain.md #102): a real shell exports SAIL_* codex knobs (settings.json);
# clear them so each subtest controls its own backend (subtests set theirs via command prefix).
unset "${!SAIL_@}"

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

# --- T4: scope guard — #56 added NO new deterministic gate (advisory prose only). ---
# HERMETIC rewrite (#78). The ORIGINAL T4 asserted `git diff --name-only main -- sail/*.py`
# was empty — a NON-HERMETIC global property of the whole branch-vs-main diff that FALSE-FAILS
# on any sibling branch that legitimately changes a sail/*.py for a DIFFERENT issue (this is the
# exact antipattern the #68 domain rule + #64 guidance warn against). The intent #56 actually
# cares about — "no new sail gate was registered" — is verified branch-independently below by
# inspecting the LIVE checker registry (a pure function of the source, never a branch diff).

# T4a — a NEW gate would register a checker in sail/checkers.py. Assert no docs-impact-named
# checker is present. Reads registry NAMES only — no git, no diff, no branch dependence.
REGISTRY="$(python3 -c 'from sail.checkers import build_registry; print(" ".join(c.name for c in build_registry()))' 2>/dev/null || true)"
[ -n "$REGISTRY" ] || fail "T4a: could not read the live sail checker registry"
for gate in docs-impact docs-check install-docs docs; do
  if echo "$REGISTRY" | grep -qw "$gate"; then
    fail "T4a: #56 is advisory-only but a '$gate' gate is registered: $REGISTRY"
  fi
done
echo "PASS T4a: #56 registered no new sail gate (advisory prose only) — registry: $REGISTRY"

# T4b — PROVE T4a is branch-independent by actually RE-RUNNING its check against a THROWAWAY
# copy of the sail package that carries an unrelated sail/*.py change (#78 regression guard).
# This is the exact scenario the OLD `git diff main -- sail/*.py` check false-failed on: a
# sibling branch legitimately edits a sail/*.py for a DIFFERENT issue. Per the hermetic-test
# domain rule we mutate a THROWAWAY copy, never the live repo root. Only ADDING a gate may flip
# the verdict; an unrelated .py edit must not.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp -R sail "$TMP/sail"
# Simulate a sibling branch's unrelated sail/*.py change (NOT a new gate):
printf '\n# unrelated sibling edit for a DIFFERENT issue (#78 proof)\n_UNRELATED = True\n' >> "$TMP/sail/plan.py"
# Re-run the SAME registry check against the mutated copy (cwd-first import picks up the copy):
REGISTRY_SIB="$(cd "$TMP" && python3 -c 'from sail.checkers import build_registry; print(" ".join(c.name for c in build_registry()))' 2>/dev/null || true)"
[ -n "$REGISTRY_SIB" ] || fail "T4b: could not read the registry from the throwaway sail copy"
[ "$REGISTRY" = "$REGISTRY_SIB" ] \
  || fail "T4b: registry check changed under an unrelated sibling sail/*.py edit — not branch-independent (got: $REGISTRY_SIB)"
echo "PASS T4b: an unrelated sibling sail/*.py change leaves T4a's verdict unchanged — branch-independent (the OLD git-diff-main check would have false-failed here)"

echo "PASS: sail #56 docs-impact advisory check verified"
