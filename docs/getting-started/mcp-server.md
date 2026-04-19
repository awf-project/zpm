---
title: "Getting Started with zpm MCP Server"
---


This guide walks you through building and running the zpm Model Context Protocol server.

## Quick Install

Install a pre-built binary with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/awf-project/zpm/main/scripts/install.sh | sh
```

Supported platforms: Linux (x86_64, arm64) and macOS (x86_64, arm64).

After installation, verify it works:

```bash
zpm --version
```

Once installed, skip ahead to [Initialize a Project](#2-initialize-a-project).

## Build from Source

If you prefer to build from source, or your platform is not supported by the pre-built binaries, follow the steps below.

### Prerequisites

- [Zig](https://ziglang.org/download/) 0.15.2 or later
- [Rust](https://www.rust-lang.org/tools/install) stable toolchain (for scryer-prolog FFI compilation)
- A terminal or command prompt

### 1. Build the Server

Clone and build the project:

```bash
git clone https://github.com/awf-project/zpm.git
cd zpm
make build
```

The executable will be created at `zig-out/bin/zpm`.

## 2. Initialize a Project

Create a `.zpm/` project directory:

```bash
zig-out/bin/zpm init
```

This creates the `.zpm/` directory with `kb/` (for Prolog source files) and `data/` (for runtime persistence). You can place `.pl` files in `.zpm/kb/` to have them loaded automatically on server startup.

## 3. Run the Server

Start the MCP server:

```bash
zig-out/bin/zpm serve
```

The server discovers the nearest `.zpm/` directory, loads any `.pl` files from `.zpm/kb/`, and begins listening on stdin/stdout for JSON-RPC 2.0 requests.

Running `zpm` without arguments displays help:

```bash
zig-out/bin/zpm
```

## 4. Test the Server

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
}' | zig-out/bin/zpm serve
```

Expected response includes server name, version, and capabilities.

### List Available Tools

```bash
echo '{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/list",
  "params": {}
}' | zig-out/bin/zpm serve
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
}' | zig-out/bin/zpm serve
```

The server echoes back your message.

## 5. Integration with Claude or Other MCP Clients

To use zpm with Claude or other MCP-compatible clients, configure your client to:

1. **Transport**: stdio
2. **Command**: `zpm serve` (or `zig-out/bin/zpm serve` if built from source)
3. **Working Directory**: zpm project root

The server handles the MCP protocol handshake and tool discovery automatically.

## Troubleshooting

**Server doesn't respond:** Make sure stdin/stdout are properly connected. The server closes cleanly when stdin reaches EOF.

**Invalid JSON:** Check your JSON format. The MCP protocol is strict about JSON-RPC 2.0 compliance.

**"No project directory found" error:** Run `zpm init` in your project root to create a `.zpm/` directory. The server requires this directory to start. If you're in a subdirectory, the server walks up the tree automatically — make sure `.zpm/` exists somewhere in the ancestry.

**Unknown command error:** If you see "unknown command", check that you're using a valid subcommand (e.g., `zpm init`, `zpm serve`). Run `zpm --help` for a list of available commands.

**Rust build errors:** Ensure `cargo` is in your PATH. The first build compiles scryer-prolog from source, which takes ~60-90 seconds. Subsequent builds use the Cargo cache.

## Next Steps

- Read the [MCP Tools Reference](../reference/mcp-tools.md) for detailed tool documentation
- Check [Project Brief](../project-brief.md) for vision and roadmap
- Review [Makefile](../../Makefile) for all available build targets
