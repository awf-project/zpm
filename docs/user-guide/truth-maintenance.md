---
title: "Truth Maintenance System: Manage Assumptions and Beliefs"
---


The Truth Maintenance System (TMS) in zpm enables you to assert facts as named assumptions and automatically manage dependencies when assumptions change. This is essential for non-monotonic reasoning where beliefs must be retracted or updated based on changing assumptions.

## Core Concepts

### Assumptions

An **assumption** is a named, retractable basis for one or more beliefs. When you assert a fact as an assumption, zpm tracks which assumption supports it. If you later retract that assumption, all beliefs dependent solely on it are automatically removed from the knowledge base.

### Justifications

A **justification** is a metadata link between a fact and the assumption that supports it. zpm records these internally using `tms_justification(Fact, AssumptionName)` predicates, allowing it to determine which facts depend on which assumptions.

### Multi-Support

A fact can be supported by **multiple assumptions**. When one assumption is retracted, facts supported by other assumptions persist. For example:
- Assumption `"network_online"` supports `reachable(server)`
- Assumption `"cache_fresh"` also supports `reachable(server)`
- If you retract `"network_online"`, `reachable(server)` survives because `"cache_fresh"` still supports it

## Working with Assumptions

### Step 1: Assert a Fact as an Assumption

Use `assume_fact` to introduce a belief backed by a named assumption:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "assume_fact",
    "arguments": {
      "assumption": "sensor_reading_valid",
      "fact": "temperature(room_a, 22.5)"
    }
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "type": "text",
    "text": "assume_fact: assumption 'sensor_reading_valid' supports fact 'temperature(room_a, 22.5)'"
  }
}
```

The fact is now asserted in the knowledge base, and its justification is recorded. You can derive other facts from it using rules:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {
    "name": "define_rule",
    "arguments": {
      "head": "comfortable_temp(Room)",
      "body": "temperature(Room, T), T > 20, T < 26"
    }
  }
}
```

Now `query_logic` can derive `comfortable_temp(room_a)` because the underlying assumption supports it.

### Step 2: Query Belief Status

Check whether a belief is currently supported and why:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "get_belief_status",
    "arguments": {
      "fact": "comfortable_temp(room_a)"
    }
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "type": "text",
    "text": "{\"status\": \"in\", \"justifications\": [\"sensor_reading_valid\"]}"
  }
}
```

If the belief is not supported by any assumption, `status` is `"out"` and `justifications` is empty.

### Step 3: List Active Assumptions

See all currently active assumptions and their supported facts:

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "tools/call",
  "params": {
    "name": "list_assumptions",
    "arguments": {}
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "type": "text",
    "text": "{\"assumptions\": [{\"name\": \"sensor_reading_valid\", \"facts\": [\"temperature(room_a, 22.5)\"]}]}"
  }
}
```

### Step 4: Retract an Assumption

When an assumption no longer holds, retract it:

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "tools/call",
  "params": {
    "name": "retract_assumption",
    "arguments": {
      "assumption": "sensor_reading_valid"
    }
  }
}
```

**Response (Success):**
```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "result": {
    "type": "text",
    "text": "Retracted assumption 'sensor_reading_valid': 1 fact(s) removed"
  }
}
```

**Automatic Propagation:** After retraction, zpm removes all facts that depended solely on that assumption from the knowledge base and journals the retraction. Derived facts that relied on those removed facts are no longer derivable. In this example, `comfortable_temp(room_a)` would no longer be derivable because its supporting fact `temperature(room_a, 22.5)` was retracted.

**Response (Error - Unknown Assumption):**

If you attempt to retract an assumption that does not exist:

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "result": {
    "type": "text",
    "text": "Unknown assumption 'nonexistent_assumption'",
    "isError": true
  }
}
```

No facts are removed and no WAL entry is written when an assumption is unknown.

### Step 5: Bulk Retract by Pattern

If you have many related assumptions (e.g., from the same reasoning session), retract them all at once using a glob pattern:

```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "method": "tools/call",
  "params": {
    "name": "retract_assumptions",
    "arguments": {
      "pattern": "session_1_*"
    }
  }
}
```

