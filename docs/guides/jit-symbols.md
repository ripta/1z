# Sampled Profiles of JIT-Compiled Code

Under `--compile=hybrid` or `--compile=eager`, 1z compiles words to machine
code at run time. An external sampler such as `samply` or `perf` sees that code
as anonymous addresses. 1z can write a symbol map that the sampler reads, so the
profile names each compiled word.

The map is a jitdump file. It is off by default. This guide covers turning it
on, running each sampler, how words are named, and how to read the result.

For AOT binaries, which carry their names in the symbol table instead, see
[AOT Symbol Names for Profilers](aot-symbols.md). For the interpreter's own
profiler, see [Profiling](profiling.md).

## Turning the Map On

Pass a directory to `--jitdump-dir`:

```
./zig-out/bin/1z run --compile=eager --jitdump-dir=prof program.1z
```

`ONEZ_JITDUMP_DIR` sets the same directory for every command that honors
`ONEZ_COMPILE`. An explicit `--jitdump-dir` wins over the variable. An empty
variable means off.

The file is `DIR/jit-<pid>.dump`. The directory must exist. A relative
directory works, because 1z resolves it to an absolute path before opening the
file.

The map needs compilation. With `--compile=off`, 1z prints one note on stderr,
writes nothing, and runs the program:

```
Note: the JIT symbol map requires --compile=eager or --compile=hybrid (or ONEZ_COMPILE); no jitdump file will be written.
```

`1z check` takes no `--compile` flag. It writes the map only when
`ONEZ_COMPILE` selects eager or hybrid.

Failures are handled in two ways:

- A file that cannot be opened ends the run at startup with an error. A bad
  directory costs no profiling time.
- A write failure in mid-run prints one warning and stops the map. The program
  still finishes. Names stop appearing at that point in the profile.

Two platform limits apply:

- On macOS the absolute path of the file may be at most 244 bytes. A longer
  path fails at startup. samply would otherwise ignore it without a diagnostic.
- On Linux 1z maps the file executable, because `perf` finds the file from that
  mapping. A directory on a `noexec` mount makes that executable mapping fail,
  and 1z stops at startup with an error that suggests a `noexec` mount.

## How Words Are Named

A compiled word appears as its identity string. That is `module/word`, or the
bare word name when the word has no module. This is the same string an AOT
build uses, so a word reads the same in a JIT profile and an AOT profile.

Three rules refine this:

- A name with a NUL, `"`, `\`, or an ASCII control character falls back to the
  mangled C identifier. Every other byte is kept as written.
- The `#<rank>` suffix that AOT gives to modules with colliding names is not
  added. A running JIT does not know the whole program's module set.
- Prelude words carry the bare name. `when` appears as `when`.

A word that the loading file defines is installed before its module is final,
so it first appears under its bare name. When the module is final, 1z writes a
second record for each such word that still holds code, under `module/word`.
The sampler applies that name from the second record's timestamp onward. A
sample taken earlier keeps the bare name.

Code that several definitions share is compiled once. It carries the name of
the first definition. Later sharers get no record of their own.

The map names every compiled body. `--dump-jit-word=` filters only the byte
dumps and does not narrow the map.

## `samply` on macOS

`samply` reads the file directly. Launch 1z as the command that `samply record`
runs:

```
samply record --save-only --no-open -o hybrid.json.gz -- \
    ./zig-out/release/bin/1z run --compile=hybrid --jitdump-dir=prof program.1z
```

Drop `--save-only --no-open` to open the Firefox Profiler view when the run
ends. `samply load hybrid.json.gz` reopens a saved profile.

### macOS gotcha: launch 1z directly

`samply` finds the file through a library it preloads with
`DYLD_INSERT_LIBRARIES`. The library watches the process's `open()` of any file
named `jit-*.dump`. macOS strips that variable when the launch passes through a
system binary. Two launches therefore lose the map:

- Running 1z through `make` or `/bin/sh`. Give `samply record` the 1z binary
  itself.
- Attaching to a running process by pid. The preload never ran there.

A profile taken either way still works. The compiled words stay anonymous.

### macOS gotcha: codesign entitlements

`samply` needs the debugger entitlement. Run `samply setup` once after install:

```
samply setup --yes
```

The same restrictions as in [AOT Symbol Names for
Profilers](aot-symbols.md) apply in sandboxed shells.

## `samply` on Linux

`samply` on Linux reads the map from the executable mapping of the file, so the
command is the same as on macOS. The kernel must allow `perf_event_open`. See
the `perf_event_paranoid` gotcha in [AOT Symbol Names for
Profilers](aot-symbols.md).

The Linux paths in this guide have not been run. The writer compiles for Linux.
`make jit-symbol-verify-linux` is the check that runs them. Treat the Linux
commands as the documented intent until that target passes.

## `perf` on Linux

