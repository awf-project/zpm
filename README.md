# zpm

A high-performance MCP (Model Context Protocol) server written in Zig, designed to bridge Large Language Models with a Prolog inference engine for deterministic logical reasoning.

## Features

- CLI entrypoint with `init` and `serve` subcommands, `--help`/`-h` and `--version`/`-v` flags
- Per-project `.zpm/` directory for isolated configuration and persistence
- MCP protocol version `2025-11-25` over STDIO transport
- Tool registration and discovery via `tools/list`
- Echo tool for health-check and smoke testing
- Prolog inference engine with Trealla C API integration
- Knowledge management tools: assert facts and define rules via MCP
- Exploration tools: query Prolog goals and trace transitive dependencies via MCP
- Supervision tools: verify knowledge base consistency and explain proof chains via MCP
- Knowledge schema discovery: introspect predicates and their types via MCP
- Delete tools: retract individual facts or clear entire categories from the knowledge base
- Update tools: atomically replace individual facts or upsert facts with pattern matching
- Truth Maintenance System: manage assumptions and automatically propagate belief changes via MCP
- Knowledge base persistence: durable storage via write-ahead journal and snapshots with automatic recovery
- Documentation site with Hugo/Thulite (Doks) and GitHub Pages auto-deployment
- Zero external runtime dependencies (statically linked, including Prolog library)

## Quick Start

### Prerequisites

