# http-static.1z: performance comparison

This documents a throughput comparison of `examples/http-static.1z`, a static
file HTTP server, across 1z's execution modes. Reproduce it with
`examples/http-static-benchmark.sh`.

## The server

`examples/http-static.1z` parses `--host` / `--port` / `--dir` flags and calls
`serve-static` from `lib/net/http.1z`. `serve-static` serves files from a
directory over HTTP/1.1. It spawns one green-thread task per connection, blocks
directory traversal, serves `index.html` for directory paths, and sets the
content type from the file extension.

## Method

The benchmark uses ApacheBench (`ab`), which ships with macOS. `wrk` is not used:
the server sends `Connection: close`, so keep-alive does not apply, and `wrk` is
not present on a stock macOS.

Each mode is measured against the same 23-byte `index.html`:

- Warmup: `ab -n 200 -c 10`, discarded. This lets the JIT modes reach steady
  state.
- Measured: `ab -n 1000 -c 20`.
- `--max-memory=2G`, raised so the per-connection memory leak (see below) does
  not kill the server mid-run.

Every mode restarts the server fresh. Numbers are one machine, one session, so
treat small differences as noise.

## Results

Apple Silicon (arm64), macOS 25.5.0:

| Mode              | req/s | ms/req (concurrent) | p50 (ms) |
|-------------------|-------|---------------------|----------|
| `--compile=off`    | 79.5  | 12.6                | 240      |
| `--compile=hybrid` | 81.4  | 12.3                | 236      |
| `--compile=eager`  | 80.8  | 12.4                | 240      |

AOT (`1z build`) is not covered here. It is deferred to a follow-up, because the
serving path relies on the module and task-scope machinery that first needs the
defects below resolved.

## Conclusion: the server is spawn-bound, not compute-bound

The three modes are within run-to-run noise of each other. Compile mode does not
matter here.

The reason is that throughput is limited by the per-connection task spawn, not by
the 1z-level request handling. The accept loop is serial: it accepts one
connection, spawns a handler task, and loops. Each spawn allocates a fresh
coroutine (a 768 KB stack) plus a context and arena. That native cost is
identical in every compile mode, so the JIT has nothing to speed up on the hot
path. Throughput is also flat with concurrency (about 82 req/s at both `-c 10`
and `-c 20`), which is the signature of a serial bottleneck rather than a
CPU-bound one.

The JIT and AOT will only start to matter for this workload once the spawn cost
stops dominating. That means serving larger responses, doing more per-request
1z-level work, or making connection handling cheaper.

## Defects found

Two pre-existing defects surfaced. Both are filed and are being addressed
separately from the server work.

- The entire high-level serve path (`serve`, `serve-static`, `serve-forever`)
  never ran. A tail call from public `serve-forever` into the private
  `serve-loop` dropped the module-deps frame, so `accept` was unresolvable. The
  library was restructured to make `serve-loop` public as a mitigation; the
  underlying runtime defect remains open.

- A `task-scope` never reaps completed children while it is open. The server's
  accept loop runs inside one perpetual `task-scope`, so every completed
  connection task's memory is retained. The server leaks about 285 KB per request
  and dies at the memory limit after roughly 900 connections. The raised
  `--max-memory` in the benchmark only defers this; it does not bound
  steady-state memory.
