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

### `upgrade`

Downloads the latest release binary from GitHub, verifies its SHA256 checksum, and atomically replaces the currently running executable.

```bash
zpm upgrade [--channel stable|dev] [--dry-run]
```

On invocation, the command:

1. Resolves the target release from the GitHub releases API for `awf-project/zpm`:
   - `stable` (default): the latest release with `prerelease: false`
   - `dev`: the most recently published release, regardless of the `prerelease` flag
2. Short-circuits with an "already up to date" message if the resolved tag matches the running binary's embedded version
3. Detects the host OS/architecture and selects the matching release asset:
   - Linux x86_64 → `zpm-linux-x86_64`
   - Linux arm64 → `zpm-linux-arm64`
   - macOS (x86_64 or arm64) → `zpm-darwin-universal` (single fat binary)
4. Downloads the asset and its `SHA256SUMS` file to a temporary location with explicit HTTP timeouts
5. Computes the SHA256 of the downloaded asset and compares it against the published entry (matched by full basename)
6. Writes the verified bytes to `<install-path>.new`, preserves the original file mode, and renames the temp file over the running binary

If any step fails (network error, checksum mismatch, permission denied, unsupported platform, unknown channel), the command exits non-zero and leaves the originally installed binary byte-identical.

**Flags:**

| Flag | Description |
|------|-------------|
| `--channel stable\|dev` | Release channel to pull from (default: `stable`). Unknown values are rejected with an error listing the supported channels. |
| `--dry-run` | Report the target version, asset URL, expected checksum, and install path without modifying anything. |

**Example:**

```bash
# Upgrade to the latest stable release
zpm upgrade

# Preview the upgrade plan without touching the binary
zpm upgrade --dry-run

# Pull the latest prerelease (dev channel)
zpm upgrade --channel dev
```

**Exit Codes:**

- `0` — Success (binary replaced, or already up to date)
- `1` — Error (network failure, checksum mismatch, permission denied, unsupported platform, unknown channel)

**Supported Platforms:** Linux (x86_64, arm64) and macOS (x86_64, arm64). On other platforms, the command exits with an error listing the supported targets.

**Read-Only Filesystems:** If the running binary lives on a path without write permission (e.g., `/usr/local/bin` without sudo), the command surfaces the permission error and suggests re-running with elevated privileges.

### Tool Subcommands

Every MCP tool is available as a CLI subcommand using kebab-case (e.g. `remember_fact` → `remember-fact`). Tool invocations share the same bootstrap as `zpm serve` — they discover the nearest `.zpm/`, load the knowledge base, run the handler, and exit.

```bash
zpm <tool-name> [positional] [--flag value ...]
```

The first required field of a tool's input schema is passed as a positional argument. Remaining required fields and all optional fields are passed as `--kebab-case` flags. The full tool roster lives in [MCP Tools Reference](mcp-tools.md); each entry documents its fields.

**Examples:**

```bash
# Insert a fact (US1)
zpm remember-fact "decision(backend, trealla, performance)"

# Upsert: replace by functor + first argument
zpm upsert-fact "task_status(f017, done)"

# Two-arg tool: head positional, body flag
zpm define-rule "ancestor(X, Z)" --body "parent(X, Y), ancestor(Y, Z)"

# Query and pipe JSON output to jq (US2)
zpm query-logic "task_status(X, done)" | jq '.[].X'

# Snapshot management (US3)
zpm save-snapshot "before-upgrade"
zpm list-snapshots
zpm restore-snapshot "before-upgrade"

# Truth maintenance
zpm assume-fact "requires_reboot(host)" --assumption "deploy-plan-v2"
zpm list-assumptions
```

**Discovering Commands:**

```bash
zpm --help                  # Lists init, serve, and every tool subcommand
zpm query-logic --help      # Shows the tool's fields, positional, and flags
```

Help is generated from each tool's input schema at runtime; adding a new MCP tool automatically produces a matching CLI entry with no manual documentation regeneration (NFR-004).

**Concurrency Warning:** Running CLI tool commands against a `.zpm/` that is actively being served by `zpm serve` is **undefined behaviour** for writes; the persistence layer does not yet coordinate locks between processes. Stop the server before issuing write commands, or restrict CLI use to read-only queries.

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
zpm 0.2.1
```

**Exit Code:** 0

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success (help, version, serve running normally, tool result with `is_error=false`) |
| 1 | Error (unknown subcommand, invalid flags, serve crashed, no `.zpm/` found, tool result with `is_error=true`, missing required field) |

Tool subcommands write results to **stdout** and error or diagnostic messages (including the tool name and the offending field) to **stderr**, per FR-007.

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

The CLI layer (F017) is split across several modules for clear separation of concerns:

1. **Registry** (`src/cli/registry.zig`) — All 22 MCP tools registered in a constant array
2. **Argument Mapper** (`src/cli/arg_mapper.zig`) — Parse argv → `--kebab-case` flags and positional args
3. **Bootstrap** (`src/cli/bootstrap.zig`) — Shared initialization: discover `.zpm/`, load knowledge base, start Prolog engine
4. **Dispatcher** (`src/cli/dispatcher.zig`) — Route tool name → handler invocation, handle panic recovery
5. **Output** (`src/cli/output.zig`) — Format tool results for stdout and write diagnostics to stderr per FR-007
6. **Subcommand Handlers** (`src/cli/{init,serve}.zig`) — Entry points for `init` and `serve` subcommands

This architecture ensures:
- Automatic CLI generation for all MCP tools (NFR-004: adding a tool generates matching CLI entry with no manual work)
- Consistent help generation from tool schemas at runtime
- Deterministic argument ordering (positional first, then flags) across all tools
- Fast `--help` and `--version` responses (no knowledge base load)
- Error recovery: panics in tool handlers are caught and reported with the tool name and problematic field (FR-007)

## Troubleshooting

**Server doesn't respond to commands**
- Ensure the server is running: `zpm serve &`
- Verify stdin/stdout are connected properly
- Check that you're sending valid JSON-RPC 2.0 requests

**"Unknown subcommand" error**
- Valid subcommands are `init`, `serve`, and every MCP tool in kebab-case (e.g. `remember-fact`, `query-logic`, `save-snapshot`)
- Run `zpm --help` to list every available subcommand
- The unknown-command list is derived from the tool registry, so any tool accessible via MCP is also accessible on the CLI

**Unexpected hang**
- If `zpm serve` appears to hang, it's likely waiting for MCP requests on stdin
- This is expected behavior for an MCP server
- Send a valid request or press Ctrl+C to terminate

## Future Extensions

The following CLI features are deferred and not currently implemented:

- Interactive REPL mode (`zpm repl`) for successive queries
- User-selectable output format (`--format json|text`) — output is currently hard-coded per command (queries emit JSON, writes emit human-readable confirmations)
- Alternative output formats (YAML, TOML, CSV)
- Shell completion scripts (bash/zsh/fish)
- Batch piping (stdin → multiple tool calls)
- `.zpm/config.toml` — Project-level configuration file
- `--transport` flag — TCP/HTTP server modes (currently STDIO only)
- `--log-level` flag — Debug logging control
- Cross-process locking for concurrent CLI + `zpm serve` access to the same `.zpm/`

See the [Roadmap](../README.md#roadmap) for more details.
