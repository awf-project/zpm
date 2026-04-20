//! Trealla Prolog C API declarations for Zig. This module replaces the former
//! `ffi/trealla-wrapper.c` shim — we now call Trealla directly from Zig, with
//! the glue code (stdout capture, findall output parsing, error detection,
//! assertz wrapping) living in `engine.zig` + `capture.zig`.

const std = @import("std");

/// Opaque handle returned by `pl_create`.
pub const Prolog = opaque {};

pub extern "C" fn pl_create() ?*Prolog;
pub extern "C" fn pl_destroy(pl: *Prolog) void;
pub extern "C" fn pl_consult(pl: *Prolog, filename: [*:0]const u8) bool;
pub extern "C" fn pl_eval(pl: *Prolog, expr: [*:0]const u8, interactive: bool) bool;

pub extern "C" fn set_quiet(pl: *Prolog) void;

/// Trealla global that leaks a dangling pointer across pl_destroy. We reset
/// it to null from Zig after each pl_destroy so the next pl_create
/// reinitialises cleanly. See ffi/trealla/src/prolog.c:g_destroy / g_init.
pub extern var g_tpl_lib: ?[*:0]u8;

// Trealla's `tpl.c` defines these but we don't include that file in library
// mode. Re-export them from Zig so the linker is satisfied.
pub export var g_envp: ?[*]?[*:0]u8 = null;
pub export fn sigfn(s: c_int) callconv(.c) void {
    _ = s;
}

const testing = std.testing;

test "pl_create returns non-null handle" {
    const pl = pl_create();
    try testing.expect(pl != null);
    pl_destroy(pl.?);
    g_tpl_lib = null;
}

test "pl_create + pl_destroy cycle twice without crashing" {
    const pl1 = pl_create();
    try testing.expect(pl1 != null);
    pl_destroy(pl1.?);
    g_tpl_lib = null;

    const pl2 = pl_create();
    try testing.expect(pl2 != null);
    pl_destroy(pl2.?);
    g_tpl_lib = null;
}

test "pl_eval succeeds on true goal" {
    const pl = pl_create().?;
    defer {
        pl_destroy(pl);
        g_tpl_lib = null;
    }
    set_quiet(pl);
    try testing.expect(pl_eval(pl, "true.", false));
}

// Documented Trealla quirk: pl_eval returns true as long as the parser +
// executor ran without raising an error, even when the goal itself fails
// (e.g. `fail.` or `once(retract(nonexistent))`). Callers that need to
// distinguish Prolog success from failure must write a stdout marker
// inside the goal and parse the capture — see engine.evalAndCheckMarker.
test "pl_eval returns true even for goals that fail (Trealla behaviour)" {
    const pl = pl_create().?;
    defer {
        pl_destroy(pl);
        g_tpl_lib = null;
    }
    set_quiet(pl);
    try testing.expect(pl_eval(pl, "fail.", false));
}
