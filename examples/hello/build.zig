const std = @import("std");
const hibana = @import("hibana");

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseSmall)") orelse .ReleaseSmall;
    const dep = b.dependency("hibana", .{});
    const worker = hibana.addWorker(b, dep, b.path("src/main.zig"), .{ .optimize = optimize });
    b.installArtifact(worker);
}
