# Control Flow

1z has no special syntax for control flow. Conditionals, loops, and error
handling are all ordinary words that take quotations. You already know the
building blocks.

## Everything Is Just Words

In most languages, `if` is a keyword with special parsing rules. In 1z,
`if` is a word like any other -- it pops a boolean and two quotations from
the stack and fires one of them. Same for `while`, `times`, `recover`, and
every other control flow word. If you understand quotations, you already
understand control flow.

## Conditionals

### `if` -- Two Branches

`if` pops a boolean and two quotations. True fires the first; false fires
the second.

```
5 3 > [ "bigger" ] [ "smaller" ] if print-line
2 3 > [ "bigger" ] [ "smaller" ] if print-line
```

Output:

```
bigger
smaller
```

### `when` -- Do Something If True

`when` pops a boolean and one quotation. True fires it; false does nothing.

```
t [ "this runs" print-line ] when
f [ "this does not" print-line ] when
```

Output:

```
this runs
```

### `unless` -- Do Something If False

`unless` is the mirror of `when` -- fires only when false.

```
f [ "this runs" print-line ] unless
t [ "this does not" print-line ] unless
```

Output:

```
this runs
```

### Truthiness

Only `f` is falsy. Everything else is truthy -- `0`, empty string `""`,
empty array `{ }`, all of it.

```
0 [ "zero is truthy" print-line ] when
"" [ "empty string is truthy" print-line ] when
{ } [ "empty array is truthy" print-line ] when
```

Output:

```
zero is truthy
empty string is truthy
empty array is truthy
```

## Multi-Way Dispatch

### `cond` -- Condition-Based Branching

`cond` takes an array of `{ predicate body }` pairs. It walks the list,
fires the body of the first predicate that returns true.

Each predicate should `dup` to preserve the value for its body. The body
receives the value on the stack and must consume it (typically with `drop`
if not needed).

A trailing bare quotation acts as the default branch. The default does not
receive the value.

```
classify: ( n -- str ) [
  {
    { [ dup 0 < ] [ drop "negative" ] }
    { [ dup 0 = ] [ drop "zero" ] }
    { [ t ]       [ drop "positive" ] }
  } cond
] ;

-3 classify print-line
0 classify print-line
7 classify print-line
```

Output:

```
negative
zero
positive
```

### `case` -- Value-Based Branching

`case` matches a value against `{ key quotation }` pairs, firing the first
match. A trailing bare quotation is the default.

```
describe: ( sym -- str ) [
  {
    { red:    [ "stop" ] }
    { yellow: [ "caution" ] }
    { green:  [ "go" ] }
    [ drop "unknown" ]
  } case
] ;

red: describe print-line
green: describe print-line
blue: describe print-line
```

Output:

```
stop
go
unknown
```

## Counted Loops

### `times` -- Repeat N Times

`times` fires a quotation a fixed number of times:

```
3 [ "hello" print-line ] times
```

Output:

```
hello
hello
hello
```

Use the stack to accumulate a result across iterations:

```
0 5 [ 1 + ] times .
```

Output:

```
5
```

This starts with 0 on the stack and adds 1 five times.

## Conditional Loops

### `while` -- Loop While True

`while` takes a predicate and a body. Tests the predicate; if true, fires
the body and loops back.

```
1 [ dup 10 < ] [ dup . 2 * ] while drop
```

Output:

```
1
2
4
8
```

Trace: start with 1. Is `1 < 10`? Yes -- print 1, double to 2. Is
`2 < 10`? Yes -- print 2, double to 4. Continue until 16 is not less than
10. `drop` discards the final 16.

### `until` -- Loop Until True

`until` is the inverse of `while`. It loops until the predicate returns true.

```
1 [ dup 100 > ] [ dup . 2 * ] until drop
```

Output:

```
1
2
4
8
16
32
64
```

### Collatz Sequence

Here is a practical example combining `while` with conditionals. The Collatz
sequence: if even, divide by 2; if odd, multiply by 3 and add 1. Repeat until
reaching 1.

```
collatz-step: ( n -- n ) [
  dup 2 % 0 = [ 2 / ] [ 3 * 1 + ] if
] ;

6 [ dup 1 /= ] [ dup . collatz-step ] while .
```

