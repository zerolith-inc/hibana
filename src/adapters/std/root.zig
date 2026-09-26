//! std.http adapter: serves a hibana app with `std.http.Server`.
//! Meant for local development and integration tests, not production.

const std = @import("std");
const hibana = @import("hibana");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;
const log = std.log.scoped(.hibana);

/// Largest request body `body()` will buffer.
pub const max_body_len = 16 * 1024 * 1024;

/// The `Runtime` for std.http. `EnvT` is whatever the app wants as `c.env`.
pub fn Runtime(comptime EnvT: type) type {
    return struct {
        pub const Env = EnvT;

        pub const Request = struct {
            io: Io,
            inner: *http.Server.Request,
            arena: Allocator,
            method_: http.Method,
            /// Copies of head data: the originals are invalidated when the body is read.
            target: []const u8,
            headers_: []const http.Header,

            pub fn init(io: Io, arena: Allocator, inner: *http.Server.Request) !Request {
                var list: std.ArrayList(http.Header) = .empty;
                var it = inner.iterateHeaders();
                while (it.next()) |h| {
                    try list.append(arena, .{
                        .name = try arena.dupe(u8, h.name),
                        .value = try arena.dupe(u8, h.value),
                    });
                }
                return .{
                    .io = io,
                    .inner = inner,
                    .arena = arena,
                    .method_ = inner.head.method,
                    .target = try arena.dupe(u8, inner.head.target),
                    .headers_ = list.items,
                };
            }

            pub fn method(self: *const Request) http.Method {
                return self.method_;
            }
            pub fn url(self: *const Request) ![]const u8 {
                return self.target;
            }
            pub fn header(self: *const Request, name: []const u8) !?[]const u8 {
                for (self.headers_) |h| {
                    if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
                }
                return null;
            }
            pub fn headers(self: *const Request) ![]const http.Header {
                return self.headers_;
            }
            pub fn body(self: *Request) !?[]const u8 {
                if (!self.method_.requestHasBody()) return null;
                const reader = if (self.inner.head.expect != null)
                    try self.inner.readerExpectContinue(&.{})
                else
                    self.inner.readerExpectNone(&.{});
                const bytes = reader.allocRemaining(self.arena, .limited(max_body_len)) catch |err| switch (err) {
                    error.StreamTooLong => return error.PayloadTooLarge,
                    else => |e| return e,
                };
                return if (bytes.len == 0) null else bytes;
            }
        };

        /// Forwards with `std.http.Client`. The response body is passed through
        /// without decompression.
        pub fn forward(_: *Env, arena: Allocator, req: hibana.ForwardRequest) !hibana.Response {
            const io = current_io orelse return error.BadGateway;
            var client: http.Client = .{ .allocator = arena, .io = io };
            defer client.deinit();

            var std_headers: http.Client.Request.Headers = .{
                .user_agent = .omit,
                .accept_encoding = .omit,
                .authorization = .omit,
                .content_type = .omit,
            };
            var extra: std.ArrayList(http.Header) = .empty;
            for (req.headers) |h| {
                if (eqlAny(h.name, &.{ "connection", "content-length", "transfer-encoding", "keep-alive", "expect" })) continue;
                if (std.ascii.eqlIgnoreCase(h.name, "user-agent")) {
                    std_headers.user_agent = .{ .override = h.value };
                } else if (std.ascii.eqlIgnoreCase(h.name, "accept-encoding")) {
                    std_headers.accept_encoding = .{ .override = h.value };
                } else if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
                    std_headers.authorization = .{ .override = h.value };
                } else if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
                    std_headers.content_type = .{ .override = h.value };
                } else try extra.append(arena, h);
            }

            const uri = try std.Uri.parse(req.url);
            var out = try client.request(req.method, uri, .{
                .headers = std_headers,
                .extra_headers = extra.items,
                .redirect_behavior = .unhandled,
                .keep_alive = false,
            });
            defer out.deinit();

            if (req.body) |b| {
                out.transfer_encoding = .{ .content_length = b.len };
                var bw = try out.sendBodyUnflushed(&.{});
                try bw.writer.writeAll(b);
                try bw.end();
                try out.connection.?.flush();
            } else try out.sendBodiless();

            var upstream = try out.receiveHead(&.{});
            var res: hibana.Response = .init(upstream.head.status, "");
            var it = upstream.head.iterateHeaders();
            while (it.next()) |h| {
                if (eqlAny(h.name, &.{ "connection", "content-length", "transfer-encoding", "keep-alive" })) continue;
                try res.headers.append(arena, .{
                    .name = try arena.dupe(u8, h.name),
                    .value = try arena.dupe(u8, h.value),
                });
            }
            const reader = upstream.reader(&.{});
            res.body = reader.allocRemaining(arena, .limited(max_body_len)) catch |err| switch (err) {
                error.ReadFailed => return upstream.bodyErr().?,
                else => |e| return e,
            };
            return res;
        }
    };
}

