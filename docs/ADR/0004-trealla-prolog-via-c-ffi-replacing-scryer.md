---
title: "0004: Trealla Prolog via C FFI Replacing Scryer-Prolog"
---


## Status

Accepted

## Date

2026-04-19

## Supersedes

[ADR-0002](0002-scryer-prolog-via-rust-ffi-staticlib.md)

## Context

ADR-0002 chose scryer-prolog (Rust) as the Prolog backend. After 9 days of production use, several pain points emerged:

- **Build time**: Rust compilation adds 60-90 seconds to clean builds and requires a separate toolchain install.
- **GLIBC symbol patching**: The `objcopy` workaround for Rust's libc GLIBC version symbols is fragile and Linux-only.
- **Binary size**: The scryer-prolog Rust staticlib produces a ~50 MB binary.
- **Contributor friction**: Two toolchains (Zig + Rust) raise the onboarding bar.
- **CI complexity**: GitHub Actions workflows require Rust toolchain setup, `cargo fmt`, `cargo clippy`, and cross-compilation targets.

Trealla Prolog is a C99 ISO-compliant Prolog implementation that can be compiled directly by Zig's built-in C compiler, eliminating all Rust dependencies.

## Candidates

| Option | Pros | Cons |
|--------|------|------|
| Keep scryer-prolog (Rust FFI) | Battle-tested; already working; full ISO compliance | Two toolchains; slow builds; GLIBC patching; large binary |
| Trealla Prolog (C99 FFI) | Single toolchain (Zig compiles C); fast builds; small binary; ISO compliant | Requires C compatibility wrapper; less community than scryer |
| Pure Zig Prolog engine | Ideal single-toolchain story | Multi-month effort; no production WAM in Zig exists |

## Decision

Replace scryer-prolog with Trealla Prolog, vendored as a git submodule at `ffi/trealla/` and compiled via Zig's built-in C compiler.

Specifically:

- **C compatibility wrapper**: A `ffi/trealla-wrapper.c` file exposes the same 9 `prolog_*` C-ABI functions that `ffi.zig` declares, translating between Trealla's native API (`pl_create`, `pl_eval`, `pl_consult`, `pl_destroy`) and the existing interface. This means `ffi.zig`, `engine.zig`, all 24 tool handlers, and all 190+ tests need zero changes.
- **JSON format translation**: The C wrapper transforms Trealla's per-solution output into the JSON array format `[{bindings}, ...]` that `engine.zig:parseQueryResult()` expects, maintaining full compatibility.
- **Build integration**: `build.zig` compiles Trealla's C source files via `addCSourceFiles()`. No Cargo, no `objcopy`, no OpenSSL linkage.
- **Submodule pinning**: Trealla source is pinned to a specific commit via git submodule for reproducible builds.
- **Compilation flags**: Trealla is compiled with `-DUSE_OPENSSL=0 -DUSE_FFI=0` for a minimal ISO Prolog core.

## Consequences

### What becomes easier

- **Single toolchain**: Only Zig >= 0.15.2 required to build. No Rust, no Cargo, no system OpenSSL.
- **Faster builds**: Clean build time reduced by ~50% (no Rust compilation step).
- **Simpler CI**: No Rust toolchain setup, no `cargo fmt`/`cargo clippy` steps, no cross-compilation target matrix.
- **Smaller binary**: Trealla is ~50K lines of C99 vs scryer-prolog's ~200K lines of Rust.
- **Cross-compilation**: Zig's built-in C compiler handles cross-compilation natively (`-Dtarget=aarch64-linux-gnu`).

### What becomes harder

- **Trealla version updates**: Must update git submodule and verify C wrapper compatibility.
- **C wrapper maintenance**: The compatibility wrapper (~200 lines) must be updated if Trealla's API changes.

## Constitution Compliance

| Principle | Status | Justification |
|-----------|--------|---------------|
| Flat module structure | Compliant | Trealla wrapper lives in `ffi/`, no new abstraction layers |
| Executable-only project | Compliant | No library module changes |
| Tool handler signatures unchanged | Compliant | C wrapper preserves all 9 FFI function signatures |
| Inline tests in every handler | Compliant | All 190+ existing tests pass against new backend |
| Engine public API preserved | Compliant | `Engine` struct, `Term` union, `QueryResult` — zero changes |
