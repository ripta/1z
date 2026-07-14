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

The benchmark uses ApacheBench (`ab`), which ships with macOS.

The interpreter and runtime are built with `make release` (`--release=fast`),
and the AOT binary links that release runtime. This is load-bearing. A debug
build runs a safety allocator that takes a global lock per allocation. That lock
serializes the allocation-heavy serve path and makes every mode roughly 35 to 50
times slower. An earlier version of this document measured that debug build.

Each mode is driven across a 2x2 matrix: two connection modes by two concurrency
levels. Plain `ab` sends HTTP/1.0 with no keep-alive header. The server closes
after every response, so this is the close-per-request baseline. `ab -k` adds
`Connection: keep-alive`. The server then reuses each connection for up to its
100-requests-per-connection cap (`requests-per-connection`), so a keep-alive run
spawns one task per reused connection instead of one per request. Keep-alive is
on by default. No server flag toggles it; the client decides by whether it sends
the keep-alive header. Each connection mode is measured at concurrency 1 and 20,
so the table shows how throughput scales with concurrency.

Each mode is measured against the same 23-byte `index.html`:

- Warmup: `ab -n 200`, discarded, at the same concurrency as the run it precedes.
  This lets the JIT modes reach steady state. The keep-alive run gets its own
  `ab -k` warmup.
- Measured: `ab -n 5000` at `-c 1` and again at `-c 20`, each also with `-k`. The
  run is long on purpose. It runs well past the point where the old leak used to
  exhaust memory, so a clean run is itself evidence of bounded memory.
- `--max-memory=256M` on the interpreter and JIT modes. The per-connection leak
  is fixed, so the default cap holds. AOT binaries ignore this driver flag; their
  memory is shown via RSS.
- Steady-state RSS is sampled after each measured run. A leak would show as a
  large resident set rather than the few tens of megabytes below.

Every mode restarts the server fresh. Numbers are one machine, one session, so
treat small differences as noise.

## Results

Apple Silicon (arm64), macOS 25.5.0, 14 logical cores:

| Mode               | Conn       |  c | req/s | ms/req (concurrent) | p50 (ms) | RSS (MB) |
|--------------------|------------|----|-------|---------------------|----------|----------|
| `--compile=off`    | close      |  1 |   421 | 2.38                |        3 |       45 |
| `--compile=off`    | close      | 20 |  2800 | 0.36                |        7 |      137 |
| `--compile=off`    | keep-alive |  1 |   650 | 1.54                |        1 |       52 |
| `--compile=off`    | keep-alive | 20 |  2742 | 0.37                |        5 |      208 |
| `--compile=hybrid` | close      |  1 |   888 | 1.13                |        1 |       42 |
| `--compile=hybrid` | close      | 20 |  2503 | 0.40                |        7 |      127 |
| `--compile=hybrid` | keep-alive |  1 |  1034 | 0.97                |        1 |       48 |
| `--compile=hybrid` | keep-alive | 20 |  2476 | 0.40                |        6 |      184 |
| `--compile=eager`  | close      |  1 |   917 | 1.09                |        1 |       51 |
| `--compile=eager`  | close      | 20 |  2393 | 0.42                |        8 |      136 |
| `--compile=eager`  | keep-alive |  1 |  1052 | 0.95                |        1 |       55 |
| `--compile=eager`  | keep-alive | 20 |  1683 | 0.59                |        8 |      189 |
| `aot`              | close      |  1 |  1106 | 0.90                |        1 |       28 |
| `aot`              | close      | 20 |  2789 | 0.36                |        7 |      102 |
| `aot`              | keep-alive |  1 |  1078 | 0.93                |        1 |       39 |
| `aot`              | keep-alive | 20 |  2172 | 0.46                |        7 |      193 |

Every mode serves the full 5000-request run bounded, under both connection modes
and both concurrency levels. Close-per-request resident memory ranges from a few
tens of megabytes at concurrency 1 to about 100 to 140 MB at concurrency 20, well
under the 256 MB cap. Keep-alive at concurrency 20 holds 20 long-lived
connections open and carries a higher resident set (184 to 208 MB on the
interpreter and JIT modes) but stays bounded. The AOT binary carries the smallest
close-mode footprint (28 to 102 MB).

## Conclusion: compilation helps the serial path; concurrency closes the gap

On release the server serves hundreds to about 2800 requests per second, not the
50 an earlier version of this document reported. That 50 was the debug safety
allocator taking a global lock per allocation, which serialized every worker. It
was never interpreter dispatch. Building release removes that lock, and every
mode speeds up by more than an order of magnitude.

The clear, reproducible signal is at concurrency 1, where requests run serially.
There compilation pays. The interpreter serves 421 req/s close, JIT hybrid and
eager about 890 to 920, and AOT 1106. AOT is about 2.6 times the interpreter
serially. This is the per-request interpreter dispatch that compiling to native
removes.

At concurrency 20 the modes converge. Close-per-request lands between 2393 and
2800 req/s across all four modes, with the interpreter (2800) and AOT (2789) tied
at the top and the JIT modes a little behind, all within run-to-run noise. The
serial dispatch advantage disappears. At 20 concurrent connections the serve path
is bound by the shared accept, spawn, and syscall work, not by per-request
interpreter overhead, so removing that overhead buys nothing.

So the old table was wrong on both axes. It understated throughput by more than
an order of magnitude, and its claim that AOT beats the interpreter by about 60
percent was a debug artifact. The honest picture is narrower. Compiling helps a
serial client and does nothing for a saturated one.

Keep-alive helps only the serial client. At concurrency 1 reusing the connection
raises throughput for every interpreted and JIT mode (interpreter 650 vs 421,
hybrid 1034 vs 888, eager 1052 vs 917), because it skips the per-request
handshake and task spawn. AOT alone is flat there. At concurrency 20 the benefit
is gone. The interpreter and hybrid land within a couple percent of their close
numbers, but the eager and AOT modes drop 20 to 30 percent (eager 1683 vs 2393,
AOT 2172 vs 2789). Once the machine is saturated, holding 20 long-lived
connections open buys nothing over the accept path it replaces, and on this run
it cost the two most-compiled modes the most.

## Defects found

- The idle-read timeout leaked memory per request. Each request reads its
  request line under a timeout. The timeout built a nested scope with a main task
  and a timer task, and neither was reaped when the scope exited. Both lingered
  in the scheduler's finished list until the process ended. A long run leaked
  about a megabyte per request and hit the memory limit after roughly 250
  connections. The timeout now reaps both tasks at scope exit. The same fix
  restores the worker's active-task counter, which the completion path had been
  driving negative. The bounded runs above and the `with_timeout_bounded`
  integration test both cover it.

- The high-level serve path once did not run at all. A tail call from public
  `serve-forever` into the private `serve-loop` dropped the module-deps frame, so
  `accept` was unresolvable. The library was restructured to make `serve-loop`
  public as a mitigation.

- The AOT-compiled server used to accept connections but never respond, so its
  rows read `reset`. Inside `static-file-handler` the bare `path>>` was baked to
  `net`'s `unix-addr` getter instead of `net/http`'s `request` getter, and the
  type mismatch was swallowed into a hang. The cause was name-keyed AOT discovery
  collapsing two same-named getters from different modules;
  per-caller-module-scoped discovery fixed it, and the AOT rows above are now
  real numbers.
