# zpm

A high-performance MCP (Model Context Protocol) server written in Zig, designed to bridge Large Language Models with a Prolog inference engine for deterministic logical reasoning.

## Features

- MCP protocol version `2025-11-25` over STDIO transport
- Tool registration and discovery via `tools/list`
- Echo tool for health-check and smoke testing
- Prolog inference engine with scryer-prolog C-ABI integration
- Knowledge management tools: assert facts and define rules via MCP
- Zero external runtime dependencies (statically linked, including Prolog library)

## Quick Start

### Prerequisites

- [Zig](https://ziglang.org/download/) >= 0.15.2
- [Rust](https://www.rust-lang.org/tools/install) stable (for scryer-prolog FFI compilation)

### Build and Run

```bash
# Build the server binary
make build

# Run unit tests
make test

# Run functional (end-to-end) tests
make functional-test
```

The built binary is located at `zig-out/bin/zpm`.

### Connect via MCP Client

Add zpm to your MCP client configuration. For example, in Claude Code's `settings.json`:

```json
{
  "mcpServers": {
    "zpm": {
      "command": "/path/to/zig-out/bin/zpm"
    }
  }
}
```

## Commands

| Command | Description |
|---------|-------------|
| `make build` | Build the server binary (includes Rust FFI compilation) |
| `make check` | Run all checks (lint + test + e2e) |
| `make clean` | Remove build artifacts |
| `make ffi-build` | Build the Rust FFI static library only |
| `make fmt` | Format source code |
| `make functional-test` | Run end-to-end MCP protocol tests |
| `make functional-test-engine` | Run end-to-end Prolog engine tests |
| `make lint` | Check formatting |
| `make test` | Run unit tests (inline Zig tests) |

## MCP Tools

| Tool | Description | Arguments |
|------|-------------|-----------|
| `define_rule` | Assert a Prolog rule into the knowledge base | `head` (string, required), `body` (string, required) |
| `echo` | Returns the provided message (health-check) | `message` (string, required) |
| `remember_fact` | Assert a Prolog fact into the knowledge base | `fact` (string, required) |

## Architecture

```
src/
  main.zig          # MCP server entry point (STDIO transport)
  tools/
    context.zig     # Engine singleton for tool handlers
    define_rule.zig # Define rule tool handler
    echo.zig        # Echo tool handler
    remember_fact.zig # Remember fact tool handler
  prolog/
    engine.zig      # Prolog engine with query, assert/retract, loading
    ffi.zig         # C-ABI extern declarations for scryer-prolog
ffi/
  zpm-prolog-ffi/   # Rust staticlib wrapping scryer-prolog
    src/lib.rs
tests/
  functional_mcp_server_test.sh    # End-to-end MCP protocol tests
  functional_prolog_engine_test.sh # End-to-end Prolog engine tests
```

The project uses a flat module structure. Hexagonal architecture is deferred until domain complexity justifies it; see [ADR-0002](docs/ADR/0002-scryer-prolog-via-rust-ffi-staticlib.md) for the rationale.

## Roadmap

- [x] F001: MCP server creation via mcp.zig
- [x] F002: Prolog inference engine integration (scryer-prolog via Rust FFI)
- [x] F003: Knowledge management tools — write (remember_fact, define_rule)
- [ ] F004: Knowledge management tools — read (query, retrieval)

## Documentation

See the [`docs/`](docs/) directory:

- [Project Brief](docs/project-brief.md) -- Vision and objectives
- [Getting Started](docs/getting-started/) -- Build, install, and first steps
- [Reference](docs/reference/) -- MCP tools and protocol details
- [ADR](docs/ADR/) -- Architecture Decision Records

## License

See [LICENSE](LICENSE).
