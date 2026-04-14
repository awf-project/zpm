# CLI Reference

The zpm command-line interface provides a structured way to interact with the Prolog inference engine via the Model Context Protocol (MCP).

## Usage

```bash
zpm [COMMAND] [FLAGS] [OPTIONS]
```

## Commands

### `serve`

Starts the zpm MCP server, listening on stdin/stdout for JSON-RPC 2.0 requests.

```bash
zpm serve
```

The server implements the full MCP protocol, including:
- Tool discovery (`tools/list`)
- Tool execution (`tools/call`)
- Request/response routing

This is the primary command for integrating zpm with MCP clients like Claude, Cline, or custom applications.

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
| 1 | Error (unknown subcommand, invalid flags, serve crashed) |

## Common Usage Patterns

### Integrate with MCP Client

Configure your MCP client to use:
- **Command:** `zig-out/bin/zpm serve`
- **Transport:** stdio

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
- Only `serve` is a valid subcommand
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
- `--transport` flag — TCP/HTTP server modes (currently STDIO only)
- `--log-level` flag — Debug logging control
- Shell completion scripts

See the [Roadmap](../README.md#roadmap) for more details.