`perf` needs a post-processing step that merges the jitdump into the recording.
Record with `-k 1` so the clock matches the file's timestamps:

```
perf record -k 1 -F 99 -g -o perf.data -- \
    ./zig-out/bin/1z run --compile=eager --jitdump-dir=prof program.1z
perf inject --jit -i perf.data -o perf.jitted.data
perf report --stdio --no-children -i perf.jitted.data
```

`perf inject --jit` writes a small shared object for each compiled body, and
the report names the words from those.

## Reading the Result

With the map on, a compiled word is an ordinary named frame. This is the output
of `scripts/jit-symbol-profile-check.py --top=12` on a hybrid profile of the
lexer workload `tests/benchmark/lexer_tokenize_loop.1z`:

```
samples: 3666
samples with an anonymous JIT frame: 0
samples whose leaf is an anonymous JIT frame: 0
top 12 named frames by self:
        6  scanner/advance
        4  strings/whitespace?
        4  scanner/at-end?
        3  lexer/(bucket-for-scanner)
        3  2dup
        3  scanner/mark
        2  1z-tokens/(tab)
        2  when
        2  scanner/rest
        1  lexer/tokenize
        1  1z-tokens/(extract-value)
        1  and
top 12 named frames by total:
     1221  when
      766  scanner/peek
      604  1z-tokens/(consume-fractional)
      505  scanner/at-end?
      295  scanner/advance
      173  lexer/(try-rules)
      166  lexer/(bucket-for-scanner)
      152  conversions/digit?
      119  1z-tokens/(digit-or-sep?)
       81  1z-tokens/(consume-exponent)
       64  scanner/rest
       53  scanner/mark
```

The same run without `--jitdump-dir` had 2202 of 3700 samples carrying an
anonymous JIT frame.

Three things in such a profile are expected:

- Named frames hold almost no self time. In the run above no named frame has
  more than 6 self samples. The self time lands on native frames that `samply`
  stores as bare addresses, and this profile does not symbolicate them. In the
  matching eager run most leaf samples were in the 1z binary, and the two
  hottest bare addresses belonged to `libsystem_platform.dylib`. Smaller shares
  were in `libsystem_malloc.dylib`, `libsystem_kernel.dylib`, and
  `libsystem_pthread.dylib`.
- Frames such as `lexer/tokenize` appear rarely near the root of a stack. The
  tokenizer is lazy. It returns an iterator, and the scanning runs later under
  `#collect`. So the entry words are not ancestors of the scanning work.
- Interpreted words do not appear by name. A sampler sees the interpreter loop
  there, not the word it is running. In hybrid mode a word that has not yet
  been compiled is interpreted.

### Choosing between `--profile` and a sampler

Use `--profile` when you want per-word call counts and inclusive times for
interpreted words. It records a word's start on the interpreter's dispatch
path. It does not see a compiled word calling another compiled word, and its
per-call timestamps add overhead that grows with call count.

Use a sampler when you want to see every compiled frame. Its overhead does not
depend on call count. It cannot name interpreted words.

## File Growth

Each load record copies the body's code bytes into the file, and every
recompile adds one. A short run is small. The lexer workload wrote about 59 KB
in hybrid mode and 427 KB in eager mode. A long run that recompiles often grows
the file without bound. Point `--jitdump-dir` at a directory you can clear.

## What's Not Covered

Instruments cannot name JIT code. It reads neither a perf map nor a jitdump,
so this guide does not cover it. 1z writes no perf map and does not use the GDB
JIT interface, so a debugger sees no names either.

The map does not reach embedders through the C API, which reads no environment
variable.

## Reproducing the Evidence

- `make jit-symbol-verify` -- records a small workload with `samply` and checks
  that three compiled words are named. It also records a control run without
  the map and checks that those words stay anonymous. It takes about 10 seconds
  on macOS, and reports `SKIP` when `samply` is not installed. A run printed:

  ```
  --- samply (jitdump) ---
  samples: 2045
  PASS samply: jit-verify-inner on 1004 samples
  PASS samply: jit-verify-outer on 1004 samples
  PASS samply: jit-verify-sum on 1004 samples
  --- samply (no jitdump, control) ---
  PASS control: the words are anonymous without a jitdump
  PASS: jit-symbol-verify
  ```

- `make jit-symbol-verify-perf` -- the `perf record -k 1`, `perf inject --jit`
  path. Linux only, and `SKIP` without `perf`.
- `make jit-symbol-verify-linux` -- both checks inside the project's Debian
  Docker image.

To profile the lexer workload, build with `make release`, then run `samply
record` as shown above on `tests/benchmark/lexer_tokenize_loop.1z`, once with
`--compile=hybrid` and once with `--compile=eager`. Read each saved profile
with:

```
python3 scripts/jit-symbol-profile-check.py --top=20 hybrid.json.gz
```

None of these targets is part of `make test`, because they need external
profilers.
