---
title: "Rename Predicates Safely"
---

This guide shows how to atomically rename a Prolog functor across your knowledge base using the `rename_predicate` tool. Unlike manual find-and-replace, this operation preserves the Truth Maintenance System (TMS) and ensures consistency across all facts, rules, and assumptions.

## Why Atomic Rename Matters

When evolving your knowledge base schema, you might need to rename a predicate. Manual approaches are error-prone:

- Renaming facts without updating rules leaves stale references
- Forgetting to update TMS assumptions can break belief tracking
- Partial renames leave your KB in an inconsistent state

The `rename_predicate` tool handles all of this in a single atomic operation.

## Basic Rename in a Single Memory

Use `rename_predicate` to rename a functor within the `default` memory:

```bash
# Step 1: Populate the knowledge base
zpm remember-fact --fact "task_status(f024, in_progress)"
zpm remember-fact --fact "task_status(f025, done)"
zpm define-rule --head "active_work(X)" --body "task_status(X, in_progress)"

# Step 2: Preview the change (dry run)
zpm rename-predicate --old_functor task_status --new_functor feature_status --arity 2 --dry_run true

# Step 3: Apply the rename
zpm rename-predicate --old_functor task_status --new_functor feature_status --arity 2

# Step 4: Verify the change
zpm query-logic --goal "feature_status(X, Y)"
# Returns: feature_status(f024, in_progress), feature_status(f025, done)

zpm query-logic --goal "task_status(X, Y)"
# Returns: (empty - old functor no longer exists)
```

## Understanding Rename Scope

The `rename_predicate` tool renames a functor in:

- All **facts** matching `old_functor/arity`
- All **rule bodies** that mention `old_functor/arity`
- All **TMS assumptions** whose justifications reference `old_functor/arity`
- Optionally, all **cross-memory references** (e.g., `other_segment:old_functor/arity`)

### Single Arity vs. All Arities

If you have multiple arities of the same functor, you must specify which one to rename:

```bash
# Before: both task_status/1 and task_status/2 exist
zpm remember-fact --fact "task_status(pending)"          # task_status/1
zpm remember-fact --fact "task_status(f024, done)"       # task_status/2

# Rename only task_status/2 → feature_status/2
zpm rename-predicate --old_functor task_status --new_functor feature_status --arity 2

# Now:
#   task_status/1 still exists
#   feature_status/2 exists (renamed from task_status/2)
```

If you omit the `arity` parameter and multiple arities exist, the operation fails:

```bash
# This fails with an error listing the detected arities
zpm rename-predicate --old_functor task_status --new_functor feature_status
# Error: ambiguous arity; detected task_status/1 and task_status/2
```

## Dry Run: Preview Before Applying

Always use `--dry_run true` to preview the impact without changing the KB:

```bash
zpm rename-predicate \
  --old_functor task_status \
  --new_functor feature_status \
  --arity 2 \
  --dry_run true

# Returns:
# {
#   "renamed_facts": 2,
#   "rewritten_rule_bodies": 1,
#   "affected_rule_ids": ["active_work(X)"],
#   "cross_memory_impact": {
#     "rewritten": [],
#     "skipped_readonly": [],
#     "warnings": []
#   }
# }
```

The dry run reports:
- **renamed_facts**: count of facts that would be renamed
- **rewritten_rule_bodies**: count of rules whose bodies mention the old functor
- **affected_rule_ids**: list of rule heads that would be updated
- **cross_memory_impact**: impact on other mounted memory segments (see below)

The KB is **not modified** during a dry run.

## Preserve TMS Assumptions

When assumptions reference the old functor, they are automatically updated:

```bash
# Create an assumption tied to task_status
zpm assume-fact --assumption sprint_4 --fact "task_status(f024, in_progress)"

# Check the assumption
zpm get-justification --assumption sprint_4
# Returns: [{"fact": "task_status(f024, in_progress)", "assumption": "sprint_4"}]

# Rename the predicate
zpm rename-predicate --old_functor task_status --new_functor feature_status --arity 2

# The assumption identifier is unchanged
zpm get-justification --assumption sprint_4
# Returns: [{"fact": "feature_status(f024, in_progress)", "assumption": "sprint_4"}]
```

The assumption name stays the same, but its justification is updated to reference the new functor.

## Rename in a Specific Memory

To rename a functor in a non-default memory segment:

```bash
# Create and mount a memory
zpm memory create audit_log
zpm memory mount audit_log

# Add facts to the audit_log memory
zpm remember-fact --memory audit_log --fact "check_result(f024, pass)"
zpm remember-fact --memory audit_log --fact "check_result(f025, fail)"

# Rename within audit_log
zpm rename-predicate \
  --memory audit_log \
  --old_functor check_result \
  --new_functor test_result \
  --arity 2
```

## Cross-Memory Propagation

When using multiple memory segments (see [Memory Segments](memory-segments.md)), one memory might reference a predicate from another memory using qualified notation:

```bash
# default memory: define a predicate
zpm remember-fact --fact "task_status(f024, done)"

# audit memory: reference the default memory's predicate
zpm memory create audit
zpm memory mount audit
zpm define-rule \
  --memory audit \
  --head "audit_status(X)" \
  --body "default:task_status(X, done)"
```

### Preview Cross-Memory Impact

The dry run always reports the full cross-memory impact, even if you don't propagate:

