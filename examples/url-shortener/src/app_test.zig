const std = @import("std");
const hibana = @import("hibana");
const app = @import("app.zig");
const mem = @import("memory_store.zig");
const t = std.testing;

const App = app.App(hibana.testing.Runtime(mem.Env), mem.Store);

test "shorten then resolve" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var env: mem.Env = .{ .gpa = t.allocator, .io = t.io };
    defer env.deinit();

    const created = hibana.testing.request(App, arena.allocator(), &env, "/shorten", .{
        .method = .POST,
        .body = "{\"url\":\"https://ziglang.org\"}",
    });
    try t.expectEqual(hibana.Status.created, created.status);
    try t.expectEqualStrings("nosniff", created.header("x-content-type-options").?);

    const Out = struct { code: []const u8, url: []const u8 };
    const out = try std.json.parseFromSliceLeaky(Out, arena.allocator(), created.body, .{});
    try t.expectEqual(app.code_len, out.code.len);

    const path = try std.fmt.allocPrint(arena.allocator(), "/{s}", .{out.code});
    const res = hibana.testing.request(App, arena.allocator(), &env, path, .{});
    try t.expectEqual(hibana.Status.found, res.status);
    try t.expectEqualStrings("https://ziglang.org", res.header("location").?);
}

test "rejects bad input and unknown codes" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var env: mem.Env = .{ .gpa = t.allocator, .io = t.io };
    defer env.deinit();
    const a = arena.allocator();

    try t.expectEqual(hibana.Status.bad_request, hibana.testing.request(App, a, &env, "/shorten", .{
        .method = .POST,
        .body = "{\"url\":\"ftp://x\"}",
    }).status);
    try t.expectEqual(hibana.Status.bad_request, hibana.testing.request(App, a, &env, "/shorten", .{
        .method = .POST,
        .body = "{}",
    }).status);
    try t.expectEqual(hibana.Status.not_found, hibana.testing.request(App, a, &env, "/abcdefg", .{}).status);
}
