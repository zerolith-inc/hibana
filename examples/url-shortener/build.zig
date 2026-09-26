const std = @import("std");
const hibana = @import("hibana");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseSmall for the worker, Debug for local/test)");
    const dep = b.dependency("hibana", .{});

    // Worker: zig-out/bin/{worker.wasm,entry.js,shim.js}
    const worker = hibana.addWorker(b, dep, b.path("src/main.zig"), .{ .optimize = optimize orelse .ReleaseSmall });
    b.installArtifact(worker);

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "hibana", .module = dep.module("hibana") },
        .{ .name = "hibana-std", .module = dep.module("hibana-std") },
    };

    // Local server on std.http with in-memory storage.
    const local = b.addExecutable(.{
        .name = "url-shortener-local",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/local.zig"),
            .target = target,
            .optimize = optimize orelse .Debug,
            .imports = imports,
        }),
    });
    const run = b.addRunArtifact(local);
    b.step("run", "Run the app locally on std.http (in-memory storage)").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/app_test.zig"),
        .target = target,
        .optimize = optimize orelse .Debug,
        .imports = imports,
    }) });
    b.step("test", "Run app tests on the fake runtime").dependOn(&b.addRunArtifact(tests).step);
}
