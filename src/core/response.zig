const std = @import("std");

pub const Header = std.http.Header;
pub const Status = std.http.Status;

/// A runtime-independent HTTP response. Adapters turn it into their native type.
pub const Response = struct {
    status: Status = .ok,
    headers: std.ArrayList(Header) = .empty,
    body: []const u8 = "",

    pub fn init(status: Status, body: []const u8) Response {
        return .{ .status = status, .body = body };
    }

    /// Returns the first header matching `name` (case-insensitive).
    pub fn header(self: *const Response, name: []const u8) ?[]const u8 {
        for (self.headers.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// Sets `name` to `value`, replacing any existing header of the same name.
    pub fn setHeader(self: *Response, gpa: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        for (self.headers.items) |*h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) {
                h.value = value;
                return;
            }
        }
        try self.headers.append(gpa, .{ .name = name, .value = value });
    }
};

test "setHeader replaces case-insensitively" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var res: Response = .init(.ok, "hi");
    try res.setHeader(arena.allocator(), "Content-Type", "text/plain");
    try res.setHeader(arena.allocator(), "content-type", "application/json");
    try std.testing.expectEqual(@as(usize, 1), res.headers.items.len);
    try std.testing.expectEqualStrings("application/json", res.header("CONTENT-TYPE").?);
}
