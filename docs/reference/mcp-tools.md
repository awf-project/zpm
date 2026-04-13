# MCP Tools Reference

## Protocol

- **Transport**: STDIO (stdin/stdout)
- **Protocol version**: `2025-11-25`
- **Server name**: `zpm`
- **Server version**: `0.1.0`

## Server Capabilities

After initialization, the server advertises:

| Capability | Supported | Details |
|------------|-----------|---------|
| Tools | yes | `listChanged: true` |
| Resources | no | Deferred to future features |
| Prompts | no | Deferred to future features |

## Lifecycle

1. Client sends `initialize` request with protocol version and client info
2. Server responds with `InitializeResult` containing server info and capabilities
3. Client sends `notifications/initialized`
4. Server enters active state and accepts `tools/list` and `tools/call` requests
5. On STDIO EOF, server exits with code 0

## Tool Discovery

Clients discover available tools by sending a `tools/list` request after the initialize handshake:

```json
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
```

## Overview

This document describes the tools available through the zpm MCP server. Each tool is exposed as a JSON-RPC method that can be called via the `tools/call` request.

## Echo Tool

**Name:** `echo`

**Description:** Echoes back a message string. Useful for testing server connectivity and tool invocation.

**Annotations:**
- Read-only: ✓
- Idempotent: ✓
- Non-destructive: ✓

### Request

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "echo",
    "arguments": {
      "message": "Hello, world!"
    }
  }
}
```

### Input Schema

```json
{
  "type": "object",
  "properties": {
    "message": {
      "type": "string",
      "description": "The message to echo"
    }
  },
  "required": ["message"]
}
```

### Response (Success)

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Hello, world!"
      }
    ]
  }
}
```

### Response (Error)

If the `message` argument is missing or null:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "InvalidArguments",
        "isError": true
      }
    ]
  }
}
```

## Remember Fact Tool

**Name:** `remember_fact`

**Description:** Assert a Prolog fact into the knowledge base. Facts persist in-memory for the duration of the engine session.

**Annotations:**
- Read-only: ✗
- Idempotent: ✗
- Non-destructive: ✗

### Request

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "remember_fact",
    "arguments": {
      "fact": "human(socrates)"
    }
  }
}
```

### Input Schema

```json
{
  "type": "object",
  "properties": {
    "fact": {
      "type": "string",
      "description": "A Prolog fact to assert (e.g. \"human(socrates)\")"
    }
  },
  "required": ["fact"]
}
```

### Response (Success)

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Asserted: human(socrates)"
      }
    ]
  }
}
```

### Response (Error)

If the `fact` argument is missing, null, or empty:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "InvalidArguments",
        "isError": true
      }
    ]
  }
}
```

## Define Rule Tool

**Name:** `define_rule`

**Description:** Assert a Prolog rule into the knowledge base. Constructs a rule from head and body (`Head :- Body`), validates syntax (including balanced parentheses), and inserts via `assertz/1`.

**Annotations:**
- Read-only: ✗
- Idempotent: ✗
- Non-destructive: ✗

### Request

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "tools/call",
  "params": {
    "name": "define_rule",
    "arguments": {
      "head": "mortal(X)",
      "body": "human(X)"
    }
  }
}
```

### Input Schema

```json
{
  "type": "object",
  "properties": {
    "head": {
      "type": "string",
      "description": "The rule head (e.g. \"mortal(X)\")"
    },
    "body": {
      "type": "string",
      "description": "The rule body (e.g. \"human(X)\")"
    }
  },
  "required": ["head", "body"]
}
```

### Response (Success)

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Asserted rule: mortal(X) :- human(X)"
      }
    ]
  }
}
```

### Response (Error)

If `head` or `body` is missing, null, or empty:

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "InvalidArguments",
        "isError": true
      }
    ]
  }
}
```

If the rule has invalid Prolog syntax (e.g. unbalanced parentheses):

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Invalid Prolog syntax in rule: unbalanced parentheses",
        "isError": true
      }
    ]
  }
}
```

## Query Logic Tool

**Name:** `query_logic`

**Description:** Execute a Prolog goal and return all variable bindings as JSON. Evaluates a deterministic Prolog query against the knowledge base and returns all solutions with their variable bindings.

