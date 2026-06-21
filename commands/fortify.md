Automated security, coverage, and static analysis review. Runs after /ship to catch what LLM review misses. Usage: /fortify [issue-number]

## Setup

### Load AskUserQuestion

Before any other work, load AskUserQuestion via ToolSearch:
```
ToolSearch({ query: "select:AskUserQuestion", max_results: 1 })
```

### Detect project context

```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel)
BRANCH=$(git branch --show-current)
CHANGED_FILES=$(git diff main...HEAD --name-only)
```

Parse `$ARGUMENTS` for an optional issue number. If not provided, extract from branch name:
- Branch `ship/<number>` → issue number = `<number>`
- Otherwise, use "unknown"

Save as `$ISSUE`.

### Detect project type from changed files

- **Python:** any `.py` file in `$CHANGED_FILES`
- **Node:** any `.js` or `.ts` file in `$CHANGED_FILES`
- **Shell:** any `.sh` file in `$CHANGED_FILES`
- Multiple types are possible simultaneously

### Tool availability check

Run each tool to detect availability. Record which are installed:

```bash
command -v gitleaks  >/dev/null 2>&1 && HAVE_GITLEAKS=1  || HAVE_GITLEAKS=0
command -v semgrep   >/dev/null 2>&1 && HAVE_SEMGREP=1   || HAVE_SEMGREP=0
command -v pip-audit >/dev/null 2>&1 && HAVE_PIP_AUDIT=1 || HAVE_PIP_AUDIT=0
command -v bandit    >/dev/null 2>&1 && HAVE_BANDIT=1    || HAVE_BANDIT=0
command -v coverage  >/dev/null 2>&1 && HAVE_COVERAGE=1  || HAVE_COVERAGE=0
command -v shellcheck >/dev/null 2>&1 && HAVE_SHELLCHECK=1 || HAVE_SHELLCHECK=0
command -v pylint    >/dev/null 2>&1 && HAVE_PYLINT=1    || HAVE_PYLINT=0
command -v radon     >/dev/null 2>&1 && HAVE_RADON=1     || HAVE_RADON=0
command -v npm       >/dev/null 2>&1 && HAVE_NPM=1       || HAVE_NPM=0
```

After recording availability, emit a calm **coverage-count** line (not an alarming "Missing"
list) so the user sees that absent tools are skipped-by-design, not a failure. Over the gate set
fortify uses (gitleaks, semgrep, pip-audit, bandit, shellcheck, coverage, pylint, radon, npm),
count how many are installed (N total) and list any that are skipped:

> Gate coverage: X of N optional checks active. Skipped (not installed): <tools>
> → Run ./install.sh to enable the rest (see INSTALL.md).

If every tool is installed, just print the `Gate coverage: N of N optional checks active.` line and
omit the skipped/pointer lines.

If NONE of the security tools are installed (gitleaks=0, semgrep=0, pip-audit=0, bandit=0), still
proceed — produce a minimal report noting that no tools ran, verdict = ADVISORY.

---

## Pass 1: Security Scan

Run security tools. Gracefully skip any tool not installed — never fail because a tool is missing. Always use `|| true` on all tool commands so that non-zero exit codes (including gitleaks exit 1 for found leaks) do not abort execution before the report is written.

**For all projects (if gitleaks installed):**
```bash
# Only scan commits on this branch (not entire repo history)
[ "$HAVE_GITLEAKS" = 1 ] && cd "$PROJECT_ROOT" && \
  gitleaks detect --source . --no-banner --report-format json \
    --report-path /tmp/fortify-gitleaks.json \
    --log-opts "main...HEAD" 2>/dev/null || true
# Exit code 1 = leaks found, 0 = clean.
# Filter parsed findings to only files present in $CHANGED_FILES before severity mapping.
```

**For all projects (if semgrep installed):**
```bash
[ "$HAVE_SEMGREP" = 1 ] && cd "$PROJECT_ROOT" && \
  semgrep scan --config auto --json --quiet \
    > /tmp/fortify-semgrep.json 2>/dev/null || true
# Parse /tmp/fortify-semgrep.json — include only findings where the file path
# appears in $CHANGED_FILES.
```

