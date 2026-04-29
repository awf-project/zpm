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
zpm <tool-name> [<positional>] [--flag value ...] [--format json|text]
```

Tool fields are passed as `--kebab-case` flags by default — `remember_fact.fact` becomes `--fact`, `explain_why.max_depth` becomes `--max-depth`, and so on. Two tools take a positional first argument as a historical exception: `define-rule` accepts the rule head positionally, and `assume-fact` accepts the fact positionally. Every other tool's required and optional fields use `--<flag> <value>` syntax. The full tool roster lives in [MCP Tools Reference](mcp-tools.md); each entry documents its fields.

Every tool subcommand also accepts `--format json|text`. The default (`text`) prints the tool's native output (queries already emit JSON, writes emit human-readable confirmations). `--format json` produces a JSON array whose elements are the raw `text` field of each result block, e.g. `["Asserted: parent(tom, bob)"]` for a write or `["[{\"X\":\"tom\"}]"]` for a query. Note that query output is doubly encoded — the inner string is itself JSON; pipe through `jq -r '.[]'` and parse the unwrapped string if you need structured access.

**Examples:**

```bash
# Insert a fact (US1)
zpm remember-fact --fact "decision(backend, trealla, performance)"

# Upsert: replace by functor + first argument
zpm upsert-fact --fact "task_status(f017, done)"

# Two-arg tool: head positional, body flag
zpm define-rule "ancestor(X, Z)" --body "parent(X, Y), ancestor(Y, Z)"

# Query and pipe JSON output to jq (US2)
zpm query-logic --goal "task_status(X, done)" | jq '.[].X'

# Snapshot management (US3)
zpm save-snapshot --name "before-upgrade"
zpm list-snapshots
zpm restore-snapshot --name "before-upgrade"

# Truth maintenance: fact is positional, assumption is a flag
zpm assume-fact "requires_reboot(host)" --assumption "deploy_plan_v2"
zpm list-assumptions
```

**Discovering Commands:**

```bash
zpm --help                  # Lists init, serve, upgrade, version, and every tool subcommand
zpm query-logic --help      # Shows the tool's flags (and any positional argument)
```

Help is generated from each tool's registry entry; adding a new MCP tool automatically produces a matching CLI entry with no manual documentation regeneration (NFR-004).

**Concurrency Warning:** Running CLI tool commands against a `.zpm/` that is actively being served by `zpm serve` is **undefined behaviour** for writes; the persistence layer does not yet coordinate locks between processes. Stop the server before issuing write commands, or restrict CLI use to read-only queries.

## Flags

### `-h, --help`

Displays help text listing available commands, subcommands, and options.

```bash
zpm --help
zpm -h
```

Running `zpm` without arguments also displays the help banner, but exits with status 1 because no subcommand was selected.

**Exit Code:** 0 for `--help`/`-h`; 1 when invoked with no arguments at all.

### `version` subcommand

Use the `version` subcommand to print the current zpm version:

```bash
zpm version
```

**Example Output:**
```
zpm 0.2.3
```

**Exit Code:** 0

The `--version` and `-v` flags are auto-generated by the underlying CLI parser, but currently fall through to the help banner with exit 1 (a known limitation in how zig-cli handles the version short-circuit). Prefer the `version` subcommand for scripts and installation checks.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success (`--help`/`-h`, `version` subcommand, `serve` running normally, tool result with `is_error=false`) |
| 1 | Error (`zpm` with no arguments, unknown subcommand, invalid or missing required flags, parse error, no `.zpm/` found, serve crashed, tool result with `is_error=true`) |

Tool subcommands write results to **stdout**; tool handler diagnostics (including the tool name and the offending field) are written to **stderr**, per FR-007. Argv parser errors emitted by zig-cli (unknown options, malformed flag values, missing required arguments) may be silently dropped before reaching the terminal in some environments — the exit code remains the authoritative signal.

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
zpm version           # Should print version (e.g. 'zpm 0.2.3')
zpm --help            # Should display help with exit 0
zpm serve &           # Should start without blocking terminal
```

## Architecture Notes

The CLI layer is split across several modules for clear separation of concerns:

1. **Registry** (`src/cli/registry.zig`) — All 22 MCP tools, each with a `ParamSpec` array describing its CLI shape (kind, required, positional, kebab name)
2. **Tool Command Generator** (`src/cli/tool_command.zig`) — Comptime generic `ToolCommand(comptime def)` that synthesizes a `cli.Command` per registry entry, including its options, positional args, and exec thunk
3. **App Assembler** (`src/cli/app.zig`) — Builds the top-level `cli.App` with the `init`, `serve`, `upgrade`, and `version` subcommands plus every generated tool command
4. **Bootstrap** (`src/cli/bootstrap.zig`) — Shared initialization: discover `.zpm/`, load knowledge base, start Prolog engine
5. **Output** (`src/cli/output.zig`) — Format tool results for stdout per the `--format` flag, and write diagnostics to stderr per FR-007
6. **Subcommand Handlers** (`src/cli/{init,serve,upgrade}.zig`) — Entry-point logic for three of the four built-in subcommands; the fourth (`version`) is inlined in `app.zig` because it has no dependencies and amounts to a one-line print

This architecture ensures:
- Automatic CLI generation for all MCP tools (NFR-004: adding a tool generates a matching CLI entry with no manual work)
- Help text is rendered by the underlying CLI parser straight from the registry, so help drift between docs and reality is structurally impossible
- Deterministic argument ordering (positional first, then flags) across all tools
- Fast `--help` and `version` responses (no knowledge base load)
- Type-validated flags: `--max-depth abc` is rejected at parse time instead of being silently dropped

## Troubleshooting

**Server doesn't respond to commands**
- Ensure the server is running: `zpm serve &`
- Verify stdin/stdout are connected properly
- Check that you're sending valid JSON-RPC 2.0 requests

**Unrecognized subcommand falls through to help**
- An unknown subcommand (e.g. `zpm bogus`) prints the help banner on stdout and exits 1, with no diagnostic identifying the offending name (the parser's error message is dropped before reaching the terminal — see Exit Codes above).
- Valid subcommands are `init`, `serve`, `upgrade`, `version`, and every MCP tool in kebab-case (e.g. `remember-fact`, `query-logic`, `save-snapshot`).
- Run `zpm --help` to list every available subcommand.
- The tool list is derived from the registry, so any tool accessible via MCP is also accessible on the CLI.

**Unexpected hang**
- If `zpm serve` appears to hang, it's likely waiting for MCP requests on stdin
- This is expected behavior for an MCP server
- Send a valid request or press Ctrl+C to terminate

## Future Extensions

The following CLI features are deferred and not currently implemented:

- Interactive REPL mode (`zpm repl`) for successive queries
- Alternative output formats (YAML, TOML, CSV)
- Shell completion scripts (bash/zsh/fish)
- Batch piping (stdin → multiple tool calls)
- `.zpm/config.toml` — Project-level configuration file
- `--transport` flag — TCP/HTTP server modes (currently STDIO only)
- `--log-level` flag — Debug logging control
- Cross-process locking for concurrent CLI + `zpm serve` access to the same `.zpm/`

See the [Roadmap](../README.md#roadmap) for more details.