**Annotations:**
- Read-only: ✓
- Idempotent: ✓
- Non-destructive: ✓

### Request

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "tools/call",
  "params": {
    "name": "query_logic",
    "arguments": {
      "goal": "fruit(X)"
    }
  }
}
```

### Input Schema

```json
{
  "type": "object",
  "properties": {
    "goal": {
      "type": "string",
      "description": "A Prolog goal to query (e.g. \"fruit(X)\", \"parent(john, Y)\")"
    }
  },
  "required": ["goal"]
}
```

### Response (Success with Results)

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "[{\"X\":\"apple\"},{\"X\":\"banana\"}]"
      }
    ]
  }
}
```

### Response (Success with No Results)

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "[]"
      }
    ]
  }
}
```

### Response (Error)

If the `goal` argument is missing, null, or empty:

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "InvalidArguments",
        "isError": true
      }
    ]
  }
}
```

## Trace Dependency Tool

**Name:** `trace_dependency`

**Description:** Trace transitive dependencies from a start node using `path/2` rules. Queries the knowledge base for all nodes reachable from a given start node through dependency chains, useful for exploring graph-like structures in logical knowledge bases.

**Annotations:**
- Read-only: ✓
- Idempotent: ✓
- Non-destructive: ✓

### Request

```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "method": "tools/call",
  "params": {
    "name": "trace_dependency",
    "arguments": {
      "start_node": "a"
    }
  }
}
```

### Input Schema

```json
{
  "type": "object",
  "properties": {
    "start_node": {
      "type": "string",
      "description": "The starting node to trace dependencies from (e.g. \"a\", \"module_a\")"
    }
  },
  "required": ["start_node"]
}
```

### Response (Success with Dependencies)

Requires `path/2` rule defined in the knowledge base (typically via `define_rule`):

```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "[\"b\",\"c\"]"
      }
    ]
  }
}
```

### Response (Success with No Dependencies)

```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "[]"
      }
    ]
  }
}
```

### Response (Error)

If the `start_node` argument is missing, null, or empty:

```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "InvalidArguments",
        "isError": true
      }
    ]
  }
}
```

## Verify Consistency Tool

**Name:** `verify_consistency`

**Description:** Check the knowledge base for integrity violations by querying `integrity_violation/N` predicates. Returns all detected contradictions or constraint breaches with their variable bindings.

**Annotations:**
- Read-only: ✓
- Idempotent: ✓
- Non-destructive: ✓

### Request

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "tools/call",
  "params": {
    "name": "verify_consistency",
    "arguments": {}
  }
}
```

### Input Schema

```json
{
  "type": "object",
  "properties": {
    "scope": {
      "type": "string",
      "description": "Optional domain scope to filter integrity checks (e.g. \"deployment\")"
    }
  },
  "required": []
}
```

### Response (Success with Violations)

Requires `integrity_violation/1` rules defined via `define_rule`:

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"violations\":[\"deploy_v3\"]}"
      }
    ]
  }
}
```

### Response (Success with No Violations)

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"violations\":[]}"
      }
    ]
  }
}
```

### Response (Error)

If the Prolog engine is unavailable:

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "ExecutionFailed",
        "isError": true
      }
    ]
  }
}
```

## Explain Why Tool

**Name:** `explain_why`

**Description:** Trace the proof tree for a given fact and return a structured JSON explanation of how it was derived. Uses recursive `clause/2` querying to reconstruct the deduction chain.

**Annotations:**
- Read-only: ✓
- Idempotent: ✓
- Non-destructive: ✓

### Request

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "method": "tools/call",
  "params": {
    "name": "explain_why",
    "arguments": {
      "fact": "risky(deploy_v3)"
    }
  }
}
```

### Input Schema

```json
{
  "type": "object",
  "properties": {
    "fact": {
      "type": "string",
      "description": "The Prolog term to explain (e.g. \"risky(deploy_v3)\")"
    },
    "max_depth": {
      "type": "integer",
      "description": "Optional maximum proof tree depth (truncates deeper levels)"
    }
  },
  "required": ["fact"]
}
```

### Response (Success — Fact Proven)

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"fact\":\"risky(deploy_v3)\",\"proven\":true,\"proof_tree\":{\"goal\":\"risky(deploy_v3)\",\"rule_applied\":\"risky(X) :- untested(X), in_production(X)\",\"children\":[{\"goal\":\"untested(deploy_v3)\",\"rule_applied\":\"fact\",\"children\":[]},{\"goal\":\"in_production(deploy_v3)\",\"rule_applied\":\"fact\",\"children\":[]}]}}"
      }
    ]
  }
}
```

