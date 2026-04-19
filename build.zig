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

    const cargo_build = b.addSystemCommand(&.{ "cargo", "build", "--release" });
    cargo_build.setCwd(b.path("ffi/zpm-prolog-ffi"));

    const patch_step: ?*std.Build.Step = if (target.result.os.tag == .linux) blk: {
        const patch_ffi = b.addSystemCommand(&.{
            "objcopy",
            "--redefine-sym",
            "cfgetospeed@GLIBC_2.2.5=cfgetospeed",
            "--redefine-sym",
            "cfgetispeed@GLIBC_2.2.5=cfgetispeed",
            "--redefine-sym",
            "cfsetospeed@GLIBC_2.2.5=cfsetospeed",
            "--redefine-sym",
            "cfsetispeed@GLIBC_2.2.5=cfsetispeed",
            "--redefine-sym",
            "cfsetspeed@GLIBC_2.2.5=cfsetspeed",
            "ffi/zpm-prolog-ffi/target/release/libzpm_prolog_ffi.a",
        });
        patch_ffi.step.dependOn(&cargo_build.step);
        break :blk &patch_ffi.step;
    } else null;

    const exe = b.addExecutable(.{
        .name = "zpm",
        .root_module = exe_module,
    });
    linkFfi(exe, b, patch_step);
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the MCP server");
    run_step.dependOn(&run_exe.step);

    // Roundtrip example
    const roundtrip_module = b.createModule(.{
        .root_source_file = b.path("examples/roundtrip.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "prolog/engine", .module = b.createModule(.{
            .root_source_file = b.path("src/prolog/engine.zig"),
            .target = target,
            .optimize = optimize,
        }) }},
    });
    const roundtrip_exe = b.addExecutable(.{
        .name = "roundtrip",
        .root_module = roundtrip_module,
    });
    linkFfi(roundtrip_exe, b, patch_step);
    const run_roundtrip = b.addRunArtifact(roundtrip_exe);
    const roundtrip_step = b.step("roundtrip", "Run Prolog roundtrip example");
    roundtrip_step.dependOn(&run_roundtrip.step);

    const test_step = b.step("test", "Run unit tests");

    // Executable tests (reuses exe_module)
    const exe_unit_tests = b.addTest(.{
        .root_module = exe_module,
    });
    linkFfi(exe_unit_tests, b, patch_step);
    // scryer-prolog FFI writes to stdout on init, corrupting the zig_test
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
    linkFfi(engine_unit_tests, b, patch_step);
    const run_engine_unit_tests = b.addRunArtifact(engine_unit_tests);
    test_step.dependOn(&run_engine_unit_tests.step);

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
    linkFfi(wal_unit_tests, b, patch_step);
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
    linkFfi(snapshot_unit_tests, b, patch_step);
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
    linkFfi(manager_unit_tests, b, patch_step);
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
    linkFfi(forget_fact_unit_tests, b, patch_step);
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
    linkFfi(clear_context_unit_tests, b, patch_step);
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
    linkFfi(update_fact_unit_tests, b, patch_step);
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
    linkFfi(upsert_fact_unit_tests, b, patch_step);
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
    linkFfi(assume_fact_unit_tests, b, patch_step);
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
    linkFfi(retract_assumption_unit_tests, b, patch_step);
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
    linkFfi(get_belief_status_unit_tests, b, patch_step);
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
    linkFfi(get_justification_unit_tests, b, patch_step);
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
    linkFfi(list_assumptions_unit_tests, b, patch_step);
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
    linkFfi(retract_assumptions_unit_tests, b, patch_step);
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
    linkFfi(restore_snapshot_unit_tests, b, patch_step);
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
    linkFfi(save_snapshot_unit_tests, b, patch_step);
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
    linkFfi(list_snapshots_unit_tests, b, patch_step);
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
    linkFfi(get_persistence_status_unit_tests, b, patch_step);
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
    linkFfi(project_unit_tests, b, patch_step);
    const run_project_unit_tests = b.addRunArtifact(project_unit_tests);
    test_step.dependOn(&run_project_unit_tests.step);
}

fn linkFfi(compile: *std.Build.Step.Compile, b: *std.Build, patch_step: ?*std.Build.Step) void {
    compile.addLibraryPath(b.path("ffi/zpm-prolog-ffi/target/release"));
    compile.linkSystemLibrary("zpm_prolog_ffi");
    compile.linkSystemLibrary("ssl");
    compile.linkSystemLibrary("crypto");
    if (compile.rootModuleTarget().os.tag == .linux) {
        compile.linkSystemLibrary("gcc_s");
    }
    compile.linkLibC();
    if (patch_step) |step| compile.step.dependOn(step);
}
