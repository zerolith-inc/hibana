# Guide

## App

```zig
const App = hibana.App(Runtime, .{
    .Vars = struct { user: ?[]const u8 = null },  // optional, every field needs a default
    .middleware = .{ auth, logger },               // optional, run in order (onion)
    .routes = .{
        hibana.get("/", index),
        hibana.post("/users", createUser),
        hibana.get("/users/:id", showUser),
        hibana.all("/proxy/*", proxy),
    },
    .on_error = onError,   // optional: fn (c: *Ctx, err: anyerror) !Response
    .not_found = notFound, // optional: fn (c: *Ctx) !Response
});
```

`Runtime` is `hibana-workers`' `Runtime`, `hibana-std`'s `Runtime(Env)`, or
`hibana.testing.Runtime(Env)`. The context type is
`hibana.Context(Runtime, Vars)` (also available as `App.Ctx`).

Routes match in declaration order. A path that matches a route with a
different method gives 405 with an `allow` header; no match gives 404.
HEAD requests are answered by the GET route with the body removed.

## Handlers and typed params

```zig
fn showUser(c: *Ctx, p: struct { id: u32 }) !hibana.Response { ... }
```

The params struct must name exactly the pattern's `:params`; this is checked
at compile time. Supported field types: `[]const u8` (percent-decoded),
integers, floats, `bool`, enums. A value that fails to parse gives a 400.
The handler's first parameter may be `anytype`.

## Context

| | |
|---|---|
| `c.req.method`, `c.req.path`, `c.req.url` | request line |
| `try c.req.header("name")` | header value or null |
| `try c.req.query("q")` | decoded query parameter or null |
| `try c.req.text()` | body bytes (read on first call only) |
| `try c.req.json(T)` | typed body; invalid gives 400 with `detail` |
| `c.env` | runtime env (`*workers.Env` on Workers) |
| `c.vars` | typed per-request storage |
| `c.arena` | per-request allocator |
| `c.text`, `c.html`, `c.json`, `c.jsonStatus`, `c.status`, `c.redirect`, `c.body` | responses |
| `try c.header(name, value)` | add a header to whatever response is returned |
| `try c.forward(url)` | proxy the request: method, body (except GET/HEAD), headers minus hop-by-hop, `host`, `cookie` and `authorization` |
| `try c.forwardWith(url, .{ .credentials = true })` | same, but keep `cookie` and `authorization` |

## Middleware

```zig
fn auth(c: *Ctx, next: hibana.Next) !hibana.Response {
    const token = (try c.req.header("authorization")) orelse return error.Unauthorized;
    c.vars.user = token;
    var res = try next.run();
    try res.setHeader(c.arena, "x-user", token);
    return res;
}
```

## Errors

Returning an error from a handler or middleware produces a JSON response
`{"error":"<reason phrase>","detail":...}` with the mapped status:

| error | status |
|---|---|
| `BadRequest` | 400 |
| `Unauthorized` | 401 |
| `Forbidden` | 403 |
| `NotFound` | 404 |
| `MethodNotAllowed` | 405 |
| `Conflict` | 409 |
| `PayloadTooLarge` | 413 |
| `UnsupportedMediaType` | 415 |
| `UnprocessableEntity` | 422 |
| `TooManyRequests` | 429 |
| `BadGateway` | 502 |
| `ServiceUnavailable` | 503 |
| anything else | 500 |

Set `c.req.validation_error` before returning `error.BadRequest` to fill `detail`.

A response whose header names are not tokens, or whose values contain CR, LF or
NUL, is replaced with a 500 before it leaves the app. Validate user input you put
into headers (for example a redirect target) and return 400 yourself.

Header names and values are not copied: keep them in `c.arena` or static memory.

## Testing

```zig
const App = hibana.App(hibana.testing.Runtime(MyEnv), .{ ... });

test "index" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var env: MyEnv = .{};
    const res = hibana.testing.request(App, arena.allocator(), &env, "/", .{});
    try std.testing.expectEqualStrings("hello", res.body);
}
```

To run the same app on several runtimes, write it as
`fn App(comptime Rt: type, ...) type` (see `examples/url-shortener`).
