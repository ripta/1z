# Your First Program

Create a file called `hello.1z` and follow along. Run it after each section with:

```
./zig-out/bin/1z hello.1z
```

## Hello World

```
"Hello, world!" print-line
```

Output:

```
Hello, world!
```

## Stack Basics

Everything in 1z lives on the stack. Numbers push themselves; words pop
values and push results.

```
3 4 + .
10 3 - .
6 7 * .
```

Output:

```
7
7
42
```

`dup` duplicates the top value. `drop` discards it. `swap` flips the top two.

```
5 dup + .
1 2 3 drop + .
1 2 swap - .
```

Output:

```
10
3
1
```

## Defining Words

A word definition starts with a symbol (name followed by `:`), a quotation
body in `[ ]`, and `;` to finalize it.

```
square: [ dup * ] ;
5 square .
9 square .
```

Output:

```
25
81
```

Stack effects document what a word pops and pushes. They go between the name
and the body:

```
cube: ( n -- n ) [ dup dup * * ] ;
3 cube .
```

Output:

```
27
```

## Booleans and Comparisons

`t` is true, `f` is false. Comparison operators return booleans.

```
5 3 > .
5 10 > .
5 5 = .
3 7 < .
```

Output:

```
t
f
t
t
```

In 1z, only `f` is falsy. Everything else -- including `0`, `""`, and `{ }` --
is truthy.

## Quotations and Control Flow

Quotations are blocks of code in `[ ]`. They sit on the stack like any other
value until something executes them.

`call` executes a quotation:

```
[ 1 2 + ] call .
```

Output:

```
3
```

`if` takes a boolean and two quotations -- true branch and false branch:

```
5 3 > [ "yes" ] [ "no" ] if print-line
```

Output:

```
yes
```

`when` runs a quotation only if the condition is true. `unless` runs it only
if the condition is false.

```
t [ "this runs" print-line ] when
f [ "this runs too" print-line ] unless
```

Output:

```
this runs
this runs too
```

## Loops

`times` runs a quotation N times:

```
5 [ "hello" print-line ] times
```

Output:

```
hello
hello
hello
hello
hello
```

`#each` iterates over a sequence:

```
{ 10 20 30 } [ . ] #each
```

Output:

```
10
20
30
```

## Strings

String literals use double quotes. `#len` gives the length. `#append`
concatenates.

```
"hello" #len .
"hello" " world" #append print-line
```

Output:

```
5
hello world
```

## Arrays

Arrays use `{ }`. They are immutable and can hold any mix of types.

```
{ 1 2 3 } .
```

Output:

```
{ 1 2 3 }
```

`#nth` gets an element by zero-based index. `#len` returns the length.

```
{ 10 20 30 } 0 #nth .
{ 10 20 30 } #len .
```

Output:

```
10
3
```

`#map` and `#filter` return lazy iterators. `#collect` materializes the
result into an array.

```
{ 1 2 3 4 5 } [ 2 * ] #map #collect .
{ 1 2 3 4 5 } [ 3 > ] #filter #collect .
```

Output:

```
{ 2 4 6 8 10 }
{ 4 5 }
```

## Hashes

Hashes use `H{ }` with symbol keys.

```
H{ name: "Alice" age: 30 } .
```

Output:

```
H{ name: "Alice" age: 30 }
```

`@get` plucks a value by key. `@set` returns a new hash with the key added
or updated. `@keys` gives the keys as an array.

```
H{ name: "Alice" age: 30 } name: @get print-line
H{ name: "Alice" } age: 30 @set .
H{ x: 1 y: 2 } @keys .
```

Output:

```
Alice
H{ name: "Alice" age: 30 }
{ x: y: }
```

## Comments

Line comments start with `\` (backslash followed by a space):

```
\ This is a comment.
42 .  \ This prints 42.
```

Doc comments start with `\\` and attach to the next word definition. They
appear in `help` output.

```
\\ Double a number by adding it to itself.
double: ( n -- n ) [ dup + ] ;
```

## Next Steps

That covers the fundamentals. The [language tutorials](../tutorials/index.md)
go deeper on each topic:

- [Stack Fundamentals](../tutorials/stack-fundamentals.md) -- understanding the
  stack in depth
- [Quotations](../tutorials/quotations.md) -- code as data, combinators
- [Defining Words](../tutorials/defining-words.md) -- anatomy, conventions,
  composition
- [Control Flow](../tutorials/control-flow.md) -- conditionals, loops,
  iteration, error handling

For a complete listing of every available word, see the
[API Reference](../reference/index.md).
