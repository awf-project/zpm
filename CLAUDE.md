## Project

zpm is a Prolog inference engine for the Model Context Protocol (MCP), written in Zig. It enables deterministic logical reasoning for AI agents via STDIO JSON-RPC transport. F001–F015 are complete (MCP server, Trealla-based Prolog engine, knowledge/supervision tools, persistence, multi-platform releases, docs site); F016 migrates the backend from scryer-prolog to Trealla.

## Build & Run

- **Zig >= 0.15.2** and a C compiler (gcc or clang) required
- **mcp.zig** library dependency (fetched via `build.zig.zon`); **Trealla Prolog** vendored as a git submodule at `ffi/trealla/` and compiled via Zig's C toolchain
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
  prolog/
    engine.zig    # Prolog engine: init/deinit, query, assert/retract, load
    ffi.zig       # C-ABI extern declarations for Trealla's pl_* API
    capture.zig   # stdout redirection for query output parsing
ffi/
  trealla/        # Trealla Prolog C source (git submodule, compiled by build.zig)
tests/
  functional_mcp_server_test.sh
docs/
  project-brief.md          # Vision, personas, MVP scope
  reference/mcp-tools.md    # Protocol and tool specs
  getting-started/mcp-server.md
  ADR/
```

- Executable-only project (no library module); `src/main.zig` is the single root
- Flat module structure; hexagonal architecture deferred until domain complexity justifies it (see [ADR-0004](docs/ADR/0004-trealla-prolog-via-c-ffi-replacing-scryer.md) for the current Prolog backend rationale)
- Engine module (`src/prolog/engine.zig`) calls Trealla's `pl_*` C API directly via extern declarations in `ffi.zig`; glue logic (stdout capture, output parsing, assertz wrapping) lives in `capture.zig` + `engine.zig`
- MCP protocol version `2025-11-25`, server capabilities: tools only (`listChanged: true`)

## Architecture Rules

- Use `mcp.zig` types directly in handlers — no wrapper abstractions
- Initialize `Server` with STDIO transport for CLI integration
- Place tool handlers in `src/tools/` with signatures matching `mcp.tools.Tool` handler interface
- Tools with parameters export `pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool` — builds `inputSchema` at runtime using `mcp.schema.InputSchemaBuilder`
- Tools with no parameters export `pub const tool` of type `mcp.tools.Tool` with `.inputSchema = .{}`
- Handler signature: `fn(std.mem.Allocator, ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult`

## Test Conventions

- Include inline tests in every tool handler file covering: happy path, null args, missing keys
- Test entry point behavior through functional integration tests (`tests/functional_mcp_server_test.sh`) since `main()` contains blocking I/O
- `make test` runs inline Zig tests; `make functional-test` runs end-to-end protocol validation

## Common Pitfalls

- Maintain Zig version parity between `.github/workflows/ci.yaml` and local environment; version drift silently breaks CI
- Track all file modifications (docs, build config, manifests) in task descriptions; unplanned changes obscure scope
- Tool handlers must handle `null` args gracefully — return `ToolError.InvalidArguments`, not a crash
- Always explicitly free HashMap entries in error paths; Zig's StringHashMap.deinit() only frees backing array, not user keys/values
- Always generate unique temp filenames with thread ID or atomic counter, not just PID; concurrent calls with same PID cause race conditions
- Always implement timeout enforcement with actual timers and cancellation; config validation alone does not enforce limits
- Always test resource unavailability in tool handlers; verify ExecutionFailed is returned when critical dependencies (engine, memory allocations) are null

## Review Standards

- Never mark spec requirements complete without verifying actual implementation; requirement validation must check enforcement, not just partial satisfaction

## ZPM Knowledge Base Usage

The ZPM MCP server is available as a Prolog-backed knowledge base. Use it proactively to store and reason about project knowledge.

### When to store facts
- Project decisions and their rationale: `decision(topic, choice, reason)`
- Task/feature statuses: `task_status(id, status)` via `upsert_fact`
- Architecture relationships: `depends_on(a, b)`, `module_role(name, role)`
- Bug findings and code review results: `finding(component, severity, description)`

### When NOT to store
- Ephemeral data from `git status`, `ls`, or file contents
- Anything already in CLAUDE.md or derivable from code

### Tool selection
- `remember_fact` for permanent ground truth
- `upsert_fact` for mutable state (replaces by functor+arg1)
- `assume_fact` for hypotheticals and temporary exploration
- `clear_context` for bulk cleanup by predicate name

### Commands
- `/zpm-capture <topic>` — Extract and store structured facts (git-state, architecture, tasks, decisions)
- `/zpm-query <question>` — Natural language query translated to Prolog
- `/zpm-cleanup [category|all|stale]` — Remove stale facts and assumptions
- `/zpm-snapshot <save|restore|list>` — Manage persistence snapshots

### Session end
Before ending a non-trivial session, propose to the user to save a ZPM snapshot if meaningful content was added to the KB during the session. Do not save automatically — ask first. Skip for purely diagnostic or exploratory sessions.
