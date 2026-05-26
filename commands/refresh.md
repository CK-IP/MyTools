Refresh the memory system — check for staleness, broken references, contradictions, and duplicates. Cross-references memory files against the filesystem and CRG code graph, then previews a clean-up plan before making changes. The user is NOT a programmer — use plain, simple language throughout.

## Setup — Load required tools

Before any refresh work, load AskUserQuestion via ToolSearch:

```
ToolSearch({ query: "select:AskUserQuestion", max_results: 1 })
```

If it fails to load, stop: "Failed to load AskUserQuestion — retry `/refresh`."

## Step 1/5 — Discover memories

**"Step 1/5 — Discover memories"**

Resolve the memory root for the current project:

1. Get the current working directory absolute path
2. Convert path separators to hyphens (e.g. `/Users/jane/projects/MyApp` becomes `-Users-jane-projects-MyApp`)
3. Check if `~/.claude/projects/<converted-path>/memory/MEMORY.md` exists
4. If not found, fall back: list all directories under `~/.claude/projects/` and look for any that contain a `memory/MEMORY.md` file
5. If still no match, stop: "No memory directory found for this project."

Once the memory root is resolved:

- Read the `MEMORY.md` index file
- List all `.md` files in the memory directory (excluding MEMORY.md itself)
- Announce to the user: **"Found X memory files in `<memory-dir>`"**

## Step 2/5 — Verify each memory

**"Step 2/5 — Verify each memory"**

For each `.md` file in the memory directory (skip MEMORY.md):

### Read and parse

- Read the full file
- Extract YAML frontmatter fields: `name`, `description`, `type`
- Look for a verified date in either `metadata.verified` (nested) or top-level `verified` field

### Age check

- If no `verified` date exists at all → flag as **UNVERIFIED**
- If `verified` date is more than 30 days old → flag as **STALE**

### Path check

- Scan the body (below frontmatter) for file path references — patterns like absolute paths starting with `/`, paths starting with `~/`, or relative paths like `commands/`, `hooks/`, `tests/`
- For each referenced path, run `test -e <expanded-path>` to check if it still exists on disk
- If any path does not exist → flag as **BROKEN-REF** and note which path is missing

### Code check (CRG integration)

- Check if any project under `~/projects/` has a `.code-review-graph/` directory
- If CRG is available, scan the memory body for references to specific functions, classes, or tool names (e.g. `get_minimal_context_tool`, `semantic_search_nodes_tool`, specific function names)
- Use `semantic_search_nodes_tool` to verify those symbols exist in the codebase
- If a referenced symbol cannot be found → flag as **BROKEN-REF**

### Duplicate check

- After reading all memories, compare each pair for overlapping content
- Two memories are **DUPLICATE** when they cover the same topic and their actionable guidance is equivalent — even if worded differently
- Focus on semantic overlap, not exact text matching: same advice about the same subject = duplicate
- Do NOT flag memories that merely mention the same topic but give different, complementary guidance
- If a duplicate pair is found → flag both as **DUPLICATE** and note which other memory it overlaps with

### Cross-check

- After reading all memories, compare their claims against each other
- Look for contradictions: e.g. one memory says "always use /ship" while another says "skip /ship for small changes"
- If a contradiction is found → flag both memories as **CONTRADICTION** and note the conflicting claim

### Index sync

- Check that every `.md` file in the directory has a corresponding entry in MEMORY.md
- Check that every entry in MEMORY.md points to an existing file
- Mismatches → flag as **INDEX-DRIFT**

## Step 3/5 — Report

**"Step 3/5 — Report"**

Present findings as a markdown table:

```
| # | Memory | Type | Verified | Finding | Severity |
|---|--------|------|----------|---------|----------|
```

Severity levels (from most to least urgent):

