const std = @import("std");
const Allocator = std.mem.Allocator;
const Method = std.http.Method;
const Header = std.http.Header;
const Status = std.http.Status;
const Response = @import("response.zig").Response;

/// What `ctx.forward` hands to `Runtime.forward`.
pub const ForwardRequest = struct {
    method: Method,
    url: []const u8,
    headers: []const Header,
    body: ?[]const u8,
};

/// The incoming request as seen by handlers. Wraps the runtime's request and
/// reads the body lazily: nothing is copied out of the runtime until a
/// handler calls `text()` or `json()`.
pub fn Request(comptime Rt: type) type {
    return struct {
        const Self = @This();

        raw: *Rt.Request,
        arena: Allocator,
        method: Method,
        /// Full URL as given by the runtime.
        url: []const u8,
        /// Path component, without query string or fragment.
        path: []const u8,
        /// Raw query string without the leading '?'.
        query_string: []const u8,
        /// Set when `json()` fails, so the error response can explain why.
        validation_error: ?[]const u8 = null,
        body_cache: ?[]const u8 = null,
        body_read: bool = false,

        pub fn init(arena: Allocator, raw: *Rt.Request) !Self {
            const url = try raw.url();
            const parts = splitUrl(url);
            return .{
                .raw = raw,
                .arena = arena,
                .method = raw.method(),
                .url = url,
                .path = parts.path,
                .query_string = parts.query,
            };
        }

        pub fn header(self: *const Self, name: []const u8) !?[]const u8 {
            return self.raw.header(name);
        }

        /// First value of query parameter `name`, percent-decoded.
        pub fn query(self: *const Self, name: []const u8) !?[]const u8 {
            var it = std.mem.splitScalar(u8, self.query_string, '&');
            while (it.next()) |pair| {
                if (pair.len == 0) continue;
                const eq = std.mem.indexOfScalar(u8, pair, '=');
                const key = if (eq) |i| pair[0..i] else pair;
                const val = if (eq) |i| pair[i + 1 ..] else "";
                const dkey = try decodeComponent(self.arena, key, true);
                if (std.mem.eql(u8, dkey, name)) return try decodeComponent(self.arena, val, true);
            }
            return null;
        }

        /// The request body as bytes (empty if there is none). Read once, on first call.
        pub fn text(self: *Self) ![]const u8 {
            if (!self.body_read) {
                self.body_cache = try self.raw.body();
                self.body_read = true;
            }
            return self.body_cache orelse "";
        }

        /// Parses the body as JSON into `T`. On malformed input or a shape
        /// mismatch this returns `error.BadRequest`, which the app turns into
        /// a 400 with the reason in `detail`.
        pub fn json(self: *Self, comptime T: type) !T {
            const bytes = try self.text();
            if (bytes.len == 0) {
                self.validation_error = "request body is empty";
                return error.BadRequest;
            }
            var diag: std.json.Diagnostics = .{};
            var scanner: std.json.Scanner = .initCompleteInput(self.arena, bytes);
            scanner.enableDiagnostics(&diag);
            return std.json.parseFromTokenSourceLeaky(T, self.arena, &scanner, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    self.validation_error = try std.fmt.allocPrint(
                        self.arena,
                        "invalid JSON body: {s} at line {d}, column {d}",
                        .{ @errorName(err), diag.getLine(), diag.getColumn() },
                    );
                    return error.BadRequest;
                },
            };
        }
    };
}

