Audit the memory system for staleness, broken references, and contradictions. Cross-references memory files against the filesystem and CRG code graph. The user is NOT a programmer — use plain, simple language throughout.

## Setup — Load required tools

Before any audit work, load AskUserQuestion via ToolSearch:

```
ToolSearch({ query: "select:AskUserQuestion", max_results: 1 })
```

If it fails to load, stop: "Failed to load AskUserQuestion — retry `/memory-audit`."

## Step 1/4 — Discover memories

**"Step 1/4 — Discover memories"**

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

## Step 2/4 — Verify each memory

**"Step 2/4 — Verify each memory"**

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

### Cross-check

- After reading all memories, compare their claims against each other
- Look for contradictions: e.g. one memory says "always use /ship" while another says "skip /ship for small changes"
- If a contradiction is found → flag both memories as **CONTRADICTION** and note the conflicting claim

### Index sync

- Check that every `.md` file in the directory has a corresponding entry in MEMORY.md
- Check that every entry in MEMORY.md points to an existing file
- Mismatches → flag as **INDEX-DRIFT**

## Step 3/4 — Report

**"Step 3/4 — Report"**

Present findings as a markdown table:

```
| # | Memory | Type | Verified | Finding | Severity |
|---|--------|------|----------|---------|----------|
```

Severity levels (from most to least urgent):

- **BROKEN-REF** — references a file path or code symbol that no longer exists
- **CONTRADICTION** — conflicts with another memory's claims
- **STALE** — `verified` date is more than 30 days old
- **UNVERIFIED** — no `verified` date in frontmatter at all
- **INDEX-DRIFT** — file/index mismatch (file exists but not in MEMORY.md, or vice versa)
- **OK** — no issues found

If all memories are OK, announce: **"All memories verified — no issues found."** and end.

If there are findings, tell the user: **"Found X issues across Y memories. Let's go through them."**

## Step 4/4 — Act (optional)

**"Step 4/4 — Act on findings"**

Only runs if Step 3 found non-OK entries. For each finding, present the memory name, the finding, and ask the user what to do via AskUserQuestion:

- **Confirm** — the memory is still accurate despite the finding; update `metadata.verified` to today's date (YYYY-MM-DD format)
- **Edit** — propose specific edits to fix the finding (you draft changes, user approves via normal Edit flow)
- **Remove** — delete the memory file and remove its line from MEMORY.md
- **Skip** — leave as-is for now

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

**"Audit complete: X memories audited, Y confirmed, Z edited, W removed, V skipped."**

## Verified date convention

This command establishes a convention for tracking memory freshness:

- Every memory file's YAML frontmatter should include a `metadata.verified` field with an ISO date (YYYY-MM-DD)
- When a memory passes audit (user confirms it's still accurate), this field is set to today's date
- Memories without this field are flagged as UNVERIFIED
- Memories with a date older than 30 days are flagged as STALE
- The command recognizes both `metadata.verified` (nested) and top-level `verified` (flat) formats
