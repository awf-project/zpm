const std = @import("std");
const ffi = @import("ffi.zig");
const Capture = @import("capture.zig").Capture;

pub const EngineConfig = struct {
    timeout_ms: u64 = 5000,
    max_solutions: usize = 100,
    max_recursion_depth: usize = 1000,
    max_memory_bytes: usize = 67108864,
};

pub const EngineError = error{
    InitFailed,
    QueryFailed,
    AssertFailed,
    RetractFailed,
    LoadFailed,
    Timeout,
    OutOfMemory,
    InvalidJson,
};

pub const Term = union(enum) {
    atom: []const u8,
    integer: i64,
    float: f64,
    compound: struct {
        functor: []const u8,
        args: []Term,
    },
    variable: []const u8,
    list: []Term,
};

pub const Solution = struct {
    bindings: std.StringHashMap(Term),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Solution) void {
        var iter = self.bindings.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeTerm(self.allocator, entry.value_ptr.*);
        }
        self.bindings.deinit();
    }
};

pub const QueryResult = struct {
    solutions: []Solution,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *QueryResult) void {
        for (self.solutions) |*s| s.deinit();
        self.allocator.free(self.solutions);
    }
};

/// Process-wide counter for temp file names in loadString.
var g_src_counter = std.atomic.Value(u32).init(0);

