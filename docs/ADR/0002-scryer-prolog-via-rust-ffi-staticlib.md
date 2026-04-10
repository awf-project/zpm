# 0002: Scryer-Prolog Integration via Rust FFI Static Library

## Status

Accepted

## Date

2026-04-10

## Context

F002 requires a Prolog inference engine inside zpm. Three approaches were evaluated:

1. **Rust FFI static library** — compile scryer-prolog into a `.a` artifact via a thin Rust crate exposing `extern "C"` functions; link it into the Zig binary at build time.
2. **Subprocess invocation** — spawn a scryer-prolog process per query, communicate over stdin/stdout.
3. **Pure Zig Prolog** — implement a WAM or resolution engine from scratch in Zig.

The latency target is **<5 ms per query**. The project is written in Zig and has a single existing dependency (`mcp.zig`). There is no production-ready Prolog engine written in Zig; scryer-prolog is a mature, ISO-compliant Prolog implemented in Rust.

## Candidates

| Option | Pros | Cons |
|--------|------|------|
| Rust FFI static library (scryer-prolog) | <1 ms call overhead; ISO-complete; battle-tested | Two toolchains; large binary; Rust/Zig boundary discipline |
| Subprocess invocation (scryer-prolog CLI) | No FFI complexity; language isolation | 50-200 ms spawn latency; process lifecycle overhead |
| Pure Zig Prolog engine | Single toolchain; smallest binary | Multi-month effort; no production WAM exists in Zig |
| Trealla-Prolog (C library) | Simpler C FFI from Zig | Less ISO-complete than scryer-prolog; smaller community |

## Decision

Integrate scryer-prolog as a **Rust static library** linked into the Zig binary, via a thin FFI crate at `ffi/zpm-prolog-ffi/`.

Specifically:

- **FFI boundary**: The Rust crate exposes `extern "C"` functions (`prolog_init`, `prolog_deinit`, `prolog_query`, `prolog_assert`, `prolog_retract`, `prolog_load_file`, `prolog_load_string`). No complex C structs cross the boundary — all results are serialized to JSON strings and returned as heap-allocated `*mut c_char`.
- **Build integration**: `build.zig` invokes `cargo build --release` and links the resulting `.a` artifact. Zig's build system owns the full pipeline.
- **Zig wrapper**: A single module `src/prolog/engine.zig` wraps the FFI with idiomatic Zig error handling, memory management via GPA, and JSON deserialization into Zig-native types.
- **Sandboxing**: Query timeouts, recursion limits, and memory limits are enforced in the Zig layer via thread-based cancellation, not inside the Rust crate.
- **Engine shape**: Monolithic `engine.zig` (not split into `types.zig` + `ffi.zig`) to honor the project's flat module structure principle.

## Consequences

### Positive

- **Latency**: In-process FFI call overhead is <1 ms — subprocess spawn (50–200 ms) ruled out for the <5 ms target.
- **Correctness**: scryer-prolog is ISO-compliant and battle-tested. No risk of building an incomplete WAM.
- **Clean boundary**: JSON serialization over the FFI boundary eliminates manual memory coordination between Rust's global allocator and Zig's GPA. Each side owns its memory; the Zig layer frees C strings with `prolog_free_string`.
- **Incremental adoption**: The thin crate design means the Rust surface area stays minimal — it is a shim, not a framework.

### Negative

- **Two build toolchains**: `cargo` and `zig` must both be present. CI and Docker images must install Rust. Build time increases by the Rust compile step (~60–90 s cold, cached thereafter).
- **Binary size**: scryer-prolog is a large crate. Binary target is ≤20 MB; this may require LTO and stripping, and could still exceed the target.
- **Language boundary complexity**: Memory ownership conventions across the C ABI require discipline. Any future contributor must understand both sides.
- **scryer-prolog as runtime lock-in**: Replacing the Prolog engine later (e.g., with trealla-prolog or a Zig-native engine) requires rewriting `engine.zig` and the FFI crate — a significant but bounded effort since the boundary is thin.

### Risks

| Risk | Likelihood | Severity | Mitigation |
|---|---|---|---|
| scryer-prolog does not compile to `staticlib` | Medium | P0 | Verify in spike before full implementation |
| Binary exceeds 20 MB | Medium | P1 | Enable LTO, strip debug symbols; accept if necessary |
| Rust/Zig allocator mismatch causes double-free | Low | P0 | All FFI strings freed via `prolog_free_string`; never freed from Zig allocator |
| cargo not available in CI | Low | P1 | Add Rust toolchain step to `.github/workflows/ci.yaml` |

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Subprocess invocation | 50–200 ms spawn latency per query violates the <5 ms target; process lifecycle management adds complexity |
| Pure Zig Prolog engine | No production-ready WAM in Zig exists; building one is a multi-month effort outside F002 scope |
| Trealla-Prolog (C library) | C FFI from Zig is simpler than Rust FFI, but trealla-prolog is less ISO-complete than scryer-prolog; revisit if scryer staticlib proves intractable |

## Constitution Compliance

| Principle | Status | Justification |
|-----------|--------|---------------|
| Use `mcp.zig` types directly — no wrapper abstractions | N/A | F002 adds no MCP tools; engine module is independent of MCP layer |
| Flat module structure | Compliant | Single `src/prolog/engine.zig` file; no premature splits |
| Inline tests in every module | Compliant | `engine.zig` contains inline tests for all engine functionality |
| Tool handlers in `src/tools/` | N/A | No new tools in F002; deferred to F003 |