**For Python projects (if pip-audit installed):**
```bash
[ "$HAVE_PIP_AUDIT" = 1 ] && cd "$PROJECT_ROOT" && \
  pip-audit --format json > /tmp/fortify-pip-audit.json 2>/dev/null || true
```

**For Python projects (if bandit installed and .py files changed):**
```bash
PYFILES=$(echo "$CHANGED_FILES" | grep '\.py$')
[ "$HAVE_BANDIT" = 1 ] && [ -n "$PYFILES" ] && cd "$PROJECT_ROOT" && \
  bandit -r $PYFILES -f json > /tmp/fortify-bandit.json 2>/dev/null || true
```

**For Node projects (if npm installed and package-lock.json exists):**
```bash
[ "$HAVE_NPM" = 1 ] && [ -f "$PROJECT_ROOT/package-lock.json" ] && \
  cd "$PROJECT_ROOT" && npm audit --json > /tmp/fortify-npm-audit.json 2>/dev/null || true
```

### Severity mapping

- gitleaks: any finding → HIGH
- semgrep: ERROR → HIGH, WARNING → MEDIUM, INFO → LOW
- pip-audit/npm audit: CVSS ≥ 7.0 → HIGH, ≥ 4.0 → MEDIUM, else → LOW
- bandit: HIGH → HIGH, MEDIUM → MEDIUM, LOW → LOW

### Fail-fast on HIGH

After Pass 1, check if any HIGH severity finding was found across all tools. If any HIGH found, skip Pass 2 and Pass 3 entirely — go directly to report generation and the BLOCK verdict. There is no benefit in measuring coverage when a secret has been leaked or a critical CVE is present.

---

## Pass 2: Coverage Check

Skip entirely if any HIGH finding was found in Pass 1 (fail-fast). Skip if no relevant language files changed.

**Python (if coverage installed and .py files changed):**
```bash
PYFILES=$(echo "$CHANGED_FILES" | grep '\.py$')
if [ "$HAVE_COVERAGE" = 1 ] && [ -n "$PYFILES" ]; then
  cd "$PROJECT_ROOT" && coverage run -m pytest --quiet 2>/dev/null || true
  # Build comma-separated include list without trailing comma
  PYINCLUDES=$(echo "$PYFILES" | paste -sd ',' -)
  cd "$PROJECT_ROOT" && coverage json -o /tmp/fortify-coverage.json \
    --include="$PYINCLUDES" 2>/dev/null || true
fi
```

**Node (if jest configured and .js/.ts files changed):**
```bash
JSFILES=$(echo "$CHANGED_FILES" | grep -E '\.(js|ts)$')
if [ "$HAVE_NPM" = 1 ] && [ -n "$JSFILES" ]; then
  cd "$PROJECT_ROOT" && npx jest --coverage --coverageReporters=json-summary \
    --silent 2>/dev/null || true
fi
```

Read coverage threshold from `.ship/domain.md` (look for a "coverage" rule). If no threshold defined, use advisory-only mode (report the number but do not change verdict based on it alone).

---

## Pass 3: Static Analysis

Skip entirely if any HIGH finding was found in Pass 1 (fail-fast). Skip tools for file types not present in CHANGED_FILES.

**Shell (if shellcheck installed and .sh files changed):**
```bash
SHFILES=$(echo "$CHANGED_FILES" | grep '\.sh$')
if [ "$HAVE_SHELLCHECK" = 1 ] && [ -n "$SHFILES" ]; then
  # Pass all files at once — produces one valid JSON array (not concatenated arrays)
  shellcheck -f json $SHFILES > /tmp/fortify-shellcheck.json 2>/dev/null || true
fi
```

**Python (if pylint installed and .py files changed):**
```bash
PYFILES=$(echo "$CHANGED_FILES" | grep '\.py$')
if [ "$HAVE_PYLINT" = 1 ] && [ -n "$PYFILES" ]; then
  pylint --errors-only --output-format=json $PYFILES \
    > /tmp/fortify-pylint.json 2>/dev/null || true
fi
```

