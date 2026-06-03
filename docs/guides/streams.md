# Streams

A stream is a uniform read / write surface over a byte transport. The
transport varies -- a file descriptor, a pair of file descriptors, an
in-memory buffer, the read end of a pipe -- but the stack effects of
`stream-read`, `stream-write`, `stream-close`, and `stream-flush` are the
same regardless. Code that takes `( stream -- )` does not need to know
what is on the other side.

## The Abstraction

`stream` is a single value type. Every stream value satisfies the
`stream?` predicate and dispatches through a small vtable for the four
operations a transport must answer to:

| Word | Effect | Notes |
|------|--------|-------|
| `stream-read` | `( stream n -- bytes )` | A single call may return fewer than n bytes; zero bytes signals EOF. |
| `stream-write` | `( stream bytes -- n )` | Returns the count actually written; loop or use `stream-write(exact)` for the full count. |
| `stream-close` | `( stream -- )` | Idempotent in the sense that a closed stream throws `closed-stream:` on every operation. |
| `stream-flush` | `( stream -- )` | No-op for transports that do not buffer. |

The convenience layer in the prelude builds on these. `stream-read(exact)`
loops on `stream-read` until n bytes arrive or EOF. `stream-write(exact)`
loops until every byte lands. `stream-read-line` reads until a newline.
`stream-read-all` reads until EOF. `print`, `print-line`, and `emit` are
thin wrappers over `stream-write` against the current output stream
parameter.

Stream positioning is a transport capability, not a stream-protocol
capability. `stream-tell`, `stream-seek`, and `stream-seek-end` throw
`not-seekable:` on transports that have no seek -- pipes, sockets,
in-memory writers, the standard streams, and the bidirectional stream
described below.

## File Streams

`stream-open` opens a file by path with one of four mode symbols:

```
"notes.txt" write: stream-open
dup "hello\n" stream-write drop
stream-close
```

The mode symbols are `read:`, `write:`, `append:`, and `read-write:`.
File streams support the positioning words; the buffering defaults to
unbuffered and can be changed with `set-buffering-mode` to `line:` or
`block:`.

## Standard Streams

`stdin`, `stdout`, and `stderr` return stream values backed by the
process's standard file descriptors. They are pre-configured with line
buffering. Their `stream-close` is guarded: it marks the value closed
but leaves the underlying fd open, so the process's stdio survives
unconditionally.

```
stdout "shipped\n" stream-write drop
```

The standard streams are not seekable. `stream-tell` and the seek
words throw `not-seekable:` against them.

## Pipes

`<pipe>` returns a pair `( -- rd wr )` of connected streams. Bytes
written to `wr` show up on `rd`. Pipes are the primary inter-task
communication primitive when a channel's value-per-message semantics do
not fit:

```
use "testing" ;

[
  <pipe>
  \ stack: reader writer
  dup [ "hello" stream-write drop ] curry spawn drop
  swap dup 5 stream-read
  "hello" >bytes "pipe transfers data" assert=
  stream-close stream-close
] task-scope
```

The [Async I/O guide](async-io.md) covers the suspend / resume behavior
that makes this work without a thread per task.

## In-Memory Streams

`<string-builder>` returns a write-only stream that accumulates bytes in
memory. `using-string-builder` runs a quotation against a fresh
builder and returns the accumulated string, closing the builder even
if the quotation throws. The quotation has effect `( stream -- )`, so
each operation must `dup` the stream to keep it on the stack:

```
use "strings" ;

[ dup "alpha " stream-write-string drop dup "beta" stream-write-string drop drop ]
using-string-builder .
```

Output:

```
"alpha beta"
```

`with-output-stream` makes the threading transparent by routing `print`
through the builder:

```
use "strings" ;

[ [ "alpha " print "beta" print ] with-output-stream ] using-string-builder .
```

`using-string-builder(bytes)` is the same shape but returns a
byte-array. See the [strings reference](../reference/strings.md) for
the surrounding family of helpers.

## Bidirectional Streams

A bidirectional stream sends `stream-read` to one file descriptor and
`stream-write` to another. The result is a single `stream` value over
two distinct fds.

The motivating use is CGI: a handler written for net/http has the
shape `( stream request -- )` and reads the request body from the
same stream it writes the response into. Under CGI, the request body
arrives on stdin and the response leaves on stdout. Bidirectional
streams let the same handler run unchanged under both transports.

The generic constructor takes two non-negative fds:

```
<duplex-stream>  \ ( read-fd write-fd -- stream )
```

Both fds must be non-negative; the constructor throws
`invalid-argument:` otherwise. Capability tag is `.io`, matching the
other stream constructors.

The stdio convenience wrapper wires `(STDIN_FILENO, STDOUT_FILENO)` and
lives in `lib/streams.1z`:

```
use "streams" ;

<stdio-stream> dup "ack: " stream-write drop
dup 11 stream-read(exact) . stream-close
```

`<stdio-stream> stream-close` does not close the process's stdio. The
underlying fd-close guard that protects `stdin` / `stdout` / `stderr`
applies to each fd of the duplex stream independently, so a duplex
stream constructed over the standard descriptors is safe to
construct, use, and discard.

The bidirectional stream is not seekable; `stream-tell`,
`stream-seek`, and `stream-seek-end` throw `not-seekable:`. Errors are
not merged across directions: a read error originates from the read fd
and a write error from the write fd, identical to how a single-fd
stream surfaces them.

`<duplex-stream>` is the generic primitive; other plausible
consumers -- a process's proxied stdio, a pipe-pair wrapper, a
fan-in / fan-out pair -- ride on the same constructor without further
native additions.

## See Also

- [Async I/O](async-io.md) -- how stream reads and writes suspend
  cooperatively inside a `task-scope`.
- [HTTP](http.md) -- the `( stream request -- )` handler shape that the
  bidirectional stream exists to preserve across transports.
- [Prelude reference](../reference/prelude.md) -- complete word list for
  `stream-*` operations.
