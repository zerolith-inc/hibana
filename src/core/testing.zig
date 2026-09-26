//! A pure-Zig fake runtime so core logic can be tested with `zig build test`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Method = std.http.Method;
const Header = std.http.Header;
const Response = @import("response.zig").Response;
const ForwardRequest = @import("context.zig").ForwardRequest;

/// A fake runtime whose `Env` is `EnvT`. If `EnvT` declares
/// `fn forward(*EnvT, Allocator, ForwardRequest) !Response`, `ctx.forward`
/// calls it; otherwise forwarding fails with `error.BadGateway`.
pub fn Runtime(comptime EnvT: type) type {
    return struct {
        pub const Env = EnvT;

        pub const Request = struct {
            method_: Method = .GET,
            url_: []const u8 = "/",
            headers_: []const Header = &.{},
            body_: ?[]const u8 = null,
            /// How many times the body was read; lets tests assert laziness.
            body_reads: usize = 0,

            pub fn method(self: *const Request) Method {
                return self.method_;
            }
            pub fn url(self: *const Request) ![]const u8 {
                return self.url_;
            }
            pub fn header(self: *const Request, name: []const u8) !?[]const u8 {
                for (self.headers_) |h| {
                    if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
                }
                return null;
            }
            pub fn headers(self: *const Request) ![]const Header {
                return self.headers_;
            }
            pub fn body(self: *Request) !?[]const u8 {
                self.body_reads += 1;
                return self.body_;
            }
        };

        pub fn forward(env: *Env, arena: Allocator, req: ForwardRequest) !Response {
            if (@hasDecl(Env, "forward")) return env.forward(arena, req);
            return error.BadGateway;
        }
    };
}

/// Fake runtime with an empty env.
pub const DefaultRuntime = Runtime(struct {});

pub const RequestOptions = struct {
    method: Method = .GET,
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
};

/// Runs one request through `App` (built on a `testing.Runtime`).
pub fn request(
    comptime AppT: type,
    arena: Allocator,
    env: *AppT.Runtime.Env,
    url: []const u8,
    opts: RequestOptions,
) Response {
    var raw: AppT.Runtime.Request = .{
        .method_ = opts.method,
        .url_ = url,
        .headers_ = opts.headers,
        .body_ = opts.body,
    };
    return AppT.handle(arena, &raw, env);
}
