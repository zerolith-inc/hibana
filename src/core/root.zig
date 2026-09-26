//! hibana core: routing, middleware, Context and error mapping.
//! Depends only on `std`; runtimes plug in through a comptime `Runtime` type.
//!
//! A `Runtime` provides:
//!   - `Request` with `method()`, `url()`, `header(name)`, `headers()`, `body()`
//!   - `Env` (bindings; opaque to core)
//!   - `forward(env: *Env, arena, ForwardRequest) !Response`

const std = @import("std");

const app = @import("app.zig");
pub const App = app.App;
pub const Next = app.Next;
pub const NoVars = app.NoVars;
pub const on = app.on;
pub const get = app.get;
pub const post = app.post;
pub const put = app.put;
pub const patch = app.patch;
pub const delete = app.delete;
pub const all = app.all;
pub const defaultErrorResponse = app.defaultErrorResponse;

const context = @import("context.zig");
pub const Context = context.Context;
pub const Request = context.Request;
pub const ForwardRequest = context.ForwardRequest;

pub const Response = @import("response.zig").Response;
pub const Status = std.http.Status;
pub const Method = std.http.Method;
pub const Header = std.http.Header;
pub const statusOf = @import("http_error.zig").statusOf;
pub const router = @import("router.zig");
pub const testing = @import("testing.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("app_test.zig");
}
