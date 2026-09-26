# hibana

A Hono-style web framework in Zig for Cloudflare Workers.

- Comptime routing with typed path params (`fn (c: *Ctx, p: struct { id: u32 })`)
- Onion middleware (`fn (c: *Ctx, next: hibana.Next) !Response`) with typed per-request `Vars`
- Typed JSON bodies: `try c.req.json(T)`; bad input becomes a 400 with a reason
- Zig errors become HTTP responses (`return error.NotFound` gives a 404)
- Lazy request bodies and `c.forward(url)` for proxying
- A runtime-independent core, with adapters for Workers (via [workers-zig](https://github.com/nilslice/workers-zig)) and `std.http` (local dev and tests)

Requires Zig 0.16.0.

## Example

```zig
const hibana = @import("hibana");
const hw = @import("hibana-workers");

const Ctx = hibana.Context(hw.Runtime, hibana.NoVars);

fn index(c: *Ctx) !hibana.Response {
    return c.text("Hello from hibana!");
}

fn greet(c: *Ctx, p: struct { name: []const u8 }) !hibana.Response {
    return c.json(.{ .hello = p.name });
}

const App = hibana.App(hw.Runtime, .{ .routes = .{
    hibana.get("/", index),
    hibana.get("/hello/:name", greet),
} });

pub const fetch = hw.fetch(App);
```

`build.zig`:

```zig
const std = @import("std");
const hibana = @import("hibana");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("hibana", .{});
    b.installArtifact(hibana.addWorker(b, dep, b.path("src/main.zig"), .{}));
}
```

Then `zig build && npx wrangler dev` (wrangler.toml needs `compatibility_flags = ["nodejs_compat"]`; see `examples/hello`).

## Layout

| Path | What |
|---|---|
| `src/core` | Router, Context, middleware, errors, typed JSON. Imports `std` only; the build gives it no other imports, so it cannot depend on workers-zig. |
| `src/core/testing.zig` | Fake runtime for unit tests (`hibana.testing`). |
| `src/adapters/workers` | `hibana-workers`: Runtime over workers-zig, `fetch(App)` entrypoint. |
| `src/adapters/std` | `hibana-std`: Runtime and server over `std.http`. |
| `vendor/workers-zig` | workers-zig with local patches (see its `PATCHES.md`). |
| `tests/e2e` | Concurrency test under `wrangler dev`. |
| `examples/hello` | Minimal worker. |
| `examples/url-shortener` | KV-backed shortener; the same app runs on Workers, on `std.http` (`zig build run`), and in tests. |
| `docs/` | Guides and design notes. |

## Development

```sh
zig build test                                   # core unit + std adapter integration tests
cd examples/url-shortener && zig build test      # example app tests
cd examples/url-shortener && zig build run       # local server on :8787
cd examples/url-shortener && zig build && npx wrangler dev
```

See [docs/guide.md](docs/guide.md) for the API and [docs/runtime-notes.md](docs/runtime-notes.md) for what the Workers adapter can and cannot do yet.
