# Getting Started with zpm MCP Server

This guide walks you through building and running the zpm Model Context Protocol server.

## Prerequisites

- Zig 0.15.2 or later
- A terminal or command prompt

## 1. Build the Server

Clone and build the project:

```bash
git clone https://github.com/YOUR_ORG/zpm.git
cd zpm
make build
```

The executable will be created at `zig-out/bin/zpm`.

## 2. Run the Server

Start the server:

```bash
zig build run
```

The server is now listening on stdin/stdout for JSON-RPC 2.0 requests.

## 3. Test the Server

In another terminal, you can send MCP protocol requests. The server implements three core methods:

### Initialize (Handshake)

```bash
echo '{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-11-25",
    "capabilities": {},
    "clientInfo": {"name": "test-client"}
  }
}' | zig-out/bin/zpm
```

Expected response includes server name, version, and capabilities.

### List Available Tools

```bash
echo '{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/list",
  "params": {}
}' | zig-out/bin/zpm
```

This shows the echo tool with its input schema.

### Call a Tool

Invoke the echo tool with a message:

```bash
echo '{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "echo",
    "arguments": {"message": "Hello, zpm!"}
  }
}' | zig-out/bin/zpm
```

The server echoes back your message.

## 4. Integration with Claude or Other MCP Clients

To use zpm with Claude or other MCP-compatible clients, configure your client to:

1. **Transport**: stdio
2. **Command**: `zig-out/bin/zpm`
3. **Working Directory**: zpm project root

The server handles the MCP protocol handshake and tool discovery automatically.

## Troubleshooting

**Server doesn't respond:** Make sure stdin/stdout are properly connected. The server closes cleanly when stdin reaches EOF.

**Invalid JSON:** Check your JSON format. The MCP protocol is strict about JSON-RPC 2.0 compliance.

**Missing tool error:** Only the `echo` tool is available in F001. More tools will be added in future releases.

## Next Steps

- Read the [MCP Tools Reference](../reference/mcp-tools.md) for detailed tool documentation
- Check [Project Brief](../project-brief.md) for vision and roadmap
- Review [Makefile](../../Makefile) for all available build targets
