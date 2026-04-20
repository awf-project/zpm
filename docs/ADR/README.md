---
title: "Architecture Decision Records"
---


| ADR | Decision | Status | Date |
|-----|----------|--------|------|
| [0001](0001-mcp-server-with-stdio-transport.md) | MCP Server with STDIO Transport via mcp.zig | Accepted | 2026-04-09 |
| [0002](0002-scryer-prolog-via-rust-ffi-staticlib.md) | Scryer-Prolog Integration via Rust FFI Static Library | Superseded by [0004](0004-trealla-prolog-via-c-ffi-replacing-scryer.md) | 2026-04-10 |
| [0003](0003-knowledge-base-persistence-via-wal-and-snapshots.md) | Knowledge Base Persistence via Write-Ahead Journal and Snapshots | Accepted | 2026-04-13 |
| [0004](0004-trealla-prolog-via-c-ffi-replacing-scryer.md) | Trealla Prolog via C FFI Replacing Scryer-Prolog | Accepted | 2026-04-19 |

This directory contains the Architecture Decision Records (ADRs) for this project.

## Format

Each ADR follows this structure:

```markdown
# NNNN: Title

**Status**: Proposed | Accepted | Superseded | Deprecated
**Date**: YYYY-MM-DD

## Context       — What is the issue motivating this decision?
## Candidates    — Options considered with trade-offs
## Decision      — What we chose and why
## Consequences  — What becomes easier/harder
## Constitution Compliance — Mapping to project principles
```

## Numbering Convention

ADRs are numbered sequentially: `0001`, `0002`, etc.
Numbers are never reused. If a decision is reversed, the original ADR is marked "Superseded" and a new ADR is created with a reference.

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-mcp-server-with-stdio-transport.md) | MCP Server with STDIO Transport via mcp.zig | Accepted |
| [0002](0002-scryer-prolog-via-rust-ffi-staticlib.md) | Scryer-Prolog Integration via Rust FFI Static Library | Superseded by [0004](0004-trealla-prolog-via-c-ffi-replacing-scryer.md) |
| [0003](0003-knowledge-base-persistence-via-wal-and-snapshots.md) | Knowledge Base Persistence via Write-Ahead Journal and Snapshots | Accepted |
| [0004](0004-trealla-prolog-via-c-ffi-replacing-scryer.md) | Trealla Prolog via C FFI Replacing Scryer-Prolog | Accepted |

<!--
  Update this table as ADRs are added. Format:
  | [0001](0001-short-name.md) | Decision Title | Accepted |
-->

## Creating a New ADR

1. Find the next number: `ls docs/ADR/ | grep -oP '^\d+' | sort -n | tail -1` + 1
2. Copy the template: `cp docs/ADR/.template.md docs/ADR/NNNN-short-name.md`
3. Fill in all sections
4. Update this index
5. Submit for review

## Pre-Merge Checklist

Before merging any new or modified ADR:

- [ ] **Cross-references**: All `[ADR-NNNN]` links resolve to existing files
- [ ] **Supersession**: If changing a prior decision, both ADRs have `Supersedes`/`Superseded by` metadata
- [ ] **Constitution**: Compliance section maps to current constitution version
- [ ] **Candidates**: At least 2 alternatives documented with trade-offs
