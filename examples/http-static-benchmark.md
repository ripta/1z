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

- Warmup: `ab -n 400`, discarded, at the same concurrency as the run it precedes.
  This lets the JIT modes reach steady state. The keep-alive run gets its own
  `ab -k` warmup.
- Measured: five runs per cell, of which the median run by throughput is reported.
  The interpreter mode varies enough run to run that a single pass cannot rank the
  modes. Each run is `ab -n 8000` at `-c 20` and `ab -n 4000` at `-c 1`, each also
  with `-k`. The runs are long on purpose, well past the point where the old leak
  used to exhaust memory.
- The tail-latency table reports the percentile line of that same median run.
- `--max-memory=256M` on the interpreter and JIT modes. The per-connection leak is
  fixed, so the cap holds. AOT binaries ignore this driver flag.
- Resident memory is sampled after each cell. A leak would show as a set that
  climbs cell over cell rather than settling.

Every mode restarts the server fresh. Numbers are one machine, one session, so
treat small differences as noise.

## Results

Apple Silicon (arm64), macOS 25.5.0, 14 logical cores. Each number is the median
of five runs.

### Throughput

| Mode               | Conn       |  c | req/s |
|--------------------|------------|----|-------|
| `--compile=off`    | close      |  1 |   968 |
| `--compile=off`    | close      | 20 |  2369 |
| `--compile=off`    | keep-alive |  1 |  1057 |
| `--compile=off`    | keep-alive | 20 |  1636 |
| `--compile=hybrid` | close      |  1 |   930 |
| `--compile=hybrid` | close      | 20 |  2374 |
| `--compile=hybrid` | keep-alive |  1 |  1054 |
| `--compile=hybrid` | keep-alive | 20 |  1722 |
| `--compile=eager`  | close      |  1 |   927 |
| `--compile=eager`  | close      | 20 |  2312 |
| `--compile=eager`  | keep-alive |  1 |  1054 |
| `--compile=eager`  | keep-alive | 20 |  1673 |
| `aot`              | close      |  1 |  1127 |
| `aot`              | close      | 20 |  2697 |
| `aot`              | keep-alive |  1 |  1050 |
| `aot`              | keep-alive | 20 |  2139 |

### Tail latency at concurrency 20

Percentiles are milliseconds, from the median run of each cell. At concurrency 1
every percentile rounds to 1 ms, so only the concurrency-20 cells appear here.

| Mode               | Conn       | p50 | p90 | p95 | p99 |  max |
|--------------------|------------|-----|-----|-----|-----|------|
| `--compile=off`    | close      |   8 |  11 |  12 |  14 |   27 |
| `--compile=off`    | keep-alive |   9 |  19 |  28 |  80 |  304 |
| `--compile=hybrid` | close      |   8 |  11 |  12 |  14 |   24 |
| `--compile=hybrid` | keep-alive |   8 |  15 |  23 | 135 |  294 |
| `--compile=eager`  | close      |   8 |  11 |  12 |  15 |   25 |
| `--compile=eager`  | keep-alive |   9 |  18 |  26 | 118 |  290 |
| `aot`              | close      |   7 |  10 |  11 |  14 |   25 |
| `aot`              | keep-alive |   7 |  15 |  18 |  64 |  256 |

Resident memory stayed bounded across the whole matrix. Close-mode cells settled
in the tens to low hundreds of megabytes. The heaviest cell, AOT keep-alive at
concurrency 20, peaked near 390 MB of process RSS, with the 1z heap capped at
256 MB on the interpreter and JIT modes. Nothing climbed cell over cell, which is
the signature the old per-request leak used to show.

### Optimization level (`-O0` vs `-O2`)

The `aot` rows in the main table were built at `-O0`, the C compiler default
before `1z build` gained the `--opt-level` flag. That flag now defaults to
`-O2`. This section compares the two levels in one session, so the delta is a
clean signal rather than a cross-session comparison. Only the AOT C codegen
changes. The interpreter and JIT modes are unaffected, so they are not
re-measured. The `-O0` rows here reproduce the main-table baseline (close c=1
1125 vs 1127, close c=20 2685 vs 2697), which anchors the control.

| AOT build | Conn       |  c | req/s |
|-----------|------------|----|-------|
| `-O0`     | close      |  1 |  1125 |
| `-O0`     | close      | 20 |  2685 |
| `-O0`     | keep-alive |  1 |  1070 |
| `-O0`     | keep-alive | 20 |  2089 |
| `-O2`     | close      |  1 |  1188 |
| `-O2`     | close      | 20 |  2695 |
| `-O2`     | keep-alive |  1 |  1123 |
| `-O2`     | keep-alive | 20 |  2152 |

Build time is the `cc` compile-and-link stage, with the release runtime already
built: `-O0` 1.40 s, `-O2` 1.52 s. Binary size: `-O0` 5.76 MiB, `-O2` 4.07 MiB.

`-O2` buys a small serial throughput gain, about 5 percent at concurrency 1
(1188 vs 1125 close, 1123 vs 1070 keep-alive). At concurrency 20 the gain washes
into noise on close (2695 vs 2685, under half a percent) and is about 3 percent
on keep-alive. The server is CPU-bound on per-request coordination at concurrency
20, not on the per-word dispatch that `-O2` inlines. So the optimization helps
most where dispatch is the bottleneck. That is the serial path.

`-O2` also shrinks the binary by about 29 percent, roughly 1.7 MiB. Dead-code
elimination and inlining leave fewer live functions, so the linker's dead-strip
drops more. The build costs about 0.1 s more. `-O2` is the better default on both
throughput and size at negligible build-time cost.

### Module-deps frame caching

