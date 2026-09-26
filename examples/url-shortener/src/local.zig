//! Local server on std.http with in-memory storage: `zig build run`.

const std = @import("std");
const hstd = @import("hibana-std");
const app = @import("app.zig");
const mem = @import("memory_store.zig");

const App = app.App(hstd.Runtime(mem.Env), mem.Store);

pub fn main(init: std.process.Init) !void {
    var env: mem.Env = .{ .gpa = init.gpa, .io = init.io };
    defer env.deinit();
    var server: hstd.Server(App) = try .listen(init.io, init.gpa, &env, .{});
    defer server.deinit();
    std.log.info("listening on http://127.0.0.1:{d}", .{server.port()});
    try server.run();
}
