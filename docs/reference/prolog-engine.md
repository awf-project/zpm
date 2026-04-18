---
title: "Prolog Engine Reference"
---


The Prolog inference engine in zpm wraps [scryer-prolog](https://github.com/mthom/scryer-prolog) via a Rust FFI staticlib, exposing a memory-safe Zig API for querying, asserting facts, and loading programs.

## Engine Lifecycle

### Initialize

```zig
var engine = try Engine.init(.{});
defer engine.deinit();
```

The engine creates its own `GeneralPurposeAllocator` internally.

**Config fields (`EngineConfig`):**

| Field | Type | Default | Purpose |
|-------|------|---------|---------|
| `timeout_ms` | `u64` | `5000` | Query execution timeout in milliseconds |
| `max_solutions` | `usize` | `100` | Maximum solutions returned per query |
| `max_recursion_depth` | `usize` | `1000` | Maximum recursion depth during query |
| `max_memory_bytes` | `usize` | `67108864` | Max memory for Prolog runtime (64MB) |

**Errors:**

- `OutOfMemory` — Allocator exhausted
- `InitFailed` — scryer-prolog runtime initialization failed

### Deinitialize

```zig
engine.deinit();
```

Cleans up Prolog runtime and leaks check. Consumes the engine; further calls will fail.

---

## Query Execution

### `query()`

Execute a Prolog query and retrieve variable bindings.

```zig
const result = try engine.query("parent(X, alice)", allocator);
defer result.deinit(allocator);
```

**Returns:** `QueryResult` containing matching solutions.

**Errors:**

- `QueryFailed` — Query execution returned null from FFI
- `Timeout` — Sandbox check failed (timeout_ms is zero)
- `OutOfMemory` — Allocation failure
- `InvalidJson` — FFI returned unparseable JSON

**QueryResult fields:**

```zig
pub const QueryResult = struct {
    solutions: []Solution,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *QueryResult) void;
};

pub const Solution = struct {
    bindings: std.StringHashMap(Term),  // Variable -> Term mapping
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Solution) void;
};

pub const Term = union(enum) {
    atom: []const u8,              // Atoms: abc, 'quoted atom'
    integer: i64,                  // Integers
    float: f64,                    // Floating point numbers
    variable: []const u8,          // Unbound variables
    list: []Term,                  // Lists: [1,2,3]
    compound: struct {             // Compounds: f(a, b)
        functor: []const u8,
        args: []Term,
    },
};
```

**Example:**

```zig
var result = try engine.query("member(X, [1, 2, 3])");
defer result.deinit();

for (result.solutions) |solution| {
    if (solution.bindings.get("X")) |term| {
        std.debug.print("X = {}\n", .{term});
    }
}
```

---

## Fact & Rule Management

### `assertFact()`

Add a fact to the knowledge base.

```zig
try engine.assertFact("parent(bob, alice)");
```

Trailing dots are stripped automatically. Also available as `engine.assert()`.

**Errors:**

- `AssertFailed` — FFI returned non-zero status
- `OutOfMemory` — Allocation failure

### `retractFact()`

Remove a fact from the knowledge base.

```zig
try engine.retractFact("parent(bob, alice)");
```

Also available as `engine.retract()`.

**Errors:**

- `RetractFailed` — FFI returned non-zero status
- `OutOfMemory` — Allocation failure

---

## Program Loading

### `loadFile()`

Load a Prolog source file (`.pl`) into the engine.

```zig
try engine.loadFile("/path/to/program.pl");
```

**Errors:**

- `LoadFailed` — FFI returned non-zero status (file not found, syntax error, permission denied)
- `OutOfMemory` — Allocation failure

### `loadString()`

Load a Prolog program from a memory buffer.

```zig
const program =
    \\ parent(tom, bob).
    \\ parent(bob, ann).
    \\ ancestor(X, Y) :- parent(X, Y).
    \\ ancestor(X, Y) :- parent(X, Z), ancestor(Z, Y).
;

try engine.loadString(program);
var result = try engine.query("ancestor(tom, ann)");
defer result.deinit();
```

**Errors:**

- `LoadFailed` — FFI returned non-zero status (syntax error)
- `OutOfMemory` — Allocation failure

---

## Sandboxing Constraints

The engine enforces three layers of protection:

### Query Timeout

Sandbox constraints are checked before each query via `checkSandbox()`:

- If `timeout_ms` is `0`, returns `EngineError.Timeout`
- If `max_memory_bytes` is less than 1024, returns `EngineError.OutOfMemory`

```zig
var engine = try Engine.init(.{ .timeout_ms = 1000 });
defer engine.deinit();

var result = try engine.query("member(X, [a,b,c])");
defer result.deinit();
```

### Recursion Depth Limit

Configured via `max_recursion_depth` (default: 1000). Passed to the FFI layer for enforcement.

### Memory Limit

Configured via `max_memory_bytes` (default: 64MB). Pre-flight check rejects configurations below 1KB.

---

## Error Handling

All engine methods return `EngineError` unions:

| Error | Cause |
|-------|-------|
| `InitFailed` | Prolog runtime failed to initialize |
| `QueryFailed` | Query execution returned null from FFI |
| `AssertFailed` | Fact assertion returned non-zero from FFI |
| `RetractFailed` | Fact retraction returned non-zero from FFI |
| `LoadFailed` | File or string loading returned non-zero from FFI |
| `Timeout` | Sandbox check: `timeout_ms` is zero |
| `OutOfMemory` | Allocation failure or sandbox check: `max_memory_bytes` < 1024 |
| `InvalidJson` | FFI returned unparseable JSON for query results |

```zig
var result = engine.query("parent(X, alice)") catch |err| switch (err) {
    error.QueryFailed => std.debug.print("Query failed\n", .{}),
    error.Timeout => std.debug.print("Timeout\n", .{}),
    error.OutOfMemory => std.debug.print("OOM\n", .{}),
    else => return err,
};
```

---

## Memory Management

The engine creates and owns its own `GeneralPurposeAllocator`:

- **Ownership:** The engine allocates itself via `page_allocator`, then uses its internal GPA for all subsequent allocations
- **Lifetime:** `QueryResult` and `Solution` own their allocations; free via `.deinit()`
- **Leaks:** GPA reports Zig-side leaks on `engine.deinit()` in debug mode
- **FFI boundary:** Rust-side strings are freed via `prolog_free_string`; each language owns its own memory

```zig
var engine = try Engine.init(.{});
defer engine.deinit();

var result = try engine.query("true");
defer result.deinit();  // Must free before engine.deinit()
```

---

## Integration with MCP Tools (F003)

The engine is intentionally independent of MCP:

- Engine methods use plain Zig types (`[]const u8`, `Term`, error unions)
- MCP tool handlers (F003) will wrap engine methods and convert results to JSON-RPC responses
- This separation allows testing and reuse without MCP protocol overhead

See [ADR-0002](../ADR/0002-scryer-prolog-via-rust-ffi-staticlib.md) for the rationale.

---

## Testing

Engine tests are colocated inline in `src/prolog/engine.zig`. Run via:

```bash
make test
```

Tests cover:
- Engine lifecycle (init, deinit, leak detection)
- Query execution (success, no-match, syntax error)
- Fact assertion and retraction
- Program loading from file and string
- Sandboxing (timeouts, recursion limits)
