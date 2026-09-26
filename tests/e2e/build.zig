const std = @import("std");
const hibana = @import("hibana");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("hibana", .{});
    b.installArtifact(hibana.addWorker(b, dep, b.path("src/main.zig"), .{}));
}
