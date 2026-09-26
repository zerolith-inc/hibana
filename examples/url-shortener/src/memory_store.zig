//! In-memory storage for tests and local runs. The std server handles
//! connections concurrently, so every map access holds `mutex`. Stored
//! strings are never freed before `deinit`, so slices returned by `get` stay
//! valid while other requests write.

const std = @import("std");

pub const Env = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    links: std.StringHashMapUnmanaged([]const u8) = .empty,
    mutex: std.Io.Mutex = .init,
    /// Values replaced by `put`, freed in `deinit`.
    replaced: std.ArrayList([]const u8) = .empty,

    pub fn deinit(env: *Env) void {
        var it = env.links.iterator();
        while (it.next()) |e| {
            env.gpa.free(e.key_ptr.*);
            env.gpa.free(e.value_ptr.*);
        }
        env.links.deinit(env.gpa);
        for (env.replaced.items) |v| env.gpa.free(v);
        env.replaced.deinit(env.gpa);
    }
};

pub const Store = struct {
    pub fn get(env: *Env, code: []const u8) !?[]const u8 {
        env.mutex.lockUncancelable(env.io);
        defer env.mutex.unlock(env.io);
        return env.links.get(code);
    }
    pub fn put(env: *Env, code: []const u8, url: []const u8) !void {
        const value = try env.gpa.dupe(u8, url);
        errdefer env.gpa.free(value);
        env.mutex.lockUncancelable(env.io);
        defer env.mutex.unlock(env.io);
        const gop = try env.links.getOrPut(env.gpa, code);
        if (gop.found_existing) {
            try env.replaced.append(env.gpa, gop.value_ptr.*);
        } else {
            gop.key_ptr.* = env.gpa.dupe(u8, code) catch |err| {
                env.links.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        gop.value_ptr.* = value;
    }
    pub fn random(env: *Env, buf: []u8) void {
        env.io.random(buf);
    }
};
