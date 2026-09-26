const std = @import("std");
const hibana = @import("root.zig");
const Response = hibana.Response;
const Next = hibana.Next;
const t = std.testing;

const Env = struct {
    forwarded: ?hibana.ForwardRequest = null,

    pub fn forward(self: *Env, _: std.mem.Allocator, req: hibana.ForwardRequest) !Response {
        self.forwarded = req;
        return .init(.accepted, "from upstream");
    }
};
const Rt = hibana.testing.Runtime(Env);

const Vars = struct { user: ?[]const u8 = null, trace: std.ArrayList(u8) = .empty };
const Ctx = hibana.Context(Rt, Vars);

const Color = enum { red, green };

fn index(c: *Ctx) !Response {
    return c.text("hello");
}
fn showUser(c: *Ctx, p: struct { id: u32 }) !Response {
    return c.json(.{ .id = p.id, .user = c.vars.user });
}
fn showColor(c: anytype, p: struct { name: []const u8, color: Color }) !Response {
    return c.text(try std.fmt.allocPrint(c.arena, "{s}:{t}", .{ p.name, p.color }));
}
fn search(c: *Ctx) !Response {
    return c.text((try c.req.query("q")) orelse "none");
}
fn createItem(c: *Ctx) !Response {
    const Item = struct { name: []const u8, qty: u32 = 1 };
    const item = try c.req.json(Item);
    return c.jsonStatus(.created, item);
}
fn ignoresBody(c: *Ctx) !Response {
    return c.status(.no_content);
}
fn fails(_: *Ctx) !Response {
    return error.Conflict;
}
fn proxy(c: *Ctx) !Response {
    return c.forward("https://upstream.example/x");
}
fn proxyWithCredentials(c: *Ctx) !Response {
    return c.forwardWith("https://upstream.example/x", .{ .credentials = true });
}
fn go(c: *Ctx) !Response {
    return c.redirect((try c.req.query("to")) orelse "/", .found);
}
fn cookies(c: *Ctx) !Response {
    try c.header("set-cookie", "a=1");
    try c.header("set-cookie", "b=2");
    return c.text("ok");
}
fn badHeaderName(c: *Ctx) !Response {
    try c.header("x a", "1");
    return c.text("x");
}

fn auth(c: *Ctx, next: Next) !Response {
    if (try c.req.header("authorization")) |v| c.vars.user = v;
    try c.vars.trace.appendSlice(c.arena, "a>");
    const res = try next.run();
    try c.vars.trace.appendSlice(c.arena, "<a");
    return res;
}
fn poweredBy(c: *Ctx, next: Next) !Response {
    try c.header("x-powered-by", "hibana");
    try c.vars.trace.appendSlice(c.arena, "b>");
    var res = try next.run();
    try c.vars.trace.appendSlice(c.arena, "<b");
    try res.setHeader(c.arena, "x-trace", c.vars.trace.items);
    return res;
}

const App = hibana.App(Rt, .{
    .Vars = Vars,
    .middleware = .{ poweredBy, auth },
    .routes = .{
        hibana.get("/", index),
        hibana.get("/users/:id", showUser),
        hibana.get("/colors/:name/:color", showColor),
        hibana.get("/search", search),
        hibana.post("/items", createItem),
        hibana.post("/lazy", ignoresBody),
        hibana.get("/fail", fails),
        hibana.all("/proxy", proxy),
        hibana.all("/proxy-creds", proxyWithCredentials),
        hibana.get("/go", go),
        hibana.get("/bad-name", badHeaderName),
        hibana.get("/cookies", cookies),
    },
});

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    env: Env = .{},

    fn init() Harness {
        return .{ .arena = .init(t.allocator) };
    }
    fn deinit(h: *Harness) void {
        h.arena.deinit();
    }
    fn req(h: *Harness, url: []const u8, opts: hibana.testing.RequestOptions) Response {
        return hibana.testing.request(App, h.arena.allocator(), &h.env, url, opts);
    }
};

test "static route" {
    var h: Harness = .init();
    defer h.deinit();
    const res = h.req("https://example.com/", .{});
    try t.expectEqual(hibana.Status.ok, res.status);
    try t.expectEqualStrings("hello", res.body);
    try t.expectEqualStrings("text/plain; charset=utf-8", res.header("content-type").?);
}

test "typed params and middleware vars" {
    var h: Harness = .init();
    defer h.deinit();
    const res = h.req("/users/42", .{ .headers = &.{.{ .name = "Authorization", .value = "alice" }} });
    try t.expectEqual(hibana.Status.ok, res.status);
    try t.expectEqualStrings("{\"id\":42,\"user\":\"alice\"}", res.body);
}

