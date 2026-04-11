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

## Future Tools

The following tools are planned for future releases:

- **forget_fact** — Remove facts from the knowledge base
- **clear_context** — Clear all facts from the knowledge base

See [Roadmap](../../README.md#roadmap) for details.
