# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **B001**: `clear_context --memory <segment>` now retracts facts from the target segment instead of the default memory
  - Root cause: `parseHeadFunctorArity` was stripping the module prefix from clauses, causing `retractall(seg:foo(_))` to retract from `user:foo(_)` instead
  - Fix: Extended `HeadFunctorArity` with an optional `module` field; updated `declareDynamic` and cache keying to preserve module qualification in `retractall` calls
  - Impact: `clear_context` with the `--memory` flag (and MCP `memory` parameter) now correctly targets the specified segment; default memory is unaffected

## [0.4.0] - 2026-05-24

### Added
- **F025**: `rename_predicate` MCP tool and CLI subcommand — atomically rename a Prolog functor across facts, rule bodies, and TMS justifications
  - `old_functor` and `new_functor` parameters (required); optional `arity`, `memory`, `dry_run`, `propagate_cross_memory_refs`
  - `dry_run=true` returns the full impact report (`renamed_facts`, `rewritten_rule_bodies`, `affected_rule_ids`, `cross_memory_impact`) without mutating the KB (byte-identical persistence files before/after)
  - TMS preservation: assumption identifiers stay unchanged; justification facts are rewritten to reference the new functor
  - Optional cross-memory propagation rewrites qualified refs (`segment:old/N`) in every writable mounted memory; read-only segments are always reported under `skipped_readonly` without modification
  - Guardrails: rejects ISO Prolog operators (built-in blacklist), self-renames, name collisions, ambiguous arity (when multiple arities exist and `arity` is omitted), and read-only target memories
  - Available via MCP (`rename_predicate`) and CLI (`zpm rename-predicate --old_functor X --new_functor Y --arity N`)
- **F022**: `get_kb_overview` MCP tool and CLI subcommand — single-call JSON snapshot of the entire knowledge base
  - Reports predicates with samples, assumptions, snapshots, persistence health, and mounted memory segments in one response
  - `sample_size` parameter (default `2`, clamped to `[0, 50]`); `0` returns predicates with empty `samples` arrays
  - Budget enforcement: payload capped at 64 KiB by progressively reducing `sample_size`; sets `truncated: true` when applied
  - `mounts` section reports `name`, `scope`, and `mode` of every mounted segment, sorted lexicographically for stable output
  - Available via MCP (`get_kb_overview`) and CLI (`zpm get-kb-overview [--sample-size N]`)
- **F021**: Segmented memories — named, isolated knowledge segments backed by Trealla Prolog modules
  - Four new MCP tools: `create_memory`, `mount_memory`, `unmount_memory`, `list_memories`
  - Optional `memory` parameter on all 20 knowledge/reasoning tools for targeting specific segments
  - CLI subcommand group: `zpm memory create|mount|unmount|list`
  - `--memory` flag on existing CLI tool subcommands
  - Read-only mount mode (`ro`) to prevent accidental mutations
  - Dual-scope storage: project-local (`.zpm/kb/`) and global (`$XDG_DATA_HOME/zpm/kb/`)
  - Per-memory WAL and snapshot persistence with independent rotation
  - Cross-memory queries via Prolog module qualification syntax (`module:predicate(Args)`)
  - Auto-creation and auto-mount of `default` memory on boot for backward compatibility

### Fixed
- Snapshots and mutations targeting the `default` memory now route through the global `PersistenceManager` instead of the segment-local one. Previously, `save_snapshot` wrote `.pl` files to `.zpm/kb/default/` and `remember_fact` journaled to `.zpm/kb/default/journal.wal`, while `initBootstrap` restored from `.zpm/data/` — causing facts and snapshots on `default` to silently disappear across restarts.

### Breaking Changes
- **`mount_memory` is now idempotent.** Calling it on an already-mounted segment returns success instead of raising `MemoryError.AlreadyMounted`. Required because `create_memory` writes the segment to the manifest and bootstrap auto-mounts it on subsequent invocations, which made an explicit `mount_memory` step fail spuriously in CLI lifecycles. Clients that previously relied on `is_error: true` to detect double-mounts will silently see success instead.
- **Knowledge base directory layout changed.** Persistence now uses `.zpm/kb/<name>/` per memory segment instead of the flat `.zpm/kb/` + `.zpm/data/` layout. Existing knowledge bases are not auto-migrated. Run `rm -rf .zpm/` and `zpm init` to reinitialize.

## [0.3.0] - 2026-04-29

## [0.2.1] - 2026-04-22

### Fixed
- Version string reported by `zpm --version` and MCP `serverInfo.version` now matches the release tag. Previous releases (`v0.1.1`, `v0.2.0`) shipped binaries that reported `0.1.0` because the version was hardcoded in `src/version.zig` and never bumped.

### Changed
- `build.zig.zon` is now the single source of truth for the project version. `build.zig` injects it into `src/version.zig` via `b.addOptions()`; functional tests read it from the ZON too. Bumping the version requires editing only `build.zig.zon`.

### Breaking Changes
- **Persistence storage format incompatible with prior versions.** Snapshot format and WAL format have both changed. After upgrading, run `rm -rf .zpm/kb/` to reset the local knowledge base. Pre-upgrade data cannot be migrated automatically.

### Refactor
- Replace hand-rolled text parsing of Prolog query results with JSON pipeline (hand-rolled JSON writer in Prolog + Zig `std.json` decoder). Removes ~500 lines of fragile parsing code.
- Snapshots now use Trealla's canonical `listing/1` writer instead of Zig-side term serialization.
- WAL switched to JSON Lines (NDJSON) with `fsync` per write and persistent file handle. No more 4KB clause / 64KB journal limits.

## [0.2.0] - 2026-04-09

### Added
- **F001**: MCP server implementation with stdio transport
  - JSON-RPC 2.0 protocol compliance
  - Server metadata and capability advertisement
  - Echo tool for testing and validation
  - Comprehensive functional test suite
  - Integration with Makefile build pipeline

## [0.1.0] - 2026-04-08

### Added
- Initial project setup with hexagonal architecture
