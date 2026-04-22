const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mcp_dep = b.dependency("mcp", .{});
    const cli_dep = b.dependency("cli", .{});
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("mcp", mcp_dep.module("mcp"));
    exe_module.addImport("cli", cli_dep.module("cli"));

    const trealla = buildTrealla(b, target, optimize);

    const exe = b.addExecutable(.{
        .name = "zpm",
        .root_module = exe_module,
    });
    linkFfi(exe, trealla);
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the MCP server");
    run_step.dependOn(&run_exe.step);

    const test_step = b.step("test", "Run unit tests");

    // Executable tests (reuses exe_module)
    const exe_unit_tests = b.addTest(.{
        .root_module = exe_module,
    });
    linkFfi(exe_unit_tests, trealla);
    // Trealla FFI writes to stdout on init, corrupting the zig_test
    // IPC protocol (--listen=-). Create Run step manually to skip IPC.
    const run_exe_unit_tests = std.Build.Step.Run.create(b, "run main tests");
    run_exe_unit_tests.addArtifactArg(exe_unit_tests);
    run_exe_unit_tests.stdio = .inherit;
    test_step.dependOn(&run_exe_unit_tests.step);

    // Engine tests
    const engine_test_module = b.createModule(.{
        .root_source_file = b.path("src/prolog/engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("prolog/engine.zig", engine_test_module);
    exe_module.addImport("../prolog/engine.zig", engine_test_module);
    const engine_unit_tests = b.addTest(.{
        .root_module = engine_test_module,
    });
    linkFfi(engine_unit_tests, trealla);
    const run_engine_unit_tests = b.addRunArtifact(engine_unit_tests);
    test_step.dependOn(&run_engine_unit_tests.step);

    // Capture tests (port of ffi/trealla-wrapper.c stdout redirection logic).
    const capture_test_module = b.createModule(.{
        .root_source_file = b.path("src/prolog/capture.zig"),
        .target = target,
        .optimize = optimize,
    });
    const capture_unit_tests = b.addTest(.{
        .root_module = capture_test_module,
    });
    // capture.zig does not need the Trealla static lib but keeping linkFfi is
    // harmless and avoids a separate link config.
    linkFfi(capture_unit_tests, trealla);
    // Capture tests temporarily redirect stdout, which would clobber the zig
    // test IPC channel. Run them inheriting stdio like the exe tests do.
    const run_capture_unit_tests = std.Build.Step.Run.create(b, "run capture tests");
    run_capture_unit_tests.addArtifactArg(capture_unit_tests);
    run_capture_unit_tests.stdio = .inherit;
    test_step.dependOn(&run_capture_unit_tests.step);

    // wal persistence module (F010) — declared early for tool test dependencies
    const wal_test_module = b.createModule(.{
        .root_source_file = b.path("src/persistence/wal.zig"),
        .target = target,
        .optimize = optimize,
    });
    wal_test_module.addImport("../prolog/engine.zig", engine_test_module);
    const wal_unit_tests = b.addTest(.{
        .root_module = wal_test_module,
    });
    linkFfi(wal_unit_tests, trealla);
    const run_wal_unit_tests = b.addRunArtifact(wal_unit_tests);
    test_step.dependOn(&run_wal_unit_tests.step);

    // term_utils shared module (used by tools and persistence)
    const term_utils_module = b.createModule(.{
        .root_source_file = b.path("src/tools/term_utils.zig"),
        .target = target,
        .optimize = optimize,
    });
    term_utils_module.addImport("../prolog/engine.zig", engine_test_module);
    const term_utils_exe_module = b.createModule(.{
        .root_source_file = b.path("src/tools/term_utils.zig"),
        .target = target,
        .optimize = optimize,
    });
    term_utils_exe_module.addImport("../prolog/engine.zig", engine_test_module);
    exe_module.addImport("term_utils", term_utils_exe_module);

    // snapshot persistence module (F010) — declared early for tool test dependencies
    const snapshot_test_module = b.createModule(.{
        .root_source_file = b.path("src/persistence/snapshot.zig"),
        .target = target,
        .optimize = optimize,
    });
    snapshot_test_module.addImport("../prolog/engine.zig", engine_test_module);
    snapshot_test_module.addImport("term_utils", term_utils_module);
    const snapshot_unit_tests = b.addTest(.{
        .root_module = snapshot_test_module,
    });
    linkFfi(snapshot_unit_tests, trealla);
    const run_snapshot_unit_tests = b.addRunArtifact(snapshot_unit_tests);
    test_step.dependOn(&run_snapshot_unit_tests.step);

    // manager persistence module (F010) — declared early for tool test dependencies
    const manager_test_module = b.createModule(.{
        .root_source_file = b.path("src/persistence/manager.zig"),
        .target = target,
        .optimize = optimize,
    });
    manager_test_module.addImport("../prolog/engine.zig", engine_test_module);
    manager_test_module.addImport("term_utils", term_utils_module);
    manager_test_module.addImport("snapshot.zig", snapshot_test_module);
    manager_test_module.addImport("wal.zig", wal_test_module);
    const manager_unit_tests = b.addTest(.{
        .root_module = manager_test_module,
    });
    linkFfi(manager_unit_tests, trealla);
    const run_manager_unit_tests = b.addRunArtifact(manager_unit_tests);
    test_step.dependOn(&run_manager_unit_tests.step);

    // forget_fact tool tests (pre-registration, F007)
    const forget_fact_test_module = b.createModule(.{
        .root_source_file = b.path("src/tools/forget_fact.zig"),
        .target = target,
        .optimize = optimize,
    });
    forget_fact_test_module.addImport("mcp", mcp_dep.module("mcp"));
    forget_fact_test_module.addImport("../prolog/engine.zig", engine_test_module);
    forget_fact_test_module.addImport("../persistence/manager.zig", manager_test_module);
    forget_fact_test_module.addImport("../persistence/wal.zig", wal_test_module);
    const forget_fact_unit_tests = b.addTest(.{
        .root_module = forget_fact_test_module,
    });
    linkFfi(forget_fact_unit_tests, trealla);
    const run_forget_fact_unit_tests = b.addRunArtifact(forget_fact_unit_tests);
    test_step.dependOn(&run_forget_fact_unit_tests.step);

    // clear_context tool tests (pre-registration, F007)
    const clear_context_test_module = b.createModule(.{
        .root_source_file = b.path("src/tools/clear_context.zig"),
        .target = target,
        .optimize = optimize,
    });
    clear_context_test_module.addImport("mcp", mcp_dep.module("mcp"));
    clear_context_test_module.addImport("../prolog/engine.zig", engine_test_module);
    clear_context_test_module.addImport("../persistence/manager.zig", manager_test_module);
    clear_context_test_module.addImport("../persistence/wal.zig", wal_test_module);
    const clear_context_unit_tests = b.addTest(.{
        .root_module = clear_context_test_module,
    });
    linkFfi(clear_context_unit_tests, trealla);
    const run_clear_context_unit_tests = b.addRunArtifact(clear_context_unit_tests);
    test_step.dependOn(&run_clear_context_unit_tests.step);

    // update_fact tool tests (pre-registration, F008)
    const update_fact_test_module = b.createModule(.{
        .root_source_file = b.path("src/tools/update_fact.zig"),
        .target = target,
        .optimize = optimize,
    });
    update_fact_test_module.addImport("mcp", mcp_dep.module("mcp"));
    update_fact_test_module.addImport("../prolog/engine.zig", engine_test_module);
    update_fact_test_module.addImport("../persistence/manager.zig", manager_test_module);
    update_fact_test_module.addImport("../persistence/wal.zig", wal_test_module);
    const update_fact_unit_tests = b.addTest(.{
        .root_module = update_fact_test_module,
    });
    linkFfi(update_fact_unit_tests, trealla);
    const run_update_fact_unit_tests = b.addRunArtifact(update_fact_unit_tests);
    test_step.dependOn(&run_update_fact_unit_tests.step);

    // upsert_fact tool tests (pre-registration, F008)
    const upsert_fact_test_module = b.createModule(.{
        .root_source_file = b.path("src/tools/upsert_fact.zig"),
        .target = target,
        .optimize = optimize,
    });
    upsert_fact_test_module.addImport("mcp", mcp_dep.module("mcp"));
    upsert_fact_test_module.addImport("../prolog/engine.zig", engine_test_module);
    upsert_fact_test_module.addImport("../persistence/manager.zig", manager_test_module);
    upsert_fact_test_module.addImport("../persistence/wal.zig", wal_test_module);
    const upsert_fact_unit_tests = b.addTest(.{
        .root_module = upsert_fact_test_module,
    });
    linkFfi(upsert_fact_unit_tests, trealla);
    const run_upsert_fact_unit_tests = b.addRunArtifact(upsert_fact_unit_tests);
    test_step.dependOn(&run_upsert_fact_unit_tests.step);

    // assume_fact tool tests (F009)
    const assume_fact_test_module = b.createModule(.{
        .root_source_file = b.path("src/tools/assume_fact.zig"),
        .target = target,
        .optimize = optimize,
    });
    assume_fact_test_module.addImport("mcp", mcp_dep.module("mcp"));
    assume_fact_test_module.addImport("../prolog/engine.zig", engine_test_module);
    assume_fact_test_module.addImport("../persistence/manager.zig", manager_test_module);
    assume_fact_test_module.addImport("../persistence/wal.zig", wal_test_module);
    const assume_fact_unit_tests = b.addTest(.{
        .root_module = assume_fact_test_module,
    });
    linkFfi(assume_fact_unit_tests, trealla);
    const run_assume_fact_unit_tests = b.addRunArtifact(assume_fact_unit_tests);
    test_step.dependOn(&run_assume_fact_unit_tests.step);

    // retract_assumption tool tests (F009)
    const retract_assumption_test_module = b.createModule(.{
        .root_source_file = b.path("src/tools/retract_assumption.zig"),
        .target = target,
        .optimize = optimize,
    });
    retract_assumption_test_module.addImport("mcp", mcp_dep.module("mcp"));
    retract_assumption_test_module.addImport("../prolog/engine.zig", engine_test_module);
    retract_assumption_test_module.addImport("../persistence/manager.zig", manager_test_module);
    retract_assumption_test_module.addImport("../persistence/wal.zig", wal_test_module);
    const retract_assumption_unit_tests = b.addTest(.{
        .root_module = retract_assumption_test_module,
    });
    linkFfi(retract_assumption_unit_tests, trealla);
    const run_retract_assumption_unit_tests = b.addRunArtifact(retract_assumption_unit_tests);
    test_step.dependOn(&run_retract_assumption_unit_tests.step);

    // get_belief_status tool tests (F009)
    const get_belief_status_test_module = b.createModule(.{
        .root_source_file = b.path("src/tools/get_belief_status.zig"),
        .target = target,
        .optimize = optimize,
    });
    get_belief_status_test_module.addImport("mcp", mcp_dep.module("mcp"));
    get_belief_status_test_module.addImport("../prolog/engine.zig", engine_test_module);
    const get_belief_status_unit_tests = b.addTest(.{
        .root_module = get_belief_status_test_module,
    });
    linkFfi(get_belief_status_unit_tests, trealla);
    const run_get_belief_status_unit_tests = b.addRunArtifact(get_belief_status_unit_tests);
    test_step.dependOn(&run_get_belief_status_unit_tests.step);

    // get_justification tool tests (F009)
    const get_justification_test_module = b.createModule(.{
        .root_source_file = b.path("src/tools/get_justification.zig"),
        .target = target,
        .optimize = optimize,
    });
    get_justification_test_module.addImport("mcp", mcp_dep.module("mcp"));
    get_justification_test_module.addImport("../prolog/engine.zig", engine_test_module);
    const get_justification_unit_tests = b.addTest(.{
        .root_module = get_justification_test_module,
    });
    linkFfi(get_justification_unit_tests, trealla);
    const run_get_justification_unit_tests = b.addRunArtifact(get_justification_unit_tests);
    test_step.dependOn(&run_get_justification_unit_tests.step);

    // list_assumptions tool tests (F009)
    const list_assumptions_test_module = b.createModule(.{
        .root_source_file = b.path("src/tools/list_assumptions.zig"),
        .target = target,
        .optimize = optimize,
    });
    list_assumptions_test_module.addImport("mcp", mcp_dep.module("mcp"));
    list_assumptions_test_module.addImport("../prolog/engine.zig", engine_test_module);
    const list_assumptions_unit_tests = b.addTest(.{
        .root_module = list_assumptions_test_module,
    });
    linkFfi(list_assumptions_unit_tests, trealla);
    const run_list_assumptions_unit_tests = b.addRunArtifact(list_assumptions_unit_tests);
    test_step.dependOn(&run_list_assumptions_unit_tests.step);

    // retract_assumptions tool tests (F009)
    const retract_assumptions_test_module = b.createModule(.{
        .root_source_file = b.path("src/tools/retract_assumptions.zig"),
        .target = target,
        .optimize = optimize,
    });
    retract_assumptions_test_module.addImport("mcp", mcp_dep.module("mcp"));
    retract_assumptions_test_module.addImport("../prolog/engine.zig", engine_test_module);
    retract_assumptions_test_module.addImport("../persistence/manager.zig", manager_test_module);
    retract_assumptions_test_module.addImport("../persistence/wal.zig", wal_test_module);
    const retract_assumptions_unit_tests = b.addTest(.{
        .root_module = retract_assumptions_test_module,
    });
    linkFfi(retract_assumptions_unit_tests, trealla);
    const run_retract_assumptions_unit_tests = b.addRunArtifact(retract_assumptions_unit_tests);
    test_step.dependOn(&run_retract_assumptions_unit_tests.step);

    retract_assumption_test_module.addImport("term_utils", term_utils_module);
    get_justification_test_module.addImport("term_utils", term_utils_module);
    retract_assumptions_test_module.addImport("term_utils", term_utils_module);

    // restore_snapshot tool tests (F010)
    const restore_snapshot_test_module = b.createModule(.{
        .root_source_file = b.path("src/tools/restore_snapshot.zig"),
        .target = target,
        .optimize = optimize,
    });
    restore_snapshot_test_module.addImport("mcp", mcp_dep.module("mcp"));
    restore_snapshot_test_module.addImport("../prolog/engine.zig", engine_test_module);
    restore_snapshot_test_module.addImport("../persistence/manager.zig", manager_test_module);
    restore_snapshot_test_module.addImport("../persistence/wal.zig", wal_test_module);
    const restore_snapshot_unit_tests = b.addTest(.{
        .root_module = restore_snapshot_test_module,
    });
    linkFfi(restore_snapshot_unit_tests, trealla);
    const run_restore_snapshot_unit_tests = b.addRunArtifact(restore_snapshot_unit_tests);
    test_step.dependOn(&run_restore_snapshot_unit_tests.step);

    // save_snapshot tool tests (F010)
    const save_snapshot_test_module = b.createModule(.{
        .root_source_file = b.path("src/tools/save_snapshot.zig"),
        .target = target,
        .optimize = optimize,
    });
    save_snapshot_test_module.addImport("mcp", mcp_dep.module("mcp"));
    save_snapshot_test_module.addImport("../prolog/engine.zig", engine_test_module);
    save_snapshot_test_module.addImport("../persistence/manager.zig", manager_test_module);
    save_snapshot_test_module.addImport("../persistence/wal.zig", wal_test_module);
    const save_snapshot_unit_tests = b.addTest(.{
        .root_module = save_snapshot_test_module,
    });
    linkFfi(save_snapshot_unit_tests, trealla);
    const run_save_snapshot_unit_tests = b.addRunArtifact(save_snapshot_unit_tests);
    test_step.dependOn(&run_save_snapshot_unit_tests.step);

    // list_snapshots tool tests (F010)
    const list_snapshots_test_module = b.createModule(.{
        .root_source_file = b.path("src/tools/list_snapshots.zig"),
        .target = target,
        .optimize = optimize,
    });
    list_snapshots_test_module.addImport("mcp", mcp_dep.module("mcp"));
    list_snapshots_test_module.addImport("../prolog/engine.zig", engine_test_module);
    list_snapshots_test_module.addImport("../persistence/manager.zig", manager_test_module);
    list_snapshots_test_module.addImport("../persistence/wal.zig", wal_test_module);
    const list_snapshots_unit_tests = b.addTest(.{
        .root_module = list_snapshots_test_module,
    });
    linkFfi(list_snapshots_unit_tests, trealla);
    const run_list_snapshots_unit_tests = b.addRunArtifact(list_snapshots_unit_tests);
    test_step.dependOn(&run_list_snapshots_unit_tests.step);

    // get_persistence_status tool tests (F010)
    const get_persistence_status_test_module = b.createModule(.{
        .root_source_file = b.path("src/tools/get_persistence_status.zig"),
        .target = target,
        .optimize = optimize,
    });
    get_persistence_status_test_module.addImport("mcp", mcp_dep.module("mcp"));
    get_persistence_status_test_module.addImport("../prolog/engine.zig", engine_test_module);
    get_persistence_status_test_module.addImport("../persistence/manager.zig", manager_test_module);
    get_persistence_status_test_module.addImport("../persistence/wal.zig", wal_test_module);
    const get_persistence_status_unit_tests = b.addTest(.{
        .root_module = get_persistence_status_test_module,
    });
    linkFfi(get_persistence_status_unit_tests, trealla);
    const run_get_persistence_status_unit_tests = b.addRunArtifact(get_persistence_status_unit_tests);
    test_step.dependOn(&run_get_persistence_status_unit_tests.step);

    // project module tests (F012)
    const project_test_module = b.createModule(.{
        .root_source_file = b.path("src/project.zig"),
        .target = target,
        .optimize = optimize,
    });
    project_test_module.addImport("prolog/engine.zig", engine_test_module);
    const project_unit_tests = b.addTest(.{
        .root_module = project_test_module,
    });
    linkFfi(project_unit_tests, trealla);
    const run_project_unit_tests = b.addRunArtifact(project_unit_tests);
    test_step.dependOn(&run_project_unit_tests.step);

    // cli module tests (F017) — registry tests run via exe_unit_tests (main.zig imports registry.zig)

    const arg_mapper_test_module = b.createModule(.{
        .root_source_file = b.path("src/cli/arg_mapper.zig"),
        .target = target,
        .optimize = optimize,
    });
    arg_mapper_test_module.addImport("mcp", mcp_dep.module("mcp"));
    const arg_mapper_unit_tests = b.addTest(.{ .root_module = arg_mapper_test_module });
    const run_arg_mapper_unit_tests = b.addRunArtifact(arg_mapper_unit_tests);
    test_step.dependOn(&run_arg_mapper_unit_tests.step);

    const output_test_module = b.createModule(.{
        .root_source_file = b.path("src/cli/output.zig"),
        .target = target,
        .optimize = optimize,
    });
    output_test_module.addImport("mcp", mcp_dep.module("mcp"));
    const output_unit_tests = b.addTest(.{ .root_module = output_test_module });
    const run_output_unit_tests = b.addRunArtifact(output_unit_tests);
    test_step.dependOn(&run_output_unit_tests.step);

    // upgrade module tests (F018)
    const version_module = b.createModule(.{
        .root_source_file = b.path("src/version.zig"),
        .target = target,
        .optimize = optimize,
    });
    const upgrade_test_module = b.createModule(.{
        .root_source_file = b.path("src/cli/upgrade.zig"),
        .target = target,
        .optimize = optimize,
    });
    upgrade_test_module.addImport("output.zig", output_test_module);
    upgrade_test_module.addImport("../version.zig", version_module);
    const upgrade_unit_tests = b.addTest(.{ .root_module = upgrade_test_module });
    const run_upgrade_unit_tests = b.addRunArtifact(upgrade_unit_tests);
    test_step.dependOn(&run_upgrade_unit_tests.step);
}

fn buildTrealla(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    // Trealla's C code has undefined-behavior patterns that trigger Zig
    // UBSan-on-Debug aborts when fed malformed Prolog (e.g. ")(invalid").
    // Real MCP clients can send arbitrary strings, so aborting the process
    // is worse than the original bug — we disable sanitize-c for Trealla so
    // bad input produces a recoverable error instead of a SIGABRT.
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .sanitize_c = .off,
    });
    const lib = b.addLibrary(.{
        .name = "trealla",
        .root_module = mod,
        .linkage = .static,
    });

    lib.addIncludePath(b.path("ffi/trealla/src"));
    lib.addIncludePath(b.path("ffi"));

    const lib_path = b.fmt("-DDEFAULT_LIBRARY_PATH=\"{s}\"", .{b.path("ffi/trealla/library").getPath(b)});
    const flags: []const []const u8 = &.{
        "-DUSE_OPENSSL=0",
        "-DUSE_FFI=0",
        "-DUSE_ISOCLINE",
        "-DEMBED=1",
        "-D_GNU_SOURCE",
        lib_path,
    };

    // Build bin2c as a native build tool to embed .pl libraries as C arrays
    const bin2c_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    const bin2c = b.addExecutable(.{
        .name = "bin2c",
        .root_module = bin2c_mod,
    });
    bin2c.addCSourceFile(.{
        .file = b.path("ffi/trealla/util/bin2c.c"),
        .flags = &.{},
    });
    bin2c.linkLibC();

    // Embed each .pl library file as a C source with byte arrays
    const pl_libs = [_][]const u8{
        "abnf",     "aggregate", "arithmetic", "assoc",   "atts",
        "builtins", "charsio",   "concurrent", "clpz",    "curl",
        "dcgs",     "debug",     "dif",        "error",   "format",
        "freeze",   "gensym",    "gsl",        "http",    "iso_ext",
        "json",     "lambda",    "lists",      "ordsets", "pairs",
        "pio",      "random",    "raylib",     "rbtrees", "reif",
        "si",       "sockets",   "sqlite3",    "time",    "ugraphs",
        "uuid",     "when",
    };

    const wf = b.addWriteFiles();
    for (pl_libs) |name| {
        const gen = b.addRunArtifact(bin2c);
        gen.setCwd(b.path("ffi/trealla"));
        gen.addArg(b.fmt("library/{s}.pl", .{name}));
        const out_name = b.fmt("library_{s}_pl.c", .{name});
        const generated_c = wf.addCopyFile(gen.captureStdOut(), out_name);
        lib.addCSourceFile(.{
            .file = generated_c,
            .flags = &.{},
        });
    }

    lib.addCSourceFiles(.{
        .root = b.path("ffi/trealla/src"),
        .files = &.{
            "imath/imath.c",
            "imath/imrat.c",
            "isocline/src/isocline.c",
            "sre/re.c",
            "base64.c",
            "bif_atts.c",
            "bif_bboard.c",
            "bif_control.c",
            "bif_csv.c",
            "bif_database.c",
            "bif_ffi.c",
            "bif_format.c",
            "bif_functions.c",
            "bif_maps.c",
            "bif_os.c",
            "bif_posix.c",
            "bif_predicates.c",
            "bif_sort.c",
            "bif_sregex.c",
            "bif_streams.c",
            "bif_tasks.c",
            "bif_threads.c",
            "compile.c",
            "heap.c",
            "history.c",
            "library.c",
            "list.c",
            "module.c",
            "network.c",
            "parser.c",
            "print.c",
            "prolog.c",
            "query.c",
            "skiplist.c",
            "terms.c",
            "toplevel.c",
            "unify.c",
            "utf8.c",
            "version.c",
        },
        .flags = flags,
    });

    lib.linkSystemLibrary("m");
    lib.linkLibC();

    return lib;
}

fn linkFfi(compile: *std.Build.Step.Compile, trealla: *std.Build.Step.Compile) void {
    compile.linkLibrary(trealla);
    compile.linkSystemLibrary("m");
    compile.linkLibC();
}
