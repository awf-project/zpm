## Project

zpm is a Prolog inference engine for the Model Context Protocol (MCP), written in Zig. It enables deterministic logical reasoning for AI agents via STDIO JSON-RPC transport. Currently on F001 (MCP server with echo tool); F002 (Prolog engine) and F003 (fact/rule/query tools) are next.

## Build & Run

- **Zig >= 0.15.2** required; single dependency: `mcp.zig` (fetched via `build.zig.zon`)
- Binary output: `zig-out/bin/zpm`

| Command | Purpose |
|---------|---------|
| `make build` | Build executable |
| `make test` | Run inline unit tests |
| `make functional-test` | End-to-end MCP protocol tests (bash) |
| `make fmt` | Format source |
| `make lint` | Check formatting |
| `make clean` | Remove `zig-out/` and `.zig-cache/` |

## Architecture

```
src/
  main.zig        # Server entry point: STDIO transport, tool registration
  tools/
    echo.zig      # Tool handler + inline tests
tests/
  functional_mcp_server_test.sh
docs/
  project-brief.md          # Vision, personas, MVP scope
  reference/mcp-tools.md    # Protocol and tool specs
  getting-started/mcp-server.md
  ADR/
```

- Executable-only project (no library module); `src/main.zig` is the single root
- Flat module structure; hexagonal architecture deferred until F002 domain complexity justifies it
- MCP protocol version `2025-11-25`, server capabilities: tools only (`listChanged: true`)

## Architecture Rules

- Use `mcp.zig` types directly in handlers — no wrapper abstractions
- Initialize `Server` with STDIO transport for CLI integration
- Place tool handlers in `src/tools/` with signatures matching `mcp.tools.Tool` handler interface
- Each tool file exports a `pub const tool` of type `mcp.tools.Tool`
- Handler signature: `fn(std.mem.Allocator, ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult`

## Test Conventions

- Include inline tests in every tool handler file covering: happy path, null args, missing keys
- Test entry point behavior through functional integration tests (`tests/functional_mcp_server_test.sh`) since `main()` contains blocking I/O
- `make test` runs inline Zig tests; `make functional-test` runs end-to-end protocol validation

## Common Pitfalls

- Maintain Zig version parity between `.github/workflows/ci.yaml` and local environment; version drift silently breaks CI
- Track all file modifications (docs, build config, manifests) in task descriptions; unplanned changes obscure scope
- Tool handlers must handle `null` args gracefully — return `ToolError.InvalidArguments`, not a crash
