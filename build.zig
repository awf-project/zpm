const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mcp_dep = b.dependency("mcp", .{});
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("mcp", mcp_dep.module("mcp"));

    const cargo_build = b.addSystemCommand(&.{ "cargo", "build", "--release" });
    cargo_build.setCwd(b.path("ffi/zpm-prolog-ffi"));

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

    const exe = b.addExecutable(.{
        .name = "zpm",
        .root_module = exe_module,
    });
    linkFfi(exe, b, &patch_ffi.step);
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
    linkFfi(roundtrip_exe, b, &patch_ffi.step);
    const run_roundtrip = b.addRunArtifact(roundtrip_exe);
    const roundtrip_step = b.step("roundtrip", "Run Prolog roundtrip example");
    roundtrip_step.dependOn(&run_roundtrip.step);

    const test_step = b.step("test", "Run unit tests");

    // Executable tests (reuses exe_module)
    const exe_unit_tests = b.addTest(.{
        .root_module = exe_module,
    });
    linkFfi(exe_unit_tests, b, &patch_ffi.step);
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    test_step.dependOn(&run_exe_unit_tests.step);

    // Engine tests
    const engine_test_module = b.createModule(.{
        .root_source_file = b.path("src/prolog/engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    const engine_unit_tests = b.addTest(.{
        .root_module = engine_test_module,
    });
    linkFfi(engine_unit_tests, b, &patch_ffi.step);
    const run_engine_unit_tests = b.addRunArtifact(engine_unit_tests);
    test_step.dependOn(&run_engine_unit_tests.step);

    // forget_fact tool tests (pre-registration, F007)
    const forget_fact_test_module = b.createModule(.{
        .root_source_file = b.path("src/tools/forget_fact.zig"),
        .target = target,
        .optimize = optimize,
    });
    forget_fact_test_module.addImport("mcp", mcp_dep.module("mcp"));
    forget_fact_test_module.addImport("../prolog/engine.zig", engine_test_module);
    const forget_fact_unit_tests = b.addTest(.{
        .root_module = forget_fact_test_module,
    });
    linkFfi(forget_fact_unit_tests, b, &patch_ffi.step);
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
    const clear_context_unit_tests = b.addTest(.{
        .root_module = clear_context_test_module,
    });
    linkFfi(clear_context_unit_tests, b, &patch_ffi.step);
    const run_clear_context_unit_tests = b.addRunArtifact(clear_context_unit_tests);
    test_step.dependOn(&run_clear_context_unit_tests.step);
}

fn linkFfi(compile: *std.Build.Step.Compile, b: *std.Build, patch_step: *std.Build.Step) void {
    compile.addLibraryPath(b.path("ffi/zpm-prolog-ffi/target/release"));
    compile.linkSystemLibrary("zpm_prolog_ffi");
    compile.linkSystemLibrary("ssl");
    compile.linkSystemLibrary("crypto");
    compile.linkSystemLibrary("gcc_s");
    compile.linkLibC();
    compile.step.dependOn(patch_step);
}