pub const Engine = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    allocator: std.mem.Allocator,
    handle: ?*ffi.Prolog,
    config: EngineConfig,
    /// Set of `F/A` keys for predicates already declared dynamic in this
    /// engine. Used to avoid re-declaring on every assertFact, and populated
    /// both on first-assert and when loading a .pl file that contains
    /// `:- dynamic(F/A).` directives. Keys are owned by the engine allocator.
    declared_dynamic: std.StringHashMap(void),

    pub fn init(config: EngineConfig) EngineError!*Engine {
        const self = std.heap.page_allocator.create(Engine) catch return EngineError.OutOfMemory;
        self.gpa = std.heap.GeneralPurposeAllocator(.{}){};
        self.allocator = self.gpa.allocator();
        self.config = config;
        self.declared_dynamic = std.StringHashMap(void).init(self.allocator);
        self.handle = ffi.pl_create();
        if (self.handle == null) {
            ffi.g_tpl_lib = null;
            self.declared_dynamic.deinit();
            _ = self.gpa.deinit();
            std.heap.page_allocator.destroy(self);
            return EngineError.InitFailed;
        }
        ffi.set_quiet(self.handle.?);
        // Declare predicates used for runtime assertion as dynamic so Trealla
        // accepts assertions without raising existence_error(procedure, ...).
        const preload =
            \\:- dynamic(zpm_source/2).
            \\:- dynamic(tms_justification/2).
            \\zpm_dump :- findall(F/A, (current_predicate(F/A), functor(H, F, A), catch(predicate_property(H, dynamic), _, fail)), Ps), zpm_emit_dyn_(Ps), zpm_dump_(Ps).
            \\zpm_emit_dyn_([]).
            \\zpm_emit_dyn_([F/A|Rs]) :- write(':- dynamic('), writeq(F), write('/'), write(A), write(').'), nl, zpm_emit_dyn_(Rs).
            \\zpm_dump_([]).
            \\zpm_dump_([P|Rs]) :- catch(listing(P), _, true), zpm_dump_(Rs).
            \\zpm_emit_solutions(Ss) :- write('['), zpm_esols(Ss), write(']').
            \\zpm_esols([]).
            \\zpm_esols([S]) :- !, zpm_esol(S).
            \\zpm_esols([S|Rs]) :- zpm_esol(S), write(','), zpm_esols(Rs).
            \\zpm_esol(Bs) :- write('['), zpm_ebs(Bs), write(']').
            \\zpm_ebs([]).
            \\zpm_ebs([B]) :- !, zpm_eb(B).
            \\zpm_ebs([B|Rs]) :- zpm_eb(B), write(','), zpm_ebs(Rs).
            \\zpm_eb(N=V) :- write('{"name":'), zpm_estr_atom(N), write(',"value":'), zpm_eval(V), write('}').
            \\zpm_estr_atom(A) :- atom_chars(A, Cs), write('"'), zpm_estrc(Cs), write('"').
            \\zpm_estrc([]).
            \\zpm_estrc([C|Cs]) :- zpm_estrc1(C), zpm_estrc(Cs).
            \\zpm_estrc1('"') :- !, put_char('\\'), put_char('"').
            \\zpm_estrc1('\\') :- !, put_char('\\'), put_char('\\').
            \\zpm_estrc1(C) :- put_char(C).
            \\zpm_eval(V) :- var(V), !, write('{"type":"variable","name":"'), write(V), write('"}').
            \\zpm_eval(N) :- integer(N), !, write('{"type":"integer","value":'), write(N), write('}').
            \\zpm_eval(F) :- float(F), !, write('{"type":"float","value":'), write(F), write('}').
            \\zpm_eval([]) :- !, write('{"type":"list","items":[]}').
            \\zpm_eval(L) :- is_list(L), !, write('{"type":"list","items":['), zpm_elist(L), write(']}').
            \\zpm_eval(A) :- atom(A), !, write('{"type":"atom","value":'), zpm_estr_atom(A), write('}').
            \\zpm_eval(T) :- compound(T), !, T =.. [F|As], write('{"type":"compound","functor":'), zpm_estr_atom(F), write(',"args":['), zpm_elist(As), write(']}').
            \\zpm_elist([]).
            \\zpm_elist([V]) :- !, zpm_eval(V).
            \\zpm_elist([V|Vs]) :- zpm_eval(V), write(','), zpm_elist(Vs).
            \\
        ;
        self.loadString(preload) catch {
            ffi.pl_destroy(self.handle.?);
            ffi.g_tpl_lib = null;
            self.declared_dynamic.deinit();
            _ = self.gpa.deinit();
            std.heap.page_allocator.destroy(self);
            return EngineError.InitFailed;
        };
        // Seed with preload-declared dynamics so subsequent assertFact on
        // these functors skips the redundant declaration.
        self.markDynamic("zpm_source", 2) catch {};
        self.markDynamic("tms_justification", 2) catch {};
        return self;
    }

    pub fn deinit(self: *Engine) void {
        if (self.handle) |h| {
            ffi.pl_destroy(h);
            ffi.g_tpl_lib = null;
        }
        var it = self.declared_dynamic.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.declared_dynamic.deinit();
        _ = self.gpa.deinit();
        std.heap.page_allocator.destroy(self);
    }

    /// Test seam: null out the Trealla handle so subsequent engine calls
    /// return errors. Safe to call once per Engine lifetime.
    pub fn simulateHandleFailure(self: *Engine) void {
        if (self.handle) |h| {
            ffi.pl_destroy(h);
            self.handle = null;
            ffi.g_tpl_lib = null;
        }
    }

    /// Insert an owned `F/A` key into declared_dynamic if not already present.
    fn markDynamic(self: *Engine, functor: []const u8, arity: usize) EngineError!void {
        const key = std.fmt.allocPrint(self.allocator, "{s}/{d}", .{ functor, arity }) catch
            return EngineError.OutOfMemory;
        if (self.declared_dynamic.contains(key)) {
            self.allocator.free(key);
            return;
        }
        self.declared_dynamic.put(key, {}) catch {
            self.allocator.free(key);
            return EngineError.OutOfMemory;
        };
    }

    /// Check whether `F/A` is already declared dynamic in this engine.
    fn isDynamic(self: *Engine, functor: []const u8, arity: usize) bool {
        var buf: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}/{d}", .{ functor, arity }) catch return false;
        return self.declared_dynamic.contains(key);
    }

    pub fn iterateDeclaredDynamic(self: *Engine) std.StringHashMap(void).Iterator {
        return self.declared_dynamic.iterator();
    }

    /// Emit `:- dynamic(F/A).` to Trealla and remember the key. Idempotent
    /// at both the engine-cache level and the Prolog-VM level.
    fn declareDynamic(self: *Engine, functor: []const u8, arity: usize) EngineError!void {
        if (self.isDynamic(functor, arity)) return;
        const code = std.fmt.allocPrintSentinel(
            self.allocator,
            ":- dynamic({s}/{d}).",
            .{ functor, arity },
            0,
        ) catch return EngineError.OutOfMemory;
        defer self.allocator.free(code);
        _ = self.evalSilently(code);
        try self.markDynamic(functor, arity);
    }

    fn checkSandbox(self: *Engine) EngineError!void {
        if (self.config.timeout_ms == 0) return EngineError.Timeout;
        if (self.config.max_memory_bytes < 1024) return EngineError.OutOfMemory;
    }

    /// Run a Prolog query and return all solutions. Parses the user goal via
    /// read_term_from_atom/3 with variable_names/1, enumerates solutions with
    /// findall, emits the solution list as JSON via zpm_emit_solutions/1 (a
    /// hand-rolled writer in the preload that avoids library(json)'s DCG
    /// generation path), and decodes the JSON with std.json on the Zig side.
    /// On any Prolog-side error the catch/3 wrapper emits '[]' so
    /// parseQueryJson returns an empty result.
    pub fn query(self: *Engine, goal: []const u8) EngineError!QueryResult {
        try self.checkSandbox();
        const handle = self.handle orelse return EngineError.QueryFailed;

        const stripped = stripDot(goal);
        if (stripped.len == 0) {
            return QueryResult{
                .solutions = &.{},
                .allocator = self.allocator,
            };
        }

        const escaped = escapeForPrologAtom(self.allocator, stripped) catch
            return EngineError.OutOfMemory;
        defer self.allocator.free(escaped);

        const code = std.fmt.allocPrintSentinel(
            self.allocator,
            "catch((read_term_from_atom('{s}.', ZpmG_, [variable_names(ZpmV_)])," ++
                " findall(ZpmV_, call(ZpmG_), ZpmS_)," ++
                " zpm_emit_solutions(ZpmS_))," ++
                " _, write('[]')).",
            .{escaped},
            0,
        ) catch return EngineError.OutOfMemory;
        defer self.allocator.free(code);

        var cap = Capture.init(self.allocator);
        cap.begin(false) catch return EngineError.QueryFailed;
        defer cap.end();

        _ = ffi.pl_eval(handle, code, false);

        const output = cap.readAndReset() catch return EngineError.OutOfMemory;
        defer self.allocator.free(output);

        return parseQueryJson(self.allocator, output, self.config.max_solutions);
    }

    pub fn assert(self: *Engine, clause: []const u8) EngineError!void {
        const stripped = stripDot(clause);
        if (stripped.len == 0) return EngineError.AssertFailed;
        if (self.handle == null) return EngineError.AssertFailed;

        // Rules with `:-` need an extra paren around the body so assertz
        // parses them with the right operator precedence. Pre-declaring
        // `:- dynamic(F/A)` avoids Trealla's permission_error on library
        // functors that default to static. Parse failures fall through —
        // assertz will surface whatever error Trealla gives us.
        const has_rule = std.mem.indexOf(u8, stripped, ":-") != null;

        if (parseHeadFunctorArity(stripped)) |fa| {
            self.declareDynamic(fa.functor, fa.arity) catch {};
        }
        const code = if (has_rule)
            std.fmt.allocPrintSentinel(
                self.allocator,
                "assertz(({s})).",
                .{stripped},
                0,
            ) catch return EngineError.OutOfMemory
        else
            std.fmt.allocPrintSentinel(
                self.allocator,
                "assertz({s}).",
                .{stripped},
                0,
            ) catch return EngineError.OutOfMemory;
        defer self.allocator.free(code);

        if (!self.evalWithErrorCheck(code)) return EngineError.AssertFailed;
    }

    pub fn retract(self: *Engine, clause: []const u8) EngineError!void {
        const stripped = stripDot(clause);
        if (stripped.len == 0) return EngineError.RetractFailed;
        if (self.handle == null) return EngineError.RetractFailed;

        // pl_eval returns true even for failing goals (it only signals
        // evaluation errors), so we can't use it to detect "no matching
        // clause". Write a marker on success and on failure, then inspect
        // the captured stdout to decide what happened.
        const code = std.fmt.allocPrintSentinel(
            self.allocator,
            "(retract({s}) -> write(zpm_retract_ok) ; write(zpm_retract_no)).",
            .{stripped},
            0,
        ) catch return EngineError.OutOfMemory;
        defer self.allocator.free(code);

        const succeeded = self.evalAndCheckMarker(code, "zpm_retract_ok");
        if (!succeeded) return EngineError.RetractFailed;
    }

    pub fn assertFact(self: *Engine, clause: []const u8) EngineError!void {
        return self.assert(clause);
    }

    pub fn retractFact(self: *Engine, clause: []const u8) EngineError!void {
        return self.retract(clause);
    }

    pub fn retractAll(self: *Engine, head: []const u8) EngineError!void {
        const stripped = stripDot(head);
        if (stripped.len == 0) return EngineError.RetractFailed;
        if (self.handle == null) return EngineError.RetractFailed;

        const code = std.fmt.allocPrintSentinel(
            self.allocator,
            "retractall({s}).",
            .{stripped},
            0,
        ) catch return EngineError.OutOfMemory;
        defer self.allocator.free(code);

        // retractall/1 succeeds per ISO Prolog even if nothing matches; we
        // don't propagate eval failure to the caller.
        _ = self.evalSilently(code);
    }

    /// Retract all clauses of every user-declared dynamic predicate while
    /// preserving the `:- dynamic(F/A)` declarations. Used by snapshot
    /// restore to make a reload replace instead of append.
    pub fn resetUserKnowledge(self: *Engine) EngineError!void {
        if (self.handle == null) return EngineError.RetractFailed;

        var it = self.declared_dynamic.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const slash = std.mem.indexOfScalar(u8, key, '/') orelse continue;
            const functor = key[0..slash];
            const arity = std.fmt.parseInt(usize, key[slash + 1 ..], 10) catch continue;

            if (arity == 0) {
                const code = std.fmt.allocPrintSentinel(self.allocator, "retractall({s}).", .{functor}, 0) catch return EngineError.OutOfMemory;
                defer self.allocator.free(code);
                _ = self.evalSilently(code);
                continue;
            }
            var args_buf: std.io.Writer.Allocating = .init(self.allocator);
            defer args_buf.deinit();
            const w = &args_buf.writer;
            w.writeAll("_") catch return EngineError.OutOfMemory;
            var i: usize = 1;
            while (i < arity) : (i += 1) w.writeAll(",_") catch return EngineError.OutOfMemory;
            const args = args_buf.toOwnedSlice() catch return EngineError.OutOfMemory;
            defer self.allocator.free(args);
            const code = std.fmt.allocPrintSentinel(
                self.allocator,
                "retractall({s}({s})).",
                .{ functor, args },
                0,
            ) catch return EngineError.OutOfMemory;
            defer self.allocator.free(code);
            _ = self.evalSilently(code);
        }
    }

    /// Populate the dynamic set from `:- dynamic(F/A).` directives in
    /// `source` so subsequent assertFact calls skip the redundant emit.
    /// Malformed directives are silently ignored.
    fn scanDynamicDirectives(self: *Engine, source: []const u8) void {
        var pos: usize = 0;
        while (pos < source.len) {
            const rest = source[pos..];
            const hit = std.mem.indexOf(u8, rest, ":-") orelse return;
            var j = hit + 2;
            while (j < rest.len and (rest[j] == ' ' or rest[j] == '\t')) : (j += 1) {}
            if (j + 7 <= rest.len and std.mem.eql(u8, rest[j .. j + 7], "dynamic")) {
                j += 7;
                while (j < rest.len and (rest[j] == ' ' or rest[j] == '\t')) : (j += 1) {}
                if (j < rest.len and rest[j] == '(') {
                    j += 1;
                    if (std.mem.indexOfScalarPos(u8, rest, j, '/')) |slash| {
                        if (std.mem.indexOfScalarPos(u8, rest, slash, ')')) |close| {
                            const functor = std.mem.trim(u8, rest[j..slash], " \t");
                            const arity_str = std.mem.trim(u8, rest[slash + 1 .. close], " \t");
                            if (std.fmt.parseInt(usize, arity_str, 10)) |arity| {
                                self.markDynamic(functor, arity) catch {};
                            } else |_| {}
                            pos += close + 1;
                            continue;
                        }
                    }
                }
            }
            pos += hit + 2;
        }
    }

    pub fn loadFile(self: *Engine, path: []const u8) EngineError!void {
        const handle = self.handle orelse return EngineError.LoadFailed;

        // Verify readability up front — mirrors the access(R_OK) check in the
        // old C wrapper so missing files fail fast instead of going through
        // Trealla's error reporting path.
        std.fs.cwd().access(path, .{}) catch return EngineError.LoadFailed;

        // pl_consult loads clauses as static; harvesting the snapshot's
        // `:- dynamic(F/A).` directives into the cache keeps post-load
        // assertFact from tripping permission_error(modify, static_procedure).
        if (std.fs.cwd().openFile(path, .{})) |f| {
            defer f.close();
            const src = f.readToEndAlloc(self.allocator, std.math.maxInt(usize)) catch null;
            if (src) |buf| {
                defer self.allocator.free(buf);
                self.scanDynamicDirectives(buf);
            }
        } else |_| {}

        // Load via `consult/1` as a Prolog goal rather than `pl_consult`.
        // Trealla's `pl_consult` is only reliable on a pristine VM; after any
        // mutation (even a plain query) it silently skips asserting clauses,
        // which made snapshot restore report success while leaving the KB
        // empty. Executing `consult/1` through `pl_eval` goes through the
        // regular directive/assertion pipeline and stays consistent.
        const escaped = escapeForPrologAtom(self.allocator, path) catch
            return EngineError.OutOfMemory;
        defer self.allocator.free(escaped);

        const code = std.fmt.allocPrintSentinel(
            self.allocator,
            "consult('{s}').",
            .{escaped},
            0,
        ) catch return EngineError.OutOfMemory;
        defer self.allocator.free(code);

        var cap = Capture.init(self.allocator);
        var have_cap = true;
        cap.begin(true) catch {
            have_cap = false;
        };
        defer if (have_cap) cap.end();

        const ok = ffi.pl_eval(handle, code, false);

        if (have_cap) {
            if (cap.readAndReset()) |out| self.allocator.free(out) else |_| {}
            if (cap.readStderr()) |err| {
                defer self.allocator.free(err);
                if (hasError(err)) return EngineError.LoadFailed;
            } else |_| {}
        }

        if (!ok) return EngineError.LoadFailed;
    }

    pub fn loadString(self: *Engine, source: []const u8) EngineError!void {
        const handle = self.handle orelse return EngineError.LoadFailed;

        self.scanDynamicDirectives(source);

        const pid = std.os.linux.getpid();
        const counter = g_src_counter.fetchAdd(1, .monotonic);
        const tmppath = std.fmt.allocPrintSentinel(
            self.allocator,
            "/tmp/zpm_src_{d}_{d}.pl",
            .{ pid, counter },
            0,
        ) catch return EngineError.OutOfMemory;
        defer self.allocator.free(tmppath);

        {
            var file = std.fs.createFileAbsoluteZ(tmppath, .{}) catch
                return EngineError.LoadFailed;
            defer file.close();
            var writer_buf: [4096]u8 = undefined;
            var file_writer = file.writer(&writer_buf);
            file_writer.interface.writeAll(source) catch return EngineError.LoadFailed;
            file_writer.interface.flush() catch return EngineError.LoadFailed;
        }
        defer std.posix.unlink(tmppath) catch {};

        var cap = Capture.init(self.allocator);
        var have_cap = true;
        cap.begin(true) catch {
            have_cap = false;
        };
        defer if (have_cap) cap.end();

        const ok = ffi.pl_consult(handle, tmppath);

        if (have_cap) {
            if (cap.readAndReset()) |out| self.allocator.free(out) else |_| {}
            if (cap.readStderr()) |err| {
                defer self.allocator.free(err);
                if (hasError(err)) return EngineError.LoadFailed;
            } else |_| {}
        }

        if (!ok) return EngineError.LoadFailed;
    }

    /// pl_eval with capture + error detection; returns true on success.
    fn evalWithErrorCheck(self: *Engine, code: [*:0]const u8) bool {
        const handle = self.handle orelse return false;

        var cap = Capture.init(self.allocator);
        var have_cap = true;
        cap.begin(true) catch {
            have_cap = false;
        };
        defer if (have_cap) cap.end();

        const ok = ffi.pl_eval(handle, code, false);

        var had_error = false;
        if (have_cap) {
            if (cap.readAndReset()) |out| self.allocator.free(out) else |_| {}
            if (cap.readStderr()) |err| {
                defer self.allocator.free(err);
                if (hasError(err)) had_error = true;
            } else |_| {}
        }

        return ok and !had_error;
    }

    /// pl_eval with stdout capture, returning true iff `marker` appears in
    /// the captured output. Used to disambiguate Prolog-level success from
    /// failure for goals like once(retract(...)) where pl_eval's boolean
    /// return value is not reliable.
    fn evalAndCheckMarker(self: *Engine, code: [*:0]const u8, marker: []const u8) bool {
        const handle = self.handle orelse return false;

        var cap = Capture.init(self.allocator);
        cap.begin(false) catch return false;
        defer cap.end();

        _ = ffi.pl_eval(handle, code, false);

        if (cap.readAndReset()) |out| {
            defer self.allocator.free(out);
            return std.mem.indexOf(u8, out, marker) != null;
        } else |_| {
            return false;
        }
    }

    /// pl_eval with capture but no error inspection; returns the eval result.
    pub fn dumpDynamicPredicates(self: *Engine, allocator: std.mem.Allocator) EngineError![]u8 {
        const handle = self.handle orelse return EngineError.QueryFailed;

        var cap = Capture.init(allocator);
        cap.begin(false) catch return EngineError.QueryFailed;
        defer cap.end();

        _ = ffi.pl_eval(handle, "zpm_dump.", false);

        return cap.readAndReset() catch EngineError.OutOfMemory;
    }

    fn evalSilently(self: *Engine, code: [*:0]const u8) bool {
        const handle = self.handle orelse return false;

        var cap = Capture.init(self.allocator);
        var have_cap = true;
        cap.begin(true) catch {
            have_cap = false;
        };
        defer if (have_cap) cap.end();

        const ok = ffi.pl_eval(handle, code, false);

        if (have_cap) {
            if (cap.readAndReset()) |out| self.allocator.free(out) else |_| {}
            if (cap.readStderr()) |err| self.allocator.free(err) else |_| {}
        }

        return ok;
    }
};

