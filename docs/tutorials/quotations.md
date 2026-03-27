# Quotations

Quotations are blocks of code wrapped in `[ ]`. They are values -- they sit
on the stack like numbers or strings until you do something with them. This
is the foundation of everything in 1z: control flow, word definitions, and
higher-order programming all work through quotations.

## Code as Data

A quotation pushes itself onto the stack without executing:

```
[ 2 3 + ]
```

Nothing happens. The quotation is just a value on the stack, waiting. You
can stack multiple quotations:

```
[ 2 3 + ] [ 10 * ] . .
```

Output:

```
[ 10 * ]
[ 2 3 + ]
```

If you have used languages with lambdas or anonymous functions, quotations
fill the same role -- but they are simpler. A quotation is just a sequence
of words. It captures no variables and creates no scope. It operates on
whatever is on the stack when it runs.

## `call` and Execution

`call` pops a quotation from the stack and executes it:

```
5 [ 2 * ] call .
```

Output:

```
10
```

Without `call`, the quotation just sits on the stack. With `call`, it runs
as though its contents were typed directly. Compare:

```
\ these two lines do the same thing:
5 2 *
5 [ 2 * ] call
```

The power of quotations is that you can decide *when* and *whether* to
execute them. This is how 1z does control flow -- `if`, `when`, `times`,
and every other control word takes quotations as arguments.

## Nesting Quotations

Quotations can contain other quotations:

```
[ [ 1 2 + ] call 10 * ] call .
```

Output:

```
30
```

The outer quotation is called. Inside it, `[ 1 2 + ]` pushes an inner
quotation, `call` executes it (producing 3), then `10 *` multiplies.

Nesting matters because many words take quotations that themselves contain
quotations. For instance, a conditional inside a loop:

```
5 5 [ dup 0 > [ dup . ] when 1 - ] times drop
```

Output:

```
5
4
3
2
1
```

The first `5` is the starting counter value left on the stack. The second
`5` tells `times` how many iterations to run. Inside the body, `[ dup . ]`
is nested inside the `[ ... ] times` quotation. Each level of `[ ]` delays
execution by one step.

## Combinators: The Power Tools

Combinators take quotations and fire them in specific patterns -- replacing
stack shuffling with clear intent.

### `dip` -- Reach Under the Top

`dip` stashes the top value, runs a quotation, then puts the value back.

```
1 2 [ 10 * ] dip . .
```

Trace through the stack:

| Step | Stack |
|------|-------|
| `1 2` | `1 2` |
| `[ 10 * ] dip` | removes `2`, runs `[ 10 * ]` on `1` |
| after `dip` | `10 2` |
| `. .` | prints `2`, then `10` |

Output:

```
2
10
```

`dip` is essential when you need to operate on a value that is not on top.
Instead of shuffling with `swap` and `rot`, you say "stash this, do the
work, put it back."

### `keep` -- Use and Preserve

`keep` fires a quotation with the top value, then restores that value.

```
5 [ 2 * ] keep . .
```

Trace:

| Step | Stack |
|------|-------|
| `5` | `5` |
| `[ 2 * ] keep` | calls `[ 2 * ]` on `5`, then restores `5` |
| after `keep` | `10 5` |
| `. .` | prints `5`, then `10` |

Output:

```
5
10
```

Reach for `keep` when you need both the result and the original value.

### `bi` -- Two Operations, One Value

`bi` applies two quotations to the same value:

```
5 [ 2 * ] [ 1 + ] bi . .
```

Trace:

| Step | Stack |
|------|-------|
| `5` | `5` |
| `[ 2 * ] [ 1 + ] bi` | applies `[ 2 * ]` to `5`, then `[ 1 + ]` to `5` |
| after `bi` | `10 6` |
| `. .` | prints `6`, then `10` |

Output:

```
6
10
```

`bi` avoids the `dup`-and-shuffle dance. It says "compute two things from
one input" directly.

### `tri` -- Three Operations, One Value

`tri` extends the pattern to three quotations:

```
10 [ 2 * ] [ 1 + ] [ 1 - ] tri . . .
```

Output:

```
9
11
20
```

## `curry` and `compose`

### Partial Application with `curry`

`curry` bakes a value into a quotation:

```
5 [ + ] curry
```

This creates `[ 5 + ]` -- a quotation that adds 5 to whatever is on the
stack. The original value is captured inside the new quotation.

```
5 [ + ] curry 3 swap call .
```

Output:

```
8
```

A practical use: building a reusable filter predicate.

```
gt-filter: ( n -- quot ) [ [ > ] curry ] ;

{ 1 5 3 8 2 7 } 4 gt-filter #filter #collect .
```

Output:

```
{ 5 8 7 }
```

### Composition with `compose`

`compose` concatenates two quotations into one:

```
[ 2 * ] [ 1 + ] compose 5 swap call .
```

Output:

```
11
```

`[ 2 * ] [ 1 + ] compose` creates a quotation equivalent to `[ 2 * 1 + ]`.
First doubles, then adds one.

Combine `curry` and `compose` to build operations incrementally:

```
3 [ * ] curry [ 1 + ] compose 4 swap call .
```

Output:

```
13
```

This creates `[ 3 * 1 + ]` and applies it to 4, giving `4 * 3 + 1 = 13`.

## Building Your Own Abstractions

Quotations let you define your own control patterns. Here is a word that
applies a quotation to each element of a pair:

```
apply-pair: ( a b quot -- a' b' ) [ [ call ] keep swap [ call ] dip swap ] ;

3 4 [ 2 * ] apply-pair . .
```

Output:

```
8
6
```

`apply-pair` uses `keep` to preserve the quotation after the first call and
`dip` to reach the second value. No special syntax -- quotations and
combinators compose naturally.

The [next tutorial](defining-words.md) covers how to package quotations into
named words with stack effects and documentation.
