# 0003: Knowledge Base Persistence via Write-Ahead Journal and Snapshots

## Status

Accepted

## Date

2026-04-13

## Context

Through F009, zpm is a fully stateless server: all facts, rules, and TMS justifications are held in scryer-prolog's in-memory database and lost when the process exits. Each agent session starts from an empty knowledge base, requiring the caller to reassert everything on reconnect.

F010 requires knowledge base persistence across server restarts. The requirements are:

1. Facts and rules asserted via MCP tools must survive process exit.
2. The knowledge base must be restorable to a previous named point in time (snapshots).
3. The server must not refuse to start if the persistence layer is unavailable (degraded mode).
4. The persistence format must be human-inspectable and debuggable without special tooling.
5. No new Rust FFI functions may be introduced (implementation complexity constraint).

Three storage strategies and two coupling models were evaluated.

### Storage strategies

| Option | Description | Tradeoff |
|--------|-------------|----------|
| Write-ahead journal + snapshots | Append-only log of Prolog source mutations; periodic full-state snapshots | Human-readable; replay via existing `loadString()`; unbounded growth mitigated by rotation |
| SQLite database | Binary database for facts/rules | Requires Zig SQLite bindings or subprocess; adds heavy dependency; not human-readable |
| Binary serialization | Custom binary format of engine state | Fast, compact; requires custom parser; not human-inspectable; no FFI path from scryer-prolog |

### Coupling models

| Option | Description |
|--------|-------------|
| **Approach A** — separate concern | Mutation tools explicitly call the journal after successful engine operations |
| **Approach B** — engine wrapper | A `PersistentEngine` struct wraps `engine.zig` and intercepts all mutation calls transparently |

## Decision

Persist the knowledge base using a **write-ahead journal (WAL) paired with point-in-time snapshots**, both stored as human-readable Prolog source text. Persistence is implemented as a **separate concern (Approach A)** — mutation tools call the persistence manager explicitly after successful engine operations.

Specifically:

- **Module layout**: New `src/persistence/` module with three files: `wal.zig` (journal append/replay), `snapshot.zig` (clause enumeration and restoration), `manager.zig` (initialization, degraded mode, state tracking). Persistence types are not mixed into `engine.zig`.
- **Journal format**: Line-oriented Prolog source with a timestamp comment prefix: `%% <unix_epoch> assert fact(value).` or `%% <unix_epoch> retract fact(value).`. Compound TMS operations (e.g., `assume_fact` asserting both the fact and `tms_justification/2`) are wrapped in `%% BEGIN <group_id>` / `%% END <group_id>` markers for atomic replay.
- **Snapshot generation**: Uses Prolog introspection via `current_predicate/1` + `clause/2` queries through the existing `engine.query()` API — the same pattern used by `get_knowledge_schema`. No new Rust FFI functions are added.
- **Snapshot restoration**: Loads snapshot file via `engine.loadString()`, which replaces in-memory state. Journal replay follows snapshot load for point-in-time recovery.
- **Journal rotation**: On `save_snapshot`, the journal is truncated. This bounds unbounded log growth.
- **Atomic writes**: All file writes go through a temp-file + `rename()` pattern to prevent partial writes from corrupting the journal or snapshot.
- **Degraded mode**: If the persistence directory is not writable at startup, the server logs a warning and continues without persistence. Persistence errors during operation are logged but do not crash the server.
- **Mutation hook points**: The 8 existing mutation tools (`remember_fact`, `forget_fact`, `define_rule`, `assume_fact`, `retract_assumption`, `retract_assumptions`, `update_fact`, `upsert_fact`) call the persistence manager after a successful engine operation. Future mutation tools must follow this pattern.
- **New MCP tools**: Four new tools expose persistence: `save_snapshot`, `restore_snapshot`, `list_snapshots`, `get_persistence_status`.
- **Source attribution**: `zpm_source(Fact, Source)` Prolog metadata facts record the MCP tool call origin of each asserted fact, following the `tms_justification/2` pattern. `get_belief_status` is extended to surface source metadata.

## Consequences

### Positive

- **No new dependencies**: Zig's standard library provides file I/O, `std.fs.rename()`, and directory operations. No SQLite binding or external crate required.
- **Human-inspectable artifacts**: Both journals and snapshots are valid Prolog source files, readable and editable with any text editor. Operators can inspect, diff, or manually repair the knowledge base without custom tooling.
- **Replay uses existing infrastructure**: Journal replay calls `engine.loadString()` — the same FFI path used for loading rules. No new replay parser.
- **Minimal coupling**: Approach A keeps `engine.zig` unchanged. Persistence concerns are isolated to `src/persistence/` and the call-sites in mutation tools. The engine remains independently testable.
- **Degraded mode**: A missing or full persistence directory does not break zpm's core reasoning function. Clients that do not need persistence are unaffected.

### Negative

- **Explicit hook discipline**: Every new mutation tool must manually call the persistence manager. This is a convention, not enforced by the type system. Missing a hook silently omits facts from the journal.
- **Snapshot performance at scale**: Generating a snapshot by iterating `current_predicate/1` + `clause/2` over the full knowledge base is O(n) in clause count. Flagged as a medium-probability risk for knowledge bases exceeding ~10K facts.
- **Journal growth between snapshots**: In workloads with high mutation rates and infrequent snapshots, the journal grows unboundedly until the next `save_snapshot` call.
- **Format lock-in**: The line-oriented journal format becomes a compatibility contract once deployed. Changing the format requires a migration step.

### Risks

| Risk | Likelihood | Severity | Mitigation |
|------|------------|----------|------------|
| Mutation hook omitted in future tool | Medium | P1 | Document pattern in CLAUDE.md; add functional test that asserts journal entry after each mutation |
| Snapshot generation too slow at >10K facts | Medium | P2 | Acceptable for current scope; revisit with streaming introspection or FFI-side enumeration if needed |
| Journal replay fails on malformed entry | Low | P1 | Replay skips unparseable lines and logs; group markers ensure partial groups are rolled back |
| Concurrent calls produce colliding temp filenames | Low | P0 | Temp filenames include thread ID + atomic counter per CLAUDE.md pitfall |

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| SQLite database | Requires a Zig SQLite binding or subprocess invocation; adds a heavy dependency for a use case well-served by append-only text files; not human-inspectable |
| Binary serialization of engine state | No scryer-prolog API exposes serializable binary state; would require new Rust FFI; not human-inspectable |
| Approach B (PersistentEngine wrapper) | Adds an abstraction layer over `engine.zig` with no benefit beyond hiding the explicit hook calls; violates the project's "no wrapper abstractions" principle (ADR-0001); makes engine module harder to test in isolation |
| Subprocess invocation of scryer-prolog `--save` | scryer-prolog does not expose a stable `--save` / `--load` flag for external state serialization |
