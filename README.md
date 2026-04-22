# zpm

A high-performance MCP (Model Context Protocol) server written in Zig, designed to bridge Large Language Models with a Prolog inference engine for deterministic logical reasoning.

## Features

- CLI entrypoint with `init`, `serve`, `upgrade`, and all 22 MCP tools exposed as subcommands (e.g. `zpm remember-fact`, `zpm query-logic`)
- Self-upgrade via `zpm upgrade` with SHA256 verification, atomic install, and `--channel stable|dev` selection
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
zpm

# Show version (also: zpm -v)
zpm --version

# Initialize a project directory
zpm init

# Start the MCP server (STDIO transport)
zpm serve

# Upgrade to the latest release (verifies SHA256, atomic replace)
zpm upgrade
zpm upgrade --channel dev --dry-run

# Invoke MCP tools directly from the shell
zpm remember-fact "task_status(f017, done)"
zpm query-logic "task_status(X, done)" --format json
zpm save-snapshot "before-deploy"
```

See the [CLI Reference](docs/reference/cli.md) for the full list of tool subcommands and flags.

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
| `make upgrade-test` | Run upgrade end-to-end tests |

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
