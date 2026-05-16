# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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

### Breaking Changes
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
