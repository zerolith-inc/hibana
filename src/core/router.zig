//! Comptime route patterns: `/users/:id`, `/static/*`.
//!
//! Patterns are parsed at compile time into segments; matching splits the
//! request path once and compares against the unrolled segment list.

const std = @import("std");
const Method = std.http.Method;

pub const Segment = union(enum) {
    literal: []const u8,
    param: []const u8,
    /// `*` as the last segment: matches the rest of the path (possibly empty).
    wildcard,
};

pub const Pattern = struct {
    segments: []const Segment,

    pub fn paramCount(comptime self: Pattern) usize {
        var n: usize = 0;
        for (self.segments) |s| {
            if (s == .param) n += 1;
        }
        return n;
    }

    pub fn hasParam(comptime self: Pattern, comptime name: []const u8) bool {
        for (self.segments) |s| {
            if (s == .param and std.mem.eql(u8, s.param, name)) return true;
        }
        return false;
    }
};

pub fn parse(comptime pattern: []const u8) Pattern {
    comptime {
        if (pattern.len == 0 or pattern[0] != '/')
            @compileError("route pattern must start with '/': \"" ++ pattern ++ "\"");
        var segs: []const Segment = &.{};
        var it = std.mem.splitScalar(u8, pattern[1..], '/');
        while (it.next()) |raw| {
            if (raw.len == 0) {
                // "/" alone, or a trailing slash: no segment.
                if (it.peek() != null) @compileError("empty segment in route pattern \"" ++ pattern ++ "\"");
                continue;
            }
            const seg: Segment = if (raw[0] == ':') blk: {
                if (raw.len == 1) @compileError("unnamed parameter in \"" ++ pattern ++ "\"");
                break :blk .{ .param = raw[1..] };
            } else if (std.mem.eql(u8, raw, "*")) blk: {
                if (it.peek() != null) @compileError("'*' must be the last segment in \"" ++ pattern ++ "\"");
                break :blk .wildcard;
            } else .{ .literal = raw };
            segs = segs ++ .{seg};
        }
        const final = segs[0..segs.len].*;
        return .{ .segments = &final };
    }
}

/// Maximum number of path segments considered when matching.
pub const max_segments = 32;

/// A request path split into segments (query string already removed).
pub const SplitPath = struct {
    buf: [max_segments][]const u8 = undefined,
    len: usize = 0,
    overflow: bool = false,

    pub fn init(path: []const u8) SplitPath {
        var sp: SplitPath = .{};
        const trimmed = std.mem.trim(u8, path, "/");
        if (trimmed.len == 0) return sp;
        var it = std.mem.splitScalar(u8, trimmed, '/');
        while (it.next()) |s| {
            if (sp.len == max_segments) {
                sp.overflow = true;
                break;
            }
            sp.buf[sp.len] = s;
            sp.len += 1;
        }
        return sp;
    }

    pub fn items(self: *const SplitPath) []const []const u8 {
        return self.buf[0..self.len];
    }

    /// The raw remainder of `path` starting at segment `index`.
    pub fn restFrom(path: []const u8, index: usize) []const u8 {
        var p = std.mem.trimStart(u8, path, "/");
        var i: usize = 0;
        while (i < index) : (i += 1) {
            const slash = std.mem.indexOfScalar(u8, p, '/') orelse return "";
            p = p[slash + 1 ..];
        }
        return p;
    }
};

/// Raw (still percent-encoded) captured parameter values, in pattern order.
pub fn Captures(comptime pattern: Pattern) type {
    return [pattern.paramCount()][]const u8;
}

/// Matches `path` against `pattern`, filling `out` with raw param values.
pub fn match(comptime pattern: Pattern, path: *const SplitPath, out: *Captures(pattern)) bool {
    if (path.overflow) return false;
    const segs = path.items();
    const has_wildcard = pattern.segments.len > 0 and pattern.segments[pattern.segments.len - 1] == .wildcard;
    const fixed = if (has_wildcard) pattern.segments.len - 1 else pattern.segments.len;
    if (has_wildcard) {
        if (segs.len < fixed) return false;
    } else if (segs.len != fixed) return false;

    comptime var p: usize = 0;
    inline for (pattern.segments[0..fixed], 0..) |seg, i| {
        switch (seg) {
            .literal => |lit| if (!std.mem.eql(u8, segs[i], lit)) return false,
            .param => {
                if (segs[i].len == 0) return false;
                out[p] = segs[i];
                p += 1;
            },
            .wildcard => unreachable,
        }
    }
    return true;
}

test "parse" {
    const p = comptime parse("/users/:id/posts/*");
    try std.testing.expectEqual(@as(usize, 4), p.segments.len);
    try std.testing.expectEqualStrings("users", p.segments[0].literal);
    try std.testing.expectEqualStrings("id", p.segments[1].param);
    try std.testing.expect(p.segments[3] == .wildcard);
    try std.testing.expectEqual(@as(usize, 0), comptime parse("/").segments.len);
}

test "match" {
    const p = comptime parse("/users/:id");
    var caps: Captures(p) = undefined;
    try std.testing.expect(match(p, &SplitPath.init("/users/42"), &caps));
    try std.testing.expectEqualStrings("42", caps[0]);
    try std.testing.expect(match(p, &SplitPath.init("/users/42/"), &caps));
    try std.testing.expect(!match(p, &SplitPath.init("/users"), &caps));
    try std.testing.expect(!match(p, &SplitPath.init("/users/42/x"), &caps));
    try std.testing.expect(!match(p, &SplitPath.init("/posts/42"), &caps));

    const root = comptime parse("/");
    var none: Captures(root) = undefined;
    try std.testing.expect(match(root, &SplitPath.init("/"), &none));
    try std.testing.expect(!match(root, &SplitPath.init("/a"), &none));

    const wild = comptime parse("/static/*");
    var w: Captures(wild) = undefined;
    try std.testing.expect(match(wild, &SplitPath.init("/static/a/b.css"), &w));
    try std.testing.expect(match(wild, &SplitPath.init("/static"), &w));
    try std.testing.expectEqualStrings("a/b.css", SplitPath.restFrom("/static/a/b.css", 1));
}