fn stripDot(s: []const u8) []const u8 {
    const trimmed = std.mem.trimRight(u8, s, " \t\n\r");
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '.') {
        return trimmed[0 .. trimmed.len - 1];
    }
    return trimmed;
}

fn parseTermValue(allocator: std.mem.Allocator, val: std.json.Value) EngineError!Term {
    const obj = switch (val) {
        .object => |o| o,
        else => return EngineError.InvalidJson,
    };
    const tag_val = obj.get("type") orelse return EngineError.InvalidJson;
    const tag = switch (tag_val) {
        .string => |s| s,
        else => return EngineError.InvalidJson,
    };

    if (std.mem.eql(u8, tag, "atom")) {
        const v = switch (obj.get("value") orelse return EngineError.InvalidJson) {
            .string => |s| s,
            else => return EngineError.InvalidJson,
        };
        return Term{ .atom = allocator.dupe(u8, v) catch return EngineError.OutOfMemory };
    } else if (std.mem.eql(u8, tag, "variable")) {
        const v = switch (obj.get("name") orelse return EngineError.InvalidJson) {
            .string => |s| s,
            else => return EngineError.InvalidJson,
        };
        return Term{ .variable = allocator.dupe(u8, v) catch return EngineError.OutOfMemory };
    } else if (std.mem.eql(u8, tag, "integer")) {
        return Term{ .integer = switch (obj.get("value") orelse return EngineError.InvalidJson) {
            .integer => |i| i,
            else => return EngineError.InvalidJson,
        } };
    } else if (std.mem.eql(u8, tag, "float")) {
        return Term{ .float = switch (obj.get("value") orelse return EngineError.InvalidJson) {
            .float => |f| f,
            else => return EngineError.InvalidJson,
        } };
    } else if (std.mem.eql(u8, tag, "compound")) {
        const functor_str = switch (obj.get("functor") orelse return EngineError.InvalidJson) {
            .string => |s| s,
            else => return EngineError.InvalidJson,
        };
        const args_arr = switch (obj.get("args") orelse return EngineError.InvalidJson) {
            .array => |a| a,
            else => return EngineError.InvalidJson,
        };
        const functor = allocator.dupe(u8, functor_str) catch return EngineError.OutOfMemory;
        errdefer allocator.free(functor);
        const args = allocator.alloc(Term, args_arr.items.len) catch return EngineError.OutOfMemory;
        var built: usize = 0;
        errdefer {
            for (args[0..built]) |*t| freeTerm(allocator, t.*);
            allocator.free(args);
        }
        while (built < args_arr.items.len) : (built += 1) {
            args[built] = try parseTermValue(allocator, args_arr.items[built]);
        }
        return Term{ .compound = .{ .functor = functor, .args = args } };
    } else if (std.mem.eql(u8, tag, "list")) {
        const items_arr = switch (obj.get("items") orelse return EngineError.InvalidJson) {
            .array => |a| a,
            else => return EngineError.InvalidJson,
        };
        const items = allocator.alloc(Term, items_arr.items.len) catch return EngineError.OutOfMemory;
        var built: usize = 0;
        errdefer {
            for (items[0..built]) |*t| freeTerm(allocator, t.*);
            allocator.free(items);
        }
        while (built < items_arr.items.len) : (built += 1) {
            items[built] = try parseTermValue(allocator, items_arr.items[built]);
        }
        return Term{ .list = items };
    }
    return EngineError.InvalidJson;
}