Output:

```
6
3
10
5
16
8
4
2
1
```

## Collection Iteration

### `#each` -- Execute for Every Element

`#each` fires a quotation once per element:

```
{ 10 20 30 } [ . ] #each
```

Output:

```
10
20
30
```

### `#map` and `#filter` -- Transform and Select

`#map` transforms each element. `#filter` keeps elements that pass a test.
Both return lazy iterators -- `#collect` materializes the result.

```
{ 1 2 3 4 5 } [ 2 * ] #map #collect .
{ 1 2 3 4 5 } [ 3 > ] #filter #collect .
```

Output:

```
{ 2 4 6 8 10 }
{ 4 5 }
```

### `#reduce` -- Fold to a Single Value

`#reduce` folds all elements into one value using an accumulator:

```
{ 1 2 3 4 5 } 0 [ + ] #reduce .
```

Output:

```
15
```

Read this as: start with 0, add each element. `0 + 1 + 2 + 3 + 4 + 5 = 15`.

### Chaining

Chain operations by connecting lazy iterators before collecting:

```
{ 1 2 3 4 5 6 7 8 9 10 }
  [ 2 % 0 = ] #filter
  [ dup * ] #map
  #collect .
```

Output:

```
{ 4 16 36 64 100 }
```

Filter to even numbers, then square each one.

### `#any` and `#all`

`#any` checks if at least one element satisfies a predicate. `#all` checks
if every element does. Both short-circuit.

```
{ 1 2 3 } [ 2 > ] #any .
{ 1 2 3 } [ 0 > ] #all .
{ 1 2 3 } [ 5 > ] #any .
```

Output:

```
t
t
f
```

## Error Handling

### `recover` -- Catch and Handle

`recover` takes a body and a handler. If the body throws, the handler fires
with the error object on the stack.

```
[ 1 0 / ] [ drop "caught division error" print-line ] recover
```

Output:

```
caught division error
```

The error is an object. Poke at it with `@get` and symbol keys:

```
[ 1 0 / ] [ error-type: @get . ] recover
```

Output:

```
division-by-zero:
```

### `try` -- Wrap the Result

`try` runs a quotation and wraps the outcome: success yields `result:ok`,
failure yields `result:err`.

```
[ 42 ] try .
[ 1 0 / ] try .
```

Output:

```
<result:ok result-value{ value: 42 }>
<result:err result-error{ error: <error division-by-zero: ...> }>
```

### `throw` -- Raise an Error

Create and throw your own errors with `make-error` and `throw`:

```
[ f "something went wrong" EUserThrown make-error throw ]
[ error-type: @get . ] recover
```

Output:

```
user-thrown:
```

### `cleanup` -- Always Run Cleanup

`cleanup` takes a body and a cleanup quotation. The cleanup fires no matter
what -- success or failure. If the body threw, `cleanup` re-throws after
the cleanup runs.

```
[ 42 . ] [ "cleaned up" print-line ] cleanup
```

Output:

```
42
cleaned up
```

This is the 1z equivalent of `try/finally` in other languages.

## Putting It Together

Here is FizzBuzz using several control flow forms. For each number from 1 to
20: print "FizzBuzz" if divisible by both 3 and 5, "Fizz" if divisible by 3,
"Buzz" if divisible by 5, or the number itself.

```
fizzbuzz: ( n -- str ) [
  {
    { [ dup 15 % 0 = ] [ drop "FizzBuzz" ] }
    { [ dup 3 % 0 = ]  [ drop "Fizz" ] }
    { [ dup 5 % 0 = ]  [ drop "Buzz" ] }
    { [ t ]             [ inspect ] }
  } cond
] ;

fizzbuzz-up-to: ( n -- ) [
  1 swap [ 2dup <= ] [ swap dup fizzbuzz print-line 1 + swap ] while 2drop
] ;

20 fizzbuzz-up-to
```

Output:

```
1
2
Fizz
4
Buzz
Fizz
7
8
Fizz
Buzz
11
Fizz
13
14
FizzBuzz
16
17
Fizz
19
Buzz
```

Word definitions, `cond` for multi-way dispatch, a `while` loop with a
counter, stack manipulation -- each piece small and testable on its own.
