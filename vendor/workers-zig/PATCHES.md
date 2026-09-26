# Local patches

Vendored from https://github.com/nilslice/workers-zig at `c82686d8c4c612ce59b4ba197d0054a8546c5738`.
Every change is marked `hibana patch` in the source.

1. **Per-call shadow stacks** (`js/shim.js`: `susp`, `promising`, `acquireStack`, `init`;
   `build.zig`: export `__stack_pointer`, `WorkerOptions.stack_size`).
   Zig keeps address-taken locals on a stack in linear memory addressed by the global
   `__stack_pointer`. Upstream, concurrent requests suspended on KV/fetch share it and
   overwrite each other's frames. Each JSPI entry now gets a pooled stack of `stack_size`
   (default 1 MiB, down from Zig's 16 MiB), and each suspending import restores the stack
   pointer before resuming.
2. **Single instantiation** (`init`): requests racing on the first call share one
   `WebAssembly.instantiate`.
3. **No stack traces in responses**: uncaught errors are logged and answered with a bare 500.
4. **`fetch_send` failures return a null handle** instead of throwing through wasm, so
   `Fetch.send` returns `error.NullHandle`.
