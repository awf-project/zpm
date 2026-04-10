# zpm

A high-performance MCP (Model Context Protocol) server written in Zig, designed to bridge Large Language Models with a Prolog inference engine for deterministic logical reasoning.

## Features

- MCP protocol version `2025-11-25` over STDIO transport
- Tool registration and discovery via `tools/list`
- Echo tool for health-check and smoke testing
- Zero external runtime dependencies (statically linked)
- Sub-10ms response latency

## Quick Start

### Prerequisites

- [Zig](https://ziglang.org/download/) >= 0.15.2

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
| `make build` | Build the server binary |
| `make test` | Run unit tests (inline Zig tests) |
| `make functional-test` | Run end-to-end MCP protocol tests |
| `make fmt` | Format source code |
| `make lint` | Check formatting |
| `make clean` | Remove build artifacts |

## MCP Tools

| Tool | Description | Arguments |
|------|-------------|-----------|
| `echo` | Returns the provided message (health-check) | `message` (string, required) |

## Architecture

```
src/
  main.zig          # MCP server entry point (STDIO transport)
  tools/
    echo.zig        # Echo tool handler
tests/
  functional_mcp_server_test.sh  # End-to-end protocol tests
```

The project uses a flat module structure. Full hexagonal architecture (ports/adapters) is deferred until F002 when domain complexity justifies it.

## Roadmap

- [x] F001: MCP server creation via mcp.zig
- [ ] F002: Prolog inference engine integration
- [ ] F003: Fact, rule, and query tools

## Documentation

See the [`docs/`](docs/) directory:

- [Project Brief](docs/project-brief.md) -- Vision and objectives
- [Getting Started](docs/getting-started/) -- Build, install, and first steps
- [Reference](docs/reference/) -- MCP tools and protocol details
- [ADR](docs/ADR/) -- Architecture Decision Records

## License

See [LICENSE](LICENSE).
