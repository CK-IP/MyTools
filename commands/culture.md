Interact with the RnD-Wiki knowledge base — set up access, capture knowledge, or search for articles. The user is NOT a programmer — use plain, simple language throughout.

## Routing

Parse `$ARGUMENTS` for the subcommand. The first word determines which section to run:

- `setup` → run the **Setup** section
- `add` or `add <topic>` → run the **Add** section (everything after `add` is the topic)
- `search` or `search <query>` → run the **Search** section
- `refresh` → run the **Refresh** section
- anything else or empty → show the **Help** section

## Help

If no subcommand is provided, or the subcommand is not recognized, show:

**"The `/culture` command helps you work with the team's knowledge base. Here's what you can do:**

- **`/culture setup`** — One-time setup. Connects your projects to the knowledge base so every agent can find domain knowledge automatically.
- **`/culture add`** — Capture something you learned during this session into a knowledge base article. Creates a draft and opens it for review.
- **`/culture search <topic>`** — Look up what's in the knowledge base. *(Coming soon)*
- **`/culture refresh`** — Run a health check on the knowledge base. Finds duplicates, articles that should be split or merged, miscategorized articles, and more.

**Just type one of those to get started."**

## Setup

> Run once per machine. Makes every project under `~/projects/` wiki-aware.

### Step 1: Check CK-Skills

Check if CK-Skills is installed by testing whether `~/.claude/commands/culture.md` exists and resolves.

If it resolves (which it must, since this command is running), say:

**"CK-Skills is installed — good to go."**

### Step 2: Check for the knowledge base repo

Check if `~/projects/RnD-Wiki` exists.

If it exists, say:

**"Knowledge base repo found at `~/projects/RnD-Wiki`."**

If it does NOT exist, say:

**"The knowledge base repo isn't on your machine yet. Let me download it."**

Then run:

```bash
git clone git@github.com:Icelandic-Provisions/RnD-Wiki.git ~/projects/RnD-Wiki
```

If the clone succeeds, say: **"Downloaded the knowledge base."**

If the clone fails (e.g., permission denied), say:

**"I couldn't download the knowledge base — you might not have access yet. Ask your team lead to add you to the `Icelandic-Provisions/RnD-Wiki` repo on GitHub, then run `/culture setup` again."**

Then STOP — do not continue to the next step.

### Step 3: Add the wiki pointer

Read `~/projects/CLAUDE.md`. Check if it already contains the text `RnD-Wiki` (case-sensitive grep).

If it already contains the pointer, say:

**"Your projects config already points to the knowledge base — no changes needed."**

If it does NOT contain the pointer, append the following block to the end of `~/projects/CLAUDE.md`:

```

## Knowledge Base

For domain knowledge (dairy science, UF formulas, equipment specs, production
rules, vendor info), check the RnD-Wiki first:
`~/projects/RnD-Wiki/INDEX.md`

See `~/projects/RnD-Wiki/CLAUDE.md` for the query protocol: read INDEX.md →
find relevant slugs → read full articles → check status before citing.
```

Then say: **"Added the knowledge base pointer to your projects config."**

### Step 4: Confirm

Say:

**"All done! Every project agent under `~/projects/` now knows about the knowledge base. When they need domain knowledge — dairy science, equipment specs, production rules — they'll check the wiki automatically.**

**You only need to run this once. To add knowledge to the wiki, use `/culture add`."**

## Add

> Capture knowledge from the current session into a new wiki article.

### Step 1: Get the topic

If a topic was provided as an argument (everything after `add`), use it.

If no topic was provided, ask:

**"What knowledge do you want to capture? Just describe the topic in a few words — for example, 'UF membrane cleaning procedure' or 'skyr fermentation temperature ranges'."**

### Step 2: Pick the domain

Show the available domains and ask:

**"Which area does this belong to?**

1. **Business** — EDI, logistics, finance tools
2. **Equipment** — plant equipment inventories and specs
3. **Formulation** — recipe science, dairy composition, blending
4. **Processing** — UF, fermentation, HTST, CIP
5. **Production** — mass balance, scheduling, capacity planning
6. **Quality** — specifications, hold criteria, test methods
7. **Software** — development patterns and conventions
8. **Vendors** — vendor-specific technical documentation

**Just tell me the number or name."**

If the domain has subfolders (like `processing/uf`, `processing/fermentation`, `processing/htst`, `processing/cip`), check if the topic fits one and use the subfolder path.

### Step 3: Generate the slug

Convert the topic to a slug:
- Lowercase
- Replace spaces with hyphens
- Remove special characters
- Keep it descriptive but concise (3-6 words)

Show the user: **"I'll call this article `<slug>`. The file will be at `articles/<domain>/<slug>.md`."**