fn parseSolution(allocator: std.mem.Allocator, val: std.json.Value) EngineError!Solution {
    const arr = switch (val) {
        .array => |a| a,
        else => return EngineError.InvalidJson,
    };
    var bindings = std.StringHashMap(Term).init(allocator);
    errdefer {
        var it = bindings.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            freeTerm(allocator, e.value_ptr.*);
        }
        bindings.deinit();
    }

    for (arr.items) |b_val| {
        const obj = switch (b_val) {
            .object => |o| o,
            else => continue,
        };
        const name_val = obj.get("name") orelse continue;
        const name = switch (name_val) {
            .string => |s| s,
            else => continue,
        };
        const value = obj.get("value") orelse continue;
        const term = try parseTermValue(allocator, value);
        const name_dup = allocator.dupe(u8, name) catch {
            freeTerm(allocator, term);
            return EngineError.OutOfMemory;
        };
        bindings.put(name_dup, term) catch {
            allocator.free(name_dup);
            freeTerm(allocator, term);
            return EngineError.OutOfMemory;
        };
    }
    return Solution{ .bindings = bindings, .allocator = allocator };
}

/// Return the leading balanced JSON array ("[...]") in `s`, or null if the
/// string does not start with '[' or has no matching close bracket. Tracks
/// bracket depth and skips over double-quoted strings (with backslash escapes)
/// so brackets inside string values do not affect nesting.
fn extractLeadingJsonArray(s: []const u8) ?[]const u8 {
    if (s.len == 0 or s[0] != '[') return null;
    var depth: usize = 0;
    var i: usize = 0;
    var in_string = false;
    var escape = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_string) {
            if (escape) {
                escape = false;
            } else if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return s[0 .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

fn parseQueryJson(
    allocator: std.mem.Allocator,
    output: []const u8,
    max_solutions: usize,
) EngineError!QueryResult {
    const trimmed = std.mem.trim(u8, output, " \t\n\r");
    if (trimmed.len == 0)
        return QueryResult{ .solutions = &.{}, .allocator = allocator };

    // Trealla's pl_eval in command mode appends a dump_vars summary after
    // our written JSON (e.g. "[[]]   ZpmG_ = true, ZpmV_ = [], ZpmS_ = [[]].").
    // Slice off everything past the first balanced top-level bracket pair.
    const json_slice = extractLeadingJsonArray(trimmed) orelse
        return QueryResult{ .solutions = &.{}, .allocator = allocator };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_slice, .{}) catch
        return EngineError.InvalidJson;
    defer parsed.deinit();

    const sols_array = switch (parsed.value) {
        .array => |a| a,
        else => return QueryResult{ .solutions = &.{}, .allocator = allocator },
    };

    const count = @min(sols_array.items.len, max_solutions);
    var solutions = allocator.alloc(Solution, count) catch return EngineError.OutOfMemory;
    var made: usize = 0;
    errdefer {
        for (solutions[0..made]) |*s| s.deinit();
        allocator.free(solutions);
    }

    while (made < count) : (made += 1) {
        solutions[made] = try parseSolution(allocator, sols_array.items[made]);
    }

    return QueryResult{ .solutions = solutions, .allocator = allocator };
}

fn freeTerm(allocator: std.mem.Allocator, term: Term) void {
    switch (term) {
        .atom => |s| allocator.free(s),
        .variable => |s| allocator.free(s),
        .list => |items| {
            for (items) |item| freeTerm(allocator, item);
            allocator.free(items);
        },
        .compound => |c| {
            allocator.free(c.functor);
            for (c.args) |arg| freeTerm(allocator, arg);
            allocator.free(c.args);
        },
        .integer, .float => {},
    }
}

fn hasError(s: []const u8) bool {
    if (s.len == 0) return false;
    return std.mem.indexOf(u8, s, "Error:") != null or
        std.mem.indexOf(u8, s, "error:") != null or
        std.mem.indexOf(u8, s, "syntax error") != null;
}

fn escapeForPrologAtom(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, s.len);
    for (s) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\'' => try out.appendSlice(allocator, "\\'"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

pub const HeadFunctorArity = struct {
    functor: []const u8,
    arity: usize,
};

/// Extract the head functor and arity from a clause. Returns null for any
/// surface syntax this mini-parser does not cover (operators, DCG, etc.) —
/// callers must tolerate null rather than treat it as an error. Functor is
/// a slice into `clause`.
pub fn parseHeadFunctorArity(clause: []const u8) ?HeadFunctorArity {
    // assert() may wrap rules in outer parens: `(head :- body)`.
    var s = std.mem.trim(u8, clause, " \t\n\r");
    if (s.len >= 2 and s[0] == '(' and s[s.len - 1] == ')') {
        s = std.mem.trim(u8, s[1 .. s.len - 1], " \t\n\r");
    }

    if (std.mem.startsWith(u8, s, ":-")) return null;

    const head = if (std.mem.indexOf(u8, s, ":-")) |idx|
        std.mem.trim(u8, s[0..idx], " \t\n\r")
    else
        s;
    if (head.len == 0) return null;

    // Skip single-quoted functors so `'Mod:Name'(...)` isn't split wrongly.
    var i: usize = 0;
    if (head[0] == '\'') {
        i = 1;
        while (i < head.len) : (i += 1) {
            if (head[i] == '\\' and i + 1 < head.len) {
                i += 1;
                continue;
            }
            if (head[i] == '\'') {
                i += 1;
                break;
            }
        }
    } else {
        while (i < head.len and head[i] != '(' and head[i] != ' ' and head[i] != '\t') : (i += 1) {}
    }
    const functor = head[0..i];
    if (functor.len == 0) return null;

    while (i < head.len and (head[i] == ' ' or head[i] == '\t')) : (i += 1) {}
    if (i >= head.len or head[i] != '(') {
        return .{ .functor = functor, .arity = 0 };
    }

    i += 1;
    var depth: i32 = 0;
    var arity: usize = 1;
    var in_sq = false;
    var in_dq = false;
    var escape = false;
    while (i < head.len) : (i += 1) {
        const c = head[i];
        if (escape) {
            escape = false;
            continue;
        }
        if (c == '\\') {
            escape = true;
            continue;
        }
        if (in_sq) {
            if (c == '\'') in_sq = false;
            continue;
        }
        if (in_dq) {
            if (c == '"') in_dq = false;
            continue;
        }
        switch (c) {
            '\'' => in_sq = true,
            '"' => in_dq = true,
            '(', '[', '{' => depth += 1,
            ')' => {
                if (depth == 0) return .{ .functor = functor, .arity = arity };
                depth -= 1;
            },
            ']', '}' => {
                if (depth > 0) depth -= 1;
            },
            ',' => if (depth == 0) {
                arity += 1;
            },
            else => {},
        }
    }
    return null;
}

const testing = std.testing;

test "parseTermValue decodes atom" {
    const json =
        \\{"type":"atom","value":"alice"}
    ;
    var p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer p.deinit();
    const t = try parseTermValue(std.testing.allocator, p.value);
    defer freeTerm(std.testing.allocator, t);
    try std.testing.expectEqualStrings("alice", t.atom);
}

test "parseTermValue decodes integer" {
    const json =
        \\{"type":"integer","value":42}
    ;
    var p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer p.deinit();
    const t = try parseTermValue(std.testing.allocator, p.value);
    defer freeTerm(std.testing.allocator, t);
    try std.testing.expectEqual(@as(i64, 42), t.integer);
}

test "parseTermValue decodes compound recursively" {
    const json =
        \\{"type":"compound","functor":"p","args":[
        \\  {"type":"atom","value":"a"},
        \\  {"type":"variable","name":"X"}
        \\]}
    ;
    var p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer p.deinit();
    const t = try parseTermValue(std.testing.allocator, p.value);
    defer freeTerm(std.testing.allocator, t);
    try std.testing.expectEqualStrings("p", t.compound.functor);
    try std.testing.expectEqual(@as(usize, 2), t.compound.args.len);
    try std.testing.expectEqualStrings("a", t.compound.args[0].atom);
    try std.testing.expectEqualStrings("X", t.compound.args[1].variable);
}

test "parseTermValue rejects unknown tag" {
    const json =
        \\{"type":"bogus","value":"x"}
    ;
    var p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer p.deinit();
    try std.testing.expectError(EngineError.InvalidJson, parseTermValue(std.testing.allocator, p.value));
}

test "parseTermValue rejects wrong-typed atom value" {
    const json =
        \\{"type":"atom","value":42}
    ;
    var p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer p.deinit();
    try std.testing.expectError(EngineError.InvalidJson, parseTermValue(std.testing.allocator, p.value));
}

test "Engine.init creates engine with non-null handle" {
    var engine = try Engine.init(.{});
    defer engine.deinit();
    try testing.expect(engine.handle != null);
}

test "Engine.init stores config" {
    var engine = try Engine.init(.{ .timeout_ms = 1000, .max_solutions = 10 });
    defer engine.deinit();
    try testing.expectEqual(@as(u64, 1000), engine.config.timeout_ms);
    try testing.expectEqual(@as(usize, 10), engine.config.max_solutions);
}

test "Engine.query parses atom binding from asserted fact" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    try engine.assert("fruit(apple).");
    var result = try engine.query("fruit(X)");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.solutions.len);
    const x = result.solutions[0].bindings.get("X").?;
    try testing.expectEqualStrings("apple", x.atom);
}

