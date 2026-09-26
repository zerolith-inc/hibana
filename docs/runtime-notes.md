# Runtime notes

Findings from building the MVP on workers-zig (pinned at `c82686d`).

## Works today

- `wrangler dev` runs the examples; `examples/hello` is 17 KB of wasm at ReleaseSmall, `examples/url-shortener` 72 KB.
- KV via `c.env.kv("NAME")` (and the rest of workers-zig's bindings through `c.env`).
- wrangler needs `compatibility_flags = ["nodejs_compat"]`: the workers-zig shim imports `node:fs`.

## Limits inherited from workers-zig

- **Request bodies are buffered by the JS shim.** workers-zig's `fetch` wrapper calls
  `request.arrayBuffer()` before entering wasm. hibana only copies the body into
  wasm memory when a handler reads it, but the bytes are already in JS memory, and
  bodies cannot be streamed.
- **`c.forward` buffers both ways.** workers-zig's outbound fetch takes the body as
  bytes and returns the upstream body as bytes. Passing the JS `ReadableStream`
  handle straight through needs new FFI in the shim.
- **Forwarded response headers are copied by name.** workers-zig can only look up
  upstream headers by name, so the adapter copies a fixed list
  (`Runtime.forwarded_response_headers`); `set-cookie` and custom headers are dropped.

Lifting these means adding a few FFI functions (request body handle, response from
handle, header iteration on fetch responses) to workers-zig, upstream or in a fork.
