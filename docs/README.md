# Documentation

Welcome to zpm documentation. Choose your path:

## For New Users

- **[Getting Started with MCP Server](getting-started/mcp-server.md)** — Set up and run the zpm MCP server in 5 minutes
- **[Project Initialization](user-guide/project-init.md)** — Initialize a `.zpm/` project directory
- **[Local Site Development](getting-started/site-development.md)** — Preview the zpm documentation site locally

## For Users

- **[Schema Discovery](user-guide/schema-discovery.md)** — Explore predicates in the knowledge base
- **[Fact Update and Upsert](user-guide/fact-update-upsert.md)** — Replace facts atomically or insert if missing
- **[Quality Checks](user-guide/quality-checks.md)** — Verify consistency and explain reasoning chains
- **[Fact Deletion](user-guide/fact-deletion.md)** — Remove individual facts or clear entire categories
- **[Truth Maintenance System](user-guide/truth-maintenance.md)** — Manage assumptions and automatically propagate belief changes
- **[Knowledge Base Persistence](user-guide/persistence.md)** — Save and restore knowledge base state with snapshots and automatic recovery
- **[Upgrading zpm](user-guide/upgrading.md)** — Keep zpm up to date with SHA256 verification
- **[Contributing to Documentation](user-guide/contributing-docs.md)** — Guidelines for writing site documentation

## For Developers

- **[CLI Reference](reference/cli.md)** — Command-line interface, subcommands, and flags
- **[Prolog Engine Reference](reference/prolog-engine.md)** — Engine API, query syntax, and sandboxing constraints
- **[MCP Tools Reference](reference/mcp-tools.md)** — Available tools and their JSON-RPC methods
- **[Site Configuration Reference](reference/site-config.md)** — Hugo site configuration, deployment, and customization
- **[Project Brief](project-brief.md)** — Vision, requirements, and success criteria
- **[Architecture Decision Records](ADR/)** — Design decisions and rationale

## Documentation Site

This documentation is also available online at **https://awf-project.github.io/zpm/**. The site is built with Hugo and the Thulite/Doks theme, and deploys automatically via GitHub Actions on push to `main`.

To preview locally: `cd site && npm ci && npm run dev`

## About zpm

zpm is a Prolog inference engine for the Model Context Protocol, implemented in Zig. It aims to enable deterministic logical reasoning in AI workflows.
