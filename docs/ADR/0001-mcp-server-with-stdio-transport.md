# 0001: MCP Server with STDIO Transport via mcp.zig

## Status

Accepted

## Date

2026-04-09

## Context

zpm is a Prolog inference engine designed to provide deterministic logical reasoning to AI agents. The project needs a communication protocol that:

1. Allows AI agents (Claude, GPT, etc.) to discover and invoke tools at runtime
2. Supports structured input/output with JSON-RPC semantics
3. Can run as a local subprocess without network dependencies
4. Has a growing ecosystem of compatible clients (IDEs, CLI tools, agent frameworks)

The **Model Context Protocol (MCP)** is an open standard (protocol version `2025-11-25`) that satisfies all four requirements. The alternative considered was a custom JSON-RPC server, which would require implementing discovery, capability negotiation, and transport handling from scratch.

For the Zig implementation, **mcp.zig** (`muhammad-fiaz/mcp.zig`) is available for Zig. It provides:

- `mcp.Server` with built-in capability negotiation (`initialize` / `initialized` handshake)
- `mcp.tools.Tool` struct for declarative tool registration with annotations
- `mcp.tools.ToolError` / `mcp.tools.ToolResult` types for handler responses
- STDIO transport (`.stdio`) for subprocess integration

## Decision

We adopt the Model Context Protocol as zpm's sole communication interface, implemented via the `mcp.zig` library with STDIO transport.

Specifically:

- **Transport**: STDIO only — the server reads JSON-RPC from stdin and writes to stdout. No HTTP/SSE transport.
- **Library**: `mcp.zig` pinned at commit `fdcf351` via `build.zig.zon`. Types are used directly in handlers — no wrapper abstractions.
- **Tool pattern**: Each tool is a separate file in `src/tools/` exporting a `pub const tool` of type `mcp.tools.Tool` with a handler matching `fn(std.mem.Allocator, ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult`.
- **Server capabilities**: Tools only (`listChanged: true`). No resources, prompts, or sampling.
- **Entry point**: `src/main.zig` initializes the server, registers all tools, and calls `server.run(.stdio)`.

## Consequences

### Positive

- **Zero network config**: STDIO transport means zpm works as a subprocess — no ports, TLS, or firewall rules. Ideal for local agent integration.
- **Ecosystem compatibility**: Any MCP-compliant client (Claude Desktop, VS Code extensions, agent frameworks) can use zpm out of the box.
- **Declarative tool registration**: Adding a new tool is one file + one `server.addTool()` call. Low ceremony.
- **Type safety**: `mcp.zig` types enforce correct handler signatures at compile time.

### Negative

- **Single library dependency**: `mcp.zig` is young (v0.0.3) with a single maintainer. If abandoned, we must fork or rewrite the transport layer.
- **STDIO limitation**: Cannot serve multiple concurrent clients. Each agent session needs its own zpm process. This is acceptable for the local-subprocess model but rules out shared server deployments.
- **No streaming**: STDIO transport does not support server-sent events or streaming responses. If Prolog queries become long-running (F002+), we'll need to return complete results, not incremental ones.

### Risks

- **Zig version coupling**: `mcp.zig` tracks Zig nightly/stable closely. A Zig version bump may require waiting for `mcp.zig` to catch up. Mitigated by pinning both.
- **Protocol evolution**: MCP is pre-1.0. Breaking changes to the protocol may require `mcp.zig` updates and handler signature changes across all tools.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Custom JSON-RPC over STDIO | Reimplements capability negotiation, tool discovery, error codes — all already handled by MCP spec and `mcp.zig` |
| HTTP/SSE transport | Adds network complexity unnecessary for local subprocess use case; can be added later if needed |
