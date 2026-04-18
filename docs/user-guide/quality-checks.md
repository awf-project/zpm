---
title: "Quality Checks: Verify Consistency and Explain Reasoning"
---


This guide shows how to detect knowledge base contradictions and justify conclusions using the supervision tools.

## Verify Consistency: Catch Contradictions

Use `verify_consistency` to run integrity checks against your knowledge base before making decisions.

### Basic Usage

Define integrity rules that catch problematic situations:

```bash
# Step 1: Define an integrity rule
define_rule head='integrity_violation(User)' body='admin(User), not_reviewed(User)'

# Step 2: Assert facts that might violate it
remember_fact fact='admin(alice)'
remember_fact fact='not_reviewed(alice)'

# Step 3: Check for violations
verify_consistency
# Returns: {"violations":["alice"]}
```

The tool queries all predicates named `integrity_violation/N` and returns the results. Each violation includes the term that matched the rule head.

### Scoped Checks

Check only a specific domain without scanning the entire knowledge base:

```bash
# Define rules for multiple domains
define_rule head='integrity_violation(deployment, Env)' body='untested(Env), in_production(Env)'
define_rule head='integrity_violation(access, User)' body='external_user(User), has_admin(User)'

# Check only deployment rules
verify_consistency scope='deployment'
# Returns violations for deployment domain only
```

## Explain Why: Justify Conclusions

Use `explain_why` to show the reasoning chain that led to a specific conclusion.

### Basic Usage

Trace how a fact was derived:

```bash
# Assert facts and rules
remember_fact fact='human(socrates)'
define_rule head='mortal(X)' body='human(X)'

# Explain why socrates is mortal
explain_why fact='mortal(socrates)'
# Returns proof tree showing:
#   mortal(socrates) :-
#     human(socrates)  [fact]
```

### Multi-Level Reasoning

Explain complex deductions across multiple rule applications:

```bash
# Define a chain of rules
remember_fact fact='parent(john, jane)'
remember_fact fact='parent(jane, bob)'
define_rule head='ancestor(X, Y)' body='parent(X, Y)'
define_rule head='ancestor(X, Y)' body='parent(X, Z), ancestor(Z, Y)'

# Explain a multi-level conclusion
explain_why fact='ancestor(john, bob)'
# Returns full proof tree with all intermediate steps
```

### Depth Limits

For deeply nested proofs, limit the tree depth to keep output manageable:

```bash
# Get only the first 3 levels of reasoning
explain_why fact='ancestor(john, bob)' max_depth=3
# Returns proof tree truncated at depth 3 with truncation marker
```

## Workflow: Build a Guardrail

Combine both tools to validate decisions:

```bash
# 1. Define your domain knowledge and constraints
define_rule head='risky(Deploy)' body='untested(Deploy), in_production(Deploy)'
define_rule head='integrity_violation(deployment, Deploy)' body='risky(Deploy)'

# 2. Assert the current state
remember_fact fact='untested(v3)'
remember_fact fact='in_production(v3)'

# 3. Verify consistency before proceeding
verify_consistency
# Returns violations indicating the deployment is risky

# 4. Explain why the violation occurred
explain_why fact='risky(v3)'
# Returns proof tree showing: v3 is risky because it's untested AND in production
```

## Common Patterns

### Pattern: Constraint Checking

Define what should never happen together:

```prolog
integrity_violation(State) :- 
  status(State, open), 
  status(State, closed).
```

### Pattern: Completeness Checking

Ensure required data is present:

```prolog
integrity_violation(Feature) :- 
  planned_feature(Feature), 
  \+ has_owner(Feature).
```

### Pattern: Consistency Checking

Ensure derived facts match explicit assertions:

```prolog
integrity_violation(User) :- 
  can_access(User, Resource), 
  not_permitted(User, Resource).
```

## Response Format

### verify_consistency Response

Success (with violations):
```json
{
  "violations": ["term1", "term2"]
}
```

Success (no violations):
```json
{
  "violations": []
}
```

### explain_why Response

Fact proven:
```json
{
  "fact": "mortal(socrates)",
  "proven": true,
  "proof_tree": {
    "goal": "mortal(socrates)",
    "rule_applied": "mortal(X) :- human(X)",
    "children": [
      {
        "goal": "human(socrates)",
        "rule_applied": "fact",
        "children": []
      }
    ]
  }
}
```

Fact not proven:
```json
{
  "fact": "mortal(socrates)",
  "proven": false,
  "proof_tree": null
}
```

## Error Handling

If `explain_why` receives an invalid Prolog term:
```json
{
  "fact": "invalid(input",
  "is_error": true
}
```

If the knowledge base is unavailable:
```json
{
  "is_error": true,
  "message": "ExecutionFailed"
}
```

## See Also

- [MCP Tools Reference](../reference/mcp-tools.md) — Full tool specifications
- [Prolog Engine Reference](../reference/prolog-engine.md) — Query syntax and semantics
