# Runtime notes

hibana vendors workers-zig (`vendor/workers-zig`, upstream `c82686d`) with the
patches in `vendor/workers-zig/PATCHES.md`. The important one: every in-flight
request runs on its own 1 MiB shadow stack. Upstream shares one stack between
concurrent requests, which corrupts memory as soon as two of them wait on KV or
fetch at the same time (`tests/e2e` reproduces it). Deep recursion past 1 MiB
overwrites the heap silently; raise `stack_size` in `addWorker` if you need more.

## Works today

- `wrangler dev` runs the examples; `examples/hello` is 17 KB of wasm at ReleaseSmall, `examples/url-shortener` 72 KB.
- KV via `c.env.kv("NAME")` (and the rest of workers-zig's bindings through `c.env`).
- wrangler needs `compatibility_flags = ["nodejs_compat"]`: the workers-zig shim imports `node:fs`.

## Limits inherited from workers-zig

- **Request bodies are buffered by the JS shim.** workers-zig's `fetch` wrapper calls
  `request.arrayBuffer()` before entering wasm. hibana only copies the body into
  wasm memory when a handler reads it, but the bytes are already in JS memory, and
  bodies cannot be streamed.
- **Unreachable upstreams give 502** (the patched shim reports the failure instead of
  throwing). Other JS exceptions still end in a bare 500, logged but never sent to the client.
- **`c.forward` buffers both ways.** workers-zig's outbound fetch takes the body as
  bytes and returns the upstream body as bytes. Passing the JS `ReadableStream`
  handle straight through needs new FFI in the shim.
- **Forwarded response headers are copied by name.** workers-zig can only look up
  upstream headers by name, so the adapter copies a fixed list
  (`Runtime.forwarded_response_headers`); `set-cookie` and custom headers are dropped.

Lifting these means adding a few FFI functions (request body handle, response from
handle, header iteration on fetch responses) to workers-zig, upstream or in a fork.
