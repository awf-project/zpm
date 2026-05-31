# 0006: Per-segment Prolog engines for memory isolation

**Status**: Accepted
**Date**: 2026-05-31
**Supersedes**: N/A
**Superseded by**: N/A

## Context

Memory segments (named knowledge bases mounted alongside the `default` memory)
were originally implemented as Prolog **modules inside a single shared engine**.
A fact written to segment `seg` was stored as `seg:fact(...)`, and tools
qualified clauses/goals with the `mod:` prefix to scope reads and writes.

Bug B001 (zpm #54) reported that `clear_context --memory seg` did not clear the
segment: `retractall(seg:foo(_))` silently cleared the `user` (default) module
instead of `seg`, and left the segment untouched.

A read-only spike (`engine.zig`, 2026-05-30) tested every plausible
module-qualified retract workaround in the shared engine — `abolish(seg:F/A)`,
`seg:abolish(F/A)`, `retract(seg:H)`, `seg:retractall(H)`, and a
snapshot-rebuild via `abolish` + re-assert. **None** produced the correct
outcome (segment emptied, default intact). Worse, the results were internally
inconsistent: some forms wiped the default module, and module-qualified
`abolish`/assert/query themselves behaved unreliably. The conclusion is that the
`mod:`-qualified clause-database operations are broken in this Trealla build, not
just `retractall`. The shared-engine + module-prefix model therefore cannot
satisfy B001 by any goal-string fix.

The forces:
- **B001 (must fix)** requires segment-scoped retract that never touches default.
- **F021** requires cross-memory reads (query `seg:goal` from anywhere).
- **F025** requires cross-memory rename propagation and, in one test, a rule
  whose **body** resolves through another memory at solve time.

## Candidates

| Option | Pros | Cons |
|--------|------|------|
| A. Keep shared engine, fix `retractAll` | Preserves F021/F025 as-is; minimal surface | Spike proved impossible in this Trealla build — module retract/assert/query all unreliable. Does not fix B001. |
| B. One dedicated engine per segment | B001 fixed cleanly; engines are fully isolated databases; retract is local and correct | Cross-memory operations no longer "just work" via `mod:` prefixes; rule **bodies** that resolve through another memory at solve time become impossible |
| C. Hybrid: per-segment writes + copy facts across engines per query | Could emulate cross-memory rule bodies | Re-introduces the coupling B001 removes; copied clauses are retractable by mistake (the exact B001 failure); high complexity |

## Decision

**Adopt Option B: each mounted segment owns a dedicated `Engine`.**

- `MemoryEntry` gains an owned `engine: *Engine` (and `owns_engine: bool`). The
  `default` memory references the global engine **without** owning it
  (`mountShared`); named segments create and own their engine (`mount`).
- Clauses are stored **UNQUALIFIED** in each segment's engine. `qualifyClause`
  becomes an identity (kept as a stable seam). `getEngineForMemory(name)`
  resolves the engine backing a memory.
- Memory-aware tool handlers resolve their engine via the target memory instead
  of the global `context.getEngine()`.

To preserve the operations that **decompose** — i.e. where *our code* drives the
traversal of memories rather than the Prolog solver:
- **Cross-memory reads (F021)** are recovered by `context.routeGoalByModule`: a
  goal with a leading `mod:` prefix matching a mounted segment is routed to that
  segment's engine and run unqualified. This keeps `query_logic
  feature_auth:task_status(X)` working.
- **Rename propagation (F025)** keeps working: our code iterates the mounted
  engines and rewrites each independently.

The single capability that **cannot** be preserved is a rule whose **body**
resolves a goal in another memory at solve time (e.g. a rule in `audit` with body
`default:task_status(X)`). Resolution happens inside one engine's solver, which
has no access to another engine's clauses, and we cannot step into the middle of
a `query` to fetch them. This is **deprecated**.

## Consequences

**What becomes easier:**
- `clear_context`, `forget_fact`, `retractAll` on a segment are correct and
  local — B001 is fixed and locked by engine-level + handler-level tests.
- Each memory is a genuine sandbox; no module-prefix bookkeeping, no cross-talk.
- Cross-memory reads and bulk operations remain available through explicit
  per-engine iteration in our code.

**What becomes harder:**
- A rule body that references another memory (`mod:goal` inside a clause body)
  no longer resolves at query time. This is the one F025 capability dropped.
- Each mounted segment now costs one live Trealla engine (memory + init time).
  Trealla's `g_tpl_count` refcount supports concurrent instances; the prior
  "process-global, no simultaneous instances" assumption was incorrect (verified
  by spike: two simultaneous engines isolate their databases correctly).

## Constitution Compliance

| Principle | Status | Justification |
|-----------|--------|---------------|
| Correctness over features | Compliant | B001 (data-loss bug: clearing a segment wiped default) outranks a single cross-memory rule-body capability. |
| Evidence before assertion | Compliant | The shared-engine dead end and the per-segment viability were both established by read-only spikes, not assumed. |
| Minimal surface | Compliant | `qualifyClause` reduced to identity; routing added as one small, well-scoped helper rather than a new abstraction layer. |
