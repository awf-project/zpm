---
title: "CLI Reference"
---


The zpm command-line interface provides a structured way to interact with the Prolog inference engine via the Model Context Protocol (MCP).

## Usage

```bash
zpm [COMMAND] [FLAGS] [OPTIONS]
```

## Commands

### `init`

Initializes a new zpm project directory in the current working directory.

```bash
zpm init
```

Creates the `.zpm/` directory structure:
- `.zpm/` — Project root for configuration and persistence
- `.zpm/kb/` — Knowledge base directory for Prolog files and snapshots
- `.zpm/data/` — Ephemeral data directory for write-ahead journal and locks
- `.zpm/.gitignore` — Git ignore rules (excludes `data/`)

This command is idempotent. Running it on an already-initialized project prints a success message and exits without modifying existing content.

**Example:**
```bash
# Initialize a new project
zpm init

# Verify the directory structure
ls -la .zpm/
# Output:
# drwxr-xr-x  kb/
# drwxr-xr-x  data/
# -rw-r--r--  .gitignore
```

**Exit Codes:**
- `0` — Success (directory created or already initialized)
- `1` — Error (permission denied, filesystem error)

### `serve`

Starts the zpm MCP server, listening on stdin/stdout for JSON-RPC 2.0 requests.

```bash
zpm serve
```

On startup, the server:
1. Discovers the nearest `.zpm/` directory by walking up from the current working directory
2. Loads all `.pl` files from `.zpm/kb/` into the Prolog engine
3. Initializes persistence (WAL journal in `.zpm/data/`, snapshots in `.zpm/kb/`)
4. Begins accepting MCP messages on STDIO

If no `.zpm/` directory is found in the directory ancestry, the server exits with an error suggesting `zpm init`. If `.zpm/` exists but is not writable, the server enters degraded mode (in-memory only).

The server implements the full MCP protocol, including:
- Tool discovery (`tools/list`)
- Tool execution (`tools/call`)
- Request/response routing

This is the primary command for integrating zpm with MCP-compatible clients (Claude Code, Claude Desktop, Cursor, Zed, Gemini CLI, Codex CLI, or custom applications). See [Configure in Your MCP Client](../getting-started/mcp-server.md#3-configure-in-your-mcp-client) for per-client configuration.

**Example:**
```bash
# Start the server
zig-out/bin/zpm serve

# In another terminal, send MCP requests
echo '{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {...}}' | socat - EXEC:'zig-out/bin/zpm serve'
```

## Flags

### `-h, --help`

Displays help text listing available commands, subcommands, and options.

```bash
zpm --help
zpm -h
```

Running `zpm` without arguments also displays the help text.

**Exit Code:** 0

### `-v, --version`

Displays the current version of zpm.

```bash
zpm --version
zpm -v
```

**Example Output:**
```
zpm 0.1.0
```

**Exit Code:** 0

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success (help, version, serve running normally) |
| 1 | Error (unknown subcommand, invalid flags, serve crashed, no `.zpm/` found) |

## Common Usage Patterns

### Integrate with MCP Client

Configure your MCP client to spawn zpm:
- **Command:** `zpm serve` (or absolute path to `zig-out/bin/zpm` if built from source)
- **Transport:** stdio
- **Working directory:** project root containing `.zpm/`

Per-client configuration examples (Claude Code, Claude Desktop, Cursor, Zed, Gemini CLI, Codex CLI) live in the [Getting Started guide](../getting-started/mcp-server.md#3-configure-in-your-mcp-client).

### Debug Server Startup

Test that the server starts and responds:

```bash
# Send initialize and immediate EOF
echo '{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "test"}}}' | zig-out/bin/zpm serve
```

### Check Installation

Verify zpm is installed and working:

```bash
zpm --version         # Should print version
zpm                   # Should display help
zpm serve &           # Should start without blocking terminal
```

## Architecture Notes

The CLI layer uses the `zig-cli` library for argument parsing and command routing. The architecture separates:

1. **Argument Parsing** — CLI flag and subcommand validation
2. **Command Dispatch** — Route to appropriate handler (serve, help, version)
3. **MCP Server** — Blocking STDIO transport in `serve` handler

This design ensures:
- Fast `--help` and `--version` responses (no MCP initialization)
- Clear error messages for invalid arguments
- Seamless integration with shell scripts and process supervisors

## Troubleshooting

**Server doesn't respond to commands**
- Ensure the server is running: `zpm serve &`
- Verify stdin/stdout are connected properly
- Check that you're sending valid JSON-RPC 2.0 requests

**"Unknown subcommand" error**
- Valid subcommands are: `init`, `serve`
- Use `zpm --help` to see available options
- Note: `zpm query` and `zpm snapshot` are not implemented (see roadmap)

**Unexpected hang**
- If `zpm serve` appears to hang, it's likely waiting for MCP requests on stdin
- This is expected behavior for an MCP server
- Send a valid request or press Ctrl+C to terminate

## Future Extensions

The following CLI features are deferred and not currently implemented:

- `zpm query` — Direct Prolog queries without MCP protocol
- `zpm snapshot` — Offline snapshot management
- `.zpm/config.toml` — Project-level configuration file
- `--transport` flag — TCP/HTTP server modes (currently STDIO only)
- `--log-level` flag — Debug logging control
- Shell completion scripts

See the [Roadmap](../README.md#roadmap) for more details.