- [Zig](https://ziglang.org/download/) >= 0.15.2
- C compiler (gcc or clang)

### Install

Install the latest pre-built binary with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/awf-project/zpm/main/scripts/install.sh | sh
```

Supported platforms: Linux (x86_64, arm64), macOS (x86_64, arm64).

### Build from Source

```bash
# Build the server binary
make build

# Run unit tests
make test

# Run functional (end-to-end) tests
make functional-test
```

The built binary is located at `zig-out/bin/zpm`.

### CLI Usage

```bash
# Display help (also: zpm --help, zpm -h)
zig-out/bin/zpm

# Show version (also: zpm -v)
zig-out/bin/zpm --version

# Initialize a project directory
zig-out/bin/zpm init

# Start the MCP server (STDIO transport)
zig-out/bin/zpm serve
```

### Connect via MCP Client

Add zpm to your MCP client configuration. For example, in Claude Code's `settings.json`:

```json
{
  "mcpServers": {
    "zpm": {
      "command": "/path/to/zig-out/bin/zpm",
      "args": ["serve"]
    }
  }
}
```

## Commands

| Command | Description |
|---------|-------------|
| `make build` | Build the server binary |
| `make check` | Run all checks (lint + test + e2e) |
| `make clean` | Remove build artifacts |
| `make fmt` | Format source code |
| `make functional-test` | Run end-to-end MCP protocol tests |
| `make lint` | Check formatting |
| `make test` | Run unit tests (inline Zig tests) |

## MCP Tools

| Tool | Description | Arguments |
|------|-------------|-----------|
| `assume_fact` | Assert a fact under a named assumption with automatic justification tracking | `assumption` (string, required), `fact` (string, required) |
| `clear_context` | Clear all facts from the knowledge base matching a pattern | `category` (string, required) |
| `define_rule` | Assert a Prolog rule into the knowledge base | `head` (string, required), `body` (string, required) |
| `echo` | Returns the provided message (health-check) | `message` (string, required) |
| `explain_why` | Trace proof tree for a fact and return structured deduction chain | `fact` (string, required), `max_depth` (integer, optional) |
| `forget_fact` | Remove a single fact from the knowledge base | `fact` (string, required) |
| `get_belief_status` | Query whether a belief is currently supported and which assumptions justify it | `fact` (string, required) |
| `get_justification` | Query all facts supported by a named assumption | `assumption` (string, required) |
| `get_knowledge_schema` | Introspect the knowledge base and list all user-defined predicates with their arity and type (fact/rule/both) | (no required arguments) |
| `get_persistence_status` | Query the persistence layer status including journal size, last snapshot, and operational mode | (no required arguments) |
| `list_assumptions` | List all currently active assumptions and their associated facts | (no required arguments) |
| `list_snapshots` | List all available knowledge base snapshots with metadata | (no required arguments) |
| `query_logic` | Execute a Prolog goal and return all variable bindings as JSON | `goal` (string, required) |
| `remember_fact` | Assert a Prolog fact into the knowledge base | `fact` (string, required) |
| `restore_snapshot` | Restore knowledge base from a named snapshot and replay subsequent journal entries | `name` (string, required) |
| `retract_assumption` | Retract a named assumption and propagate its removal through the knowledge base | `assumption` (string, required) |
| `retract_assumptions` | Retract all assumptions matching a glob-style pattern | `pattern` (string, required) |
| `save_snapshot` | Create a named point-in-time snapshot of the knowledge base | `name` (string, required) |
| `trace_dependency` | Trace transitive dependencies from a start node using path/2 rules | `start_node` (string, required) |
| `update_fact` | Atomically replace an existing fact (retract old, assert new) | `old_fact` (string, required), `new_fact` (string, required) |
| `upsert_fact` | Replace a fact matching functor+first arg, or insert if not found | `fact` (string, required) |
| `verify_consistency` | Check knowledge base for integrity violations | `scope` (string, optional) |

## Architecture

```
src/
  main.zig          # CLI entrypoint and MCP server (STDIO transport)
  project.zig       # Project directory discovery (.zpm/) and initialization
  tools/
    assume_fact.zig        # TMS: assert fact under named assumption
    clear_context.zig      # Clear context tool handler (bulk fact deletion)
    context.zig            # Engine singleton for tool handlers
    define_rule.zig        # Define rule tool handler
    echo.zig               # Echo tool handler
    explain_why.zig        # Proof tree explanation tool handler
    forget_fact.zig        # Forget fact tool handler (single fact deletion)
    get_belief_status.zig  # TMS: query belief support status and justifications
    get_justification.zig  # TMS: list facts supported by an assumption
    get_knowledge_schema.zig   # Knowledge schema introspection tool handler
    get_persistence_status.zig # Persistence layer status and metadata
    list_assumptions.zig   # TMS: list all active assumptions
    list_snapshots.zig     # List available snapshots and metadata
    query_logic.zig        # Query logic tool handler
    remember_fact.zig      # Remember fact tool handler
    restore_snapshot.zig   # Restore from a named snapshot and replay journal
    retract_assumption.zig # TMS: retract assumption with propagation
    retract_assumptions.zig # TMS: bulk retract by glob pattern
    save_snapshot.zig      # Create a named snapshot of the knowledge base
    term_utils.zig         # Shared Prolog term parsing utilities
    trace_dependency.zig   # Trace dependency tool handler
    update_fact.zig        # Update fact tool handler (atomic replacement)
    upsert_fact.zig        # Upsert fact tool handler (insert or replace)
    verify_consistency.zig # Knowledge base consistency checker
  persistence/
    manager.zig     # Persistence lifecycle: initialization, degraded mode, state tracking
    snapshot.zig    # Snapshot generation and restoration via Prolog introspection
    wal.zig         # Write-ahead journal: append mutations and replay from checkpoints
  prolog/
    engine.zig      # Prolog engine with query, assert/retract, loading
    ffi.zig         # C-ABI extern declarations for Trealla's pl_* API
    capture.zig     # stdout redirection for query output parsing
ffi/
  trealla/          # Trealla Prolog C source (git submodule, compiled by build.zig)
site/
  config/              # Hugo configuration (params, menus, modules, production)
  content/             # Homepage, blog, and docs section index pages
  layouts/             # Custom Hugo templates (home.html, redirect)
  assets/              # Custom JS/CSS assets
  package.json         # Thulite/Doks theme dependencies
.github/
  workflows/
    hugo.yml           # GitHub Pages build and deploy workflow
tests/
  functional_mcp_server_test.sh    # End-to-end MCP protocol tests
```

The project uses a flat module structure. Hexagonal architecture is deferred until domain complexity justifies it; see [ADR-0004](docs/ADR/0004-trealla-prolog-via-c-ffi-replacing-scryer.md) for the current Prolog backend rationale.

## Roadmap

- [x] F001: MCP server creation via mcp.zig
- [x] F002: Prolog inference engine integration (Trealla via C API)
- [x] F003: Knowledge management tools — write (remember_fact, define_rule)
- [x] F004: Knowledge management tools — read (query_logic, trace_dependency)
- [x] F005: Supervision and quality tools (verify_consistency, explain_why)
- [x] F006: Knowledge schema discovery (get_knowledge_schema)
- [x] F007: Fact deletion tools (forget_fact, clear_context)
- [x] F008: Fact update and upsert tools (update_fact, upsert_fact)
- [x] F009: Truth Maintenance System (assume_fact, retract_assumption, get_belief_status, get_justification, list_assumptions, retract_assumptions)
- [x] F010: Knowledge base persistence via WAL and snapshots (save_snapshot, restore_snapshot, list_snapshots, get_persistence_status)
- [x] F011: CLI entrypoint with help and serve subcommand
- [x] F012: Local project directory for configuration and persistence (`.zpm/` init, discovery, per-project isolation)
- [x] F013: GitHub Actions release workflow with tag-triggered releases and dev pre-releases
- [x] F014: Hugo static site with GitHub Pages auto-deployment
- [x] F015: Binary installation & multi-platform release (4 platforms: linux-x86_64, linux-arm64, darwin-x86_64, darwin-arm64)
- [x] F016: Replace Scryer-Prolog with Trealla and remove Rust stack

## Documentation

Browse the documentation online at **https://awf-project.github.io/zpm/** or in the [`docs/`](docs/) directory:

- [Project Brief](docs/project-brief.md) -- Vision and objectives
- [Getting Started](docs/getting-started/) -- Build, install, and first steps
- [Reference](docs/reference/) -- MCP tools and protocol details
- [ADR](docs/ADR/) -- Architecture Decision Records

To preview the documentation site locally:

```bash
cd site && npm ci && npm run dev
```

## License

See [LICENSE](LICENSE).
