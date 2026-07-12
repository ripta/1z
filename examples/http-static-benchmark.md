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
- Measured: `ab -n 5000 -c 20`. The run is long on purpose. It runs well past the
  point where the old leak used to exhaust memory, so a clean run is itself
  evidence of bounded memory.
- `--max-memory=256M` on the interpreter and JIT modes. The per-connection leak
  is fixed, so the default cap holds.
- Steady-state RSS is sampled after each measured run. A leak would show as a
  large resident set rather than the few tens of megabytes below.

Every mode restarts the server fresh. Numbers are one machine, one session, so
treat small differences as noise.

## Results

Apple Silicon (arm64), macOS 25.5.0:

| Mode               | req/s | ms/req (concurrent) | p50 (ms) | RSS (MB) |
|--------------------|-------|---------------------|----------|----------|
| `--compile=off`    | 50.1  | 19.9                | 390      | 49       |
| `--compile=hybrid` | 50.0  | 20.0                | 391      | 49       |
| `--compile=eager`  | 49.8  | 20.1                | 391      | 61       |
| `aot`              | reset | n/a                 | n/a      | n/a      |

The interpreter and JIT modes each serve the full 5000-request run bounded.
Resident memory stays flat at about 50-60 MB, well under the 256 MB cap.

### AOT does not serve yet

The AOT binary builds.
`1z build --interpreter-fallback=false examples/http-static.1z` compiles with no
rejected word. It links the interpreter as a fallback for the row-variable
combinators the serve path uses (`keep`, `2dip`, `try`), binds the port, and
prints its serving banner.

But it does not serve. It accepts each connection, reads the request, and resets
the connection with no response. The compiled serve path fails at request
handling. So the AOT row records `reset`, not a throughput number. A working AOT
number needs the compiled serve path to run, which is separate work from this
benchmark.

## Conclusion: the server is spawn-bound, not compute-bound

The three working modes are within run-to-run noise of each other. Compile mode
does not matter here.

The reason is that throughput is limited by the per-connection task spawn, not by
the 1z-level request handling. The accept loop is serial. It accepts one
connection, spawns a handler task, and loops. Each spawn allocates a fresh
coroutine with a 768 KB stack, plus a context and arena. That native cost is
identical in every compile mode, so the JIT has nothing to speed up on the hot
path.

The JIT and AOT will only start to matter for this workload once the spawn cost
stops dominating. That means serving larger responses, doing more per-request
1z-level work, or making connection handling cheaper.

## Defects found

- The idle-read timeout leaked memory per request. Each request reads its request
  line under a timeout. The timeout built a nested scope with a main task and a
  timer task, and neither was reaped when the scope exited. Both lingered in the
  scheduler's finished list until the process ended. A long run leaked about a
  megabyte per request and hit the memory limit after roughly 250 connections. The
  timeout now reaps both tasks at scope exit. The same fix restores the worker's
  active-task counter, which the completion path had been driving negative. The
  bounded runs above and the `with_timeout_bounded` integration test both cover
  it.

- The high-level serve path once did not run at all. A tail call from public
  `serve-forever` into the private `serve-loop` dropped the module-deps frame, so
  `accept` was unresolvable. The library was restructured to make `serve-loop`
  public as a mitigation. The underlying runtime defect remains open. The AOT
  serve path resetting connections may be a related bare-word resolution failure
  in compiled code.

- The AOT-compiled server resets every connection instead of responding. It
  builds and binds the port, then accepts, reads the request, and closes the
  socket with no response and no diagnostic. The interpreter and both JIT modes
  serve the same program correctly.