**Python complexity (if radon installed and .py files changed):**
```bash
PYFILES=$(echo "$CHANGED_FILES" | grep '\.py$')
if [ "$HAVE_RADON" = 1 ] && [ -n "$PYFILES" ]; then
  radon cc $PYFILES -n C -j > /tmp/fortify-radon.json 2>/dev/null || true
fi
```

**TypeScript (if npm/npx available and .ts files changed):**
```bash
TSFILES=$(echo "$CHANGED_FILES" | grep '\.ts$')
if [ "$HAVE_NPM" = 1 ] && [ -n "$TSFILES" ]; then
  npx tsc --noEmit $TSFILES > /tmp/fortify-tsc.txt 2>/dev/null || true
fi
```

---

## Report Generation

Read the JSON output files from each tool. Build the report by formatting their contents as markdown tables — this is deterministic string formatting, not LLM summarization.

### Report location

- If running within a /ship worktree (`.ship/review/` directory exists): write to `.ship/review/fortify-report.md`
- Standalone: write to `.ship/fortify-report-<issue>.md` (create `.ship/` if needed)

### Report format

```markdown
# Fortify Report — #<issue>

**Branch:** <branch>
**Date:** <date>
**Verdict:** CLEAR | ADVISORY | BLOCK

## Security Scan
| Tool | HIGH | MED | LOW | Status |
|------|------|-----|-----|--------|
| semgrep | N | N | N | installed / not installed |
| gitleaks | N | N | N | installed / not installed |
| pip-audit | N | N | N | installed / not installed / N/A |
| bandit | N | N | N | installed / not installed / N/A |
| npm audit | N | N | N | installed / not installed / N/A |

### HIGH findings (must resolve)
- [tool] description — file:line

### MEDIUM findings (review)
- [tool] description — file:line

## Coverage
| Scope | Coverage | Threshold | Status |
|-------|----------|-----------|--------|
| Changed files | X% | Y% | PASS/FAIL/advisory |

Uncovered lines:
- file:line-range

## Static Analysis
| Tool | Findings |
|------|----------|
| shellcheck | N issues |
| pylint | N errors |
| radon | N complex functions |
| tsc | N type errors |

### Details
- [tool] finding — file:line

## Health Summary
Security: NH/NM/NL | Coverage: X% (≥Y%) | Static Analysis: N findings
```

---

## Verdict Rules

After building the report, determine the verdict:

- **BLOCK:** Any HIGH severity security finding (secrets, critical CVEs, critical SAST)
- **ADVISORY:** MEDIUM security findings present, OR coverage below threshold, OR static analysis findings present. No HIGHs.
- **CLEAR:** No HIGH security findings, coverage at or above threshold (or no threshold defined), no static analysis findings

---

## User Gate

After writing the report, present the verdict via AskUserQuestion (already loaded at startup):

**If BLOCK:**
Call AskUserQuestion with:
- question: "Fortify found HIGH-severity security issues:\n<list of HIGH findings>\n\nThese should be resolved before merge. How would you like to proceed?"
- options: ["Fix now (return to implementation)", "Acknowledge risk and continue", "Pause"]

**If ADVISORY:**
Call AskUserQuestion with:
- question: "Fortify review complete with advisories. See report at <path>. Continue to merge?"
- options: ["Yes, continue", "No, review findings first"]

**If CLEAR:**
No user gate needed. Print: "Fortify review complete — all clear. Report at <path>." and proceed.

---

## Graceful Degradation

At every step, handle missing tools gracefully:
- Never fail because a tool is not installed — skip it, record "not installed" in the report
- Always use `|| true` on tool invocations so non-zero exit codes do not abort the skill
- If ALL security tools are missing: produce a minimal report, verdict = ADVISORY
- If a JSON file is absent or empty: treat as zero findings for that tool
- The skill must complete and produce a report regardless of what tools are installed
