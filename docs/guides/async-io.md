# Async I/O

I/O in 1z is transparently asynchronous inside a `task-scope`. You write the
same `stream-read` and `stream-write` calls as you would for synchronous
code; the runtime handles the rest. When an I/O operation would block, the
current task steps aside and other tasks run. When the data lands, the task
picks up where it left off.

## Transparent Async

There is no special async syntax. The standard stream words --
`stream-read`, `stream-write`, `stream-readln`, `stream-close` -- sniff out
whether they are running inside a `task-scope`. If so, they register the
file descriptor with a platform multiplexer and yield instead of blocking.

Outside a `task-scope`, the same words block normally. Your code does not
change; the behavior adapts to the context.

## How It Works

The runtime uses kqueue on macOS and epoll on Linux to watch file
descriptors. When a task hits `stream-read` and the data is not yet
available:

1. The file descriptor is registered with the multiplexer
2. The task suspends
3. Other tasks run
4. When the multiplexer signals readiness, the task resumes and the read
   completes

This happens for sockets, pipes, and TTYs -- anything that might block.
Regular file I/O stays synchronous because disk reads are fast enough that
multiplexing adds overhead without benefit.

## Pipes

`<pipe>` creates a pair of connected streams for inter-task communication:

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

The writer task sends `"hello"` through the pipe. The reader task calls
`stream-read` for 5 bytes, which suspends until the data arrives. Both
ends must be closed with `stream-close` when done.

### Multiple Writers

Multiple tasks can write to the same pipe. The reader receives all bytes;
the order depends on scheduling:

```
use "testing" ;

[
  <pipe>
  dup [ "ab" stream-write drop ] curry spawn drop
  dup [ "cd" stream-write drop ] curry spawn drop
  swap dup 4 stream-read
  #len 4 "received 4 bytes" assert=
  stream-close stream-close
] task-scope
```

## Timeouts and Cancellation

`with-timeout` wraps an I/O operation with a deadline. If the operation
does not complete in time, it throws a `timeout:` error:

```
use "testing" ;
use "time" ;

[
  [
    <pipe> drop
    [ 1024 stream-read ] curry 50 milliseconds with-timeout
  ] task-scope
] timeout: "empty pipe times out" assert-error-type
```

Nobody writes to the pipe, so the read hangs until the 50-millisecond
timeout fires.

Cancelling a task also wakes it from I/O. If a sibling task throws an
unhandled error, all I/O-blocked siblings get cancelled automatically --
no orphaned tasks sitting forever on a dead connection.

## When to Yield Explicitly

I/O words yield automatically. You only need to call `yield` in CPU-bound
code that runs inside a `task-scope`:

```
[
  [
    \ CPU-bound loop: yield periodically so other tasks run
    0 1000 [ 1 + yield ] times drop
  ] spawn drop
  [ "other work" drop ] spawn drop
] task-scope
```

Without the `yield` inside the loop, the second task would not run until
the loop finishes. I/O-heavy code does not need manual yields -- every
`stream-read`, `stream-write`, and `sleep` yields implicitly.

The [next guide](http.md) walks through the HTTP library.