### Response (Success — Fact Not Proven)

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"fact\":\"risky(deploy_v3)\",\"proven\":false,\"proof_tree\":null}"
      }
    ]
  }
}
```

### Response (Error)

If the `fact` argument is missing, null, or empty:

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "InvalidArguments",
        "isError": true
      }
    ]
  }
}
```

## Get Knowledge Schema Tool

**Name:** `get_knowledge_schema`

**Description:** Introspect the knowledge base to discover all user-defined predicates, their arities, and whether they are facts, rules, or both. Returns structural metadata only — no predicate content is exposed.

**Annotations:**
- Read-only: ✓
- Idempotent: ✓
- Non-destructive: ✓

### Request

```json
{
  "jsonrpc": "2.0",
  "id": 9,
  "method": "tools/call",
  "params": {
    "name": "get_knowledge_schema",
    "arguments": {}
  }
}
```

### Input Schema

```json
{
  "type": "object",
  "properties": {},
  "required": []
}
```

No arguments are required. The tool accepts empty or null arguments.

### Response (Success with Predicates)

```json
{
  "jsonrpc": "2.0",
  "id": 9,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"predicates\":[{\"name\":\"user_prefers\",\"arity\":1,\"type\":\"fact\",\"count\":2},{\"name\":\"depends_on\",\"arity\":2,\"type\":\"fact\",\"count\":3},{\"name\":\"path\",\"arity\":2,\"type\":\"both\",\"count\":4}],\"total\":3}"
      }
    ]
  }
}
```

Each predicate entry includes:

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Predicate functor name |
| `arity` | integer | Number of arguments |
| `type` | string | `"fact"`, `"rule"`, or `"both"` |
| `count` | integer | Total number of clauses |

The root-level `total` field indicates the number of user-defined predicates.

### Response (Empty Knowledge Base)

```json
{
  "jsonrpc": "2.0",
  "id": 9,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"predicates\":[],\"total\":0}"
      }
    ]
  }
}
```

### Response (Error)

If the Prolog engine is not initialized:

```json
{
  "jsonrpc": "2.0",
  "id": 9,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "ExecutionFailed",
        "isError": true
      }
    ]
  }
}
```

## Forget Fact Tool

**Name:** `forget_fact`

**Description:** Remove a single fact from the knowledge base by retracting the first matching clause. Uses Prolog's `retract/1` semantics — when multiple identical facts exist, only one is removed per call.

**Annotations:**
- Read-only: ✗
- Idempotent: ✗
- Non-destructive: ✗

### Request

```json
{
  "jsonrpc": "2.0",
  "id": 10,
  "method": "tools/call",
  "params": {
    "name": "forget_fact",
    "arguments": {
      "fact": "human(socrates)"
    }
  }
}
```

### Input Schema

```json
{
  "type": "object",
  "properties": {
    "fact": {
      "type": "string",
      "description": "A Prolog fact to retract (e.g. \"human(socrates)\")"
    }
  },
  "required": ["fact"]
}
```

### Response (Success)

```json
{
  "jsonrpc": "2.0",
  "id": 10,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Retracted: human(socrates)"
      }
    ]
  }
}
```

### Response (Error - Fact Not Found)

If the fact does not exist in the knowledge base:

```json
{
  "jsonrpc": "2.0",
  "id": 10,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "No matching clause found for: human(socrates)",
        "isError": true
      }
    ]
  }
}
```

### Response (Error - Invalid Arguments)

If the `fact` argument is missing, null, or empty:

```json
{
  "jsonrpc": "2.0",
  "id": 10,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "InvalidArguments",
        "isError": true
      }
    ]
  }
}
```

---

## Clear Context Tool

**Name:** `clear_context`

