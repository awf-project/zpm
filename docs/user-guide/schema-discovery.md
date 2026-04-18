---
title: "Schema Discovery: Explore the Knowledge Base"
---


This guide shows how to discover what predicates exist in the knowledge base using the `get_knowledge_schema` tool.

## Discover All Predicates

Use `get_knowledge_schema` to list every user-defined predicate, its arity, and whether it is a fact, rule, or both.

### Basic Usage

```bash
# Step 1: Populate the knowledge base
remember_fact fact='likes(alice, bob)'
remember_fact fact='likes(bob, alice)'
define_rule head='friend(X, Y)' body='likes(X, Y), likes(Y, X)'

# Step 2: Discover what's in the knowledge base
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

The tool requires no arguments. It returns all user-defined predicates — Scryer-Prolog built-ins are excluded.

## Understand Predicate Types

Each predicate has a `type` field indicating its clause composition:

| Type | Meaning | Example |
|------|---------|---------|
| `"fact"` | Only ground facts asserted via `remember_fact` | `likes/2` |
| `"rule"` | Only rules defined via `define_rule` | `friend/2` |
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
# 1. Discover what predicates exist
get_knowledge_schema
# Returns: depends_on/2 (fact, 5), risky/1 (rule, 1), ...

# 2. Use the schema to formulate valid queries
query_logic goal='depends_on(X, Y)'

# 3. Trace specific dependencies
trace_dependency start_node='service_a'
```

Without schema discovery, the agent would have to guess predicate names and arities.

## Empty Knowledge Base

When no user-defined predicates exist:

```bash
get_knowledge_schema
# Returns: {"predicates": [], "total": 0}
```

This is a valid response, not an error. Use it to confirm the knowledge base is clean before populating it.

## Error Handling

If the Prolog engine is unavailable:

```json
{
  "is_error": true,
  "message": "ExecutionFailed"
}
```

This indicates the engine failed to initialize. Check server logs for details.

## See Also

- [MCP Tools Reference](../reference/mcp-tools.md) — Full tool specifications
- [Quality Checks](quality-checks.md) — Verify consistency and explain reasoning chains
- [Prolog Engine Reference](../reference/prolog-engine.md) — Query syntax and semantics