test "Engine.assert and retract succeed" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    try engine.assert("temp(42).");
    try engine.retract("temp(42).");

    var result = try engine.query("temp(X)");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.solutions.len);
}

test "Engine.assertFact then query succeeds" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    try engine.assertFact("fruit(apple).");
    var result = try engine.query("fruit(X)");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.solutions.len);
    const x = result.solutions[0].bindings.get("X").?;
    try testing.expectEqualStrings("apple", x.atom);
}

test "Engine.retractFact then query returns no results" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    try engine.assertFact("temp(42).");
    try engine.retractFact("temp(42).");

    var result = try engine.query("temp(X)");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.solutions.len);
}

test "Engine.assertFact with invalid term returns parse error" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    const err = engine.assertFact(")(invalid");
    try testing.expectError(EngineError.AssertFailed, err);
}

test "Engine.loadString accepts valid Prolog source" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    try engine.loadString("color(red). color(green). color(blue).");
    var result = try engine.query("color(X)");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.solutions.len);
}

test "Engine.loadFile loads predicates from disk and makes them queryable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const pl_content = "parent(tom, bob). parent(bob, ann).";
    try tmp.dir.writeFile(.{ .sub_path = "kb.pl", .data = pl_content });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = try tmp.dir.realpath("kb.pl", &path_buf);

    var engine = try Engine.init(.{});
    defer engine.deinit();

    try engine.loadFile(abs_path);

    var result = try engine.query("parent(tom, X)");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.solutions.len);
    try testing.expectEqualStrings("bob", result.solutions[0].bindings.get("X").?.atom);
}