**Description:** Remove all facts from the knowledge base matching a given category or pattern. Uses Prolog's `retractall/1` semantics — clears all clauses matching the pattern in a single operation. The tool always succeeds, even when no matching facts exist (idempotent behavior).

**Annotations:**
- Read-only: ✗
- Idempotent: ✓
- Non-destructive: ✗

### Request

```json
{
  "jsonrpc": "2.0",
  "id": 11,
  "method": "tools/call",
  "params": {
    "name": "clear_context",
    "arguments": {
      "category": "project(beta, _)"
    }
  }
}
```

### Input Schema

```json
{
  "type": "object",
  "properties": {
    "category": {
      "type": "string",
      "description": "A Prolog pattern to match facts for bulk deletion (e.g. \"project(beta, _)\", \"role(_, _)\")"
    }
  },
  "required": ["category"]
}
```

### Response (Success - Matched Facts)

```json
{
  "jsonrpc": "2.0",
  "id": 11,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Cleared all facts matching: project(beta, _)"
      }
    ]
  }
}
```

### Response (Success - No Matches)

When no facts match the pattern (idempotent — still returns success):

```json
{
  "jsonrpc": "2.0",
  "id": 11,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Cleared all facts matching: nonexistent(_, _)"
      }
    ]
  }
}
```

### Response (Error - Invalid Arguments)

If the `category` argument is missing, null, or empty:

```json
{
  "jsonrpc": "2.0",
  "id": 11,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "InvalidArguments",
        "isError": true
      }
    ]
  }
}
```

---

## Update Fact Tool

**Name:** `update_fact`

**Description:** Atomically replace an existing Prolog fact in the knowledge base (retract old_fact, assert new_fact). Returns an error if old_fact is not found, leaving the knowledge base unchanged.

**Annotations:**
- Read-only: ✗
- Idempotent: ✗
- Non-destructive: ✗

### Request

```json
{
  "jsonrpc": "2.0",
  "id": 12,
  "method": "tools/call",
  "params": {
    "name": "update_fact",
    "arguments": {
      "old_fact": "server(alpha, \"1.0\")",
      "new_fact": "server(alpha, \"2.0\")"
    }
  }
}
```

### Input Schema

```json
{
  "type": "object",
  "properties": {
    "old_fact": {
      "type": "string",
      "description": "The existing Prolog fact to retract (e.g. \"server(alpha, \\\"1.0\\\")\")"
    },
    "new_fact": {
      "type": "string",
      "description": "The new Prolog fact to assert in its place (e.g. \"server(alpha, \\\"2.0\\\")\")"
    }
  },
  "required": ["old_fact", "new_fact"]
}
```

### Response (Success)

```json
{
  "jsonrpc": "2.0",
  "id": 12,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Updated: server(alpha, \"1.0\") -> server(alpha, \"2.0\")"
      }
    ]
  }
}
```

### Response (Error - Fact Not Found)

If the old fact does not exist in the knowledge base:

```json
{
  "jsonrpc": "2.0",
  "id": 12,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "No matching clause for: server(alpha, \"1.0\")",
        "isError": true
      }
    ]
  }
}
```

### Response (Error - Rule Syntax)

If the new_fact contains rule syntax (`:-`):

```json
{
  "jsonrpc": "2.0",
  "id": 12,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "new_fact must not contain rule syntax",
        "isError": true
      }
    ]
  }
}
```

### Response (Error - Invalid Arguments)

If either argument is missing, null, or empty:

```json
{
  "jsonrpc": "2.0",
  "id": 12,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "InvalidArguments",
        "isError": true
      }
    ]
  }
}
```

---

## Upsert Fact Tool

**Name:** `upsert_fact`

**Description:** Insert or replace a Prolog fact in the knowledge base. Retracts all existing clauses matching the same functor and first argument, then asserts the new fact. Succeeds even if no prior fact exists.

**Annotations:**
- Read-only: ✗
- Idempotent: ✓
- Non-destructive: ✗

### Request

```json
{
  "jsonrpc": "2.0",
  "id": 13,
  "method": "tools/call",
  "params": {
    "name": "upsert_fact",
    "arguments": {
      "fact": "deploy(prod, v2)"
    }
  }
}
```

### Input Schema

