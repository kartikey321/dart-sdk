# dart-zig Timeline — Contributor Guide

This folder tracks all work done on the dart-zig project as a structured
developer journal. Every session that touches dart-zig code, research, or
decisions **must** produce a timeline entry.

---

## Folder Structure

```
timeline/
├── README.md              ← this file — read before contributing
├── CHANGELOG.md           ← master changelog, append-only, all phases
└── phases/
    ├── phase-0.md         ← per-phase detail log (created when phase starts)
    ├── phase-1.md
    └── ...
```

---

## When to Write an Entry

Write a timeline entry whenever you:
- Complete a task (or a meaningful chunk of one)
- Hit a blocker or make a decision that changes the approach
- Discover something new about the codebase that affects the plan
- Run a test or benchmark — even if it fails
- Change the impl plan (`impl-plan.md`)

**Do not batch multiple sessions into one entry.** One session = one entry.

---

## Entry Format — CHANGELOG.md

Each entry in `CHANGELOG.md` follows this exact template:

```
---
## [PHASE-N] Title of What Was Done
**Date:** YYYY-MM-DD
**Phase:** N — Phase Name
**Status:** IN-PROGRESS | COMPLETED | BLOCKED | RESEARCH
**Author:** name or handle

### What Was Done
- Bullet list of concrete actions taken (files changed, code written, commands run)

### What Was Verified
- Things that were tested and confirmed working
- Include commands and their output (abbreviated)

### What Broke / Blockers
- Errors encountered, with exact messages if available
- Blockers that prevent moving forward

### Decisions Made
- Any choice between alternatives, with rationale
- Changes to the impl plan

### Files Changed
- `path/to/file.cc` — what changed and why
- (leave empty if research only)

### Next Steps
- Concrete next actions (not vague goals)
- Can be claimed by next contributor
---
```

**Rules:**
1. Entries are **prepended** (newest at top of file, after the header block)
2. Never edit a past entry — add a new one to correct or update
3. The `Status` field refers to the **phase** state after this entry, not just
   this session's work
4. `Files Changed` must list real paths relative to the dart-sdk repo root

---

## Entry Format — phases/phase-N.md

Each phase gets its own detailed log file. Create it when the phase starts.
Use this structure:

```markdown
# Phase N — Phase Name

**Started:** YYYY-MM-DD
**Completed:** YYYY-MM-DD (fill when done)
**Status:** NOT-STARTED | IN-PROGRESS | COMPLETED | BLOCKED

## Goal
One sentence from impl-plan.md.

## Success Criteria
Exact, testable conditions that define "done" for this phase.
- [ ] criterion 1
- [ ] criterion 2

## Session Log
(append newest session at bottom)

### Session YYYY-MM-DD
**Duration:** Xh
**What happened:** ...
**Commands run:**
```sh
...
```
**Result:** ...

## Blockers
Active blockers (move to resolved when fixed).

| # | Blocker | Discovered | Resolved |
|---|---------|-----------|---------|
| 1 | Description | date | — |

## Resolved Blockers
| # | Blocker | Resolution | Date |
|---|---------|-----------|------|

## Artifacts
Files/outputs produced by this phase.
```

---

## Phase Status Definitions

| Status | Meaning |
|---|---|
| `NOT-STARTED` | No work begun |
| `IN-PROGRESS` | Actively being worked on |
| `BLOCKED` | Cannot proceed — waiting on a dependency or decision |
| `COMPLETED` | All success criteria met and verified |
| `ABANDONED` | Approach changed, see note |

---

## Quick Reference: Phase Map

| Phase | Name | Track | Status |
|---|---|---|---|
| 0 | Build From Source | Both | NOT-STARTED |
| 1 | Fork runtime/engine | Track 1 | NOT-STARTED |
| 2 | create_group callback | Track 1 | NOT-STARTED |
| 3 | Zig Host Binary | Track 2 | NOT-STARTED |
| 4 | io_uring Event Loop + Timers | Track 2 | NOT-STARTED |
| 5 | Full Host Responsibilities | Track 2 | NOT-STARTED |
| 6 | Zig I/O Natives | Track 2 | NOT-STARTED |
| 7 | Multi-Core | Both | NOT-STARTED |
| 8 | True Zero-Copy | Track 2 | NOT-STARTED |
| 9 | Benchmarks | Both | NOT-STARTED |

Update this table in-place when phase status changes.

---

## Do Not

- Do not skip entries because "it was a small change" — small changes compound
- Do not write vague next steps like "continue phase 1" — be specific
- Do not edit CHANGELOG.md entries retroactively — add a correction entry
- Do not mark a phase COMPLETED without all success criteria checked off
