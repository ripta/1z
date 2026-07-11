# POSIX

`lib/posix.1z` is a library home for libc-bound POSIX functions. It opens the
system C library once, binds a set of syscalls through the errno-aware FFI
convention, and exposes a constant-lookup word. A library author who wants a new
syscall binding writes it here in 1z. No Zig change and no interpreter rebuild
are needed.

```
use "posix" ;

getpid   \ the calling process id
```

The "posix" name signals the abstraction level and intent, a syscall-baseline
surface, not strict POSIX.1-2017 conformance for every word. Functions that are
BSD-derived rather than strictly standardized, `flock(2)` for instance, live here
honestly and are documented as platform-specific where they diverge.

This guide assumes you are comfortable with the [FFI guide](ffi.md). The errno
convention and the per-binding capability model are FFI features documented
there. This guide is the worked consumer.

## When to Use `lib/posix.1z` vs Native Primitives

1z already exposes many operating-system operations as native primitives:
`stream-open` for files, the socket surface for networking, the filesystem words
(`create-directory`, `delete-file`). Those stay the right answer. They go through
Zig's standard library, which already absorbs the platform difference, so they
cost nothing extra and work identically everywhere 1z runs.

Reach for `lib/posix.1z` when you need a syscall the standard library does not
surface to 1z:

- advisory whole-file locks (`flock`)
- resource limits (`getrlimit` / `setrlimit`)
- signals (`kill`)
- memory tuning the stdlib does not expose (`mprotect`, `madvise`)
- fine-grained clocks (`clock_gettime`)
- file-descriptor control and truncation (`fcntl`, `truncate`, `ftruncate`)
- non-blocking child reaping (`waitpid`, `wait`)

The two routes coexist. A new binding picks the route based on what the syscall
needs. Where Zig stdlib already does the work, going through libc is added cost
for no benefit.

## Constants: `posix-const`

`posix-const` maps a constant name to its value on the build target, returning a
fixnum. It is the bridge from the C header's compile-time constants to a 1z
value.

```
use "posix" ;

"LOCK_EX" posix-const     \ 2
"PROT_READ" posix-const   \ 1
"O_CLOEXEC" posix-const   \ a positive bit value
```

The value goes straight into an FFI call with no conversion. An unknown name is
an error, surfaced when the lookup runs:

```
use "posix" ;

[ "NOT_A_CONSTANT" posix-const ] [ drop "unknown constant" print-line ] recover
```

Some constants are platform-specific. The `POSIX_FADV_*` advice values exist only
on Linux, so a program that reads them guards the lookup with parse-time platform
dispatch:

```
use "posix" ;

target-os choose{
  linux: [ "POSIX_FADV_SEQUENTIAL" posix-const ]
  _ [ f ]
}
```

## Low-Level Bindings and High-Level Wrappers

Every function is bound under its raw libc name. A raw binding reads like the man
page and returns the raw integer, with errno reaching the caller through the
error context. `flock`, `kill`, `getrlimit`, `truncate`, and the rest are all
available directly.

```
use "posix" ;

getpid getppid   \ ( -- pid ppid )
```

On top of the raw layer, a high-level wrapper is added only where it earns its
keep: where it throws on failure, manages a resource, or hides a constant.

`lock-file` wraps `flock`. It takes a stream and a symbol mode, looks up the
`LOCK_*` constant, and acquires the lock. The lock releases when the descriptor
closes.

```
use "posix" ;

"work.lock" write: stream-open   \ stack: stream
dup exclusive: lock-file          \ acquire an exclusive advisory lock
\ ... hold the lock while doing work ...
stream-close                      \ releases the lock
"work.lock" delete-file
```

`resource-limit` wraps `getrlimit`. It takes a resource-kind symbol, hides the
`RLIMIT_*` lookup, and returns the soft and hard limits.

```
use "posix" ;

nofile: resource-limit   \ ( -- soft hard ) open-file-descriptor limits
```