test "anytype ctx, percent-decoded string and enum params" {
    var h: Harness = .init();
    defer h.deinit();
    const res = h.req("/colors/a%20b/green", .{});
    try t.expectEqualStrings("a b:green", res.body);
}

test "unparseable param is a 400 with detail" {
    var h: Harness = .init();
    defer h.deinit();
    const res = h.req("/users/abc", .{});
    try t.expectEqual(hibana.Status.bad_request, res.status);
    try t.expectEqualStrings("{\"error\":\"Bad Request\",\"detail\":\"invalid path parameter 'id'\"}", res.body);
}

test "404 and 405" {
    var h: Harness = .init();
    defer h.deinit();
    try t.expectEqual(hibana.Status.not_found, h.req("/nope", .{}).status);
    const res = h.req("/users/1", .{ .method = .DELETE });
    try t.expectEqual(hibana.Status.method_not_allowed, res.status);
    try t.expectEqualStrings("GET, HEAD", res.header("allow").?);
}

test "HEAD is served by the GET route without a body (review M3)" {
    var h: Harness = .init();
    defer h.deinit();
    const res = h.req("/", .{ .method = .HEAD });
    try t.expectEqual(hibana.Status.ok, res.status);
    try t.expectEqualStrings("", res.body);
    try t.expectEqualStrings("text/plain; charset=utf-8", res.header("content-type").?);
}

test "'://' in an origin-form query does not re-route (review M1)" {
    var h: Harness = .init();
    defer h.deinit();
    try t.expectEqualStrings("none", h.req("/search?next=http://x/", .{}).body);
    try t.expectEqual(hibana.Status.not_found, h.req("/nope?next=http://x/", .{}).status);
}

test "CR/LF in header values and invalid names never reach the wire (review H2)" {
    var h: Harness = .init();
    defer h.deinit();
    for ([_][]const u8{ "/go?to=/x%0D%0Aset-cookie:%20pwn=1", "/go?to=/x%0Aset-cookie:%20pwn=1", "/go?to=/x%00" }) |url| {
        const res = h.req(url, .{});
        try t.expectEqual(hibana.Status.internal_server_error, res.status);
        try t.expect(res.header("location") == null);
        try t.expect(res.header("set-cookie") == null);
    }
    try t.expectEqual(hibana.Status.found, h.req("/go?to=/ok", .{}).status);
    try t.expectEqual(hibana.Status.internal_server_error, h.req("/bad-name", .{}).status);
}

test "middleware runs as an onion and c.header reaches the response" {
    var h: Harness = .init();
    defer h.deinit();
    const res = h.req("/", .{});
    try t.expectEqualStrings("b>a><a<b", res.header("x-trace").?);
    try t.expectEqualStrings("hibana", res.header("x-powered-by").?);
}

test "query string" {
    var h: Harness = .init();
    defer h.deinit();
    try t.expectEqualStrings("zig lang", h.req("/search?x=1&q=zig+lang", .{}).body);
    try t.expectEqualStrings("none", h.req("/search", .{}).body);
}

test "typed JSON body" {
    var h: Harness = .init();
    defer h.deinit();
    const res = h.req("/items", .{ .method = .POST, .body = "{\"name\":\"pen\",\"extra\":true}" });
    try t.expectEqual(hibana.Status.created, res.status);
    try t.expectEqualStrings("{\"name\":\"pen\",\"qty\":1}", res.body);
}

test "invalid JSON body is a 400 with detail" {
    var h: Harness = .init();
    defer h.deinit();
    const missing = h.req("/items", .{ .method = .POST, .body = "{\"qty\":2}" });
    try t.expectEqual(hibana.Status.bad_request, missing.status);
    try t.expect(std.mem.indexOf(u8, missing.body, "MissingField") != null);

    const empty = h.req("/items", .{ .method = .POST });
    try t.expectEqual(hibana.Status.bad_request, empty.status);

    const malformed = h.req("/items", .{ .method = .POST, .body = "{nope" });
    try t.expectEqual(hibana.Status.bad_request, malformed.status);
}

test "body is not read unless the handler asks" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var env: Env = .{};
    var raw: Rt.Request = .{ .method_ = .POST, .url_ = "/lazy", .body_ = "big" };
    const res = App.handle(arena.allocator(), &raw, &env);
    try t.expectEqual(hibana.Status.no_content, res.status);
    try t.expectEqual(@as(usize, 0), raw.body_reads);
}

test "handler errors map to HTTP statuses" {
    var h: Harness = .init();
    defer h.deinit();
    const res = h.req("/fail", .{});
    try t.expectEqual(hibana.Status.conflict, res.status);
    try t.expectEqualStrings("{\"error\":\"Conflict\"}", res.body);
}