### Step 4: Check for related articles

Before creating anything, scan the existing knowledge base for articles that might already cover this topic.

1. Read `~/projects/RnD-Wiki/INDEX.md`
2. Scan the "By Domain" tables for articles with similar titles, overlapping tags, or semantically related summaries. Compare the new topic against every existing article's title, summary, and tags. Look for:
   - Same or synonymous concepts (e.g., "UF membrane cleaning" vs "membrane CIP procedure")
   - Overlapping tags
   - Summaries that describe the same underlying knowledge

3. **If NO related articles found:** proceed silently to Step 5.

4. **If related articles found**, show them to the user:

   **"Before I create a new article, I found these existing articles that might be related:**

   - **`<slug-1>`** — <summary> *(status: <status>)*
   - **`<slug-2>`** — <summary> *(status: <status>)*

   **Is this genuinely a new topic, or should this knowledge go into one of these existing articles?"**

5. **If the user says it's new:** proceed to Step 5 (branch creation).

6. **If the user says it belongs in an existing article:** still capture the knowledge — ask the same questions you would for a new article (summary, details, sources). Then file it as a GitHub issue:

   ```bash
   gh issue create --repo Icelandic-Provisions/RnD-Wiki \
     --title "knowledge: add to <existing-slug>" \
     --label "knowledge-addition" \
     --body "$(cat << 'EOF'
   ## Knowledge to Add

   **Target article:** `<existing-slug>` (`articles/<domain>/<existing-slug>.md`)

   ### Summary

   <one-line summary of the new knowledge>

   ### Details

   <the captured knowledge content>

   ### Sources

   <source references from the current session>

   ---
   *Filed automatically by `/culture add` — this knowledge was identified as belonging
   to an existing article rather than a new one.*
   EOF
   )"
   ```

   Then tell the user:

   **"Got it — I've filed the knowledge as an issue on the wiki. Someone can merge it into the existing article during the next review. You're all set to get back to work."**

   Then END the Add workflow — do NOT create a branch, template, or PR.

### Step 5: Create the branch and file

Run the following in `~/projects/RnD-Wiki`:

1. Make sure you're on main and up to date:
   ```bash
   cd ~/projects/RnD-Wiki && git checkout main && git pull
   ```

2. Check for slug collisions before creating anything:
   ```bash
   test -f ~/projects/RnD-Wiki/articles/<domain>/<slug>.md
   ```

   If the file already exists, tell the user:

   **"There's already an article called `<slug>` in that domain. Want to pick a different name, or did you mean to update the existing one? (Updating an existing article is a different process — let me know and I'll walk you through it.)"**

   Then STOP and wait for the user to choose a new slug or confirm they want to update. If updating, point them to the RnD-Wiki CONTRIBUTING.md process for updating validated articles. Do NOT create a branch until the slug is confirmed unique.

3. Create a new branch:
   ```bash
   cd ~/projects/RnD-Wiki && git checkout -b "docs/<slug>"
   ```

4. Ensure the domain folder exists and copy the template:
   ```bash
   mkdir -p ~/projects/RnD-Wiki/articles/<domain>
   cp ~/projects/RnD-Wiki/templates/article-template.md ~/projects/RnD-Wiki/articles/<domain>/<slug>.md
   ```

Tell the user: **"Created a new branch and article file."**

### Step 6: Fill the frontmatter

Edit the new article file. Fill in the YAML frontmatter:

- `title`: The topic, in title case
- `slug`: The generated slug
- `summary`: Ask the user — **"In one sentence, what's the key takeaway someone should know about this topic?"**
- `status`: `draft`
- `tags`: Ask the user — **"Any tags for this? These help people find the article later. Here are some common ones: `uf-membranes`, `dairy-science`, `formulation`, `scheduling`, `mass-balance`, `equipment`, `cip`, `fermentation`, `htst`, `scoring`, `constants`, `tetra-pak`. You can use existing tags or make new ones (just use lowercase-with-hyphens)."**
- `domain`: The domain chosen in Step 2
- `created`: Today's date (YYYY-MM-DD)
- `updated`: Today's date (YYYY-MM-DD)
- `author`: `claude-code`
- `reviewed-by`: (leave empty)
- `review-date`: (leave empty)
- `sources`: Fill based on where the knowledge came from in the current session. Use the appropriate source type:
  - `project-file` if it came from reading code
  - `expert-knowledge` if the user shared it from experience
  - `vendor-doc` or `external-literature` if from external sources
- `related`: (leave empty — can be filled during review)

### Step 7: Write the article body

Ask the user:

**"Now let's capture the knowledge. Tell me what you've learned about this topic — I'll write it up in the article format. You can be as detailed or brief as you want. I'll organize it into sections:**