/// Per-request state handed to middleware and handlers.
///
/// `Vars` is the app's typed per-request storage (`c.vars.user = ...`);
/// every field needs a default value.
pub fn Context(comptime Rt: type, comptime Vars: type) type {
    return struct {
        const Self = @This();
        pub const Runtime = Rt;

        arena: Allocator,
        req: Request(Rt),
        env: *Rt.Env,
        vars: Vars = .{},
        /// Headers added with `header()`; merged into whatever response is returned.
        headers: std.ArrayList(Header) = .empty,

        pub fn init(arena: Allocator, raw: *Rt.Request, env: *Rt.Env) !Self {
            return .{ .arena = arena, .req = try .init(arena, raw), .env = env };
        }

        /// Adds a header to the eventual response (does not override one the
        /// response sets itself).
        pub fn header(self: *Self, name: []const u8, value: []const u8) !void {
            try self.headers.append(self.arena, .{ .name = name, .value = value });
        }

        pub fn body(self: *Self, code: Status, content_type: ?[]const u8, bytes: []const u8) !Response {
            var res: Response = .init(code, bytes);
            if (content_type) |ct| try res.setHeader(self.arena, "content-type", ct);
            return res;
        }

        pub fn text(self: *Self, s: []const u8) !Response {
            return self.body(.ok, "text/plain; charset=utf-8", s);
        }

        pub fn html(self: *Self, s: []const u8) !Response {
            return self.body(.ok, "text/html; charset=utf-8", s);
        }

        pub fn json(self: *Self, value: anytype) !Response {
            return self.jsonStatus(.ok, value);
        }

        pub fn jsonStatus(self: *Self, code: Status, value: anytype) !Response {
            const bytes = try std.json.Stringify.valueAlloc(self.arena, value, .{});
            return self.body(code, "application/json", bytes);
        }

        pub fn status(self: *Self, code: Status) !Response {
            return self.body(code, null, "");
        }

        pub fn redirect(self: *Self, location: []const u8, code: Status) !Response {
            var res: Response = .init(code, "");
            try res.setHeader(self.arena, "location", location);
            return res;
        }

        /// Sends the current request to `url` and returns the upstream response.
        /// Hop-by-hop headers are dropped, and so are `cookie` and
        /// `authorization` unless `opts.credentials` is set. The body is sent
        /// for every method except GET and HEAD when there is one.
        pub fn forward(self: *Self, url: []const u8) !Response {
            return self.forwardWith(url, .{});
        }

        pub fn forwardWith(self: *Self, url: []const u8, opts: ForwardOptions) !Response {
            const all_headers = try self.req.raw.headers();
            var connection_tokens: []const u8 = "";
            for (all_headers) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "connection")) connection_tokens = h.value;
            }
            var hdrs: std.ArrayList(Header) = .empty;
            for (all_headers) |h| {
                if (isHopByHop(h.name, connection_tokens)) continue;
                if (!opts.credentials and (std.ascii.eqlIgnoreCase(h.name, "cookie") or
                    std.ascii.eqlIgnoreCase(h.name, "authorization"))) continue;
                try hdrs.append(self.arena, .{ .name = h.name, .value = h.value });
            }
            const req_body: ?[]const u8 = switch (self.req.method) {
                .GET, .HEAD => null,
                else => blk: {
                    const b = try self.req.text();
                    break :blk if (b.len == 0) null else b;
                },
            };
            return Rt.forward(self.env, self.arena, .{
                .method = self.req.method,
                .url = url,
                .headers = hdrs.items,
                .body = req_body,
            });
        }
    };
}

pub const ForwardOptions = struct {
    /// Also forward `cookie` and `authorization`.
    credentials: bool = false,
};

/// RFC 9110 7.6.1 connection-specific headers, plus `host` and
/// `content-length`, which the runtime sets for the new request.
fn isHopByHop(name: []const u8, connection_tokens: []const u8) bool {
    const fixed = [_][]const u8{
        "connection",         "keep-alive",        "proxy-connection", "te",
        "trailer",            "transfer-encoding", "upgrade",          "proxy-authorization",
        "proxy-authenticate", "host",              "content-length",
    };
    for (fixed) |f| {
        if (std.ascii.eqlIgnoreCase(name, f)) return true;
    }
    var it = std.mem.tokenizeAny(u8, connection_tokens, ", \t");
    while (it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(name, tok)) return true;
    }
    return false;
}

const UrlParts = struct { path: []const u8, query: []const u8 };

/// Splits an absolute URL ("https://h/p?q") or origin-form target ("/p?q").
pub fn splitUrl(url: []const u8) UrlParts {
    var rest = url;
    // Only an absolute URL has a scheme; in origin form ("/p?next=http://x")
    // a "://" belongs to the query and must not move the path.
    if (!std.mem.startsWith(u8, rest, "/")) {
        if (std.mem.indexOf(u8, rest, "://")) |i| {
            rest = rest[i + 3 ..];
            const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
            rest = rest[end..];
        }
    }
    if (std.mem.indexOfScalar(u8, rest, '#')) |h| rest = rest[0..h];
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
        return .{ .path = if (q == 0) "/" else rest[0..q], .query = rest[q + 1 ..] };
    }
    return .{ .path = if (rest.len == 0) "/" else rest, .query = "" };
}

/// Percent-decodes `s` into a new allocation (or returns it as-is if there
/// is nothing to decode). With `plus_as_space`, '+' becomes ' ' (query strings).
pub fn decodeComponent(arena: Allocator, s: []const u8, plus_as_space: bool) ![]const u8 {
    if (std.mem.indexOfAny(u8, s, if (plus_as_space) "%+" else "%") == null) return s;
    const buf = try arena.dupe(u8, s);
    if (plus_as_space) std.mem.replaceScalar(u8, buf, '+', ' ');
    return std.Uri.percentDecodeInPlace(buf);
}

test splitUrl {
    const a = splitUrl("https://example.com/a/b?x=1#frag");
    try std.testing.expectEqualStrings("/a/b", a.path);
    try std.testing.expectEqualStrings("x=1", a.query);
    try std.testing.expectEqualStrings("/", splitUrl("https://example.com").path);
    try std.testing.expectEqualStrings("/", splitUrl("/?a=b").path);
    try std.testing.expectEqualStrings("/x", splitUrl("/x").path);
    // Regression: "://" in the query must not re-route (review M1).
    try std.testing.expectEqualStrings("/public", splitUrl("/public?next=http://x/admin").path);
    try std.testing.expectEqualStrings("/", splitUrl("https://h?next=http://x/admin").path);
    try std.testing.expectEqualStrings("next=http://x/admin", splitUrl("https://h?next=http://x/admin").query);
}

test decodeComponent {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try decodeComponent(a, "a%20b+c", true);
    try std.testing.expectEqualStrings("a b c", d);
    try std.testing.expectEqualStrings("plain", try decodeComponent(a, "plain", false));
}