test "forward passes method, headers (minus host) and body" {
    var h: Harness = .init();
    defer h.deinit();
    const res = h.req("/proxy", .{
        .method = .PUT,
        .body = "payload",
        .headers = &.{ .{ .name = "Host", .value = "me" }, .{ .name = "x-a", .value = "1" } },
    });
    try t.expectEqual(hibana.Status.accepted, res.status);
    const fwd = h.env.forwarded.?;
    try t.expectEqual(hibana.Method.PUT, fwd.method);
    try t.expectEqualStrings("https://upstream.example/x", fwd.url);
    try t.expectEqual(@as(usize, 1), fwd.headers.len);
    try t.expectEqualStrings("x-a", fwd.headers[0].name);
    try t.expectEqualStrings("payload", fwd.body.?);
}

const sensitive_headers = [_]hibana.Header{
    .{ .name = "content-length", .value = "7" },
    .{ .name = "Connection", .value = "keep-alive, x-secret" },
    .{ .name = "x-secret", .value = "s" },
    .{ .name = "te", .value = "trailers" },
    .{ .name = "proxy-authorization", .value = "p" },
    .{ .name = "cookie", .value = "session=abc" },
    .{ .name = "authorization", .value = "Bearer t" },
    .{ .name = "x-keep", .value = "1" },
};

test "forward drops hop-by-hop and credentials, keeps DELETE bodies (review M2)" {
    var h: Harness = .init();
    defer h.deinit();
    _ = h.req("/proxy", .{ .method = .DELETE, .body = "payload", .headers = &sensitive_headers });
    const fwd = h.env.forwarded.?;
    try t.expectEqualStrings("payload", fwd.body.?);
    try t.expectEqual(@as(usize, 1), fwd.headers.len);
    try t.expectEqualStrings("x-keep", fwd.headers[0].name);

    _ = h.req("/proxy", .{ .method = .GET, .body = "ignored" });
    try t.expect(h.env.forwarded.?.body == null);
}

test "forwardWith credentials keeps cookie and authorization" {
    var h: Harness = .init();
    defer h.deinit();
    _ = h.req("/proxy-creds", .{ .method = .POST, .headers = &sensitive_headers });
    const fwd = h.env.forwarded.?;
    try t.expectEqual(@as(usize, 3), fwd.headers.len);
    try t.expect(fwd.body == null);
}

fn customError(c: *Ctx, err: anyerror) !Response {
    return c.jsonStatus(hibana.statusOf(err), .{ .message = @errorName(err) });
}
fn customNotFound(c: *Ctx) !Response {
    var res = try c.text("custom 404");
    res.status = .not_found;
    return res;
}
const CustomApp = hibana.App(Rt, .{
    .Vars = Vars,
    .routes = .{hibana.get("/fail", fails)},
    .on_error = customError,
    .not_found = customNotFound,
});

test "custom on_error and not_found" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var env: Env = .{};
    const a = hibana.testing.request(CustomApp, arena.allocator(), &env, "/fail", .{});
    try t.expectEqualStrings("{\"message\":\"Conflict\"}", a.body);
    const b = hibana.testing.request(CustomApp, arena.allocator(), &env, "/x", .{});
    try t.expectEqualStrings("custom 404", b.body);
    try t.expectEqual(hibana.Status.not_found, b.status);
}

test "repeated c.header values are all kept (set-cookie)" {
    var h: Harness = .init();
    defer h.deinit();
    const res = h.req("/cookies", .{});
    var n: usize = 0;
    for (res.headers.items) |hd| {
        if (std.ascii.eqlIgnoreCase(hd.name, "set-cookie")) n += 1;
    }
    try t.expectEqual(@as(usize, 2), n);
}

test "forward honors tokens from every Connection field" {
    var h: Harness = .init();
    defer h.deinit();
    _ = h.req("/proxy", .{ .headers = &.{
        .{ .name = "connection", .value = "x-internal" },
        .{ .name = "connection", .value = "keep-alive" },
        .{ .name = "x-internal", .value = "secret" },
        .{ .name = "x-keep", .value = "1" },
    } });
    const fwd = h.env.forwarded.?;
    try t.expectEqual(@as(usize, 1), fwd.headers.len);
    try t.expectEqualStrings("x-keep", fwd.headers[0].name);
}

test "malformed percent escapes are not a server error" {
    var h: Harness = .init();
    defer h.deinit();
    try t.expectEqualStrings("%", h.req("/search?q=%", .{}).body);
    try t.expectEqualStrings("%ZZ", h.req("/search?q=%ZZ", .{}).body);
    try t.expectEqual(hibana.Status.bad_request, h.req("/users/%ZZ", .{}).status);
    try t.expectEqualStrings("x:red", h.req("/colors/x/red", .{}).body);
    try t.expectEqualStrings("%ZZ:red", h.req("/colors/%ZZ/red", .{}).body);
}