test "Engine.loadFile with non-existent path returns LoadFailed" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    const err = engine.loadFile("/tmp/zpm_nonexistent_file_that_does_not_exist.pl");
    try testing.expectError(EngineError.LoadFailed, err);
}

test "Engine.loadString with invalid syntax returns LoadFailed" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    const err = engine.loadString(")(not valid prolog((.");
    try testing.expectError(EngineError.LoadFailed, err);
}

test "Engine.query succeeds with explicit sandbox limits set" {
    var engine = try Engine.init(.{
        .timeout_ms = 5000,
        .max_recursion_depth = 1000,
        .max_memory_bytes = 67108864,
    });
    defer engine.deinit();

    try engine.assert("sandboxed(ok).");
    var result = try engine.query("sandboxed(X)");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.solutions.len);
    try testing.expectEqualStrings("ok", result.solutions[0].bindings.get("X").?.atom);
}

test "Engine.query returns Timeout when timeout_ms is zero" {
    var engine = try Engine.init(.{ .timeout_ms = 0 });
    defer engine.deinit();

    try engine.assert("timeout_test(x).");
    const err = engine.query("timeout_test(X)");
    try testing.expectError(EngineError.Timeout, err);
}

test "Engine.query returns OutOfMemory when max_memory_bytes is too small" {
    var engine = try Engine.init(.{ .max_memory_bytes = 1 });
    defer engine.deinit();

    try engine.assert("memtest(x).");
    const err = engine.query("memtest(X)");
    try testing.expectError(EngineError.OutOfMemory, err);
}

