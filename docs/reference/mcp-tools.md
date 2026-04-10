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

## Future Tools

The following tools are planned for future releases:

- **query** — Evaluate deterministic Prolog queries
- **retract** — Remove facts from the knowledge base
- **explain** — Generate proof explanations for queries

See [Roadmap](../../README.md#roadmap) for details.
