# AOT Symbol Names for Profilers

`1z build` produces a native executable whose C function symbols are routed
through `asm("...")` declaration attributes so that the linker symbol table
carries the original 1z word names rather than the mangled C identifiers the
backend would otherwise emit. `nm`, `perf`, and `samply` all read those
symbols, so a profile of a 1z program lands on names like `parse-json?` and
`person/id>>` instead of `onez_w_parse_json_Q` and `onez_w_id_G_G`.

For the complete build pipeline that produces these functions and symbols, see
[Ahead-of-Time Compilation](aot.md).

The verification harness shipped with this repo confirms the policy across the
toolchains that consume the symbol table, on both macOS and Linux. This guide
documents what it covers and the per-tool surprises it surfaced.

## Naming Convention

| Kind of word | Asm-name format | Example |
|---|---|---|
| User-defined word | the 1z word name, verbatim | `parse-json?`, `>foo` |
| Prelude word | the 1z word name, verbatim | `print-line` |
| Compiled quotation | `<defining-word>/quot@<line>:<col>` | `pick-quot/quot@17:1` |
| Generated word (struct accessor, enum predicate) | `<parent>/<synthesized-name>` | `person/id>>`, `status/status?` |

Characters that are illegal in C identifiers (`-`, `?`, `>`, `<`, `#`, `!`)
are preserved without transformation. Only NUL bytes, embedded quotes, and
ASCII controls fall back to the mangled C identifier.

## Running the Harness

The fixture lives at `tests/aot/aot_symbol_verify_workload.1z` and runs four
named workloads (a word with `?` and `-`, a word starting with `>`, a word
holding two inline quotation arms, and an `if` driving each). The macOS-side
harness is:

```
make aot-symbol-verify
```

It builds the fixture, then runs `nm`, `samply`, and `perf` against the
binary, reporting `PASS`, `NOTE`, or `SKIP` per tool. Tools that aren't
installed produce `SKIP`; tools that exercise cleanly but find a
platform-specific quirk produce `NOTE`.

The Linux side runs the same harness inside the project's Debian build image,
with the kernel capabilities `perf_event_open` needs:

```
make aot-symbol-verify-linux
```

This rebuilds `1z-build:local` from the Dockerfile (`linux-perf` and `samply`
are installed for both x86_64 and aarch64 hosts) and invokes the harness with
`--security-opt seccomp=unconfined --cap-add SYS_ADMIN`.

## `nm`: The Baseline

`nm` reads the binary's symbol table directly. It works on both macOS Mach-O
and Linux ELF without any runtime permission. The harness asserts that the
verbatim names appear:

```
$ nm zig-out/aot-symbol-verify-workload | grep -E ' T (parse-json|>foo|pick-quot)'
0000000100ae8aec T >foo
0000000100af00d0 T >foo/quot@15:8
0000000100ae7c58 T parse-json?
0000000100af05d0 T parse-json?/quot@11:8
0000000100ae93fc T pick-quot
0000000100aee068 T pick-quot/quot@19:1
0000000100aee978 T pick-quot/quot@19:10
0000000100aeee78 T pick-quot/quot@20:1
0000000100aef788 T pick-quot/quot@20:10
```

That is the macOS output. The same binary built inside the Linux build image
produces:

```
$ nm /workspace/zig-out/aot-symbol-verify-workload-linux | grep -E ' T (parse-json|>foo|pick-quot)'
000000000119f6b0 T parse-json?
00000000011a0544 T >foo
00000000011a0e54 T pick-quot
00000000011a5ac0 T pick-quot/quot
00000000011a63d0 T pick-quot/quot
00000000011a68d0 T pick-quot/quot
00000000011a71e0 T pick-quot/quot
00000000011a7b28 T >foo/quot
00000000011a8028 T parse-json?/quot
```

Word and prelude symbols round-trip cleanly. Compiled-quotation symbols
collapse: see the ELF `@` gotcha below.

## `samply`

`samply` is a sampling profiler that produces Firefox Profiler JSON. It
records on both Linux and macOS. With `--save-only` and
`--unstable-presymbolicate`, it writes the profile alongside a `.syms.json`
sidecar that resolves stack addresses to symbol strings:

```
samply record --unstable-presymbolicate --save-only --no-open \
    -o aot-symbol-verify.profile.json.gz \
    -- ./zig-out/aot-symbol-verify-workload
```

The harness asserts the verbatim word names appear in the sidecar:

```
$ grep -oE '"(parse-json\?|>foo|pick-quot)"' aot-symbol-verify.profile.json.syms.json | sort -u
"parse-json?"
">foo"
"pick-quot"
```

Loading the profile with `samply load` opens the Firefox Profiler in a
browser and displays the Call Tree with those names directly.

