---
title: "Schema Discovery: Explore the Knowledge Base"
---


This guide shows how to discover what predicates exist in the knowledge base using the `get_knowledge_schema` tool. Discovery includes file-loaded static predicates and predicates asserted after startup; built-ins and ZPM implementation predicates are excluded.

## Discover All Predicates

Use `get_knowledge_schema` to list every user-defined predicate, its arity, and whether it is a fact, rule, or both.

### Basic Usage

```bash
# Step 1: Populate the knowledge base
remember_fact fact='likes(alice, bob)'
remember_fact fact='likes(bob, alice)'
define_rule head='friend(X, Y)' body='likes(X, Y), likes(Y, X)'

# Step 2: Discover what's in the default memory
get_knowledge_schema
# Returns:
# {
#   "predicates": [
#     {"name": "likes", "arity": 2, "type": "fact", "count": 2},
#     {"name": "friend", "arity": 2, "type": "rule", "count": 1}
#   ],
#   "total": 2
# }
```

The `memory` argument is optional. When omitted, the tool returns predicates
from the `default` memory; pass a mounted segment name to inspect that segment
instead. Discovery includes facts and rules loaded from `knowledge.pl` without
`dynamic` declarations, as well as predicates asserted after mounting. It also
works for read-only mounts. Predicates from other memories, Prolog built-ins,
operators, and ZPM helper predicates are excluded.

```bash
# Discover predicates in a named memory segment
zpm get-knowledge-schema --memory feature_auth
```

For example, if a mounted segment's `knowledge.pl` contains `note(c).` and
`note(cs).`, `zpm get-knowledge-schema --memory music_theory` reports `note/1`
as `"fact"` with `count: 2`. The file does not need a `dynamic` directive for
discovery. Query the same memory to use those facts.

## Understand Predicate Types

Each predicate has a `type` field indicating its clause composition:

| Type | Meaning | Example |
|------|---------|---------|
| `"fact"` | Only fact clauses, whether file-loaded or asserted | `likes/2` |
| `"rule"` | Only rule clauses, whether file-loaded or defined at runtime | `friend/2` |
| `"both"` | Mix of facts and rules for the same predicate | `path/2` with a base fact and recursive rule |

### Example: Mixed Predicate

```bash
# Assert a base fact and a recursive rule for the same predicate
remember_fact fact='path(a, b)'
define_rule head='path(X, Y)' body='path(X, Z), path(Z, Y)'

get_knowledge_schema
# path/2 shows type: "both", count: 2
```

## Workflow: Bootstrap an Agent Session

Use schema discovery as the first step when an LLM connects to a knowledge base it hasn't seen before:

```bash
# 1. Discover what predicates exist in the default memory
get_knowledge_schema
# Returns: depends_on/2 (fact, 5), risky/1 (rule, 1), ...

# 2. Use the schema to formulate valid queries
query_logic goal='depends_on(X, Y)'

# 3. Trace specific dependencies
trace_dependency start_node='service_a'
```

For an isolated knowledge base, select the same segment for discovery and
follow-up queries:

```bash
zpm get-knowledge-schema --memory feature_auth
zpm query-logic --goal 'depends_on(X, Y)' --memory feature_auth
```

Without schema discovery, the agent would have to guess predicate names and arities.

## Empty Knowledge Base

When no user-defined predicates exist:

```bash
get_knowledge_schema
# Returns: {"predicates": [], "total": 0}
```

This is a valid response, not an error. It means no discoverable user clauses
exist in the selected memory.

## Error Handling

If predicate introspection fails, the tool reports `ExecutionFailed` instead
of an empty schema. An unavailable engine also returns an error result.

```json
{
  "is_error": true,
  "message": "ExecutionFailed"
}
```

Check server logs for the underlying failure. An empty schema is returned only
when discovery succeeds and finds no user clauses.

## See Also

- [Knowledge Base Overview](knowledge-base-overview.md) — Get a comprehensive snapshot with samples and assumptions
- [MCP Tools Reference](../reference/mcp-tools.md) — Full tool specifications
- [Quality Checks](quality-checks.md) — Verify consistency and explain reasoning chains
- [Prolog Engine Reference](../reference/prolog-engine.md) — Query syntax and semantics
