//! Cloudflare Workers entrypoint: links live in the `LINKS` KV namespace.

const workers = @import("workers-zig");
const hw = @import("hibana-workers");
const app = @import("app.zig");

const KvStore = struct {
    pub fn get(env: *workers.Env, code: []const u8) !?[]const u8 {
        const kv = try env.kv("LINKS");
        return kv.getText(code);
    }
    pub fn put(env: *workers.Env, code: []const u8, url: []const u8) !void {
        const kv = try env.kv("LINKS");
        kv.put(code, url);
    }
    pub fn random(_: *workers.Env, buf: []u8) void {
        workers.io().random(buf);
    }
};

pub const fetch = hw.fetch(app.App(hw.Runtime, KvStore));
