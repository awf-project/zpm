# Fact Deletion: Remove and Clean Up Knowledge

This guide shows how to retract individual facts and clear entire categories from the knowledge base using the deletion tools.

## Forget a Single Fact

Use `forget_fact` to retract one specific fact. The fact must match exactly.

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"remember_fact","arguments":{"fact":"role(jean, manager)"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"forget_fact","arguments":{"fact":"role(jean, manager)"}}}
```

After retraction, querying `role(jean, manager)` returns no results.

### Handling Duplicates

If the same fact was asserted multiple times, `forget_fact` removes only the first matching clause per call. Call it repeatedly to remove all duplicates:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"remember_fact","arguments":{"fact":"likes(alice, bob)"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"remember_fact","arguments":{"fact":"likes(alice, bob)"}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"forget_fact","arguments":{"fact":"likes(alice, bob)"}}}
```

After the `forget_fact` call above, one `likes(alice, bob)` remains.

### Non-Existent Facts

Calling `forget_fact` on a fact that does not exist returns an error with `isError: true`. This lets agents distinguish between successful retraction and no-ops.

## Clear All Facts by Category

Use `clear_context` to remove all facts matching a pattern in one operation. Use Prolog wildcards (`_`) to match any argument:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"clear_context","arguments":{"category":"project(beta, _)"}}}
```

This removes all `project/2` facts where the first argument is `beta`, regardless of the second argument.

### Clear an Entire Predicate

To remove all facts for a functor, use wildcards for every argument:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"clear_context","arguments":{"category":"role(_, _)"}}}
```

This removes every `role/2` fact from the knowledge base.

### Idempotent Behavior

`clear_context` always succeeds, even when no facts match the pattern. This makes it safe to call as a cleanup step without checking whether facts exist first.

## When to Use Which Tool

| Scenario | Tool | Example |
|----------|------|---------|
| Correct a single outdated fact | `forget_fact` | Remove `role(jean, manager)` after a role change |
| Clean up a topic after finishing work | `clear_context` | Remove all `project(beta, _)` facts |
| Remove all facts for a predicate | `clear_context` | Clear every `role(_, _)` fact |
| Remove one duplicate among many | `forget_fact` | Retract one `likes(alice, bob)` when two exist |

## See Also

- [MCP Tools Reference](../reference/mcp-tools.md) -- Full request/response schemas for all tools
- [Schema Discovery](schema-discovery.md) -- Inspect predicates before deciding what to delete