/// Set while a request is being served so `forward` can reach the Io.
threadlocal var current_io: ?Io = null;

fn eqlAny(name: []const u8, comptime list: []const []const u8) bool {
    inline for (list) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

pub const ServeOptions = struct {
    address: Io.net.IpAddress = .{ .ip4 = .loopback(8787) },
};

/// A listening server for `AppT` (an app built on this adapter's `Runtime`).
pub fn Server(comptime AppT: type) type {
    return struct {
        const Self = @This();

        io: Io,
        gpa: Allocator,
        env: *AppT.Runtime.Env,
        tcp: Io.net.Server,

        pub fn listen(io: Io, gpa: Allocator, env: *AppT.Runtime.Env, opts: ServeOptions) !Self {
            return .{
                .io = io,
                .gpa = gpa,
                .env = env,
                .tcp = try opts.address.listen(io, .{ .reuse_address = true }),
            };
        }

        pub fn deinit(self: *Self) void {
            self.tcp.deinit(self.io);
        }

        pub fn port(self: *const Self) u16 {
            return self.tcp.socket.address.getPort();
        }

        /// Accepts connections until canceled, serving each concurrently.
        pub fn run(self: *Self) Io.Cancelable!void {
            var group: Io.Group = .init;
            defer group.cancel(self.io);
            while (true) {
                const stream = self.tcp.accept(self.io) catch |err| switch (err) {
                    error.Canceled => |e| return e,
                    else => |e| {
                        log.err("accept failed: {t}", .{e});
                        return;
                    },
                };
                group.concurrent(self.io, serveConnection, .{ self, stream }) catch {
                    // No concurrency available: serve inline.
                    self.serveConnection(stream);
                };
            }
        }

        fn serveConnection(self: *Self, stream: Io.net.Stream) void {
            defer {
                var s = stream;
                s.close(self.io);
            }
            current_io = self.io;
            var send_buffer: [4096]u8 = undefined;
            var recv_buffer: [16 * 1024]u8 = undefined;
            var reader = stream.reader(self.io, &recv_buffer);
            var writer = stream.writer(self.io, &send_buffer);
            var server: http.Server = .init(&reader.interface, &writer.interface);

            while (true) {
                var request = server.receiveHead() catch |err| switch (err) {
                    error.HttpConnectionClosing => return,
                    else => return log.debug("receive head failed: {t}", .{err}),
                };
                self.serveRequest(&request) catch |err| {
                    return log.debug("serving '{s}' failed: {t}", .{ request.head.target, err });
                };
            }
        }

        fn serveRequest(self: *Self, request: *http.Server.Request) !void {
            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();
            const a = arena.allocator();

            var raw: AppT.Runtime.Request = try .init(self.io, a, request);
            const res = AppT.handle(a, &raw, self.env);

            // If the handler never read the body, drain it so keep-alive works.
            if (request.head.method.requestHasBody() and !raw_body_consumed(request)) {
                _ = raw.body() catch return error.BodyDrainFailed;
            }

            try request.respond(res.body, .{
                .status = res.status,
                .extra_headers = res.headers.items,
                .keep_alive = true,
            });
        }

        fn raw_body_consumed(request: *http.Server.Request) bool {
            return request.server.reader.state != .received_head;
        }
    };
}
