const std = @import("std");
const Allocator = std.mem.Allocator;
const Method = std.http.Method;
const router = @import("router.zig");
const context = @import("context.zig");
const http_error = @import("http_error.zig");
const Response = @import("response.zig").Response;

/// The `Vars` type used when an app declares none. Use it to name the
/// context type: `hibana.Context(Runtime, hibana.NoVars)`.
pub const NoVars = struct {};

/// A route definition, built with `get`, `post`, ... or `on`.
pub fn Route(comptime Handler: type) type {
    return struct {
        /// null matches any method.
        method: ?Method,
        pattern: []const u8,
        handler: Handler,
    };
}

pub fn on(comptime method: ?Method, comptime pattern: []const u8, comptime handler: anytype) Route(@TypeOf(handler)) {
    return .{ .method = method, .pattern = pattern, .handler = handler };
}
pub fn get(comptime pattern: []const u8, comptime handler: anytype) Route(@TypeOf(handler)) {
    return on(.GET, pattern, handler);
}
pub fn post(comptime pattern: []const u8, comptime handler: anytype) Route(@TypeOf(handler)) {
    return on(.POST, pattern, handler);
}
pub fn put(comptime pattern: []const u8, comptime handler: anytype) Route(@TypeOf(handler)) {
    return on(.PUT, pattern, handler);
}
pub fn patch(comptime pattern: []const u8, comptime handler: anytype) Route(@TypeOf(handler)) {
    return on(.PATCH, pattern, handler);
}
pub fn delete(comptime pattern: []const u8, comptime handler: anytype) Route(@TypeOf(handler)) {
    return on(.DELETE, pattern, handler);
}
pub fn all(comptime pattern: []const u8, comptime handler: anytype) Route(@TypeOf(handler)) {
    return on(null, pattern, handler);
}

/// The continuation passed to middleware. Call `next.run()` to invoke the
/// rest of the chain (later middleware, then the matched handler).
pub const Next = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque) anyerror!Response,

    pub fn run(self: Next) anyerror!Response {
        return self.func(self.ctx);
    }
};