```json
{
  "type": "object",
  "properties": {
    "fact": {
      "type": "string",
      "description": "A Prolog fact to insert or replace (e.g. \"deploy(prod, v2)\")"
    }
  },
  "required": ["fact"]
}
```

### Response (Success)

```json
{
  "jsonrpc": "2.0",
  "id": 13,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Upserted: deploy(prod, v2)"
      }
    ]
  }
}
```

### Response (Error - Rule Syntax)

If the fact contains rule syntax (`:-`):

```json
{
  "jsonrpc": "2.0",
  "id": 13,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "fact must not contain rule syntax",
        "isError": true
      }
    ]
  }
}
```

### Response (Error - Invalid Arguments)

If the `fact` argument is missing, null, or empty:

```json
{
  "jsonrpc": "2.0",
  "id": 13,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "InvalidArguments",
        "isError": true
      }
    ]
  }
}
```

---

## Update Fact Tool

**Name:** `update_fact`

**Description:** Atomically replace an existing fact with a new fact. The operation is all-or-nothing: if the old fact does not exist, the new fact is not asserted and an error is returned. This ensures fact replacements are guaranteed or fail cleanly without partial updates.

**Annotations:**
- Read-only: ✗
- Idempotent: ✗
- Non-destructive: ✗
- Atomic: ✓

### Request

```json
{
  "jsonrpc": "2.0",
  "id": 12,
  "method": "tools/call",
  "params": {
    "name": "update_fact",
    "arguments": {
      "old_fact": "role(jean, manager)",
      "new_fact": "role(jean, director)"
    }
  }
}
```

### Input Schema

```json
{
  "type": "object",
  "properties": {
    "old_fact": {
      "type": "string",
      "description": "The existing Prolog fact to retract (e.g. \"role(jean, manager)\")"
    },
    "new_fact": {
      "type": "string",
      "description": "The new Prolog fact to assert (e.g. \"role(jean, director)\")"
    }
  },
  "required": ["old_fact", "new_fact"]
}
```

### Response (Success)

```json
{
  "jsonrpc": "2.0",
  "id": 12,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Updated: role(jean, manager) → role(jean, director)"
      }
    ]
  }
}
```

### Response (Error - Old Fact Not Found)

If the old fact does not exist in the knowledge base:

```json
{
  "jsonrpc": "2.0",
  "id": 12,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "No matching clause found for: role(nonexistent, manager)",
        "isError": true
      }
    ]
  }
}
```

### Response (Error - Invalid Arguments)

If `old_fact` or `new_fact` arguments are missing, null, or empty:

```json
{
  "jsonrpc": "2.0",
  "id": 12,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "InvalidArguments",
        "isError": true
      }
    ]
  }
}
```

---

## Upsert Fact Tool

**Name:** `upsert_fact`

**Description:** Atomically replace a fact if it exists (based on functor and first argument), or insert the fact if no match is found. All existing facts matching the functor and first argument are removed before the new fact is asserted. The tool always succeeds, even when inserting a new fact.

**Annotations:**
- Read-only: ✗
- Idempotent: ✓
- Non-destructive: ✗
- Atomic: ✓

### Request

```json
{
  "jsonrpc": "2.0",
  "id": 13,
  "method": "tools/call",
  "params": {
    "name": "upsert_fact",
    "arguments": {
      "fact": "deploy(prod, v2)"
    }
  }
}
```

### Input Schema

```json
{
  "type": "object",
  "properties": {
    "fact": {
      "type": "string",
      "description": "A Prolog fact to insert or update (e.g. \"deploy(prod, v2)\")"
    }
  },
  "required": ["fact"]
}
```

### Response (Success - Inserted)

When the fact is new and no match exists:

```json
{
  "jsonrpc": "2.0",
  "id": 13,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Inserted: deploy(prod, v2)"
      }
    ]
  }
}
```

### Response (Success - Updated)

When one or more matching facts are replaced:

```json
{
  "jsonrpc": "2.0",
  "id": 13,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Updated: deploy(prod, v1) → deploy(prod, v2)"
      }
    ]
  }
}
```

### Response (Error - Invalid Arguments)

If the `fact` argument is missing, null, or empty:

```json
{
  "jsonrpc": "2.0",
  "id": 13,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "InvalidArguments",
        "isError": true
      }
    ]
  }
}
```
