# Error Handling

Errors in 1z are first-class values with a type tag, message, and source
location. `recover` catches them, `try` wraps them in result types, and
`cleanup` guarantees teardown.

## `recover` -- catch and inspect

`recover` takes a body quotation and a handler. If the body throws, the
handler receives the error object on the stack:

```
[ 1 0 / ] [ error-type: @get . ] recover
```

Output:

```
division-by-zero:
```

If the body succeeds, the handler is skipped entirely:

```
[ 42 ] [ drop -1 ] recover .
```

Output:

```
42
```

## `try` -- exceptions to results

`try` wraps the outcome in `result:ok` or `result:err`. Combine with
`unwrap-or` for a default value on failure:

```
[ 42 ] try 0 unwrap-or .
```

Output:

```
42
```

```
[ 1 0 / ] try 0 unwrap-or .
```

Output:

```
0
```

## `ignore-errors` -- best-effort operations

`ignore-errors` silently discards any error. Use sparingly -- silent failure
hides bugs.

```
[ drop ] ignore-errors
\ program continues
```

## `cleanup` -- guaranteed teardown

`cleanup` runs the second quotation whether the first succeeds or fails.
Both results stay on the stack:

```
[ 10 ] [ 20 ] cleanup
```

Output:

```
\ stack: 10 20
```

When the body throws, cleanup still runs, then the error propagates:

```
[
  [ [ drop ] [ 99 ] cleanup ] [ drop ] recover
] call .
```

Output:

```
99
```

## Custom errors

Build an error with `make-error` and throw it. The handler inspects fields
with `@get`:

```
[
  f "bad input" EUserThrown make-error throw
] [ message: @get . ] recover
```

Output:

```
"bad input"
```

## Nesting handlers

Inner `recover` handles the error; the outer handler never fires:

```
[
  [ 1 0 / ]
  [ drop "caught" ]
  recover
] [ drop "outer" ] recover .
```

Output:

```
"caught"
```

See also: [Control Flow tutorial](../tutorials/control-flow.md)
