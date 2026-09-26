//! Concurrency e2e worker (review C1): each request fills stack buffers,
//! suspends on KV and sleep while others run, then checks its buffers.

const std = @import("std");
const hibana = @import("hibana");
const hw = @import("hibana-workers");
const Ctx = hibana.Context(hw.Runtime, hibana.NoVars);

noinline fn recurse(c: *Ctx, id: []const u8, depth: usize, sleep_ms: u32) !bool {
    var buf: [256]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = id[i % id.len];
    var ok = true;
    if (depth > 0) {
        ok = try recurse(c, id, depth - 1, sleep_ms);
    } else {
        const kv = try c.env.kv("KV");
        _ = try kv.getText("k");
        hw.workers_zig.sleep(sleep_ms);
    }
    for (buf, 0..) |b, i| if (b != id[i % id.len]) return false;
    return ok;
}

fn stack(c: *Ctx, p: struct { id: []const u8, depth: u8, sleep: u32 }) !hibana.Response {
    if (!try recurse(c, p.id, p.depth, p.sleep)) return c.text("CORRUPT");
    return c.text("ok");
}

const App = hibana.App(hw.Runtime, .{ .routes = .{
    hibana.get("/stack/:id/:depth/:sleep", stack),
} });

pub const fetch = hw.fetch(App);