/// Builds an application type for runtime `Rt` from a comptime config:
///
/// ```zig
/// const App = hibana.App(Runtime, .{
///     .Vars = struct { user: ?[]const u8 = null },   // optional
///     .middleware = .{ logger },                      // optional
///     .routes = .{
///         hibana.get("/", index),
///         hibana.get("/users/:id", showUser),
///     },
///     .on_error = onError,                            // optional
///     .not_found = notFound,                          // optional
/// });
/// ```
///
/// Handlers are `fn (c: *Ctx) !Response` or `fn (c: *Ctx, params: P) !Response`,
/// where `P` is a struct whose fields name the pattern's `:params`. Field
/// types can be `[]const u8`, integers, floats, bools or enums; a value that
/// does not parse gives a 400. `c` may also be declared `anytype`.
///
/// Middleware are `fn (c: *Ctx, next: Next) !Response`.
pub fn App(comptime Rt: type, comptime config: anytype) type {
    const Config = @TypeOf(config);
    const Vars = if (@hasField(Config, "Vars")) config.Vars else NoVars;
    const middleware = if (@hasField(Config, "middleware")) config.middleware else .{};
    const routes = if (@hasField(Config, "routes")) config.routes else .{};

    return struct {
        pub const Runtime = Rt;
        pub const Ctx = context.Context(Rt, Vars);

        /// Runs the request through middleware and routing. Never fails:
        /// errors become responses (see `http_error.statusOf`).
        pub fn handle(arena: Allocator, raw: *Rt.Request, env: *Rt.Env) Response {
            var c = Ctx.init(arena, raw, env) catch |err| return fallbackError(err);
            var res = chain(0)(&c) catch |err| errorResponse(&c, err);
            // `c.header` values fill in names the response did not set itself;
            // repeated names (set-cookie) are all kept.
            const own = res.headers.items.len;
            for (c.headers.items) |h| {
                const set_by_response = for (res.headers.items[0..own]) |r| {
                    if (std.ascii.eqlIgnoreCase(r.name, h.name)) break true;
                } else false;
                if (!set_by_response) {
                    res.headers.append(arena, h) catch return fallbackError(error.OutOfMemory);
                }
            }
            // Every header passes through here, so this is the one place that
            // stops CR/LF injection whatever path built the response.
            if (!validHeaders(res.headers.items)) {
                res = defaultErrorResponse(arena, error.InvalidHeader, null);
            }
            if (c.req.method == .HEAD) res.body = "";
            return res;
        }

        fn chain(comptime i: usize) fn (*Ctx) anyerror!Response {
            if (i == middleware.len) return dispatch;
            return struct {
                fn erased(p: *anyopaque) anyerror!Response {
                    return chain(i + 1)(@ptrCast(@alignCast(p)));
                }
                fn run(c: *Ctx) anyerror!Response {
                    return middleware[i](c, Next{ .ctx = c, .func = &erased });
                }
            }.run;
        }

        fn dispatch(c: *Ctx) anyerror!Response {
            const path: router.SplitPath = .init(c.req.path);
            // HEAD is answered by the GET route; `handle` drops the body.
            const method: Method = if (c.req.method == .HEAD) .GET else c.req.method;
            var allow: std.ArrayList(u8) = .empty;
            inline for (routes) |r| {
                const pattern = comptime router.parse(r.pattern);
                var caps: router.Captures(pattern) = undefined;
                if (router.match(pattern, &path, &caps)) {
                    if (r.method == null or r.method.? == method) {
                        return callHandler(r.handler, pattern, c, &caps);
                    }
                    const name = if (r.method.? == .GET) "GET, HEAD" else @tagName(r.method.?);
                    if (allow.items.len > 0) try allow.appendSlice(c.arena, ", ");
                    try allow.appendSlice(c.arena, name);
                }
            }
            if (allow.items.len > 0) {
                try c.header("allow", allow.items);
                return error.MethodNotAllowed;
            }
            if (@hasField(Config, "not_found")) return config.not_found(c);
            return error.NotFound;
        }

        fn callHandler(
            comptime handler: anytype,
            comptime pattern: router.Pattern,
            c: *Ctx,
            caps: *const router.Captures(pattern),
        ) anyerror!Response {
            const info = @typeInfo(@TypeOf(handler)).@"fn";
            switch (info.params.len) {
                1 => return handler(c),
                2 => {
                    const P = info.params[1].type orelse
                        @compileError("the params argument of a handler needs a concrete struct type");
                    return handler(c, try parseParams(P, pattern, c, caps));
                },
                else => @compileError("handlers take (c) or (c, params)"),
            }
        }

        fn parseParams(
            comptime P: type,
            comptime pattern: router.Pattern,
            c: *Ctx,
            caps: *const router.Captures(pattern),
        ) !P {
            const fields = @typeInfo(P).@"struct".fields;
            comptime {
                for (fields) |f| {
                    if (!pattern.hasParam(f.name))
                        @compileError("param '" ++ f.name ++ "' is not in the route pattern");
                }
                if (fields.len != pattern.paramCount())
                    @compileError("params struct must declare every ':param' of the route pattern");
            }
            var out: P = undefined;
            comptime var idx: usize = 0;
            inline for (pattern.segments) |seg| {
                if (seg != .param) continue;
                const raw = try context.decodeComponent(c.arena, caps[idx], false);
                idx += 1;
                @field(out, seg.param) = convert(@FieldType(P, seg.param), raw) catch {
                    c.req.validation_error = try std.fmt.allocPrint(
                        c.arena,
                        "invalid path parameter '{s}'",
                        .{seg.param},
                    );
                    return error.BadRequest;
                };
            }
            return out;
        }

        fn errorResponse(c: *Ctx, err: anyerror) Response {
            if (@hasField(Config, "on_error")) {
                if (config.on_error(c, err)) |res| return res else |_| {}
            }
            return defaultErrorResponse(c.arena, err, c.req.validation_error);
        }

        fn fallbackError(err: anyerror) Response {
            return .init(http_error.statusOf(err), "");
        }
    };
}

/// `{"error":"Not Found"}` (plus `"detail"` when known) with the mapped status.
pub fn defaultErrorResponse(arena: Allocator, err: anyerror, detail: ?[]const u8) Response {
    const status = http_error.statusOf(err);
    const phrase = status.phrase() orelse "Error";
    const Body = struct { @"error": []const u8, detail: ?[]const u8 = null };
    const bytes = std.json.Stringify.valueAlloc(arena, Body{ .@"error" = phrase, .detail = detail }, .{
        .emit_null_optional_fields = false,
    }) catch return .init(status, "");
    var res: Response = .init(status, bytes);
    res.setHeader(arena, "content-type", "application/json") catch {};
    return res;
}

/// Header names must be tokens and values must not contain CR, LF or NUL.
fn validHeaders(headers: []const std.http.Header) bool {
    for (headers) |h| {
        if (h.name.len == 0) return false;
        for (h.name) |ch| {
            if (ch <= ' ' or ch >= 0x7f or std.mem.indexOfScalar(u8, "\"(),/:;<=>?@[\\]{}", ch) != null) return false;
        }
        if (std.mem.indexOfAny(u8, h.value, "\r\n\x00") != null) return false;
    }
    return true;
}

fn convert(comptime T: type, raw: []const u8) !T {
    if (T == []const u8) return raw;
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, raw, 10),
        .float => std.fmt.parseFloat(T, raw),
        .bool => if (std.mem.eql(u8, raw, "true")) true else if (std.mem.eql(u8, raw, "false")) false else error.InvalidBool,
        .@"enum" => std.meta.stringToEnum(T, raw) orelse error.InvalidEnum,
        else => @compileError("unsupported path parameter type " ++ @typeName(T)),
    };
}
