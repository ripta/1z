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

Each mode is driven under two connection modes. Plain `ab` sends HTTP/1.0 with no
keep-alive header. The server closes after every response, so this is the
close-per-request baseline. `ab -k` adds `Connection: keep-alive`. The server then
reuses each connection for up to its 100-requests-per-connection cap
(`requests-per-connection`), so a keep-alive run spawns one task per reused connection
instead of one per request. Keep-alive is on by default. No server flag toggles it;
the client decides by whether it sends the keep-alive header.

Each mode is measured against the same 23-byte `index.html`:

- Warmup: `ab -n 200 -c 10`, discarded. This lets the JIT modes reach steady
  state. The keep-alive run gets its own `ab -k` warmup.
- Measured: `ab -n 5000 -c 20`, and again with `-k`. The run is long on purpose. It
  runs well past the point where the old leak used to exhaust memory, so a clean run
  is itself evidence of bounded memory.
- `--max-memory=256M` on the interpreter and JIT modes. The per-connection leak
  is fixed, so the default cap holds.
- Steady-state RSS is sampled after each measured run. A leak would show as a
  large resident set rather than the few tens of megabytes below.

Every mode restarts the server fresh. Numbers are one machine, one session, so
treat small differences as noise.

## Results

Apple Silicon (arm64), macOS 25.5.0:

| Mode               | Conn      | req/s | ms/req (concurrent) | p50 (ms) | RSS (MB) |
|--------------------|-----------|-------|---------------------|----------|----------|
| `--compile=off`    | close     | 49.5  | 20.2                | 393      | 48       |
| `--compile=off`    | keep-alive| 51.7  | 19.3                | 282      | 137      |
| `--compile=hybrid` | close     | 49.3  | 20.3                | 395      | 49       |
| `--compile=hybrid` | keep-alive| 52.6  | 19.0                | 279      | 162      |
| `--compile=eager`  | close     | 49.2  | 20.3                | 395      | 60       |
| `--compile=eager`  | keep-alive| 51.6  | 19.4                | 284      | 177      |
| `aot`              | close     | reset | n/a                 | n/a      | n/a      |
| `aot`              | keep-alive| reset | n/a                 | n/a      | n/a      |

The interpreter and JIT modes each serve the full 5000-request run bounded, under
both connection modes. Close-per-request resident memory stays flat at about 50-60 MB,
well under the 256 MB cap. Keep-alive holds 20 long-lived connections open across the
run, so its resident set is higher (about 140-180 MB) but still bounded.

Keep-alive barely moves throughput: about 52 req/s versus 49 for close-per-request, a
few percent. It does lower per-request latency: p50 drops from about 393 ms to about
282 ms, because a reused connection skips the TCP handshake and per-connection task
spawn. But the sustained rate is the same.

### AOT does not serve yet

The AOT binary builds.
`1z build --interpreter-fallback=false examples/http-static.1z` compiles with no
rejected word. It links the interpreter as a fallback for the row-variable
combinators the serve path uses (`keep`, `2dip`, `try`), binds the port, and
prints its serving banner.

But it does not serve. It accepts each connection, reads the request, and never
sends a response. The compiled serve path fails at request handling. The harness
probes with `curl --max-time 5` before measuring; the probe times out, so both AOT
rows record `reset` rather than a throughput number. This happens the same way under
both connection modes. A working AOT number needs the compiled serve path to run,
which is separate work from this benchmark.

## Conclusion: throughput is bound by a per-request serial cost

Two things are constant across the table. Compile mode does not matter: the three
working modes are within run-to-run noise of each other in both connection modes.
Connection reuse does not matter for throughput either: keep-alive is within a few
percent of close-per-request.

The keep-alive result is the informative one. A keep-alive run serves up to 100
requests on one connection, so it does roughly one task spawn per 100 requests instead
of one per request. If the ceiling were the per-connection accept and task spawn,
removing 99 percent of the spawns would raise throughput sharply. It does not. So the
per-connection spawn is not what caps this workload at about 50 req/s.

What keep-alive does change is latency, not rate. p50 drops from about 393 ms to about
282 ms, the cost of the handshake and spawn a reused connection avoids. But the
sustained rate holds at about 50 req/s. That points at a per-request serial cost paid
whether or not the connection is reused. This benchmark does not pin down what that
cost is. Identifying it is separate work; the ~20 ms mean service time per request is
the thing to chase.

The one firm negative result: neither the compile mode nor connection reuse is the
lever here, so JIT and AOT will not help this workload until that per-request serial
cost is found and removed.

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
  public as a mitigation. The underlying runtime defect remains open. It is the
  same bare-word resolution failure that keeps the AOT server from responding.

- The AOT-compiled server accepts connections but never responds. It builds and
  binds the port, then accepts, reads the request, and stalls with no response and
  no diagnostic. It does not close the socket either: an unguarded `curl` against it
  hangs indefinitely, which is why the harness probes with `curl --max-time 5`. The
  cause is a bare word in the spawned handler resolving to the wrong getter across
  the spawn boundary; the compiled server cannot serve until that is fixed. The
  interpreter and both JIT modes serve the same program correctly.
