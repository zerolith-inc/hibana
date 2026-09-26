const std = @import("std");
const workers_zig = @import("workers-zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library modules carry no target, so they compile for whatever root
    // module imports them (native for tests, wasm32-wasi for workers).
    //
    // Core is given no imports, so it cannot reach workers-zig or any
    // adapter: the boundary is enforced by the compiler.
    const core = b.addModule("hibana", .{
        .root_source_file = b.path("src/core/root.zig"),
    });

    const std_adapter = b.addModule("hibana-std", .{
        .root_source_file = b.path("src/adapters/std/root.zig"),
        .imports = &.{.{ .name = "hibana", .module = core }},
    });

    const workers_dep = b.dependency("workers-zig", .{});
    _ = b.addModule("hibana-workers", .{
        .root_source_file = b.path("src/adapters/workers/root.zig"),
        .imports = &.{
            .{ .name = "hibana", .module = core },
            .{ .name = "workers-zig", .module = workers_dep.module("workers-zig") },
        },
    });

    const test_step = b.step("test", "Run core unit tests and std adapter integration tests");

    const core_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    const std_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/adapters/std/test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hibana", .module = core },
            .{ .name = "hibana-std", .module = std_adapter },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(std_tests).step);
}

pub const WorkerOptions = workers_zig.WorkerOptions;

/// Builds a Cloudflare Worker whose source can `@import("hibana")` and
/// `@import("hibana-workers")` (and `@import("workers-zig")`). Produces
/// `zig-out/bin/{worker.wasm,entry.js,shim.js}` for wrangler.
///
/// ```zig
/// const hibana = @import("hibana");
/// const dep = b.dependency("hibana", .{});
/// _ = hibana.addWorker(b, dep, b.path("src/main.zig"), .{ .optimize = optimize });
/// ```
pub fn addWorker(
    b: *std.Build,
    hibana_dep: *std.Build.Dependency,
    source: std.Build.LazyPath,
    options: WorkerOptions,
) *std.Build.Step.Compile {
    const workers_dep = hibana_dep.builder.dependency("workers-zig", .{});
    const exe = workers_zig.addWorker(b, workers_dep, source, options);
    const user_mod = exe.root_module.import_table.get("worker_main").?;
    user_mod.addImport("hibana", hibana_dep.module("hibana"));
    user_mod.addImport("hibana-workers", hibana_dep.module("hibana-workers"));
    return exe;
}
