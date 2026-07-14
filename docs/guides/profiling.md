# Profiling 1z Programs

1z has two profiling paths. The interpreter collects per-word wall-time samples
and can emit them directly as a pprof profile. AOT-compiled binaries carry no
built-in sampler, so they are profiled with an external native profiler whose
output is then converted to pprof. Both paths end at the same tooling: `go tool
pprof` and the flamegraph, call-graph, and source-annotation views it drives.

## Interpreter Profiling

Run any program under `--profile` to collect a per-word wall-time sample buffer
and print a flat table when the program exits:

```
./zig-out/bin/1z --profile program.1z
```

The table is sorted by total time, highest first:

```
=== Word Profile (top 20 by total time) ===
  Word                   Calls    Total time     Self time   Time/call
  parse-line                42       1.20ms         840us        28us
  tokenize                   1       1.80ms         600us       1.80ms
  ...
```

The columns are:

- **Calls** -- how many times the word was dispatched.
- **Total time** -- inclusive wall time, counting time spent inside words the
  word called. A recursive word can exceed the program's wall time here.
- **Self time** -- exclusive wall time, with time spent in directly-called words
  subtracted out.
- **Time/call** -- total time divided by calls.

`--profile-top=N` caps the table at `N` rows. The default is 20.

### Emitting a pprof Profile

`--profile-out=FILE` writes the same sample buffer as a gzipped pprof profile.
It implies `--profile`, so the flat table still prints to stdout. The two
outputs go to different sinks, so they never conflict:

```
./zig-out/bin/1z --profile-out=program.pb.gz program.1z
```

pprof output is gzipped binary protobuf. It cannot share stdout with the
program's own output. So it needs a file destination.

## Opening a pprof Profile

The `.pb.gz` file is a gzipped `profile.proto`. Every pprof-consuming tool reads
it. With Go's `pprof`:

```
go tool pprof program.pb.gz
```

From there, `top` lists the hottest words, `web` renders a call graph, and
`list <word>` annotates a word's callers. The profile carries two sample types:

- **wall** in nanoseconds -- each sample's exclusive self-time. This is the
  default axis, so tools open on the time-weighted view.
- **calls** as a count -- one per recorded interval.

Each interval is one pprof sample whose stack is the word's full ancestor chain,
leaf-first. pprof derives the cumulative and flat views from those stacks. Flat
wall time is self time. Cumulative wall time is total time. The count axis gives
direct versus on-stack call counts. This covers all three columns of the
flat table, plus the call-graph structure the table cannot show.

## Limitation: Main-Context-Only

The interpreter's sample collector is attached to the main context only.
Spawned and detached task bodies run with no collector attached, so **their word
dispatches are not recorded at all**. Any work a program pushes into a task is
invisible to both the flat table and the pprof profile.

This hits the workloads that most want profiling. A server runs each connection
handler in a spawned or detached task, so a `--profile` run of a server captures
the accept loop and nothing of the handlers. Treat an interpreter profile as
covering only the code that runs on the main context.

Closing this gap -- per-task sample buffers merged into one labeled profile --
is a planned concurrency-aware profiling follow-on.

## Profiling AOT Binaries

`1z build` produces a native executable with no built-in pprof emitter. Profile
it the way you would any native binary. Use an external sampling profiler, then
convert the result to pprof.

The AOT binary carries verbatim 1z word names in its native symbol table, so the
samples land on names like `parse-json?` rather than mangled C identifiers. See
[AOT Symbol Names for Profilers](aot-symbols.md) for how that naming works and
for the per-tool platform gotchas -- `perf_event_paranoid`, `CAP_PERFMON` /
`CAP_SYS_ADMIN`, the macOS debugger entitlement, and the ELF `@` symbol-collapse
-- which apply unchanged here.

### `perf` -> pprof

On Linux, record with `perf` and a call-graph, then hand the `perf.data` to
Google's `perf_data_converter`:

```
perf record -F 99 -g -- ./program
perf_to_profile -i perf.data -o program.pb
go tool pprof program.pb
```

`perf record -F 99 -g` samples at 99 Hz with call stacks. `perf_to_profile` (the
`perf_data_converter` tool) turns the `perf.data` into a pprof profile that
`go tool pprof` opens directly.

### `samply`

`samply` is a sampling profiler that records on both Linux and macOS and opens
its own Firefox Profiler view:

```
samply record -- ./program
```

`samply load` reopens a saved profile. [AOT Symbol Names for
Profilers](aot-symbols.md) documents the `--save-only` and
`--unstable-presymbolicate` flags and the sidecar it writes.

### Privilege and Target Caveats

The external path works only where a sampler can attach to the process. That is
not always the case:

- **Privilege-denied environments.** A locked-down container, a CI runner, or a
  production sandbox may deny `perf_event_open`, ptrace, or the debugger
  entitlement. No external sampler can attach there. The per-tool privilege
  requirements are in [AOT Symbol Names for Profilers](aot-symbols.md).
- **Freestanding targets.** A bare-metal, no-OS AOT binary -- the class built by
  the [Bare-Metal AOT Builds](bare-metal.md) path -- has no operating-system
  profiler to attach at all.

In both cases the AOT binary is currently not profilable, since the only AOT
profiling path is the external native one. For the interpreter path and the
overall build pipeline, see [Execution and Compilation
Modes](execution-modes.md) and [Ahead-of-Time Compilation](aot.md).
