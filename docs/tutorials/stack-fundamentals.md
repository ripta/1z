# Stack Fundamentals

Every value in 1z lives on the stack. Get the stack and you get the language.
This tutorial builds that understanding from the ground up.

## The Stack as Your Workspace

In most languages you write `3 + 4`. In 1z you write `3 4 +`. The numbers
land on the stack, and `+` pops two and pushes their sum.

Walk through `3 4 + 5 *` one token at a time:

| Token | Stack after |
|-------|-------------|
| `3`   | `3`         |
| `4`   | `3 4`       |
| `+`   | `7`         |
| `5`   | `7 5`       |
| `*`   | `35`        |

```
3 4 + 5 * .
```

Output:

```
35
```

The stack grows to the right. The rightmost value is the "top" -- the one
that words operate on first. `.` pops the top value and prints it.

No operator precedence to remember. Execution proceeds left to right, one
word at a time. `3 4 + 5 *` means "add 3 and 4, then multiply by 5" --
unambiguously.

## Core Shuffle Words

Shuffle words rearrange values on the stack without consuming them for
computation. Three groups.

### Duplicating

`dup` copies the top value:

```
5 dup . .
```

Output:

```
5
5
```

`2dup` copies the top two values as a pair:

```
3 4 2dup . . . .
```

Output:

```
4
3
4
3
```

`over` copies the second value to the top:

```
1 2 over . . .
```

Output:

```
1
2
1
```

`tuck` copies the top value below the second:

```
1 2 tuck . . .
```

Output:

```
2
1
2
```

`pick` copies the third value to the top:

```
1 2 3 pick . . . .
```

Output:

```
1
3
2
1
```

### Removing

`drop` discards the top value:

```
1 2 3 drop . .
```

Output:

```
2
1
```

`2drop` discards the top two:

```
1 2 3 2drop .
```

Output:

```
1
```

`3drop` discards the top three:

```
1 2 3 4 3drop .
```

Output:

```
1
```

`nip` drops the second value, keeping the top:

```
1 2 nip .
```

Output:

```
2
```

### Reordering

`swap` flips the top two values:

```
1 2 swap . .
```

Output:

```
1
2
```

`<rot-` rotates the top three values left. `a b c` becomes `b c a`:

```
1 2 3 <rot- . . .
```

Output:

```
1
3
2
```

`-rot>` rotates the top three values right. `a b c` becomes `c a b`:

```
1 2 3 -rot> . . .
```

Output:

```
2
1
3
```

## Reading Stack Effects

Stack effects document what a word pops and pushes. They appear in
parentheses between the name and body of a word definition:

```
square: ( n -- n ) [ dup * ] ;
```

Read `( n -- n )` as: "pops one value, pushes one value." The `--`
separates inputs (left) from outputs (right). The names `n`, `a`, `b` are
mnemonics -- they help you follow the data flow but the language does not
enforce them.

Some more examples:

| Effect | Meaning |
|--------|---------|
| `( a -- )` | pops one value, pushes nothing |
| `( -- a )` | pushes one value from nothing |
| `( a b -- sum )` | pops two, pushes one |
| `( a b -- a b a )` | pops two, pushes three (like `over`) |

Look up any word's stack effect with `help`. Load the introspection library
first:

```
use "runtime/introspect" ;
dup: help
```

Output:

```
Duplicate top of stack.
dup ( a -- a a ) \native
```

## Thinking in Data Flow

Translating intent to stack operations is a skill that develops with practice.
Here is the thought process for `abs` (absolute value):

The goal: given a number, return it unchanged if non-negative, or negate it
if negative.

Step 1 -- check the sign. We need the number for both the test and the result,
so duplicate it first:

```
\ stack: n
dup 0 <
\ stack: n flag
```

Step 2 -- if negative, negate with `-@`. Otherwise, do nothing:

```
[ -@ ] when
\ stack: |n|
```

Putting it together:

```
my-abs: ( n -- n ) [ dup 0 < [ -@ ] when ] ;
-5 my-abs .
5 my-abs .
```

Output:

```
5
5
```

The built-in `abs` does exactly this. The point is the process: duplicate
what you need to preserve, test, act conditionally.

## When Shuffling Gets Awkward

Shuffle words handle two or three values fine. Beyond that, they get painful.
Consider adding two pairs of numbers: `(a + b) + (c + d)`. With only shuffle
words:

```
\ stack: a b c d
-rot> +
\ stack: a (c+d) b
-rot> +
\ stack: (c+d) (a+b)
+ .
```

This works, but good luck tracing the intermediate stack states. Combinators
like `dip`, `keep`, and `bi` exist for exactly this: "run this, but stash a
value first" or "apply two operations to the same value."

The [next tutorial](quotations.md) covers quotations and combinators in
depth.
