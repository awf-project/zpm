---
title: "Segmented Memories"
---

# Segmented Memories

Segmented memories allow you to organize knowledge into isolated, independent domains. Each memory segment has its own facts, rules, and persistence state, enabling you to:

- **Separate concerns** by domain (e.g., user profiles, project tasks, system state)
- **Control access** with read-only mode to prevent accidental mutations
- **Scale workflows** by managing agent-specific knowledge without cross-contamination
- **Reuse knowledge** across projects with global memory scopes

## Quick Start

### Create a memory

Create a new memory segment named `feature_docs`:

```bash
zpm memory create --name feature_docs
```

Or via MCP:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_memory","arguments":{"name":"feature_docs"}}}
```

### Assert facts into a memory

After creation, the memory is automatically added to the persistent mount manifest and will be mounted on the next CLI command:

```bash
zpm remember-fact --fact "component(auth, critical)" --memory feature_docs
```

Or via MCP (the memory is automatically mounted when created via MCP):

```json
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"remember_fact","arguments":{"fact":"component(auth, critical)","memory":"feature_docs"}}}
```

### Query a memory

Query facts within a specific memory — results are isolated from other memories:

```bash
zpm query-logic --goal "component(auth, Status)" --memory feature_docs
```

Or via MCP:

```json
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"query_logic","arguments":{"goal":"component(auth, Status)","memory":"feature_docs"}}}
```

### List memories

View all available memory segments and their mount status:

```bash
zpm memory list
```

Or via MCP:

```json
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"list_memories","arguments":{}}}
```

## Memory Scopes

Memories can be stored in two scopes:

### Project Scope (Default)

Facts stored in `.zpm/kb/<memory_name>/` — available only within the current project.

```bash
zpm memory create --name auth --scope project
```

### Global Scope

Facts stored in `$XDG_DATA_HOME/zpm/kb/<memory_name>/` — shared across all projects.

```bash
zpm memory create --name shared_profiles --scope global
```

When mounting an unqualified name, the system searches project scope first, then global scope.

## Access Modes

Control whether a mounted memory accepts mutations:

### Read-Write Mode (Default)

Allow all operations:

```bash
zpm memory mount --name feature_docs --mode rw
```

### Read-Only Mode

Reject all mutations (`remember_fact`, `assume_fact`, etc.):

```bash
zpm memory mount --name shared_profiles --mode ro
```

Attempting to write to a read-only memory returns an error:

```bash
zpm remember-fact --fact "status(done)" --memory shared_profiles
# Error: Memory is read-only
```

Read-only mode is useful for consulting shared knowledge without risking accidental changes.

## Persistence

Each memory maintains independent persistence:

- **Snapshot** — Point-in-time copy of all facts in the memory
- **Write-Ahead Journal (WAL)** — Log of mutations, replayed on mount
- **Auto-recovery** — On mount, the latest snapshot loads, then WAL entries replay

Persistence is transparent and automatic. When you unmount a memory, all changes are durably stored:

```bash
zpm remember-fact --fact "progress(50)" --memory project_kb
zpm memory unmount --name project_kb
# Changes are flushed to disk

zpm memory mount --name project_kb
zpm query-logic --goal "progress(X)" --memory project_kb
# Result: progress(50) — recovered from persistence
```

## Common Workflows

### Multi-Agent Collaboration

Create isolated memories for each agent to prevent cross-contamination:

```bash
# Agent 1: auth domain
zpm memory create --name auth_agent
zpm remember-fact --fact "role(user_123, admin)" --memory auth_agent

# Agent 2: access control domain (cannot see auth_agent facts)
zpm memory create --name acl_agent
zpm remember-fact --fact "permission(admin, read)" --memory acl_agent

# Both agents can query their own knowledge without interference
zpm query-logic --goal "role(X, admin)" --memory auth_agent
zpm query-logic --goal "permission(admin, Y)" --memory acl_agent
```

### Shared Baselines

Create read-only global memories for reference data:

```bash
# Create once, globally
zpm memory create --name org_schema --scope global
zpm remember-fact --fact "entity(user)" --memory org_schema
zpm remember-fact --fact "entity(project)" --memory org_schema

# Mount read-only in any project
zpm memory mount --name org_schema --mode ro

# Can query, cannot mutate
zpm query-logic --goal "entity(X)" --memory org_schema
```

### Backup and Recovery

Snapshots provide explicit checkpoints:

```bash
# Create a snapshot before risky operations
zpm save-snapshot --name "before_migration" --memory feature_docs

# If something goes wrong, restore
zpm restore-snapshot --name "before_migration" --memory feature_docs
```

## Cross-Memory Queries

You can query facts from multiple memories using Prolog's module qualification syntax:

```bash
# Query default memory (unqualified)
zpm query-logic --goal "task(X, done)"

# Query specific memory
zpm query-logic --goal "feature_docs:component(auth, Status)" --memory feature_docs

# This finds facts in the feature_docs memory only, even if the same facts exist elsewhere
```

## Constraints and Edge Cases

### Valid Memory Names

Memory names must be valid Prolog atoms:

- Start with lowercase letter or underscore
- Contain only alphanumeric characters and underscores
- No spaces, hyphens, or special characters
- Examples: `auth`, `user_profiles`, `_temp`, `project_2024`

Invalid names are rejected:

```bash
zpm memory create --name my-memory  # Error: Invalid atom name
zpm memory create --name 123abc     # Error: Invalid atom name
zpm memory create --name ""         # Error: Invalid atom name
```

### Scope Disambiguation

If a memory name exists in both project and global scope, the system requires explicit qualification:

```bash
# Create in both scopes
zpm memory create --name shared_kb --scope project
zpm memory create --name shared_kb --scope global

# Mounting without qualification fails
zpm memory mount --name shared_kb
# Error: Memory 'shared_kb' is ambiguous. Use 'project:shared_kb' or 'global:shared_kb'

# Qualify explicitly
zpm memory mount --name project:shared_kb
zpm memory mount --name global:shared_kb
```

### Default Memory Protection

The `default` memory is required and cannot be unmounted:

```bash
zpm memory unmount --name default
# Error: Cannot unmount the default memory
```

However, you can still mount it in read-only mode for reference:

```bash
zpm memory mount --name default --mode ro
zpm query-logic --goal "task(X, done)"  # Can query
zpm remember-fact --fact "new_task(y)"  # Error: Memory is read-only
```

## Troubleshooting

### Memory is not mounting

Check that the memory exists:

```bash
zpm memory list  # Shows all discoverable memories
```

### WAL or snapshot corruption

If you see warnings about corrupted entries:

1. Check the memory's persistence files:
   ```bash
   ls .zpm/kb/memory_name/
   # Should contain: knowledge.pl journal.wal snapshot.bin
   ```

2. Restore from the last good snapshot:
   ```bash
   zpm restore-snapshot --name <snapshot_name> --memory memory_name
   ```

### Running out of memory

Very large knowledge bases can consume significant RAM. If `mount` is slow:

1. Check persistent storage availability
2. Consider splitting facts across multiple memories
3. Create regular snapshots to reduce WAL size

## Next Steps

- [Knowledge Base Persistence](persistence.md) — Understand snapshots and WAL in detail
- [MCP Tools Reference](../reference/mcp-tools.md) — Full API documentation
- [CLI Reference](../reference/cli.md) — Complete command-line options
