# MyTools — Domain Knowledge

## Rules

### Symlink operations are post-merge only
Never create a symlink pointing into this repo during a ship run. Symlinks that target paths in this repo (e.g. `~/projects/CK-Skills/commands/idea.md`) must only be created AFTER the branch merges to main — the target file does not exist at the main-repo path until merge. Document the symlink step in INSTALL.md and execute it manually post-merge.

*Source: RT-1/RT-13 — recurred across plan reviews until correctly deferred.*

### Shell scripts use `set -euo pipefail`
All `.sh` files in this repo must include `set -euo pipefail` near the top (after the shebang and any comments). This applies to test scripts and any future install/setup scripts.

*Source: RT-25 — consistency finding from full-branch review.*

### delivery-gate.sh gates /sloop and /skiff commits too — set the bypass in a separate call
The globally-installed `delivery-gate.sh` PreToolUse hook fires on any `git commit` (and `git push`/`git merge`/`gh issue close`) whenever a `~/.ship/ship-state-*.json` exists — including `/sloop` and `/skiff` runs, which have no advisor() protocol of their own. It blocks the commit unless an advisor() JSONL entry is on record OR `~/.ship/advisor-exempt-$PPID` exists; it blocks push/merge/close unless `~/.ship/delivery-approved-$CLAUDE_CODE_SESSION_ID` exists. Write the exempt flag / delivery signal in a SEPARATE Bash call BEFORE the gated command — PreToolUse hooks evaluate the whole command string before it runs, so a `touch … && git commit …` compound is still blocked (the touch hasn't executed yet).

*Source: /sloop #43 — commit blocked twice until the flag-write was isolated into its own prior Bash call.*

### sail parse_*: "one object WITH the key" is intentional fail-closed — don't re-flag it
`sail/review.py parse_findings` and `sail/plan.py parse_plan` collect only top-level JSON objects that HAVE the expected key (`findings` / `risks`), then return `None` if `len(candidates) != 1`. An extra top-level object that LACKS the key is intentionally ignored: it carries no findings/risks, so it cannot inject or suppress them, and a second object WITH the key trips `!=1 → None` (fail-closed). This deliberately tolerates chatty backends (a JSON example + the answer). Tightening to "exactly one top-level object total" REGRESSES that tolerance. The pattern is correct — red-team must NOT flag it as a fail-closed gap (it re-raised 3× as a false-positive during #46).

*Source: #46 — Gate S1/S2 + full-branch review repeatedly re-flagged the audited mirror pattern.*

### Validate required string fields with isinstance, not str() coercion
`str(x).strip() == ""` does NOT reject non-string values: `str(None) == "None"`, `str([]) == "[]"`, `str({}) == "{}"` are all non-empty, so `{"approach": null}` slips through a `str()`-based emptiness check. Use `isinstance(x, str) and x.strip()` to require a real, non-empty string. Applies to any "this field must be present and meaningful" gate (e.g. sail plan's usable-plan check on `approach`).

*Source: #46 — full-branch red-team R3 (a real HIGH: a `str()`-coercion emptiness check let `null`/`[]`/`{}` pass as a completed plan).*

### gitleaks `--config` REPLACES the default ruleset — require `[extend] useDefault = true`
A gitleaks config passed via `--config` does NOT merge onto the built-in rules — it replaces them. A config with only `[allowlist]` and no `[extend]\nuseDefault = true` silently disables ALL secret detection: the gate passes on every real leak. Any shipped gitleaks config MUST start with `[extend]\nuseDefault = true`. Exclusion mechanism differs per tool: bandit uses an `-x` fnmatch glob (`_BANDIT_EXCLUDE`); gitleaks uses an `[allowlist] paths` regex — do not assume one tool's idiom transfers. (Testing note: gitleaks allowlists the canonical AWS docs key `AKIAIOSFODNN7EXAMPLE` as a known example — use a non-example secret like a slack-bot-token to exercise detection.)

*Source: #48 RT-1 (CRITICAL, caught at plan red-team; live-verified after install).*

### Directory-exclusion in a scanner must be RELATIVE to the target, not an absolute-path substring
A file-discovery walk that excludes dirs by testing `"/.claude/" in dirpath` wrongly matches the target's OWN ancestor path — when sail runs `--target .` from a worktree under `.claude/worktrees/ship-NN/`, every dir is excluded and the gate silently scans nothing. Exclude by path segment relative to target: `rel = os.path.relpath(dirpath, target); parts = rel.split(os.sep); if ".claude" in parts: continue` (exact-segment match, so `.claude-backup` is not pruned). Do NOT exclude `.sail` — the diff-mode baseline worktree lives at `.sail/runs/*/baseline-src` and must be scanned. The legacy `_BANDIT_EXCLUDE` glob `*/.claude/*` has the same latent absolute-match flaw (separate, not yet fixed).

*Source: #48 RT-1 (HIGH, full-branch red-team — shellcheck would silently lint nothing when run from a worktree).*

### stdout-only checkers use `Checker.stdout_artifact=True` and must fail closed on empty
`_run_checker` writes captured stdout to the artifact verbatim when `stdout_artifact` is set (e.g. shellcheck `-f json` has no file flag). Do NOT coerce empty stdout to `[]` — a genuinely empty stdout (tool crash) must yield an unreadable artifact that fails closed downstream (never-mask). For the legitimate no-input case (shellcheck with no `*.sh`), emit a valid empty artifact via a `["printf","[]"]` no-op, never a zero-byte file (`delta._records` reads zero-byte as None → false block).

*Source: #48 RT-8.*

### Adding a registry checker must backfill resumed run-state gates
`gates_by_name[checker.name]` is indexed at two sites (the per-checker loop AND the `blocking_failed` comprehension); a resumed `run-state.json` predating a new checker KeyErrors. After building `gates_by_name`, backfill any missing registry checker as a fresh pending gate (RunState.init shape) in registry order; the in-loop `next_seq` assigns a monotonic gap-free seq. A new diff-mode artifact also needs a `delta.KIND_BY_ARTIFACT` entry + extractor, and the extractor MUST normalize file paths via `delta._rel(file, root)` (as `_sarif_records` does) so baseline vs current fingerprints match cross-worktree.

*Source: #48 RT-3/RT-4/RT-6/RT-7.*

### Python 3.9 host — no `tomllib`, no `match`; shellcheck ignores safe single-word literals
The sail host runs Python 3.9: no stdlib `tomllib` (3.11+) and no `match` statement. Parse TOML with the regex idiom used by `_testpaths_from_pyproject`, not `tomllib`/`tomli`. Tool-absent e2e gates are availability-gated (`command -v <tool>` guard); registry-contract + logic tests run regardless. shellcheck will NOT flag a var assigned a safe single-word literal (`var=x; echo $var` → no SC2086) — e2e fixtures needing a guaranteed SC2086 must use an unconstrained expansion (`ls $1` / `echo $1`, or `echo $var` without assignment).

*Source: #48 RT-9 + live verification (the original hermetic e2e used a non-triggering fixture).*

## Structure
- `commands/` — personal Claude skill files (markdown)
- `tests/` — shell test scripts verifying repo structure
- `INSTALL.md` — setup guide for new machines
- `.gitignore` — ignores `.claude/worktrees/`, `.ship/review/`, `.handoffs/`
