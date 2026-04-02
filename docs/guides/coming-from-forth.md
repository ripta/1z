# Coming from Forth or Factor

If you know Forth, Factor, or another concatenative language, most of 1z will
feel familiar -- values live on the stack, words consume and produce them,
composition is implicit. This guide highlights the places where 1z diverges:
the syntax, semantics, and idioms that trip up experienced stack-language
programmers.

Each section shows the Forth or Factor way alongside the 1z equivalent.
Where 1z adds something with no Forth counterpart, the section says so.

---

## Definitions and Syntax

### Word Definition

In Forth, `: name ... ;` compiles a definition. In Factor, `: name ( effect ) ... ;`.

In 1z, the name is a symbol literal (trailing `:`), the body is always a
quotation in `[ ]`, and `;` is a regular word that pops both and registers
the definition. No special parser state, no compile mode -- just stack
operations.

In Forth:

```
: double 2 * ;
```

In Factor:

```
: double ( n -- n ) 2 * ;
```

In 1z:

```
double: [ 2 * ] ;
double: ( n -- n ) [ 2 * ] ;   \ with stack effect
```

The colon is part of the symbol, not a separate keyword. This keeps the
semicolon as an ordinary word rather than a mode-switching compiler directive.

### Comments

Forth uses `( ... )` for comments and `\` for line comments. In 1z,
`( ... )` is stack effect notation -- the parser reads it, it is not a
comment. `\` is the only comment syntax.

In Forth:

```
( this is a comment )
```

In 1z:

```
\ this is a comment
\\ This is a doc comment for the next word.
```

### Stack Effects

Stack effects look like Factor's `( inputs -- outputs )`, but they sit
between the symbol name and the quotation body -- not after a colon keyword.

In Factor:

```
: foo ( a b -- sum ) a b + ;
```

In 1z:

```
foo: ( a b -- sum ) [ + ] ;
```

Stack effects are optional. Omitting them is valid:

```
foo: [ + ] ;
```

### Quotations

Forth compiles word bodies inline; the `: ... ;` syntax is a compiler
directive. In 1z, word bodies are always quotations -- first-class values
delimited by `[ ]`. There is no compile mode; everything is interpretation
of stack values.

In Forth:

```
: square dup * ;
: apply-twice dup execute execute ;
```

In 1z:

```
square: [ dup * ] ;
apply-twice: [ dup call call ] ;
```

Quotations are values. Pass them on the stack, store them in arrays, execute
them with `call`. This eliminates the need for Forth's STATE flag and the
complexity of immediate words.

### Markers

Markers are metadata attached to word definitions, placed between the stack
effect and the quotation body:

```
PI: const [ 3.14159 ] ;            \ cannot be redefined
describe: generic [ "unknown" ] ;  \ enables method dispatch
H{: parse-time [ "}" parse-until make-hash ] ;  \ runs at parse time
```

Markers are first-class values -- `generic type-of` returns `marker:`.

### Parse-Time Words

Forth has `IMMEDIATE` words that execute during compilation. 1z has
`parse-time` words that execute during parsing -- same idea, different
mechanism. No STATE flag, no compile/interpret duality; parse-time words
simply run when the parser encounters them.

In Forth:

```
: my-syntax ... ; IMMEDIATE
```

In 1z:

```
my-syntax: parse-time [ ... ] ;
```

Parse-time words can read additional tokens from the input stream. They are
the mechanism behind `H{`, `struct{`, `enum{`, `virtual{`, `method{`, and
`protocol{`.

### Local Definitions

Forth has `LOCALS|` or `{: ... :}`. 1z has no local variable syntax.
Instead, definitions inside quotations are scoped to that quotation:

```
[
  a: [ 1 ] ;
  b: [ 2 ] ;
  a b +
] call    \ 3
```

These are lexically scoped -- `a` and `b` shadow outer definitions and are
restored on exit.

---

## Data Types

### Booleans and Truthiness

Forth uses `TRUE`/`FALSE` (often -1 and 0). Factor uses `t` and `f`. 1z
uses `t`/`f`, but truthiness is simpler than both: **only `f` is falsy**.
Everything else -- `0`, `""`, `{ }`, empty collections -- is truthy.

A single falsy value is the simplest rule. No edge cases, no surprises from
accidentally treating zero or an empty string as false.

In Forth (0 is false):

```
0 IF ." truthy" THEN   \ does NOT execute
```

In 1z (0 is truthy):

```
0 [ "zero is truthy" print-line ] when   \ executes
```

### Strings

Forth strings vary by implementation (`S" ..."`, `." ..."`). 1z uses
double-quoted strings only. They are immutable sequences of Unicode
codepoints.

In Forth:

```
S" hello"
." hello world"
```

In 1z:

```
"hello"
"hello world" print-line
```

Escape sequences: `\n`, `\t`, `\"`, `\\`.

### Symbol Literals

Any token ending with `:` is a symbol literal. Symbols are pushed as values,
not executed. They serve as hash keys, word names, type identifiers, and
enum variant tags.

```
foo:        \ pushes the symbol foo:
+:          \ pushes the symbol +:
```

There is no separate quoting mechanism like Factor's `\ word` or Forth's
`' word`. The symbol value itself does not include the `:` suffix --
`foo: >string` yields `"foo"`, and the round-trip works:
`"foo" >symbol` yields `foo:`.

### Data Literals

Forth has no standard collection literals. Factor uses `{ }` for arrays and
`H{ }` for hash tables, but the syntax differs.

**Arrays** (immutable):

```
{ 1 2 3 }
{ "a" 2 true }      \ mixed types
{ { 1 2 } { 3 4 } } \ nested
```

**Hash tables** (immutable, symbol keys):

In Factor:

```
H{ { "name" "Alice" } { "age" 30 } }
```

In 1z:

```
H{ name: "Alice" age: 30 }
```

Keys are symbol literals. Values follow immediately.

**Other collection literals:**

```
V{ 1 2 3 }           \ vector (mutable array)
B{ 0xFF 0x00 0x42 }  \ byte array
S{ "a" "b" "c" }     \ set
M{ key: value }       \ mutable map
W{ foo bar baz }      \ word array: { "foo" "bar" "baz" }
C{ 3.0 4.0 }         \ complex number (requires use "complex" ;)
nd{ 1 2 ; 3 4 }      \ n-dimensional array (requires use "ndarray" ;)
```

### Ranges

Forth has no range type. 1z has lazy integer ranges with O(1) length and
indexed access:

```
use "ranges" ;

1 10 <range>       \ exclusive [1, 10)
1 10 range=        \ inclusive [1, 10]
5 iota             \ [0, 5)
1 10 2 range-step  \ [1, 10) step 2
0 range-from       \ infinite from 0
```

Ranges work with all sequence operations:
`5 iota [ 2 * ] #map #collect` yields `{ 0 2 4 6 8 }`.

### Complex Numbers

Forth has no complex number support. 1z has complex numbers as a virtual
type:

```
use "complex" ;

C{ 3.0 4.0 }                  \ literal (real imag)
C{ 1.0 2.0 } C{ 3.0 4.0 } +  \ arithmetic
C{ 3.0 4.0 } magnitude        \ 5.0
C{ 3.0 4.0 } conjugate        \ C{ 3.0 -4.0 }
```

Components are promoted to float. Full arithmetic dispatch across all
numeric types.

### Parameterized Types

Forth and Factor have no parameterized type system. 1z has
`define-parameterized-type` for typed container wrappers:

```
vector(fixnum): vector fixnum define-parameterized-type

V{ 1 2 3 } >vector(fixnum)              \ wrap
V{ 1 2 } >vector(fixnum) 3 #push!       \ ok
V{ 1 2 } >vector(fixnum) "hello" #push! \ throws error
```

Mutation operations validate element types and preserve the typed wrapper.

---

## Control Flow and Dispatch

### Conditionals

Forth uses `IF ... ELSE ... THEN` (compile-time words). 1z uses
quotation-based combinators.

In Forth:

```
: check  0 > IF ." positive" ELSE ." not positive" THEN ;
```

In 1z:

```
check: [
  0 > [ "positive" print ] [ "not positive" print ] if
] ;
```

Word order: `condition true-branch false-branch if`. Both branches are
quotations. `when` and `unless` are single-branch variants:

```
t [ "yes" print ] when
f [ "fallback" print ] unless
```

### Loops

Forth has `DO ... LOOP` and `BEGIN ... UNTIL`. 1z uses quotation-based loop
combinators -- no compile-time loop constructs.

In Forth:

```
: count  10 0 DO I . LOOP ;
: wait   BEGIN check-done UNTIL ;
```

In 1z:

```
count: [ [ . ] 10 times ] ;
wait:  [ [ check-done ] loop ] ;
```

Available: `n [ body ] times`, `[ pred ] [ body ] while`,
`[ pred ] loop`.

### Recursion

Forth words reference themselves by name; some Forths need `RECURSE`. In 1z,
just use the word's name -- it resolves from the dictionary at call time:

```
fact: [
  dup 1 <= [ drop 1 ] [ dup 1 - fact * ] if
] ;
```

No `recurse` keyword needed.

### Multi-Way Dispatch

**`case`** (equality-based):

```
value {
  { 1 [ "one" ] }
  { 2 [ "two" ] }
  [ drop "other" ]
} case
```

**`cond`** (predicate-based):

```
value {
  { [ dup 0 > ] [ "positive" ] }
  { [ dup 0 = ] [ "zero" ] }
  [ "negative" ]
} cond
```

### Match Syntax

`match{` is a parse-time word that validates exhaustiveness at parse time:

```
color: enum{ red: unit green: unit blue: unit } ;

color:green match{
  color:red:   [ "R" ]
  color:green: [ "G" ]
  color:blue:  [ "B" ]
}
```

All variants must be covered, or `_` must be present as a default. Unknown
or duplicate variants produce parse-time errors.

### Method Dispatch

Forth and Factor have no user-defined operator dispatch. 1z has `method{`
for registering type-specific implementations:

```
describe: generic ( val -- str ) [ drop "unknown" ] ;
describe: method{ duration } [ drop "a duration" ] ;

+: method{ duration duration } [
  swap unmake-duration swap unmake-duration + >duration
] ;
```

Dispatch precedence: exact type match, then enum-level, then `any` wildcard,
then native fallback.

---

## Collections

### Sequence Operations

Sequence operations use the `#` prefix. They are polymorphic across strings,
arrays, vectors, byte arrays, sets, and iterators.

```
{ 1 2 3 } #len           \ 3
{ 1 2 3 } 0 #nth         \ 1 (zero-indexed)
{ 1 2 } { 3 } #append    \ { 1 2 3 }
```

Higher-order words return lazy iterators, not materialized collections.
This avoids intermediate allocations in pipelines and enables infinite
sequences.

```
{ 1 2 3 } [ 2 * ] #map            \ returns an iterator
{ 1 2 3 } [ 2 * ] #map #collect   \ { 2 4 6 }
```

Use `#collect` to materialize, `#reduce` to fold, `#each` to iterate for
side effects.

See also: [Iterators and Sequences](iterators.md)

### Associative Operations

Associative operations use the `@` prefix:

```
H{ name: "Alice" age: 30 } name: @get   \ "Alice"
H{ name: "Alice" } age: @has?           \ f
H{ name: "Alice" } age: 30 @set         \ H{ name: "Alice" age: 30 }
```

### Spread Operator

Forth has no spread/unpack operation. 1z has `...` which pushes each element
of a sequence onto the stack:

```
{ 1 2 3 } ...    \ pushes 1 2 3
"abc" ...         \ pushes "a" "b" "c"
```

Works on arrays, vectors, strings, byte arrays, iterators, ranges, hashes,
and mutable maps.

---

## Type Definitions

### Structs

Forth has no standard struct syntax. Factor uses `TUPLE:`.

In Factor:

```
TUPLE: person name age ;
```

In 1z:

```
person: struct{ name age } ;
```

This generates `make-person`, `name>>`, `>>name`, `person?`, and
`unmake-person`.

### Virtual Types (Newtypes)

Virtual types wrap an existing type with a distinct type identity:

```
duration: virtual{ fixnum } ;
```

Generates `>duration`, `unmake-duration`, `duration?`.

For ordinary multi-field records, use `struct{ ... }`. Virtual types are for
nominal wrappers or intentional opacity:

```
timestamp-inner: struct{ sec nsec } ;
timestamp: virtual{ timestamp-inner } ;
```

### Enums

Tagged unions (sum types):

```
color: enum{ red: unit green: unit blue: unit } ;
```

Generates constructors (`color:red`, etc.), predicates (`color:red?`,
`color?`), and wrap/unwrap words.

Data-carrying variants:

```
circle-data: struct{ radius } ;
shape: enum{ circle: circle-data point: unit } ;
```

### Protocols

Forth has no protocol concept. 1z has `protocol{`, which defines a named set
of required method signatures:

```
shapeful: protocol{ perimeter area } ;
circle: shapeful    \ throws if methods missing
```

---

## Standard Patterns

### Option and Result Types

Forth uses sentinel values (-1, 0) for failure. 1z has algebraic
option/result types:

```
42 >option:some          \ wrap a value
option:none              \ no value

opt 0 unwrap-or          \ extract or default
opt [ 2 * ] ?map         \ transform if present
opt [ [ 0 ] ] ?or-else   \ fallback if none

[ risky ] try            \ returns result:ok or result:err
res unwrap-or-throw      \ extract or re-throw
```

Combinators use the `?` prefix.

### Error Handling

Forth has `CATCH`/`THROW`. Factor has `try`/`recover`. 1z uses `recover`
and `throw`:

In Forth:

```
' risky-word CATCH IF ." error" THEN
```

In 1z:

```
[ risky-code ] [ error-handler ] recover
[ risky-code ] ignore-errors
f "something went wrong" EUserThrown make-error throw
```

The error handler receives the error object on the stack. Fields are
accessible via `@get`:

```
[ 1 0 / ] [ error-type: @get ] recover
\ yields division-by-zero:
```

See also: [Error Handling cookbook](../cookbook/error-handling.md)

### Conversions

Conversion words use the `>` prefix for the target type:

```
42 >float        \ fixnum to float
3.14 >integer    \ float to fixnum (truncates)
42 >string       \ any value to string
value >iterator  \ sequence to lazy iterator
```

Some conversions include the source type: `foo>bar` converts from foo to bar.

### String Formatting

Forth uses `S"` and `.` for output. 1z uses template-based interpolation:

In Forth:

```
S" hello " TYPE name TYPE
```

In 1z:

```
H{ name: "Alice" age: 30 } "{name} is {age}" fmt   \ "Alice is 30"
42 "The answer is {}." fmt                           \ "The answer is 42."
```

Placeholders: `{}` (identity), `{name}` (named), `{0}` (indexed),
`{name:width=5,fill=0}` (format specifiers).

### Dynamic Variables

Forth uses `VALUE` and `TO`. Factor uses `SYMBOL:` and namespaces. 1z uses
`define-parameter` for dynamically-scoped variables:

In Forth:

```
42 VALUE my-var
99 TO my-var
```

In 1z:

```
my-var: define-parameter [ 42 ] ;
my-var get                             \ 42
99 my-var [ my-var get ] with-parameter \ temporarily 99
my-var get                             \ back to 42
```

The `with-parameter` combinator restores the binding after the quotation
completes, even on error.

---

## Systems

### Modules

Forth uses `INCLUDE` or `REQUIRE`. Factor has `USING:` vocabularies.

In Forth:

```
INCLUDE utils.fs
REQUIRE math
```

In Factor:

```
USING: math sequences ;
```

In 1z:

```
use "testing" ;              \ standard library
use "math" ;                 \ lib/math.1z
use "./local-file.1z" ;     \ relative path
use { split: } "strings" ;  \ selective import
```

For qualified access, bind the module with `load` and use dot notation:

```
m: "math" load ;
m.sin m.cos m.pi
```

See also: [Modules](modules.md)

### Concurrency

Forth has no standard concurrency. 1z has cooperative green threads -- a
single OS thread with deterministic scheduling, which eliminates data races
and keeps debugging predictable.

```
[
  [ "hello" print ] spawn
  [ "world" print ] spawn
] task-scope

<channel>                    \ unbuffered channel
10 <buffered-channel>        \ buffered
channel value send           \ blocks if full
channel receive              \ blocks if empty
```

See also: [Concurrency](concurrency.md)

### FFI

Forth FFI varies by implementation. 1z has a declarative dynamic FFI built
on libffi:

In Forth:

```
C-LIBRARY mylib
c-function add int int -- int
```

In 1z:

```
use "ffi" ;

"libm" lib-open
dup "sqrt" lib-symbol ffi{ f64 -> f64 } bind-sig
2.0 swap ffi-call

\ Declarative multi-binding:
"libm" lib-open ffi-def{
  sine: "sin" ffi{ f64 -> f64 }
  cosn: "cos" ffi{ f64 -> f64 }
} >module
```

FFI types: `i8`, `i16`, `i32`, `i64`, `u16`, `usize`, `isize`, `f32`,
`f64`, `bool`, `ptr`, `void`. Out-parameters use `out-` prefix, in-out
parameters use `inout-`.

See also: [Foreign Function Interface](ffi.md)