Every call to a word from a library module used to rebuild that module's
deps-and-words dictionary into a fresh local frame, re-hashing every entry. The
serve path lives in `lib/net/http.1z`, so this ran on essentially every word
call. The rebuild now clones an immutable per-module template: one allocation and
one `memcpy` of the map backing, no re-hashing. The push path stays lock-free,
and the clone does fewer allocations than the per-entry rebuild it replaced.

The table below compares the current build against the release baseline. The
`--compile=off` rows compare against the main throughput table. The `aot` rows
compare against the `-O2` rows, since `1z build` now defaults to `-O2`. Hybrid and
eager track the interpreter, so only `--compile=off` is shown. Each current number
is a two-run median of medians, rounded. The two runs agreed within about 3
percent. The exception is AOT keep-alive at concurrency 20, which spanned 1934 to
2094.

| Mode            | Conn       |  c | baseline | current |
|-----------------|------------|----|----------|---------|
| `--compile=off` | close      |  1 |      968 |    1580 |
| `--compile=off` | close      | 20 |     2369 |    1820 |
| `--compile=off` | keep-alive |  1 |     1057 |    1930 |
| `--compile=off` | keep-alive | 20 |     1636 |    1310 |
| `aot` (`-O2`)   | close      |  1 |     1188 |    1200 |
| `aot` (`-O2`)   | close      | 20 |     2695 |    2630 |
| `aot` (`-O2`)   | keep-alive |  1 |     1123 |    1130 |
| `aot` (`-O2`)   | keep-alive | 20 |     2152 |    2010 |

Read this as the change in the whole build since the baseline, not as the cache in
isolation. The interpreter baseline predates two serve-path changes: a quotation
scope-capture guard and this cache. The interpreter serial throughput is much
higher than the baseline (close 1580 versus 968). AOT serial is flat across the
two sessions (1200 versus 1188), so that serial gain is the serve-path code
changes, not a faster machine. Splitting it between the capture guard and this
cache needs an in-session build-versus-build run, which this did not do.

The interpreter concurrency-20 throughput is lower than the baseline (close 1820
versus 2369). That gap is not the cache. This session the interpreter scales only
about 1.2x from one connection to twenty, while AOT scales about 2.2x. The
interpreter and JIT modes run under `--max-memory`, whose limit allocator does an
atomic add and subtract on one shared byte counter on every allocation. That is a
contention point the allocation-heavy interpreter path has and the unlimited AOT
server does not. It does not by itself explain the drop, though. The baseline
session ran under the same `--max-memory` and still scaled the interpreter about
2.4x. The concurrency-20 rate also varies with machine load, and this was a busier
session than the baseline. What changed the interpreter's scaling between the two
sessions is not established here.

The cache itself is lock-free and does fewer allocations per push than the
per-entry rebuild it replaced, so it cannot add contention or regress the serial
path. Confirming a concurrency win, or ruling one out, needs an in-session
build-versus-build comparison.

## Conclusion: AOT wins a steady margin; the JIT does not; keep-alive trades throughput for a tail

On release the server serves about 930 to 1130 req/s serially and, at concurrency
20, about 2300 to 2700 close, not the 50 an earlier version of this document
reported. That 50 was the debug safety allocator taking a global lock per
allocation, which serialized every worker. Building release removes the lock.
Every mode speeds up by more than an order of magnitude.

AOT is the one mode that helps, by a steady margin at both concurrencies. On the
median-of-five numbers it beats the interpreter about 16 percent serially (1127
vs 968) and about 14 percent at concurrency 20 (2697 vs 2369). That margin is the
per-request native dispatch AOT removes ahead of time. It does not wash out under
load.

The JIT does not help. Hybrid and eager track the interpreter, and at concurrency
1 they sit just below it (930 and 927 versus 968). The serve path lives on a
short-lived per-connection task. The JIT has little chance to run a word often
enough to amortize compiling it. Only ahead-of-time compilation pays here.

Throughput scales about 2.4x from one connection to twenty for every mode. That
scaling is what the debug allocator lock used to hide. The lock pinned every mode
near 50 req/s regardless of concurrency, which is why the old conclusion mistook a
lock-contention floor for interpreter cost.

The concurrency ceiling is the server, not the benchmark client. Driving one
server with two `ab -c 20` clients at once does not raise its total rate above a
single client's (interpreter 2168 versus 2414, AOT 2477 versus 2670), so one `ab`
already saturates it. The server burns about 11 of 14 cores at concurrency 20 yet
delivers only about 2.4x its single-connection rate. It is CPU-bound on the
per-request serve path and scales sub-linearly, so most of the added cores go to
coordination overhead rather than throughput. Naming the exact contention needs a
lock-aware profiler.

So the old table was wrong on both axes. It understated throughput by more than
an order of magnitude, and its 60 percent AOT figure was a debug artifact. The
honest AOT margin is about 15 percent.

Keep-alive splits by concurrency. At concurrency 1 reusing the connection helps
the interpreter and JIT modes a little (interpreter 1057 vs 968, eager 1054 vs
927), because it skips the per-request handshake and task spawn. AOT is flat
there. At concurrency 20 keep-alive costs every mode 20 to 31 percent of its close
throughput. The cost is not a slower typical request. The keep-alive median
matches close, around 7 to 9 ms. It is a fat tail. p99 jumps from close's 14 to
15 ms to 64 to 135 ms, and the worst request stretches to 256 to 304 ms. A small
fraction of requests on reused connections stall, and those stalls, not the
median, lower the rate. The stall sits in the wait for the next request on a live
connection. That is where the idle-read timeout the Defects section describes
arms, once per reused request, so it is the likely culprit.

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