This retracts all assumptions matching the pattern `session_1_*` (e.g., `session_1_a`, `session_1_b`) and propagates their removal throughout the knowledge base.

## Handling Multi-Support

When a fact is supported by multiple assumptions, TMS ensures it survives retraction of any single assumption:

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "tools/call",
  "params": {
    "name": "assume_fact",
    "arguments": {
      "assumption": "backup_reading",
      "fact": "temperature(room_a, 22.5)"
    }
  }
}
```

Now `temperature(room_a, 22.5)` is supported by both `"sensor_reading_valid"` and `"backup_reading"`. When you retract one:

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "method": "tools/call",
  "params": {
    "name": "retract_assumption",
    "arguments": {
      "assumption": "sensor_reading_valid"
    }
  }
}
```

The fact persists because `"backup_reading"` still supports it. The response shows an empty retracted facts list:

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "result": {
    "type": "text",
    "text": "retract_assumption: removed assumption 'sensor_reading_valid' and retracted facts: []"
  }
}
```

## Querying Assumption Justifications

Find all facts supported by a specific assumption:

```json
{
  "jsonrpc": "2.0",
  "id": 9,
  "method": "tools/call",
  "params": {
    "name": "get_justification",
    "arguments": {
      "assumption": "backup_reading"
    }
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 9,
  "result": {
    "type": "text",
    "text": "{\"facts\": [\"temperature(room_a, 22.5)\"]}"
  }
}
```

## Important Notes

### Non-TMS Facts Are Protected

If you assert a fact directly using `remember_fact` (without an assumption), it is never retracted by the TMS:

```json
{
  "jsonrpc": "2.0",
  "id": 10,
  "method": "tools/call",
  "params": {
    "name": "remember_fact",
    "arguments": {
      "fact": "always_true"
    }
  }
}
```

Even if you retract all assumptions, `always_true` persists because it has no justification record.

### Assumption Names Are Constrained

Assumption names must be valid Prolog atoms:
- Must start with a lowercase letter
- May contain letters, digits, and underscores: `[a-z][a-zA-Z0-9_]*`
- Examples: `assumption_1`, `network_check`, `user_preference`
- Invalid: `1st_assumption` (starts with digit), `My_Assumption` (starts with uppercase)

### Rules Are Not Assumption-Managed

The `assume_fact` tool only accepts facts, not rules. You cannot assert a rule (containing `:-`) as an assumption. Rules should be defined separately using `define_rule`.

## Workflow Example

Here's a complete workflow using the TMS:

1. **Assert initial beliefs as assumptions:**
   ```json
   {"method": "tools/call", "params": {"name": "assume_fact", "arguments": {"assumption": "env_prod", "fact": "environment(prod)"}}}
   {"method": "tools/call", "params": {"name": "assume_fact", "arguments": {"assumption": "feature_enabled", "fact": "feature(auto_scaling)"}}}
   ```

2. **Define inference rules:**
   ```json
   {"method": "tools/call", "params": {"name": "define_rule", "arguments": {"head": "can_scale", "body": "environment(prod), feature(auto_scaling)"}}}
   ```

3. **Check derived beliefs:**
   ```json
   {"method": "tools/call", "params": {"name": "get_belief_status", "arguments": {"fact": "can_scale"}}}
   ```
   → Response: `{"status": "in", "justifications": ["env_prod", "feature_enabled"]}`

4. **Disable a feature:**
   ```json
   {"method": "tools/call", "params": {"name": "retract_assumption", "arguments": {"assumption": "feature_enabled"}}}
   ```
   → `can_scale` is no longer derivable

5. **Audit current assumptions:**
   ```json
   {"method": "tools/call", "params": {"name": "list_assumptions", "arguments": {}}}
   ```
   → Shows only `env_prod` remains active

## See Also

- [Quality Checks](quality-checks.md) — Verify consistency after assumption changes
- [Fact Deletion](fact-deletion.md) — Manual fact retraction (contrasts with automatic TMS propagation)
- [MCP Tools Reference](../reference/mcp-tools.md) — Complete tool documentation
