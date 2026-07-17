# Concurrency

1z runs concurrent tasks as green threads on a single OS thread. There is no
preemption -- tasks yield coöperatively, either explicitly or at I/O
boundaries. Structured concurrency via `task-scope` guarantees that every
spawned task finishes before its scope exits.

## The Model

A task is a lightweight execution context with its own stack and memory
arena. Multiple tasks share a single OS thread and take turns running.
Because there is only one thread, there are no data races -- but a task
that never yields starves every other task.

Tasks yield in three situations:

- Explicitly, by calling `yield`
- Implicitly, when performing I/O (reads, writes, network operations)
- When calling `sleep`

## `task-scope` and `spawn`

`task-scope` creates a scope for concurrent work. `spawn` fires off a
quotation as a new task inside that scope:

```
use "testing" ;

[
  [ 42 ] spawn
  await 42 "task returns 42" assert=
] task-scope
```

The scope blocks until all tasks inside it have completed. You cannot spawn
a task outside of a `task-scope`.

Multiple tasks run concurrently within a single scope:

```
use "testing" ;

[
  { }
  [ 10 ] spawn #push
  [ 20 ] spawn #push
  [ 30 ] spawn #push
  await-all
  { 10 20 30 } "three tasks" assert=
] task-scope
```

`await-all` takes an array of tasks and returns an array of results in
the same order. Build the array with `#push` as you spawn.

## Getting Results with `await`

`await` blocks the calling task until the target task finishes, then
hands back its result:

```
use "testing" ;

[
  [ "hello world" ] spawn
  await "hello world" "string result" assert=
] task-scope
```

Results are deep-copied from the child task's memory arena to the caller's.
This means you always get an independent value -- mutations on one side do
not affect the other. As an optimization, a provably immutable container is
shared by reference count instead of copied; that sharing is unobservable,
because such a value cannot be mutated by either side.

A few reference types live on the task's arena and cannot cross a task
boundary at all: iterators, parameters, benchmark reports, resources, and
streams. Returning one from a task, or sending one through a channel, throws
`task-arena-escape:`. The error message names a per-type workaround: for
example, materialize an iterator with `#collect` and send the array, or send
a file descriptor and rebuild the stream with `fd>stream` in the receiving
task. This applies even when the value is nested inside a container or
captured in a quotation. One known limitation: values created by parse-time
words (markers, struct types, sandbox specs, constraint combinators) are not
checked, because they normally belong to the main context, which lives for
the whole process. `eval-string` inside a task can produce arena-owned ones
that escape undetected.

If a task pushes nothing, `await` returns `f`:

```
use "testing" ;

[
  [ ] spawn
  await f "empty task returns f" assert=
] task-scope
```

## Coöperative Scheduling

`yield` hands control to other tasks:

```
use "testing" ;

[
  { }
  [ yield 1 ] spawn #push
  [ yield 2 ] spawn #push
  await-all
  { 1 2 } "both tasks ran" assert=
] task-scope
```

`sleep` suspends the current task for a duration. Other tasks continue
running while it sleeps:

```
[
  [ 10 milliseconds sleep "done" . ] spawn drop
] task-scope
```

Output:

```
"done"
```

If you have a CPU-bound loop inside `task-scope`, insert `yield` calls to
let other tasks make progress.

## Error Propagation and Cancellation

When a task throws an unhandled error, the error bubbles out of
`task-scope` and all sibling tasks get cancelled:

```
use "testing" ;

[
  [
    [ f "boom" test-error: make-error throw ] spawn
    yield
    await
  ] task-scope
] test-error: "error propagates from task" assert-error-type
```

Use `recover` inside a task to catch errors and prevent them from cancelling
siblings:

```
use "testing" ;

[
  [ [ 1 0 / ] [ drop 0 ] recover ] spawn
  await 0 "recovered from division by zero" assert=
] task-scope
```

The task catches the division-by-zero error and returns 0 instead. No
sibling tasks are affected.

## Channels

Channels are how tasks talk to each other. An unbuffered channel blocks the
sender until a receiver is ready, and vice versa:

```
use "testing" ;

[
  <channel>
  dup [ 42 swap send ] curry spawn drop
  receive
  42 "received via channel" assert=
] task-scope
```

`<channel>` creates an unbuffered channel. `send` shoves a value into the
channel; `receive` pulls one out. The sender blocks until a receiver calls
`receive`, creating a rendezvous.

### Buffered Channels

`<buffered-channel>` creates a channel with a fixed-size buffer. The sender
only blocks when the buffer is full:

```
use "testing" ;

[
  3 <buffered-channel>
  dup 1 swap send
  dup 2 swap send
  dup 3 swap send
  dup receive 1 "first buffered" assert=
  dup receive 2 "second buffered" assert=
  receive 3 "third buffered" assert=
] task-scope
```

Three sends succeed without blocking because the buffer holds three values.

### `select`

`select` watches multiple channels at once and grabs the first available
value along with the channel it came from:

```
use "testing" ;

[
  <channel>
  dup [ 42 swap send ] curry spawn drop
  yield
  { } swap #push
  select
  drop 42 "select picks ready channel" assert=
] task-scope
```

`select` takes an array of channels and returns `( channel value )`. It
blocks until at least one channel has data.

### Closing Channels

`close-channel` signals that no more values will be sent. A receive on a
closed channel throws:

```
use "testing" ;

[
  [
    <channel>
    dup close-channel
    receive
  ] task-scope
] channel-closed: "closed channel throws" assert-error-type
```

The error propagates out of `task-scope`. You can also use `receive?`,
which returns `option:none` on a closed channel instead of throwing.

## Patterns

### Fan-Out / Fan-In

Spawn N workers, collect their results:

```
use "testing" ;

[
  { }
  [ 1 ] spawn #push
  [ 2 ] spawn #push
  [ 3 ] spawn #push
  await-all
  0 [ + ] #reduce
  6 "sum of three tasks" assert=
] task-scope
```

### Producer / Consumer

One task produces values through a channel; another consumes them:

```
use "testing" ;

[
  <channel>
  dup [
    dup 10 swap send
    dup 20 swap send
    30 swap send
  ] curry spawn drop
  dup receive swap
  dup receive swap
  receive
  + + 60 "producer/consumer sum" assert=
] task-scope
```

See also: [Concurrency Patterns cookbook](../cookbook/concurrency-patterns.md)

The [next guide](async-io.md) covers how I/O operations integrate with the
task scheduler.