`send-signal` wraps `kill`, mapping a bare signal-name symbol to its number. A
signal of `0` checks for existence without sending.

```
use "posix" ;

getpid WINCH: send-signal   \ SIGWINCH is ignored by default, so this is harmless
```

## Waiting for Children

`waitpid` reaps an exited child. It takes a pid and an options word and returns
the reaped pid and the raw status word.

```
use "posix" ;

child-pid 0 waitpid   \ ( -- pid status ) blocking wait for one specific child
```

The status is the raw C status word, not a decoded exit code. Decode it with your
own arithmetic. For a normal exit the exit code lives in the high byte on both
Linux and macOS, so `256 div` recovers it:

```
use "posix" ;

child-pid 0 waitpid   \ pid status
256 div               \ pid exit-code
```

`wait` is the high-level wrapper. It reaps any exited child without blocking, by
calling `waitpid` with `-1` and `WNOHANG`. It returns pid `0` when no child is
ready:

```
use "posix" ;

wait   \ ( -- pid status ) pid is 0 when nothing is ready
```

`wait` is non-blocking on purpose. A blocking wait through the FFI would block the
whole scheduler worker thread, not just the calling task. Poll it and yield
between polls instead:

```
use "posix" ;

reap-any: ( -- pid status ) [
  wait over 0 = [ 2drop yield reap-any ] [ ] if
] ;
```

Do not mix `wait` with the scheduler-managed child processes in `lib/process.1z`
(`spawn-process` with `wait-process`). `wait` reaps any child, so it can steal a
child the scheduler is already waiting on. That leaves the scheduler's waiter
hanging. Use one model or the other for a given child, not both. When there are no
children at all, `wait` fails with `echild:`.

## Errno Failures

A raw binding raises `posix-error:` when the syscall fails. The error carries the
portable errno name and the raw integer. The mechanics are covered in the
[FFI guide](ffi.md#errno-aware-bindings); the pattern for a POSIX word is:

```
use "posix" ;

[ "/no/such/path" 0 truncate ]
[ data: @get name: @get ]   \ enoent:
recover
```

Match on the `name:` symbol (`enoent:`, `ebadf:`, `esrch:`, ...). It is the same
on every platform, unlike the raw errno integer.

## Capabilities

Each binding declares the sandbox capability it requires, checked at the FFI
boundary. See the [FFI guide](ffi.md#per-binding-capabilities) for how the check
works. The v1 words split as:

- `io/fs`: `flock`, `lock-file`, `truncate`, `ftruncate`, `fcntl`, `posix_fadvise`
- `system`: `kill`, `send-signal`, `mprotect`, `madvise`, `getrlimit`, `setrlimit`,
  `resource-limit`, `set-resource-limit`, `waitpid`, `wait`
- `none`: `getpid`, `getppid`, `clock_gettime`

A sandbox that grants `io/fs` can lock a file but cannot send a signal.

## Adding a New POSIX Binding

The module has libc open, errno wired up, and the constant lookup ready, so a new
syscall is a one-line addition to the `ffi-def{ }` block plus a thin public word.
To bind `fsync(int) -> int`, which flushes a file descriptor and reports failure
on `-1`:

```
"c" lib-open ffi-def{
  \ ... existing entries ...
  (fsync): "fsync" H{ errno: neg1: cap: io/fs: } ffi{ i32 -> i32 }
} call "posix-raw" swap >module reexport

\\ Flush a file descriptor's buffered data to disk.
\\
\\ Throws `posix-error:` on failure.
fsync: ( fd -- result ) [ (fsync) ] ;
```

The entry names the C symbol, declares the errno sentinel and the capability, and
gives the type signature. The public word is a pass-through: the errno convention
does the throwing and the capability gate fires inside the call, so the wrapper's
only job is the man-page name, the stack effect, and the doc comment. Add a
high-level wrapper on top only if there is a constant to hide or a resource to
manage.

The [guides index](index.md) has links to all conceptual guides.
