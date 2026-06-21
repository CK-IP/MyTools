# /fortify ↔ /sail parity matrix

**Issue #52 deliverable.** `/sail` is replacing `/ship` (and its post-ship `/fortify` pass) for
routine work, so its coverage and test-quality posture must **match or beat** `/ship` + `/fortify`.
This matrix cross-checks each `/fortify` gate against `/sail`'s equivalent.

Verdict legend: **covered** (parity), **improved** (strictly better in `/sail`),
**intentionally-skipped** (not ported, with reason).

| /fortify gate | What /fortify does | /sail equivalent | Verdict | Notes |
|---|---|---|---|---|
| **npm audit** | `npm audit --json` on Node projects, only when `package-lock.json` exists; advisory→verdict by CVSS | `npm-audit` checker (#52): target-aware — invokes `npm audit --json` (with `cwd=target`) only when a Node manifest is present, else emits an empty-JSON sentinel so a no-Node repo passes cleanly in **both** whole-repo and diff modes; delta fingerprints by **module + advisory-id**, diff-mode suppresses pre-existing advisories; an `npm audit` error payload fails closed | **improved** | /fortify only ran on `package-lock.json`; /sail also detects `package.json`/`yarn.lock`/`npm-shrinkwrap.json`, is diff-aware (only *new* advisories block) where /fortify re-reports the whole tree, and never false-blocks a no-Node repo. |
| **coverage** | `coverage run -m pytest` then `coverage json`; **file-level** %; advisory unless a `.ship/domain.md` coverage rule sets a threshold | `diff-coverage` checker (#52): **line-level** coverage of **changed lines only** via `diff-cover` against the compare ref; one finding per uncovered changed line; advisory unless `.ship/domain.md` sets `diff-coverage-threshold: N`; tool-gated on `diff-cover` (skips cleanly when absent); diff-mode concept (no-ops in whole-repo / baseline generation) | **improved** | Line-level on the diff is strictly better than /fortify's whole-file %. A 95%-covered file whose 5% gap is *your new lines* passes /fortify but is caught by /sail. Same domain.md-threshold opt-in model preserved. |
| **pylint** | `pylint --errors-only` on changed `.py`; lists error-class findings | **ruff** checker (existing /sail registry): `ruff check` SARIF, diff-scoped (only new findings block) | **covered** | ruff's error rules subsume pylint's `--errors-only` class for the lint surface /fortify checked; ruff is the faster, SARIF-native equivalent already wired into the delta/blocking spine. pylint not ported as a separate gate — see follow-up. |
| **radon** | `radon cc -n C` complexity; lists high-complexity functions (advisory) | *(none)* | **intentionally-skipped** | Cyclomatic-complexity scoring is advisory-only in /fortify (never changes the verdict). /sail's quality bar is enforced by the blocking LLM review (which flags over-complex changes in context) plus convergence, not a numeric CC threshold. Porting radon as an advisory gate adds noise without a blocking signal. Recorded as a follow-up if a numeric CC gate is later wanted. |
| **tsc** | `npx tsc --noEmit` on changed `.ts`; type errors (advisory) | *(none)* | **intentionally-skipped** | This repo (and /sail's primary targets) are Python + shell — no TypeScript. A tsc gate would always no-op here. The npm-audit contract work (target-aware manifest detection) is the reusable seam to add a tsc gate when a TS target appears; deferred to that point. Recorded as a follow-up. |

## Net posture

`/sail` **matches or beats** `/fortify` on the two gates that carry a blocking signal
(npm-audit, coverage) — both are now diff-aware and, for coverage, line-level — and covers
pylint's error surface via ruff. The two skipped gates (radon, tsc) were **advisory-only** in
`/fortify` (they never changed its verdict), so skipping them does not weaken the enforced bar.

## Remaining gaps — explicit follow-up notes (not silent omissions)

1. **radon (cyclomatic complexity)** — no numeric CC gate in /sail. Mitigated today by the
   blocking LLM review + convergence. *Follow-up:* add an advisory `radon` checker if a numeric
   CC threshold is later desired (would slot in as a non-blocking registry entry).
2. **tsc (TypeScript types)** — no TS gate; no TS in current targets. *Follow-up:* add a
   `tsc` checker reusing #52's target-aware manifest detection (`tsconfig.json` present) when a
   TypeScript target is onboarded.
3. **pylint beyond `--errors-only`** — ruff covers the error surface /fortify checked; pylint's
   broader (convention/refactor) classes are not ported. *Follow-up:* enable additional ruff
   rule families if that breadth is wanted, rather than re-introducing pylint.
4. **npm-audit manifest detection is root-level only** — a monorepo with nested `package.json`
   dirs is not recursively audited, and Yarn projects (`yarn.lock` without `package-lock.json`)
   are detected but `npm audit` may not fully resolve them. *Follow-up* (review lens1-f929 /
   lens2-aca3): recursive/per-package detection or a Yarn-aware variant if a monorepo/Yarn
   target is onboarded. Scoped out of #52 (single-target root audit is the issue's scope).
