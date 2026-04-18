---
title: "Fact Update and Upsert: Modify Knowledge"
---


This guide shows how to replace facts and upsert facts into the knowledge base using atomic update operations.

## Update a Single Fact

Use `update_fact` to atomically replace an existing fact with a new one. Both the old and new facts must be valid Prolog terms.

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"remember_fact","arguments":{"fact":"role(jean, manager)"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"update_fact","arguments":{"old_fact":"role(jean, manager)","new_fact":"role(jean, director)"}}}
```

After the update, querying `role(jean, manager)` returns no results, and `role(jean, director)` returns the new fact.

### Atomic Semantics

`update_fact` is atomic: either both the retraction and assertion succeed, or neither does. If the old fact is not found in the knowledge base, the operation fails with an error and no changes are made:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"update_fact","arguments":{"old_fact":"role(nonexistent, manager)","new_fact":"role(nonexistent, director)"}}}
```

This returns an error because `role(nonexistent, manager)` does not exist.

### Use Cases

- Correct outdated facts: `role(alice, junior)` → `role(alice, senior)`
- Evolve state: `deploy(prod, v1)` → `deploy(prod, v2)`
- Migrate data: `user(id=123, name="John")` → `user(id=123, name="Jonathan")`

## Upsert a Fact

Use `upsert_fact` to replace a fact if it exists, or insert it if it doesn't. Upsert matches on the functor and first argument only.

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"upsert_fact","arguments":{"fact":"deploy(prod, v1)"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"upsert_fact","arguments":{"fact":"deploy(prod, v2)"}}}
```

After the first `upsert_fact`, `deploy(prod, v1)` is asserted. After the second, the old version is removed and `deploy(prod, v2)` is inserted.

### Pattern Matching

Upsert removes all facts that match the functor and first argument of the provided fact:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"upsert_fact","arguments":{"fact":"project(beta, active)"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"upsert_fact","arguments":{"fact":"project(beta, archived, 2025-04-13)"}}}
```

The second call removes `project(beta, active)` and asserts the new `project(beta, archived, 2025-04-13)`, even though the arity differs.

### Idempotent Behavior

`upsert_fact` always succeeds, even when the fact is new. This makes it safe for initialization or repeated operations:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"upsert_fact","arguments":{"fact":"status(ready)"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"upsert_fact","arguments":{"fact":"status(ready)"}}}
```

Both calls succeed. The first inserts the fact, the second finds it already exists and does nothing.

### Use Cases

- Maintain a single "current" value: `current_version(prod, v2)`
- Track state without duplicates: `session(user_id, token_hash)`
- Enforce at-most-one semantics: `primary_database(prod_db_1)`

## When to Use Which Tool

| Scenario | Tool | Behavior |
|----------|------|----------|
| Correct a fact that must exist | `update_fact` | Fails if old fact is missing |
| Replace or insert a fact | `upsert_fact` | Always succeeds |
| Evolve state (same functor) | Either | Both work; choose based on error handling needs |
| Initialize with defaults | `upsert_fact` | Safe for repeated initialization |
| Enforce exactly-one fact | `upsert_fact` | Removes duplicates automatically |

## Differences from Deletion

| Operation | Update/Upsert | Deletion |
|-----------|----------------|----------|
| Scope | Single fact | Single fact or pattern |
| Effect | Replace | Remove |
| Atomicity | Atomic (both-or-nothing) | Single operation |
| Idempotence | `upsert_fact` is idempotent | `forget_fact` errors if not found |

## See Also

- [Fact Deletion](fact-deletion.md) -- Remove individual facts or clear categories
- [Schema Discovery](schema-discovery.md) -- Inspect predicates before updating
- [MCP Tools Reference](../reference/mcp-tools.md) -- Full request/response schemas for all tools