test "Engine.retractAll removes all matching facts" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    try engine.assertFact("color(red).");
    try engine.assertFact("color(green).");
    try engine.assertFact("color(blue).");

    try engine.retractAll("color(_)");

    var result = try engine.query("color(X)");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.solutions.len);
}

test "Engine.retractAll succeeds when no facts match" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    try engine.retractAll("nonexistent(_)");
}

test "Engine.retractAll only removes matching predicate facts" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    try engine.assertFact("animal(cat).");
    try engine.assertFact("color(red).");

    try engine.retractAll("color(_)");

    var result = try engine.query("animal(X)");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.solutions.len);
    try testing.expectEqualStrings("cat", result.solutions[0].bindings.get("X").?.atom);
}

test "escapeForPrologAtom escapes single quotes and backslashes" {
    const out = try escapeForPrologAtom(testing.allocator, "a'b\\c");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a\\'b\\\\c", out);
}

test "hasError detects Trealla Error markers" {
    try testing.expect(hasError("Error: existence_error"));
    try testing.expect(hasError("parse error: syntax error"));
    try testing.expect(!hasError("all good"));
    try testing.expect(!hasError(""));
}

test "stripDot removes trailing dot and whitespace" {
    try testing.expectEqualStrings("foo(X)", stripDot("foo(X)."));
    try testing.expectEqualStrings("foo(X)", stripDot("foo(X). \n"));
    try testing.expectEqualStrings("foo(X)", stripDot("foo(X)"));
    try testing.expectEqualStrings("", stripDot(""));
    try testing.expectEqualStrings("", stripDot("."));
}

