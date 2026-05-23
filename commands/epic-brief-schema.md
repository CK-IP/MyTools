# epic-brief.md — Schema Template
# Copy this file to .handoffs/epic-brief-<issue>-<timestamp>.md and fill in each section.

## Epic Metadata
- **title:** <!-- One-line description of the Epic -->
- **issue:** <!-- GitHub issue number, e.g. #12 -->
- **goal:** <!-- 2-3 sentence plain-language goal statement -->
- **repo:** <!-- owner/repo -->

## Workers
<!-- One entry per parallel workstream. Each worker has exclusive ownership of their files. -->

### Worker: <name>
- **sub_issue:** <!-- GitHub issue number this worker will ship -->
- **scope:** <!-- Plain description of what this worker builds -->
- **pipeline:** <!-- `/ship` (default) or `/sloop`. /skiff is excluded — fleet coordination requires per-worker branches. -->
- **files_owned:**
  <!-- Files this worker has exclusive write access to. No other worker touches these. -->
  - path/to/file1
- **files_readonly:**
  <!-- Files this worker reads but does not modify -->
  - path/to/shared-file
- **integration_contracts_produces:**
  <!-- Named contracts this worker outputs that other workers depend on -->
  - contract_name: description of the interface/format/schema
- **integration_contracts_consumes:**
  <!-- Named contracts this worker depends on from other workers -->
  - contract_name: what this worker expects the interface to look like

## QA Spec
- **qa_model:** opus
- **qa_mode:** rolling  <!-- QA reviews each worker as they complete, not after all finish -->
- **integration_points:**
  <!-- What QA must verify across workers' outputs -->
  - point 1: description
- **conflict_definition:**
  <!-- What counts as a conflict for this Epic -->
  <!-- e.g. "two workers write to the same file" or "produced contract doesn't match consumed spec" -->

## Cross-Cutting Concerns
<!-- Rules all workers must follow -->
- **naming:** <!-- File naming conventions -->
- **error_format:** <!-- How errors should be reported -->
- **shared_patterns:** <!-- Shared formatting, response shapes, etc. -->

## Epic Acceptance Criteria
<!-- Full-Epic definition of done — verified by QA across all workers' output -->
- [ ] criterion 1
- [ ] criterion 2

## Merge Rules
- **dependency_order:**
  <!-- Workers listed in the order their branches must be merged into main -->
  - worker-a   <!-- merge first -->
  - worker-b   <!-- merge second -->
  - worker-c   <!-- merge last -->
- **merge_condition:**
  <!-- What must be true before any merge: e.g. "QA CLEAR on all sub-issues, zero conflicts" -->
- **conflict_resolution:**
  <!-- What to do if a merge conflict is detected -->