- **What This Is — plain-language explanation**
- **Details — the core knowledge (I'll use tables for any numbers or specs)**
- **Where This Is Used — which projects or decisions this matters for**
- **Open Questions — anything that still needs to be checked or confirmed"**

Listen to the user's response and fill in the article sections. Follow the wiki's writing standards:
- Plain language first — define jargon on first use
- Every claim needs a source (fill the `sources:` field)
- Use tables for constants and specs
- The summary line must be understandable by someone who is not a programmer

### Step 8: Update the index

Run:

```bash
cd ~/projects/RnD-Wiki && make index
```

Tell the user: **"Updated the master index."**

### Step 9: Commit

Stage and commit the new article and the updated index:

```bash
cd ~/projects/RnD-Wiki && git add "articles/<domain>/<slug>.md" INDEX.md && git commit -m "$(cat << 'EOF'
docs: add <slug> article (draft)

New knowledge base article capturing <one-line summary of topic>.
Domain: <domain>. Status: draft.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Step 10: Open a PR

Push the branch and create a PR:

```bash
cd ~/projects/RnD-Wiki && git push -u origin "docs/<slug>"
```

Then create the PR using the repo's PR template format:

```bash
cd ~/projects/RnD-Wiki && gh pr create --title "docs: add <slug>" --body "$(cat << 'EOF'
## Article Review

**Article slug:** `<slug>`
**Domain:** `<domain>`
**Status change:** `draft` → `in-review`

### What This Article Covers

<Brief description of the knowledge captured>

### Review Checklist

- [ ] Summary line is accurate and understandable by a non-expert
- [ ] All facts are supported by cited sources
- [ ] Sources are accessible (file paths exist, references are real)
- [ ] No unsourced claims
- [ ] Tags use the controlled vocabulary where possible
- [ ] Article is in the correct domain folder
- [ ] Related articles are correctly cross-referenced
- [ ] Constants and formulas match the cited source code or literature
EOF
)"
```

Tell the user:

**"All done! Here's what I created:**

- **Article:** `articles/<domain>/<slug>.md`
- **Branch:** `docs/<slug>`
- **PR:** <link to PR>

**The article starts as a draft. A reviewer will check the facts and sources, then mark it as validated. Once validated, every project agent will treat it as confirmed knowledge.**

**You can view the PR on GitHub to see the review checklist."**

## Search

> Quick lookup in the knowledge base.

Say:

**"Search is coming soon! For now, here's how to find knowledge:**

1. **Ask me directly** — I already check the knowledge base when answering questions in any project under `~/projects/`. Just ask your question and I'll look it up.

2. **Browse the index** — The master index at `~/projects/RnD-Wiki/INDEX.md` lists every article with its topic, status, and tags. You can open it in any text editor or on GitHub.

**If you want to add new knowledge, use `/culture add`."**

## Refresh

> Periodic health check of the knowledge base. Finds duplicates, scope issues, misfilings, and gaps.

### Setup — Load required tools

Before any refresh work, load AskUserQuestion via ToolSearch:

```
ToolSearch({ query: "select:AskUserQuestion", max_results: 1 })
```

If it fails to load, stop: **"Failed to load required tools — retry `/culture refresh`."**

### Step 1: Scan the knowledge base

Read `~/projects/RnD-Wiki/INDEX.md` to get the full article list. Then read each article file to get the complete frontmatter and body content.

Announce: **"Found X articles across Y domains. Running health checks..."**

### Step 2: Run checks

For each article (and across articles), run the following checks:

| Check | Severity | What it catches |
|---|---|---|
| **NEAR-DUPLICATE** | HIGH | Two articles covering the same concept under different names — compare titles, summaries, tags, and body content for semantic overlap |
| **CONTRADICTION** | HIGH | Two articles making conflicting claims about the same thing — e.g., different temperature ranges for the same process |
| **SCOPE-CREEP** | MEDIUM | A single article covering 3+ distinct topics (look for unrelated H2 sections) that should be separate articles |
| **MERGE-CANDIDATE** | MEDIUM | Two short articles (<200 words each) on tightly related topics that would be stronger as one article |
| **MISCATEGORIZED** | MEDIUM | Article in the wrong domain folder based on its actual content, tags, and subject matter |
| **ORPHAN** | LOW | Article with no inbound `related:` links from any other article — it exists but nothing points to it |
| **STALE-DRAFT** | LOW | Article with `status: draft` and `created:` date more than 30 days ago — it was started but never reviewed |
| **MISSING-CROSS-REF** | LOW | Article mentions a concept that has its own article in the wiki but doesn't link to it via the `related:` field |

### Step 3: Report

If no findings: say **"Knowledge base looks clean — no issues found."** and end.

If there are findings, present them as a table:

**"Found X issues across Y articles:"**

```
| # | Article | Domain | Check | Severity | Details |
|---|---------|--------|-------|----------|---------|
```

Group findings by severity (HIGH first, then MEDIUM, then LOW).

### Step 4: Preview proposed changes

For each finding, propose a concrete action:

- **Merge** (for NEAR-DUPLICATE, MERGE-CANDIDATE) — **"Combine `<slug-a>` and `<slug-b>` into a single article, keeping the most complete version of each section."**
- **Split** (for SCOPE-CREEP) — **"Break `<slug>` into separate articles: `<new-slug-1>` (covering X) and `<new-slug-2>` (covering Y)."**
- **Move** (for MISCATEGORIZED) — **"Move `<slug>` from `<current-domain>` to `<correct-domain>`."**
- **Edit** (for CONTRADICTION) — **"Resolve the conflict between `<slug-a>` and `<slug-b>` — one claims X, the other claims Y. Check the sources and correct the wrong one."**
- **Add links** (for MISSING-CROSS-REF) — **"Add `<related-slug>` to the `related:` field in `<slug>`."**
- **Flag** (for ORPHAN, STALE-DRAFT) — **"Flag `<slug>` for attention — <reason>."**

Show a summary count: **"Proposed: X merges, Y splits, Z moves, W edits, V link additions, U flags."**

Then ask via AskUserQuestion:

- **Apply all** — proceed with every proposed change (still announce each one as it happens)
- **Go one by one** — walk through each finding individually and ask what to do
- **Cancel** — stop without making any changes

### Step 5: Act on findings

#### If "Apply all"

Process each proposed change in order. For each one, briefly announce what you're doing:
- **"Merging `<slug-a>` + `<slug-b>`..."**
- **"Splitting `<slug>` into `<new-slug-1>` and `<new-slug-2>`..."**
- **"Moving `<slug>` from `<old-domain>` to `<new-domain>`..."**
- **"Fixing contradiction in `<slug>`..."**
- **"Adding cross-reference: `<slug>` → `<related-slug>`..."**
- **"Flagging `<slug>` — <reason>"**

#### If "Go one by one"

For each finding, present the article name, the finding, and ask via AskUserQuestion:

- **Fix** — apply the proposed change
- **Defer** — skip for now, file as a GitHub issue on `Icelandic-Provisions/RnD-Wiki` with the label `kb-maintenance`
- **Skip** — leave as-is, no action

#### After all changes

1. Run `make index` in `~/projects/RnD-Wiki` to update INDEX.md
2. Create a branch and commit all changes:

   ```bash
   cd ~/projects/RnD-Wiki && git checkout -b "docs/refresh-$(date +%Y-%m-%d)"
   cd ~/projects/RnD-Wiki && git add -A && git commit -m "$(cat << 'EOF'
   docs: knowledge base refresh

   Periodic audit of the knowledge base. Changes include:
   <list of actions taken — merges, splits, moves, edits, cross-refs>

   Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
   EOF
   )"
   ```

3. Push and open a PR:

   ```bash
   cd ~/projects/RnD-Wiki && git push -u origin "docs/refresh-$(date +%Y-%m-%d)"
   cd ~/projects/RnD-Wiki && gh pr create --title "docs: knowledge base refresh" --body "$(cat << 'EOF'
   ## Knowledge Base Refresh

   Periodic audit of the knowledge base.

   ### Changes Made

   <bulleted list of all actions taken>

   ### Review Checklist

   - [ ] Merged articles preserve all unique claims from both originals
   - [ ] Split articles are self-contained and correctly cross-referenced
   - [ ] Moved articles have correct `domain:` frontmatter
   - [ ] Contradiction resolutions cite the authoritative source
   - [ ] New cross-references are bidirectional where appropriate
   EOF
   )"
   ```

4. Tell the user:

   **"Refresh complete: X articles audited, Y merged, Z split, W moved, V edited, U cross-refs added, T flagged, S skipped.**

   **I've opened a PR with all the changes for review: <link to PR>"**

## Rules

- NEVER show raw code unless the user asks to see it
- NEVER use programming terms without explaining them
- Keep updates short — one or two sentences per step
- If something fails, explain what went wrong and what to do about it in plain terms
- All git operations in the Add workflow happen in `~/projects/RnD-Wiki`, NOT in the current project directory
- The Setup workflow modifies `~/projects/CLAUDE.md` (the shared projects config), NOT any individual project's CLAUDE.md
- When writing article content, follow the wiki's quality standards: plain language, sourced claims, tables for data
- Use quoted heredoc delimiters (`<< 'EOF'`) for all commit messages and PR bodies
