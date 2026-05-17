---
title: "Knowledge Base Overview"
---


Get a comprehensive snapshot of your knowledge base with the `get_kb_overview` tool. This guide shows how to inspect predicates, sample facts, assumptions, snapshots, and persistence health in a single query.

## Quick Overview

Use `get_kb_overview` to see what's in your knowledge base at a glance:

```bash
zpm get-kb-overview
```

This returns a JSON object with:
- **Predicates**: Names, arities, kinds (fact/rule/both), and sample clauses
- **Assumptions**: Active truth maintenance assumptions and their supported facts
- **Snapshots**: Available persistence snapshots with creation timestamps
- **Persistence**: Health status of the write-ahead journal and checkpoint
- **Mounts**: Currently mounted memory segments with their scope and access mode

## Basic Usage

### Get predicates with default samples (2 clauses per predicate)

```bash
zpm get-kb-overview
```

### Get extended samples (5 clauses per predicate)

```bash
zpm get-kb-overview --sample-size 5
```

### Get overview without samples (for large knowledge bases)

```bash
zpm get-kb-overview --sample-size 0
```

## Response Structure

### Predicates

Each predicate in the response includes:

```json
{
  "name": "task_status",
  "arity": 2,
  "kind": "fact",
  "count": 5,
  "samples": [
    "task_status(f017, done)",
    "task_status(f020, pending)"
  ]
}
```

| Field | Description |
|-------|-------------|
| `name` | Predicate name (functor) |
| `arity` | Number of arguments |
| `kind` | `"fact"` (only asserted), `"rule"` (only defined), or `"both"` (mixed) |
| `count` | Total number of clauses (facts + rules) |
| `samples` | Example clauses (up to `sample_size`); rules shown as `Head :- Body` |

### Assumptions

Active assumptions in the truth maintenance system:

```json
{
  "name": "user_context",
  "facts": [
    "user_id(alice)",
    "session_token(xyz123)"
  ]
}
```

If no assumptions are registered, this is an empty array.

### Snapshots

Available snapshots for recovery or rollback:

```json
{
  "name": "before_deploy",
  "timestamp": 1685678900
}
```

Each snapshot shows its creation time as a Unix epoch timestamp.

### Persistence

The persistence health section:

```json
{
  "status": "active",
  "journal_size_bytes": 2048,
  "last_snapshot": "after_migration",
  "last_checkpoint_epoch": 1685678950
}
```

| Field | Description |
|-------|-------------|
| `status` | `"active"`, `"degraded"`, or `"offline"` |
| `journal_size_bytes` | Write-ahead journal size in bytes |
| `last_snapshot` | Name of the most recent snapshot (or null) |
| `last_checkpoint_epoch` | Unix epoch of the last checkpoint |

### Mounts

Currently mounted memory segments:

```json
{
  "available": true,
  "count": 2,
  "items": [
    {"name": "default", "scope": "project", "mode": "rw"},
    {"name": "shared", "scope": "global", "mode": "ro"}
  ]
}
```

| Field | Description |
|-------|-------------|
| `available` | `true` when the memory registry is initialized; `false` when it is not yet set up |
| `count` | Number of mounted memory segments |
| `items[].name` | Mount name (a valid Prolog atom) |
| `items[].scope` | `"project"` — scoped to the current project; `"global"` — shared across projects |
| `items[].mode` | `"rw"` — read-write; `"ro"` — read-only |

When `available` is `false`, `count` is `0` and `items` is empty. This occurs when the memory registry has not been initialized (e.g., the server started without a `.zpm/` directory or before the first `mount_memory` call).

## Workflow: Diagnose Knowledge Base State

Use `get_kb_overview` to quickly understand what's in your knowledge base:

```bash
# Step 1: Get an overview of all predicates
zpm get-kb-overview --sample-size 0
# Shows: which predicates exist, how many facts/rules, persistence status

# Step 2: Look deeper at specific predicates
zpm get-kb-overview --sample-size 5
# Shows: sample clauses for investigation

# Step 3: Check assumptions for debugging
# Look at the "assumptions" section to see active TMS state

# Step 4: Verify persistence
# Check "persistence.status" and "journal_size_bytes" to ensure durability
```

## Use Cases

### Debugging Rule Interactions

Check which rules are defined and how they compose with facts:

```bash
zpm get-kb-overview --sample-size 3
# Look for predicates with kind: "both" — these are facts+rules
```

### Monitoring Knowledge Base Health

Track journal size and persistence status:

```bash
zpm get-kb-overview --sample-size 0 | jq '.persistence'
# Output:
# {
#   "status": "active",
#   "journal_size_bytes": 2048,
#   "last_snapshot": "before_deploy",
#   "last_checkpoint_epoch": 1685678950
# }

# If journal_size_bytes is growing, consider:
# zpm save-snapshot --name "cleanup-point"
# Then retract old facts to keep the KB lean
```

### Understanding Assumption State

See what assumptions are active and which facts depend on them:

```bash
zpm get-kb-overview | jq '.assumptions'
# Output:
# [
#   {
#     "name": "experiment_mode",
#     "facts": ["debug_enabled(true)", "log_level(verbose)"]
#   }
# ]

# Retract assumptions when experiments conclude:
# zpm retract-assumption --assumption experiment_mode
```

### Bootstrapping an LLM Agent

Use the overview as context for an agent session:

```bash
# Get a high-level view (no samples to save tokens)
zpm get-kb-overview --sample-size 0 \
  | jq '{predicates: .predicates[].name, assumptions: .assumptions[].name, persistence_status: .persistence.status}'

# Output:
# {
#   "predicates": ["task_status", "depends_on", "friend"],
#   "assumptions": ["user_context"],
#   "persistence_status": "active"
# }

# Agent can now make informed queries without exploring blindly
```

## Performance Notes

- The tool queries the knowledge base once, making it efficient even for large KBs
- Output is truncated at 64 KB total. If the overview is truncated (check `"truncated": true`):
  - Use `sample_size: 0` to reduce output
  - Query specific predicates with `query_logic` instead
  
- Sample clauses are formatted as they appear in the KB (atoms for facts, `Head :- Body` for rules)
- Built-in predicates (starting with `$`, containing `:`, or named `tms_justification`, `zpm_source`, `portray`) are excluded

## Comparison with Other Tools

| Tool | Purpose | When to Use |
|------|---------|------------|
| `get_kb_overview` | Comprehensive snapshot with samples and assumptions | First diagnostic step; checking KB health and persistence |
| `get_knowledge_schema` | Predicate names, arities, and types only | Lightweight schema inspection; building query templates |
| `query_logic` | Execute specific Prolog goals | Finding facts matching a pattern; testing rules |
| `explain_why` | Trace proof tree for a single fact | Understanding how a specific conclusion was derived |

## See Also

- [MCP Tools Reference](../reference/mcp-tools.md) — Full tool specifications
- [Schema Discovery](schema-discovery.md) — Lightweight predicate introspection
- [Knowledge Base Persistence](persistence.md) — Snapshots and recovery
- [Truth Maintenance System](truth-maintenance.md) — Understanding assumptions and beliefs
