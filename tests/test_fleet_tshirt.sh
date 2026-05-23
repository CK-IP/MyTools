#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLEET="$REPO_ROOT/commands/fleet.md"
SCHEMA="$REPO_ROOT/commands/epic-brief-schema.md"

PASS=0
FAIL=0

pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
}

# --- epic-brief-schema.md ---

# 1. Schema has a pipeline field
grep -qF '**pipeline:**' "$SCHEMA" && pass "schema: pipeline field exists" || fail "schema: pipeline field missing"

# 2. Pipeline field documents /ship as default
grep -q '/ship.*(default)' "$SCHEMA" && pass "schema: /ship is default pipeline" || fail "schema: /ship not marked as default"

# 3. Pipeline field documents /sloop as option
grep -q '/sloop' "$SCHEMA" && pass "schema: /sloop is an option" || fail "schema: /sloop not listed"

# 4. Pipeline field excludes /skiff with reason
grep -q '/skiff.*excluded' "$SCHEMA" && pass "schema: /skiff excluded with reason" || fail "schema: /skiff exclusion not documented"

# --- fleet.md description ---

# 5. Description mentions XL tier
grep -q 'XL' "$FLEET" && pass "fleet: mentions XL" || fail "fleet: XL not mentioned"

# 6. Description mentions t-shirt size framework
grep -qi 't-shirt' "$FLEET" && pass "fleet: mentions t-shirt" || fail "fleet: t-shirt not mentioned"

# --- fleet.md worker prompt template ---

# 7. Worker prompt references pipeline field (not hardcoded to /ship only)
grep -q '/sloop' "$FLEET" && pass "fleet: /sloop referenced in worker prompt" || fail "fleet: /sloop not referenced"

# 8. Worker rules mention sloop convergence gate (Stage 3d)
grep -q 'Stage 3d' "$FLEET" && pass "fleet: sloop Stage 3d referenced" || fail "fleet: sloop Stage 3d not referenced"

# 9. Worker rules mention sloop domain write stage (Stage 5)
grep -qE 'Stage 5.*domain|domain.*Stage 5' "$FLEET" && pass "fleet: sloop Stage 5 domain rule" || fail "fleet: sloop Stage 5 domain rule missing"

# 10. Worker rules for /ship still reference Stage 6e
grep -q 'Stage 6e' "$FLEET" && pass "fleet: /ship Stage 6e still referenced" || fail "fleet: /ship Stage 6e missing"

# 11. Worker rules for /ship still reference Stage 6d
grep -q 'Stage 6d' "$FLEET" && pass "fleet: /ship Stage 6d still referenced" || fail "fleet: /ship Stage 6d missing"

# --- fleet.md cross-references ---

# 12. Cross-references section exists
grep -q '## Cross-references' "$FLEET" && pass "fleet: cross-references section exists" || fail "fleet: cross-references section missing"

# 13. Cross-references mention /sloop
grep -A 10 '## Cross-references' "$FLEET" | grep -q 'sloop' && pass "fleet: xref includes sloop" || fail "fleet: xref missing sloop"

# 14. Cross-references mention /skiff exclusion
grep -A 10 '## Cross-references' "$FLEET" | grep -q 'skiff' && pass "fleet: xref includes skiff" || fail "fleet: xref missing skiff"

# 15. Cross-references mention epic-brief-schema
grep -A 10 '## Cross-references' "$FLEET" | grep -q 'epic-brief-schema' && pass "fleet: xref includes epic-brief-schema" || fail "fleet: xref missing epic-brief-schema"

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
