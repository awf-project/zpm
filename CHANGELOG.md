# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
