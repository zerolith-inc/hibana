//! Cloudflare Workers adapter, built on workers-zig.
//!
//! ```zig
//! const hibana = @import("hibana");
//! const hw = @import("hibana-workers");
//! const App = hibana.App(hw.Runtime, .{ .routes = .{ ... } });
//! pub const fetch = hw.fetch(App);
//! ```

const std = @import("std");
const hibana = @import("hibana");
const workers = @import("workers-zig");

pub const workers_zig = workers;

pub const Runtime = struct {
    /// workers-zig's request already has the shape core expects
    /// (`method`, `url`, `header`, `headers`, `body`). Its body is only
    /// copied into wasm memory when a handler reads it.
    pub const Request = workers.Request;
    /// `c.env.kv("NAME")`, `c.env.d1("DB")`, `c.env.get("VAR")`, ...
    pub const Env = workers.Env;

    /// Response headers copied back from the upstream on `forward`.
    /// workers-zig exposes upstream headers by name only.
    pub const forwarded_response_headers = [_][]const u8{
        "content-type",
        "cache-control",
        "etag",
        "last-modified",
        "location",
        "content-language",
        "vary",
    };

    pub fn forward(_: *Env, arena: std.mem.Allocator, req: hibana.ForwardRequest) !hibana.Response {
        var upstream = try workers.fetch(arena, req.url, .{
            .method = req.method,
            .headers = req.headers,
            .body = if (req.body) |b| .{ .bytes = b } else .none,
        });
        defer upstream.deinit();

        var res: hibana.Response = .init(upstream.status(), try upstream.bytes());
        for (forwarded_response_headers) |name| {
            if (try upstream.header(name)) |value| try res.headers.append(arena, .{ .name = name, .value = value });
        }
        return res;
    }
};

/// Converts a core response into a workers-zig response.
pub fn toWorkers(res: hibana.Response) workers.Response {
    var out = workers.Response.new();
    out.setStatus(res.status);
    for (res.headers.items) |h| out.setHeader(h.name, h.value);
    // A body (even an empty one) is not allowed on 101/204/205/304.
    if (res.body.len > 0) out.setBody(res.body);
    return out;
}

/// Returns a workers-zig `fetch` entrypoint for `AppT`.
pub fn fetch(comptime AppT: type) fn (*workers.Request, *workers.Env, *workers.Context) workers.Response {
    return struct {
        fn handler(req: *workers.Request, env: *workers.Env, _: *workers.Context) workers.Response {
            return toWorkers(AppT.handle(env.allocator, req, env));
        }
    }.handler;
}
