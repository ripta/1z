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

Each mode is driven under two connection modes. Plain `ab` sends HTTP/1.0 with
no keep-alive header. The server closes after every response, so this is the
close-per-request baseline. `ab -k` adds `Connection: keep-alive`. The server
then reuses each connection for up to its 100-requests-per-connection cap
(`requests-per-connection`), so a keep-alive run spawns one task per reused
connection instead of one per request. Keep-alive is on by default. No server
flag toggles it; the client decides by whether it sends the keep-alive header.

Each mode is measured against the same 23-byte `index.html`:

- Warmup: `ab -n 200 -c 10`, discarded. This lets the JIT modes reach steady
  state. The keep-alive run gets its own `ab -k` warmup.
- Measured: `ab -n 5000 -c 20`, and again with `-k`. The run is long on
  purpose. It runs well past the point where the old leak used to exhaust
  memory, so a clean run is itself evidence of bounded memory.
- `--max-memory=256M` on the interpreter and JIT modes. The per-connection
  leak is fixed, so the default cap holds.
- Steady-state RSS is sampled after each measured run. A leak would show as a
  large resident set rather than the few tens of megabytes below.

Every mode restarts the server fresh. Numbers are one machine, one session, so
treat small differences as noise.

## Results

Apple Silicon (arm64), macOS 25.5.0:

| Mode               | Conn      | req/s | ms/req (concurrent) | p50 (ms) | RSS (MB) |
|--------------------|-----------|-------|---------------------|----------|----------|
| `--compile=off`    | close     | 48.5  | 20.6                | 401      | 48       |
| `--compile=off`    | keep-alive| 52.1  | 19.2                | 282      | 163      |
| `--compile=hybrid` | close     | 49.1  | 20.4                | 397      | 49       |
| `--compile=hybrid` | keep-alive| 52.1  | 19.2                | 280      | 174      |
| `--compile=eager`  | close     | 49.4  | 20.2                | 392      | 61       |
| `--compile=eager`  | keep-alive| 49.9  | 20.0                | 315      | 177      |
| `aot`              | close     | 78.9  | 12.7                | 245      | 38       |
| `aot`              | keep-alive| 66.7  | 15.0                | 223      | 67       |

Every mode serves the full 5000-request run bounded, under both connection
modes. Close-per-request resident memory stays flat at a few tens of megabytes,
well under the 256 MB cap.

Keep-alive holds 20 long-lived connections open across the run. The interpreter
and JIT modes carry a higher resident set (about 160-180 MB) but stay bounded.
The AOT binary holds far fewer bytes (37-67 MB) in both modes.

## Conclusion: AOT raises throughput; JIT and connection reuse do not

The interpreter and both JIT modes land within run-to-run noise of each other,
about 49 req/s close and 52 keep-alive. So the JIT does not help this workload,
and neither does connection reuse: keep-alive is a few percent of close-per-
request.

The keep-alive result explains why. A keep-alive run serves up to 100 requests
on one connection, so it does roughly one task spawn per 100 requests instead
of one per request. Removing 99 percent of the per-connection spawns does not
raise the interpreter/JIT rate, so the per-connection accept and spawn is not
what caps them at about 50 req/s. Keep-alive lowers latency, not rate: p50
drops from about 400 ms to about 280 ms, the handshake and spawn a reused
connection skips.

AOT is the outlier and the useful result: 78.9 req/s close, about 60 percent
above the interpreter, at lower latency (p50 245 ms) and a smaller resident
set. Compiling the serve path to native removes per-request interpreter
dispatch overhead that the JIT, on this short-lived per-connection path, never
amortizes. So the per-request serial cost that caps the interpreter and JIT is
substantially interpreter overhead, and AOT is the mode that cuts it. AOT close
outruns AOT keep-alive here (78.9 vs 66.7); with the per-request cost lowered,
the long-lived connections keep-alive holds open cost more than the handshakes
they save.

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
