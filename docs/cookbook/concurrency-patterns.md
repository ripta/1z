# Concurrency Patterns

1z uses cooperative green threads on a single OS thread. `task-scope`
provides structured concurrency -- all spawned tasks must complete before
the scope exits. Channels connect tasks.

## Fan-out with `task-scope`

`task-scope` runs a quotation that can `spawn` tasks. The scope blocks
until every spawned task finishes:

```
[
  [ "hello" print-line ] spawn drop
  [ "world" print-line ] spawn drop
] task-scope
```

Output (order may vary):

```
hello
world
```

## Producer-consumer with channels

An unbuffered channel blocks the sender until a receiver is ready, and
vice versa. This makes channels a natural synchronization point:

```
use "channel" ;

[
  <channel>
  dup [
    dup 10 swap send
    dup 20 swap send
    30 swap send
  ] curry spawn drop

  dup receive .
  dup receive .
  receive .
] task-scope
```

Output:

```
10
20
30
```

## Buffered channels

A buffered channel holds up to N values before `send` blocks. Sends into
a non-full buffer return immediately:

```
use "channel" ;

[
  3 <buffered-channel>
  dup 1 swap send
  dup 2 swap send
  dup 3 swap send

  dup receive .
  dup receive .
  receive .
] task-scope
```

Output:

```
1
2
3
```

## `select` for multiplexed receives

`select` takes an array of channels and receives from the first one that
has data ready:

```
use "channel" ;

[
  <channel>
  dup [ 42 swap send ] curry spawn drop
  yield
  { } swap #push
  select
  drop .
] task-scope
```

Output:

```
42
```

## Timeouts

`with-timeout` cancels a computation if it exceeds a duration:

```
use "time" ;

[
  [ 42 ] 5000 milliseconds with-timeout .
] task-scope
```

Output:

```
42
```

A slow computation triggers a `timeout:` error:

```
use "time" ;

[
  [
    [ 10000 milliseconds sleep 99 ] 10 milliseconds with-timeout
  ] try result:err? .
] task-scope
```

Output:

```
t
```

See also: [Concurrency guide](../guides/concurrency.md)
