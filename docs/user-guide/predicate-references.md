---
title: "Find Predicate References: Safe Refactoring"
---

This guide shows how to locate all usage sites of a Prolog predicate before refactoring using the `find_predicate_references` tool.

## Find All References to a Predicate

Use `find_predicate_references` to locate every rule body, direct fact, assumption, and cross-memory reference involving a target predicate.

### Basic Usage

```bash
# Step 1: Populate the knowledge base
remember_fact fact='task_status(f024, in_progress)'
remember_fact fact='task_status(f025, done)'
define_rule head='active_work(X)' body='task_status(X, in_progress)'
define_rule head='completed(X)' body='task_status(X, done)'

# Step 2: Find all references to task_status
find_predicate_references functor='task_status'
# Returns references from both rules, the direct facts count, and any assumptions
```

The tool requires the `functor` argument. Optional arguments are `arity`, `memory`, and `include_cross_memory_refs`.

## Search by Functor and Arity

When you specify both functor and arity, the tool only matches predicates with that exact arity.

### Exact Arity Match

```bash
# Find only task_status/2 references (not task_status/1 if it exists)
find_predicate_references functor='task_status' arity=2

# Find all arities of task_status
find_predicate_references functor='task_status'
```

### Multiple Arities Example

```bash
# Define predicates with the same functor but different arities
remember_fact fact='status(f024)'           # status/1
remember_fact fact='status(f024, done)'     # status/2

# Search for status/1 only
find_predicate_references functor='status' arity=1
# Returns: direct_facts_count: 1 (only the status/1 fact)

# Search for all status predicates
find_predicate_references functor='status'
# Returns: direct_facts_count: 2 (both status/1 and status/2 facts)
```

## Understand the Response

The response includes multiple sections:

| Section | Content | Use Case |
|---------|---------|----------|
| `rules` | All rules whose body mentions the predicate | Identify rules that depend on the predicate |
| `direct_facts_count` | Count of matching facts | See how many ground facts exist |
| `facts_referenced_in_assumptions` | TMS assumptions referencing the predicate | Know which hypotheses reference it |
| `cross_memory_refs` | Module-qualified references from other memory segments | Detect external dependencies |

### Example Response

```bash
find_predicate_references functor='task_status' arity=2

# Returns (formatted):
# {
#   "target": "task_status/2",
#   "memory": "default",
#   "rules": [
#     {"head": "active_work(X)", "body": "task_status(X, in_progress)", "memory": "default"},
#     {"head": "completed(X)", "body": "task_status(X, done)", "memory": "default"}
#   ],
#   "direct_facts_count": 2,
#   "facts_referenced_in_assumptions": [],
#   "cross_memory_refs": []
# }
```

## Workflow: Safe Refactoring

Before renaming a predicate or changing its arity, always consult `find_predicate_references` to identify all places that need updating:

```bash
# 1. Discover all references
find_predicate_references functor='old_name' arity=2

# 2. Review the rules and facts returned
# (in the response: check all entries in "rules" and direct_facts_count)

# 3. Rename the predicate using rename_predicate (future feature)
# or manually:
#   - Retract old facts and rules
#   - Assert new facts and rules with updated name

# 4. Verify the refactor is complete
find_predicate_references functor='old_name' arity=2
# Should now return: direct_facts_count: 0, empty rules, no assumptions
```

## Search Assumptions

If the knowledge base uses TMS (Truth Maintenance System) assumptions, the response includes a `facts_referenced_in_assumptions` section that shows which assumptions justify facts mentioning the predicate.

### Example with Assumptions

```bash
# Assert a fact under an assumption
assume_fact assumption='sprint_planning' fact='task_status(f024, in_progress)'

# Find all references including assumptions
find_predicate_references functor='task_status'

# The response now includes:
# "facts_referenced_in_assumptions": [
#   {"assumption": "sprint_planning", "fact": "task_status(f024, in_progress)", "memory": "default"}
# ]
```

This is crucial for understanding which hypothetical beliefs would be invalidated if you change or remove the predicate.

## Cross-Memory References

When using segmented memories (F021), the `cross_memory_refs` section surfaces module-qualified references like `other_segment:predicate(...)` from other mounted memory segments.

### Example with Multiple Memories

```bash
# Create two memory segments
memory create audit_log
memory mount audit_log

# In the default memory, define a rule
define_rule head='critical_tasks(X)' body='task_status(X, critical)'

# In the audit_log memory, define a rule that references the default memory
remember_fact fact='task_status(f024, critical)' memory=audit_log
define_rule head='verify_critical(X)' body='default:task_status(X, critical)' memory=audit_log

# Search all memories for references
find_predicate_references functor='task_status' memory='__all__'

# The response includes:
# "rules": [
#   {"head": "critical_tasks(X)", "body": "task_status(X, critical)", "memory": "default"}
# ],
# "cross_memory_refs": [
#   {"head": "verify_critical(X)", "body": "default:task_status(X, critical)", "memory": "audit_log", "qualifier": "default"}
# ]
```

## Skip Cross-Memory References

By default, module-qualified references are included in the response. To search only for same-segment references:

```bash
# Search without cross-memory references
find_predicate_references functor='task_status' memory='__all__' include_cross_memory_refs=false

# The response now omits the "cross_memory_refs" section
```

## Search a Specific Memory Segment

If you only care about references within one memory segment, specify the `memory` parameter:

```bash
# Search only the "audit" memory
find_predicate_references functor='task_status' memory='audit'

# Returns references only from the "audit" memory segment
```

## Error Handling

### Predicate Not Found

If the predicate does not exist in the knowledge base, the tool returns an empty result:

```bash
find_predicate_references functor='nonexistent'

# Returns:
# {
#   "target": "nonexistent",
#   "memory": "default",
#   "rules": [],
#   "direct_facts_count": 0,
#   "facts_referenced_in_assumptions": [],
#   "cross_memory_refs": []
# }
```

This is not an error — it confirms the predicate has no references.

### Memory Not Mounted

If you specify a memory segment that is not mounted:

```json
{
  "is_error": true,
  "message": "Memory not mounted: unknown_segment"
}
```

Check available memories with `memory list`.

### Invalid Functor

If the functor contains invalid characters or is not a valid Prolog atom:

```json
{
  "is_error": true,
  "message": "InvalidArguments"
}
```

Ensure the functor is a valid Prolog identifier (letters, digits, and underscores; starts with a lowercase letter).

## See Also

- [Schema Discovery](schema-discovery.md) — Explore all predicates in the knowledge base
- [Memory Segments](memory-segments.md) — Work with isolated knowledge domains
- [Quality Checks](quality-checks.md) — Verify consistency and explain reasoning chains
- [MCP Tools Reference](../reference/mcp-tools.md) — Full tool specifications
- [Prolog Engine Reference](../reference/prolog-engine.md) — Query syntax and semantics