- **BROKEN-REF** — references a file path or code symbol that no longer exists
- **CONTRADICTION** — conflicts with another memory's claims
- **DUPLICATE** — substantially overlaps with another memory; should be merged
- **STALE** — `verified` date is more than 30 days old
- **UNVERIFIED** — no `verified` date in frontmatter at all
- **INDEX-DRIFT** — file/index mismatch (file exists but not in MEMORY.md, or vice versa)
- **OK** — no issues found

If all memories are OK, announce: **"All memories verified — no issues found."** and end.

If there are findings, tell the user: **"Found X issues across Y memories."** and continue to Step 4.

## Step 4/5 — Preview proposed changes

**"Step 4/5 — Here's what I'd recommend"**

Before touching any files, present a plain-language summary of all proposed changes grouped by action:

- **Merge** (for DUPLICATE pairs): "Combine *memory-A* and *memory-B* into a single memory, keeping the most complete version of each claim."
- **Edit** (for BROKEN-REF, CONTRADICTION): "Update *memory-X* to remove the reference to `path/that/no-longer/exists`." or "Resolve the contradiction between *memory-A* and *memory-B* by keeping the newer guidance."
- **Confirm** (for STALE, UNVERIFIED that appear still accurate): "Mark *memory-Y* as verified today — the content still looks correct."
- **Remove** (for memories that are clearly obsolete): "Delete *memory-Z* — its content is outdated and no longer relevant."
- **No change** (for OK memories): omit from the preview.

End the preview with a count: **"Proposed: X merges, Y edits, Z confirms, W removals."**

Then ask the user via AskUserQuestion:

- **Apply all** — proceed with every proposed change (still show each change as it happens)
- **Go one by one** — walk through each finding individually (Step 5 behavior)
- **Cancel** — stop without making changes

## Step 5/5 — Act on findings

**"Step 5/5 — Applying changes"**

### If "Apply all" was chosen

Process each proposed change in order. For each one, briefly announce what you're doing ("Merging *memory-A* + *memory-B*...") and make the edit. The user does not need to approve each individual change — they already approved the batch.

### If "Go one by one" was chosen

For each finding, present the memory name, the finding, and ask the user what to do via AskUserQuestion:

- **Confirm** — the memory is still accurate despite the finding; update `metadata.verified` to today's date (YYYY-MM-DD format)
- **Edit** — propose specific edits to fix the finding (you draft changes, user approves via normal Edit flow)
- **Merge** — (only shown for DUPLICATE findings) draft a combined memory that keeps the best of both, delete the redundant one, and update MEMORY.md
- **Remove** — delete the memory file and remove its line from MEMORY.md
- **Skip** — leave as-is for now

### Merge behavior

When merging two duplicate memories:

1. Draft a single combined memory that preserves all unique claims from both originals
2. Keep the `name` and filename of whichever memory is more descriptive (or ask the user if unclear)
3. Set `metadata.verified` to today's date
4. Delete the redundant memory file
5. Update MEMORY.md: remove the old entry, keep (or update) the surviving entry

### Updating the verified date

When the user selects **Confirm**, update the memory file's frontmatter:

- If the file has a `metadata:` block, add or update `verified: YYYY-MM-DD` under it
- If the file has no `metadata:` block, add one:
  ```yaml
  metadata:
    verified: YYYY-MM-DD
  ```
- Also recognize and update a top-level `verified:` field if that's what the file already uses

### Summary

After processing all findings, print:

**"Refresh complete: X memories audited, Y confirmed, Z edited, W merged, V removed, U skipped."**

## Verified date convention

This command establishes a convention for tracking memory freshness:

- Every memory file's YAML frontmatter should include a `metadata.verified` field with an ISO date (YYYY-MM-DD)
- When a memory passes refresh (user confirms it's still accurate), this field is set to today's date
- Memories without this field are flagged as UNVERIFIED
- Memories with a date older than 30 days are flagged as STALE
- The command recognizes both `metadata.verified` (nested) and top-level `verified` (flat) formats
