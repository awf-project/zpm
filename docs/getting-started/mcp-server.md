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
zpm version
```

Once installed, skip ahead to [Initialize a Project](#2-initialize-a-project).

## Build from Source

If you prefer to build from source, or your platform is not supported by the pre-built binaries, follow the steps below.

### Prerequisites

- [Zig](https://ziglang.org/download/) 0.17.1 or later
- C compiler (gcc or clang)
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

## 3. Configure in Your MCP Client

Use an MCP client that supports revision `2026-07-28` and `server/discover` over stdio. Add it to your agentic tool's configuration — the tool will spawn `zpm serve` on demand and discover the tools automatically.

The examples below assume `zpm` is on your `PATH` (via [Quick Install](#quick-install)). If you built from source, replace `zpm` with the absolute path to `zig-out/bin/zpm`.

> **Working directory.** `zpm serve` walks up from its CWD to find the nearest `.zpm/`. If your client doesn't run the command from the project root, add `"cwd": "/absolute/path/to/project"` (JSON) or `cwd = "..."` (TOML) to pin it.

### Claude Code

Add the server from the project root:

```bash
claude mcp add zpm -- zpm serve
```

Or commit a project-scoped `.mcp.json` at the repo root:

```json
{
  "mcpServers": {
    "zpm": {
      "command": "zpm",
      "args": ["serve"]
    }
  }
}
```

### Claude Desktop

Edit `claude_desktop_config.json`:

- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Linux: `~/.config/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`

```json
{
  "mcpServers": {
    "zpm": {
      "command": "zpm",
      "args": ["serve"],
      "cwd": "/absolute/path/to/your/project"
    }
  }
}
```

Restart Claude Desktop to load the server.

### Cursor

Create `.cursor/mcp.json` at your project root (or `~/.cursor/mcp.json` for global):

```json
{
  "mcpServers": {
    "zpm": {
      "command": "zpm",
      "args": ["serve"]
    }
  }
}
```

### Zed

Edit `~/.config/zed/settings.json`:

```json
{
  "context_servers": {
    "zpm": {
      "command": {
        "path": "zpm",
        "args": ["serve"]
      }
    }
  }
}
```

### Gemini CLI

Edit `.gemini/settings.json` at your project root (or `~/.gemini/settings.json` for global):

```json
{
  "mcpServers": {
    "zpm": {
      "command": "zpm",
      "args": ["serve"]
    }
  }
}
```

### Codex CLI

With Codex CLI 0.171.0, enable MCP discovery and start a new session:

```bash
codex features enable mcp_2026_07_28
```

For a manual STDIO registration, select the protocol revision for ZPM in `~/.codex/config.toml`:

```toml
[mcp_servers.zpm]
command = "zpm"
args = ["serve"]
env = { CODEX_MCP_PROTOCOL_VERSION = "2026-07-28" }
```

For a plugin installation, the same environment setting belongs in the plugin's ZPM server entry.

## 4. Manual Testing (Optional)

If you want to exercise the protocol directly without a client — for debugging or CI — you can pipe JSON-RPC 2.0 requests to `zpm serve` over stdio.

### Discover the Server and Call a Tool

Run this from an initialized ZPM project. Each line is an independent JSON-RPC request. The client identifies its protocol revision and capabilities on every request.

```bash
zpm serve <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"example","version":"1.0"},"io.modelcontextprotocol/clientCapabilities":{}}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"example","version":"1.0"},"io.modelcontextprotocol/clientCapabilities":{}}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"example","version":"1.0"},"io.modelcontextprotocol/clientCapabilities":{}},"name":"echo","arguments":{"message":"Hello, zpm!"}}}
EOF
```

The first response lists `supportedVersions`, `capabilities`, and the server name and version in `result._meta["io.modelcontextprotocol/serverInfo"]`. The second lists the tools. The server echoes back your message.

## Troubleshooting

**Client can't find `zpm`:** GUI apps like Claude Desktop don't always inherit your shell `PATH`. If the client logs show `ENOENT` or "command not found", use an absolute path in the config (e.g., `"command": "/usr/local/bin/zpm"` or `"/home/you/.local/bin/zpm"`).
**Tools don't appear in the client:** Check the client's MCP logs — most tools expose a log panel or file. Verify `zpm version` works in the same environment the client runs from, then restart the client after editing its config.
**"No project directory found" error:** The client likely spawns `zpm serve` from a working directory that has no `.zpm/` above it. Run `zpm init` in your project root, then either launch the client from that directory or add `"cwd": "/absolute/path/to/project"` to the server entry.
**Server doesn't respond (manual testing):** Make sure stdin/stdout are properly connected. The server closes cleanly when stdin reaches EOF.
**Invalid JSON (manual testing):** The MCP protocol is strict about JSON-RPC 2.0 compliance — check your request format.
**Unknown command error:** If you see "unknown command", check that you're using a valid subcommand (e.g., `zpm init`, `zpm serve`). Run `zpm --help` for a list of available commands.

## Next Steps

- Read the [MCP Tools Reference](../reference/mcp-tools.md) for detailed tool documentation
- Check [Project Brief](../project-brief.md) for vision and roadmap
- Review [Makefile](../../Makefile) for all available build targets
