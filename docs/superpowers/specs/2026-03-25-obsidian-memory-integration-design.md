---
title: Obsidian Memory Integration
date: 2026-03-25
status: draft
---

# Obsidian Memory Integration

## Overview

Extend Claude's memory system by integrating Obsidian as a **knowledge memory layer** alongside the existing `.claude/memory/` operational memory. Claude writes daily journals, maintains evergreen technical notes, and triages the Obsidian inbox — creating a growing knowledge base that serves as context for future sessions and raw material for blogging.

## Architecture: Two-Layer Memory

### Layer 1: Operational Memory (`.claude/memory/` — unchanged)

- User prefs, feedback corrections, project context, references
- Auto-loaded every session via `MEMORY.md`
- Fast, always available, session-critical
- Types: user, feedback, project, reference

### Layer 2: Knowledge Memory (Obsidian — new)

- Daily journals, evergreen technical notes, inbox triage
- Read via Obsidian CLI when deeper context is useful
- Written via Obsidian CLI on triggers (cron, achievement, manual)

### Interaction Rules

- Claude reads Obsidian when starting work on a topic likely to have evergreen notes
- Claude reads Obsidian when user asks "what do I know about X?"
- Claude does NOT read Obsidian for every session — only when the topic warrants it
- Claude never overwrites or restructures user's manual edits — only appends
- Claude does not write to `Projects/` without being asked

## Obsidian Vault Structure

```
Journal/                          # Daily notes
  2026-03-25.md

Knowledge/                        # Evergreen technical notes
  Engineering/
    adk-tool-calling.md
    vllm-configuration.md
    eval-framework-design.md
  Concepts/
    prompt-engineering-patterns.md
    agent-architectures.md

Inbox/                            # Unsorted incoming notes (triaged nightly)

Projects/                         # Epic tracking (user-managed, Claude reads only)
  Agent Project/
  Company Ideas/
  FedStart/
  OnPrem/

Areas/                            # Ongoing areas of responsibility
  Career/
  Homelab/
  Work/

Resources/                        # Reference material
  Kubernetes/
  Linux/
  PKM/
  Recipes/
  Roadmaps/

_Templates/                       # Note templates
```

## Component 1: Daily Journal

### Template

```markdown
---
date: YYYY-MM-DD
tags: [journal]
---

# YYYY-MM-DD

## Achievements

- Things completed or shipped. Bar: "would future-me or a blog reader care?"

## Learnings

- Technical insights worth remembering.

## In Progress

- Active work items.

## Inbox Triage

- [[note-name]] → Destination/Folder/ (reason for classification)

## Reading / Inspiration

- Articles, papers, links consumed today.

## Reflections

- Freeform synthesis — patterns noticed, connections made.
```

### Generation Triggers

| Trigger                  | How                                                                               | When        |
| ------------------------ | --------------------------------------------------------------------------------- | ----------- |
| **Cron**                 | Claude Code cron runs nightly, synthesizes the day's sessions                     | ~11pm daily |
| **Achievement/Learning** | Claude proactively asks "want me to journal this?" when something notable happens | During work |
| **Manual**               | User runs `/journal` or asks Claude to update today's entry                       | Anytime     |

### Behavior Rules

- Cron creates the entry if it doesn't exist, or appends to existing sections
- Never overwrites manual entries — always appends
- Links to relevant evergreen notes using `[[wikilinks]]`

## Component 2: Evergreen Knowledge Notes

### Template

```markdown
---
title: Topic Name
tags: [category, subcategory]
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: seed | growing | mature
---

# Topic Name

## Core Concept

Brief explanation of what this is and why it matters.

## How It Works

Technical details, gotchas, patterns.

## Lessons Learned

- Bullet points of hard-won insights.

## Links

- [[related-note]] — relationship description
- Journal references: [[YYYY-MM-DD]]
```

### Lifecycle

- **seed** — created when Claude notices a recurring topic across sessions. Minimal content, mostly bullet points.
- **growing** — Claude appends learnings as the user encounters more. Sections fill out.
- **mature** — enough substance to convert into a blog post.

### Creation Triggers

- A topic comes up across 2+ sessions
- User explicitly asks Claude to capture something
- A journal learning is substantial enough to stand alone

### Interaction Rules

- Claude checks if a relevant evergreen note exists before creating a new one
- Claude appends to existing sections or adds new sections — never restructures
- Claude links journal entries to evergreen notes (and vice versa)

## Component 3: Nightly Cron Job

The cron runs three tasks in sequence:

### Task 1: Generate/Update Daily Journal

1. Synthesize the day's Claude sessions (achievements, learnings, in-progress work)
2. Check if today's journal entry exists in `Journal/`
3. If yes, append new content to existing sections
4. If no, create from template
5. Cross-reference any relevant evergreen notes with `[[wikilinks]]`

### Task 2: Triage Inbox

1. List all files in `Inbox/`
2. For each note, read content and determine the correct destination folder
3. Move the note to the appropriate location
4. Log the move in the daily journal under `## Inbox Triage`

### Task 3: Import Apple Notes (future)

1. Export new Apple Notes to `Inbox/` (via AppleScript or Shortcuts CLI — TBD)
2. Delete originals from Apple Notes
3. Notes will be triaged in the next cron run (or same run if sequenced after import)

**Implementation:**

- Claude Code cron (`CronCreate`)
- Allowed tools: `Bash`, `Read`, `Grep`, `mcp__mcp-obsidian__*`

## Component 4: `/journal` Skill

A custom Claude Code skill for manual journal triggers:

1. Check if today's entry exists in `Journal/`
2. If yes, read it and present current state
3. Ask what to add or let Claude synthesize from current session
4. Append new content to appropriate sections
5. Update links to evergreen notes if applicable

## Component 5: Mid-Session Achievement/Learning Capture

During normal work sessions, Claude should:

- Recognize when something notable is achieved or learned
- Proactively ask: "That's a solid insight — want me to add it to today's journal?"
- If yes, append to the journal and check if an evergreen note should be created/updated
- Keep the bar high: only trigger on things worth remembering

## Future Extensions

- **Apple Notes import** — automated pipeline from Apple Notes → Inbox → sorted
- **Blog drafting** — skill that takes a mature evergreen note and drafts a blog post
- **Reading capture** — integration with read-later services (Readwise, Pocket) to populate Reading/Inspiration
- **Weekly/monthly retrospectives** — synthesize journal entries into higher-level summaries
- **Obsidian as context source** — as content accumulates, Claude reads relevant notes before starting sessions on known topics