### macOS gotcha: codesign entitlements

`samply` on macOS needs the debugger entitlement to sample another process.
Run `samply setup` once after install:

```
samply setup --yes
```

Some shells (CI runners, sandboxed sessions, restricted IDE consoles) cannot
grant the entitlement to the brew-installed binary even after `samply setup`
reports success -- the harness handles that case by reporting
`SKIP samply` instead of `FAIL`. Run the harness from a normal interactive
terminal to capture the evidence.

### Linux gotcha: `perf_event_paranoid`

On Linux `samply` calls `perf_event_open`, which requires
`/proc/sys/kernel/perf_event_paranoid` to be `1` or lower for non-root users.
The kernel default in Debian is `2`. The Docker harness tries to write `1` to
that file at start-up, but `/proc/sys` is mounted read-only in unprivileged
containers (and even under OrbStack's Linux VM with `--cap-add SYS_ADMIN`),
so the override only takes effect on hosts where you can set the sysctl at
the host level. When the override fails, the harness reports
`SKIP samply` and surfaces samply's own error message, which names the file.

## `perf`

`perf` is Linux-only and reads symbols from the ELF binary's symbol table.
The harness runs it as `perf record -F 99 -g` then `perf report --stdio --no-children`,
and asserts the verbatim 1z names appear in the report. A representative
slice from the Linux harness output is:

```
# Samples: 393  of event 'task-clock:ppp'
# Overhead  Command          Shared Object                     Symbol
# ........  ...............  ................................  ......
    85.75%  aot-symbol-veri  aot-symbol-verify-workload-linux  [.] signal.checkPendingSignals
            |
            ---signal.checkPendingSignals
               jitSafepoint
               |--43.00%--pick-quot
               |--21.88%-->foo
                --20.87%--parse-json?
```

The hot frame is `signal.checkPendingSignals` because the inner loop bodies
in the fixture spend almost all of their time inside the AOT safepoint check;
the 1z words appear by name in the call-stack tree.

### Linux gotcha: kernel capability

`perf_event_open` needs either `CAP_PERFMON` (Linux 5.8+), the older
`CAP_SYS_ADMIN`, or `perf_event_paranoid <= 1`. The harness uses
`--cap-add SYS_ADMIN`, which is enough for `perf record` to succeed under
unprivileged Docker. The same cap is *not* enough for `samply` (see above),
which uses a different code path under the hood.

### Linux gotcha: arm64 perf unwinding

On aarch64 hosts (Apple Silicon under OrbStack), `perf record -g` prints
`unwind: get_proc_name unsupported` repeatedly while sampling. The samples
themselves are valid -- the warning comes from perf's libunwind backend
failing to resolve some non-1z frames -- and the verbatim 1z names still
show up in the report.

## ELF `@` Gotcha: Compiled-Quotation Symbol Collision

On Linux ELF, `@` inside a symbol name is reserved for symbol versioning
(`name@version`). The toolchain strips the `@<line>:<col>` suffix from the
asm-name when constructing the symbol table, so four sibling compiled
quotations -- emitted as `pick-quot/quot@19:1`, `pick-quot/quot@19:10`,
`pick-quot/quot@20:1`, `pick-quot/quot@20:10` -- all collapse to
`pick-quot/quot`. The four distinct functions still exist at distinct
addresses, but `nm`, `perf`, and `samply` cannot disambiguate them by name;
samples land in a single bucket labeled `pick-quot/quot`.

Mach-O does not interpret `@` and preserves the full suffix, so macOS
profiles still attribute each quotation arm separately.

The harness emits a `NOTE` (not `FAIL`) when it detects the collapse on
ELF: the verbatim policy is still applied, it just doesn't survive the ELF
symbol-versioning convention.

## What's Not Covered

This guide is about the asm-name layer. It addresses the *linker symbol* and
`DW_AT_linkage_name`. The DWARF `DW_AT_name` attribute, which is what `gdb` and
`lldb` display in backtraces (`bt`) and step-into, still shows the mangled C
identifier (`onez_w_parse_json_Q`). Adding DWARF-side overrides is deferred to
a follow-on proposal whose revisit hook is the cross-tool evidence captured
here.

## Reproducing the Evidence

Both targets run as part of regular development workflows:

- `make aot-symbol-verify` -- macOS-side harness, ~5 seconds when all tools
  are installed.
- `make aot-symbol-verify-linux` -- Linux-side harness inside the build
  Docker image, ~30 seconds on the first run (image rebuild), ~10 seconds
  on subsequent runs.

Neither target is wired into `make test` because they exercise external
profiler tools that aren't part of the standard build dependency closure.
Run them ad hoc when the asm-name policy code changes.
