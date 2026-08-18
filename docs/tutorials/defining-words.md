# Defining Words

Words are the building blocks of 1z programs. Every operation -- from `+` to
`print-line` -- is a word. This tutorial covers how to define your own.

## Anatomy of a Word Definition

A word definition has four parts:

```
square: ( n -- n ) [ dup * ] ;
```

| Part | Purpose |
|------|---------|
| `square:` | The name (a symbol with trailing `:`) |
| `( n -- n )` | Stack effect declaration (optional) |
| `[ dup * ]` | The body (a quotation) |
| `;` | Finalizes the definition |

After this definition, writing `square` anywhere in your program executes
`dup *`.

```
square: ( n -- n ) [ dup * ] ;
5 square .
9 square .
```

Output:

```
25
81
```

The name must be a symbol -- a word with a trailing colon. The colon is part
of the definition syntax; when you later call the word, you write `square`
without the colon.

## Stack Effects as Contracts

Stack effects are optional, but they pull triple duty:

**Documentation.** `( n -- n )` tells anyone reading the code that `square`
takes one value and produces one value.

**Static checking.** When you run `./zig-out/bin/1z --check file.1z`, the
checker verifies that your code is consistent with declared effects.

**Help output.** Stack effects appear when you look up a word:

```
use "runtime/introspect" ;

square: ( n -- n ) [ dup * ] ;
square: help
```

Output:

```
square ( n -- n )
```

Write stack effects for anything used outside its immediate context. Skip
them for small local helpers where the intent is obvious.

## Doc-Comments

Doc-comments start with `\\` (double backslash) and attach to the next word
definition. They appear in `help` output.

```
use "runtime/introspect" ;

\\ Compute the square of a number.
square: ( n -- n ) [ dup * ] ;
square: help
```

Output:

```
Compute the square of a number.
square ( n -- n )
```

Explain *what* the word does, not *how*. The stack effect and body already
show the how.

## Constants and Markers

The `const` marker defines a word that always pushes the same value:

```
PI: const [ 3.14159 ] ;
PI 2 * .
```

Output:

```
6.28318
```

A `const` word ignores the stack entirely -- it just pushes its value.

The `override` marker claims permission to replace an existing word. A
top-level definition that would overwrite an import, or shadow a prelude
or native word like `dup`, throws `import-conflict` unless it carries the
marker:

```
dup: override ( a -- x ) [ drop 0 ] ;
```

Redefining your own word needs no marker. The [Redefinition and Shadowing
guide](../guides/redefinition-and-shadowing.md) covers the full model.

## Naming Conventions

1z uses prefixes and suffixes to signal what a word does at a glance:

| Pattern | Meaning | Example |
|---------|---------|---------|
| `name?` | Predicate (returns boolean) | `empty?`, `fixnum?` |
| `name!` | Mutating or dangerous | `@set!`, `#push!` |
| `>name` | Conversion to a type | `>float`, `>string` |
| `#name` | Sequence operation | `#len`, `#map`, `#nth` |
| `@name` | Associative operation | `@get`, `@set`, `@keys` |
| `?name` | Option/result combinator | `?map`, `?and-then` |
| `<name>` | Smart constructor (validates) | `<range>`, `<channel>` |
| `make-name` | Raw positional constructor | `make-person` |
| `field>>` | Struct getter | `name>>`, `age>>` |
| `>>field` | Struct setter | `>>name`, `>>age` |

These are conventions, not enforced rules. Follow them and your code reads
naturally to anyone who knows 1z.

## Composing Words

Small words compose into complex behavior. Start simple and build up.

Define `square`:

```
square: ( n -- n ) [ dup * ] ;
```

Use `square` in `sum-of-squares`:

```
sum-of-squares: ( a b -- n ) [ [ square ] dip square + ] ;
```

Use `sum-of-squares` in `hypotenuse` (which needs `sqrt` from the math
library):

```
use "math" ;
hypotenuse: ( a b -- c ) [ sum-of-squares >float sqrt ] ;
```

Each word is short, testable, and reusable:

```
use "math" ;

square: ( n -- n ) [ dup * ] ;
sum-of-squares: ( a b -- n ) [ [ square ] dip square + ] ;
hypotenuse: ( a b -- c ) [ sum-of-squares >float sqrt ] ;

5 square .
3 4 sum-of-squares .
3 4 hypotenuse .
```

Output:

```
25
25
5.0
```

`hypotenuse` reads almost like its mathematical definition. That is the
goal -- high-level code that expresses intent directly.

Notice how `sum-of-squares` uses `dip` to apply `square` to the value
underneath the top. The stack starts as `a b`. `[ square ] dip` temporarily
removes `b`, squares `a`, then restores `b`. Now the stack is `a*a b`.
`square` squares `b`, and `+` adds them.

## When to Define a Word

Define a word when:

- You use the same sequence of operations more than once
- A chunk of code has a clear name that would make the calling code more
  readable
- You want to document a stack effect for clarity or static checking

Keep a quotation inline when:

- It is used exactly once and its purpose is obvious from context
- It is short (two or three words) and the surrounding code reads clearly
  without a name

```
\ Inline quotation -- clear enough in context:
{ 1 2 3 4 5 } [ 2 * ] #map #collect .

\ Named word -- reused and non-obvious:
celsius>fahrenheit: ( c -- f ) [ 9 * 5 / 32 + ] ;
0 celsius>fahrenheit .
100 celsius>fahrenheit .
```

Output:

```
{ 2 4 6 8 10 }
32
212
```

The [next tutorial](control-flow.md) covers conditionals, loops, and error
handling -- all of which build on quotations and word definitions.
