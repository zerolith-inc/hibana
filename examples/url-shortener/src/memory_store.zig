//! In-memory storage for tests and local runs.

const std = @import("std");

pub const Env = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    links: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(env: *Env) void {
        var it = env.links.iterator();
        while (it.next()) |e| {
            env.gpa.free(e.key_ptr.*);
            env.gpa.free(e.value_ptr.*);
        }
        env.links.deinit(env.gpa);
    }
};

pub const Store = struct {
    pub fn get(env: *Env, code: []const u8) !?[]const u8 {
        try env.mutex.lock(env.io);
        defer env.mutex.unlock(env.io);
        return env.links.get(code);
    }
    pub fn put(env: *Env, code: []const u8, url: []const u8) !void {
        try env.mutex.lock(env.io);
        defer env.mutex.unlock(env.io);
        try env.links.put(env.gpa, try env.gpa.dupe(u8, code), try env.gpa.dupe(u8, url));
    }
    pub fn random(env: *Env, buf: []u8) void {
        env.io.random(buf);
    }
};