test "freeTerm releases all allocated memory without leaks" {
    const allocator = testing.allocator;
    const functor = try allocator.dupe(u8, "f");
    const arg = Term{ .atom = try allocator.dupe(u8, "a") };
    const args = try allocator.alloc(Term, 1);
    args[0] = arg;
    const term = Term{ .compound = .{ .functor = functor, .args = args } };
    freeTerm(allocator, term);
}

test "Engine.query round-trips compound values via JSON" {
    var engine = try Engine.init(.{});
    defer engine.deinit();
    try engine.assertFact("rel(a, b).");
    try engine.assertFact("rel(c, d).");

    var result = try engine.query("rel(X, Y)");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.solutions.len);

    const sol0 = result.solutions[0].bindings;
    try testing.expect(sol0.contains("X"));
    try testing.expect(sol0.contains("Y"));
}

test "iterateDeclaredDynamic includes preload-seeded predicates" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    var it = engine.iterateDeclaredDynamic();
    var found_zpm_source = false;
    var found_tms = false;
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "zpm_source/2")) found_zpm_source = true;
        if (std.mem.eql(u8, entry.key_ptr.*, "tms_justification/2")) found_tms = true;
    }
    try testing.expect(found_zpm_source);
    try testing.expect(found_tms);
}

test "iterateDeclaredDynamic includes predicate after assertFact" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    try engine.assertFact("feature(f019, test, planned).");

    var it = engine.iterateDeclaredDynamic();
    var found = false;
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "feature/3")) found = true;
    }
    try testing.expect(found);
}

test "iterateDeclaredDynamic keys have functor/arity format" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    try engine.assertFact("tag(alpha).");
    try engine.assertFact("pair(x, y).");

    var it = engine.iterateDeclaredDynamic();
    var found_tag = false;
    var found_pair = false;
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const slash = std.mem.indexOfScalar(u8, key, '/');
        try testing.expect(slash != null);
        if (std.mem.eql(u8, key, "tag/1")) found_tag = true;
        if (std.mem.eql(u8, key, "pair/2")) found_pair = true;
    }
    try testing.expect(found_tag);
    try testing.expect(found_pair);
}

test "iterateDeclaredDynamic includes predicate from loadString dynamic directive" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    try engine.loadString(":- dynamic(rule/3). rule(a, b, c).");

    var it = engine.iterateDeclaredDynamic();
    var found = false;
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "rule/3")) found = true;
    }
    try testing.expect(found);
}
