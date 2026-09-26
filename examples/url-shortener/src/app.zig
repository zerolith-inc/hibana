//! URL shortener, written once against hibana core and run on any runtime.
//!
//! `Store` supplies storage and randomness for the runtime's `Env`:
//!   get(env, code) !?[]const u8, put(env, code, url) !void, random(env, buf) void

const std = @import("std");
const hibana = @import("hibana");

pub const code_len = 7;
const alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

pub fn App(comptime Rt: type, comptime Store: type) type {
    const Ctx = hibana.Context(Rt, hibana.NoVars);

    return hibana.App(Rt, .{
        .middleware = .{securityHeaders(Ctx)},
        .routes = .{
            hibana.get("/", Handlers(Ctx, Store).index),
            hibana.post("/shorten", Handlers(Ctx, Store).shorten),
            hibana.get("/:code", Handlers(Ctx, Store).resolve),
        },
    });
}

fn Handlers(comptime Ctx: type, comptime Store: type) type {
    return struct {
        fn index(c: *Ctx) !hibana.Response {
            return c.text("POST /shorten {\"url\": \"https://...\"} then GET /:code\n");
        }

        fn shorten(c: *Ctx) !hibana.Response {
            const In = struct { url: []const u8 };
            const in = try c.req.json(In);
            if (!isHttpUrl(in.url)) {
                c.req.validation_error = "url must start with http:// or https://";
                return error.BadRequest;
            }
            var raw: [code_len]u8 = undefined;
            Store.random(c.env, &raw);
            const code = try c.arena.alloc(u8, code_len);
            for (code, raw) |*out, r| out.* = alphabet[r % alphabet.len];
            try Store.put(c.env, code, in.url);
            return c.jsonStatus(.created, .{ .code = code, .url = in.url });
        }

        fn resolve(c: *Ctx, p: struct { code: []const u8 }) !hibana.Response {
            if (p.code.len != code_len) return error.NotFound;
            const url = (try Store.get(c.env, p.code)) orelse return error.NotFound;
            return c.redirect(url, .found);
        }
    };
}

fn securityHeaders(comptime Ctx: type) fn (*Ctx, hibana.Next) anyerror!hibana.Response {
    return struct {
        fn mw(c: *Ctx, next: hibana.Next) anyerror!hibana.Response {
            try c.header("x-content-type-options", "nosniff");
            return next.run();
        }
    }.mw;
}

fn isHttpUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://");
}