```bash
zpm rename-predicate \
  --old_functor task_status \
  --new_functor feature_status \
  --arity 2 \
  --dry_run true

# Returns:
# {
#   "renamed_facts": 1,
#   "rewritten_rule_bodies": 0,
#   "affected_rule_ids": [],
#   "cross_memory_impact": {
#     "rewritten": [],
#     "warnings": [
#       {
#         "memory": "audit",
#         "refs": 1,
#         "reason": "propagate_cross_memory_refs=false"
#       }
#     ],
#     "skipped_readonly": []
#   }
# }
```

The `warnings` section lists writable segments that contain references to the old functor but will NOT be modified (because `propagate_cross_memory_refs=false`).

### Apply Cross-Memory Propagation

To rename the functor everywhere it's referenced, including in other writable memories:

```bash
zpm rename-predicate \
  --old_functor task_status \
  --new_functor feature_status \
  --arity 2 \
  --propagate_cross_memory_refs true

# Now audit's rule body is rewritten to:
#   "audit_status(X)" :- "default:feature_status(X, done)"
```

The response reports which segments were updated:

```json
{
  "renamed_facts": 1,
  "rewritten_rule_bodies": 0,
  "affected_rule_ids": [],
  "cross_memory_impact": {
    "rewritten": [
      {
        "memory": "audit",
        "rules_updated": 1
      }
    ],
    "warnings": [],
    "skipped_readonly": []
  }
}
```

### Read-Only Memories are Always Skipped

If a read-only memory contains references to the old functor, it is never modified, but reported in the response:

```bash
# Mount a memory as read-only
zpm memory create archive --scope global
zpm memory mount archive --mode ro

# archive contains a rule referencing task_status, but it won't be updated
zpm rename-predicate \
  --old_functor task_status \
  --new_functor feature_status \
  --arity 2 \
  --propagate_cross_memory_refs true

# Returns:
# {
#   "cross_memory_impact": {
#     "rewritten": [...],
#     "warnings": [],
#     "skipped_readonly": [
#       {
#         "memory": "archive",
#         "refs": 1,
#         "reason": "read-only"
#       }
#     ]
#   }
# }
```

The operation succeeds, but the read-only segment is left as-is.

## Safety Guardrails

### Blacklisted Functors

You cannot rename ISO Prolog operators, even if they theoretically exist in your KB:

```bash
# These will fail immediately:
zpm rename-predicate --old_functor = --new_functor equals --arity 2
# Error: cannot rename built-in operator =/2

zpm rename-predicate --old_functor is --new_functor equals --arity 2
# Error: cannot rename built-in operator is/2
```

### Collision Detection

You cannot rename a functor to a name that already exists:

```bash
# Before
zpm remember-fact --fact "task_status(f024, done)"
zpm remember-fact --fact "feature_status(f025, done)"

# This fails (feature_status/2 already exists)
zpm rename-predicate \
  --old_functor task_status \
  --new_functor feature_status \
  --arity 2
# Error: feature_status/2 already exists
```

To rename to an existing name, you must first rename or delete the conflicting predicate.

### No Self-Renames

Renaming a functor to itself is rejected:

```bash
zpm rename-predicate \
  --old_functor task_status \
  --new_functor task_status \
  --arity 2
# Error: old_functor and new_functor are identical
```

## Workflow: Safe Schema Evolution

1. **Survey the KB**:
   ```bash
   zpm find-predicate-references --functor old_name --arity 2
   ```
   Review which rules and assumptions depend on the predicate.

2. **Plan the rename**:
   - Decide on the new functor name
   - Check if other memories reference this predicate
   - Decide whether to propagate changes across memories

3. **Dry run**:
   ```bash
   zpm rename-predicate \
     --old_functor old_name \
     --new_functor new_name \
     --arity 2 \
     --dry_run true
   ```
   Review the counts and affected rules. Ensure no unexpected rules are impacted.

4. **Create a snapshot** (optional):
   ```bash
   zpm save-snapshot --name "before-rename"
   ```

5. **Apply the rename**:
   ```bash
   zpm rename-predicate \
     --old_functor old_name \
     --new_functor new_name \
     --arity 2
   ```

6. **Verify**:
   ```bash
   zpm query-logic --goal "new_name(X, Y)"
   zpm query-logic --goal "old_name(X, Y)"  # Should return empty
   ```

## Error Messages

### Ambiguous Arity

When multiple arities exist and you don't specify one:

```json
{
  "is_error": true,
  "message": "Ambiguous arity for task_status; detected arities: 1, 2. Specify arity parameter."
}
```

**Fix**: Provide the `--arity` parameter.

### Collision Error

When the target name already exists:

```json
{
  "is_error": true,
  "message": "Cannot rename: feature_status/2 already exists in memory 'default'"
}
```

**Fix**: First rename or delete the conflicting predicate.

### Read-Only Memory

When the target memory is mounted read-only:

```json
{
  "is_error": true,
  "message": "Cannot rename in read-only memory: archive"
}
```

**Fix**: Remount the memory in read-write mode, or rename in a different memory.

### Blacklisted Functor

When trying to rename a built-in operator:

```json
{
  "is_error": true,
  "message": "Cannot rename ISO operator: =/2"
}
```

**Fix**: Choose a different functor name.

## See Also

- [Find Predicate References](predicate-references.md) — Locate all usage sites before renaming
- [Schema Discovery](schema-discovery.md) — Explore all predicates in the knowledge base
- [Memory Segments](memory-segments.md) — Work with multiple isolated knowledge domains
- [Truth Maintenance System](truth-maintenance.md) — Understand how assumptions are updated
- [MCP Tools Reference](../reference/mcp-tools.md) — Full tool specifications
