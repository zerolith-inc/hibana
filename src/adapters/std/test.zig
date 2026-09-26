//! Integration test: a real std.http server and client over loopback.

const std = @import("std");
const hibana = @import("hibana");
const hstd = @import("hibana-std");
const t = std.testing;

const Env = struct { greeting: []const u8 = "hi" };
const Rt = hstd.Runtime(Env);
const Ctx = hibana.Context(Rt, hibana.NoVars);

fn hello(c: *Ctx, p: struct { name: []const u8 }) !hibana.Response {
    return c.text(try std.fmt.allocPrint(c.arena, "{s} {s}", .{ c.env.greeting, p.name }));
}
fn echo(c: *Ctx) !hibana.Response {
    const In = struct { n: i64 };
    const in = try c.req.json(In);
    return c.json(.{ .doubled = in.n * 2 });
}
fn skip(c: *Ctx) !hibana.Response {
    return c.text("skipped body");
}
fn proxy(c: *Ctx) !hibana.Response {
    const target = (try c.req.query("to")) orelse return error.BadRequest;
    return c.forward(target);
}

const App = hibana.App(Rt, .{ .routes = .{
    hibana.get("/hello/:name", hello),
    hibana.post("/echo", echo),
    hibana.post("/skip", skip),
    hibana.all("/proxy", proxy),
} });

const Fixture = struct {
    env: Env = .{},
    server: hstd.Server(App) = undefined,
    task: std.Io.Future(std.Io.Cancelable!void) = undefined,

    fn start(f: *Fixture) !void {
        f.server = try .listen(t.io, t.allocator, &f.env, .{ .address = .{ .ip4 = .loopback(0) } });
        f.task = try t.io.concurrent(hstd.Server(App).run, .{&f.server});
    }
    fn stop(f: *Fixture) void {
        f.task.cancel(t.io) catch {};
        f.server.deinit();
    }
};

const Result = struct { status: std.http.Status, body: []u8 };

fn call(arena: std.mem.Allocator, method: std.http.Method, url: []const u8, payload: ?[]const u8) !Result {
    var client: std.http.Client = .{ .allocator = t.allocator, .io = t.io };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(arena);
    const r = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .response_writer = &body.writer,
        .keep_alive = false,
    });
    return .{ .status = r.status, .body = body.written() };
}

test "std adapter serves routes, JSON, errors and forward over real HTTP" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var f: Fixture = .{};
    try f.start();
    defer f.stop();
    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{f.server.port()});

    const r1 = try call(a, .GET, try std.fmt.allocPrint(a, "{s}/hello/zig", .{base}), null);
    try t.expectEqual(std.http.Status.ok, r1.status);
    try t.expectEqualStrings("hi zig", r1.body);

    const r2 = try call(a, .POST, try std.fmt.allocPrint(a, "{s}/echo", .{base}), "{\"n\":21}");
    try t.expectEqualStrings("{\"doubled\":42}", r2.body);

    const r3 = try call(a, .POST, try std.fmt.allocPrint(a, "{s}/echo", .{base}), "{\"n\":\"x\"}");
    try t.expectEqual(std.http.Status.bad_request, r3.status);

    const r4 = try call(a, .GET, try std.fmt.allocPrint(a, "{s}/missing", .{base}), null);
    try t.expectEqual(std.http.Status.not_found, r4.status);

    const r5 = try call(a, .POST, try std.fmt.allocPrint(a, "{s}/skip", .{base}), "unread body");
    try t.expectEqualStrings("skipped body", r5.body);

    // Forward to ourselves: /proxy?to=<base>/hello/fwd
    const r6 = try call(a, .GET, try std.fmt.allocPrint(a, "{s}/proxy?to={s}/hello/fwd", .{ base, base }), null);
    try t.expectEqual(std.http.Status.ok, r6.status);
    try t.expectEqualStrings("hi fwd", r6.body);
}
