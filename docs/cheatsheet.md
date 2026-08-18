# Cheatsheet

A compact reference for 1z syntax and standard words. For progressive
explanations, start with the [Language Tutorials](tutorials/index.md). For
deep dives into specific subsystems, see the [Conceptual Guides](guides/index.md).

## Data Literals

| Syntax | Type | Example |
|--------|------|---------|
| `42`, `-7` | fixnum | `42` |
| `3.14`, `-0.5` | float | `3.14` |
| `0xFF`, `0b1010`, `0o77` | fixnum (hex/bin/oct) | `0xFF` |
| `1_000_000` | fixnum with separators | `1_000_000` |
| `"hello"` | string | `"hello\nworld"` |
| `foo:` | symbol | `name:`, `+:` |
| `t` / `f` | boolean | `true`, `false` |
| `[ ... ]` | quotation | `[ 2 * ]` |
| `{ ... }` | array (immutable) | `{ 1 2 3 }` |
| `H{ k: v ... }` | hash (immutable) | `H{ name: "Alice" }` |
| `V{ ... }` | vector (mutable array) | `V{ 1 2 3 }` |
| `B{ ... }` | byte array | `B{ 0xFF 0x00 }` |
| `S{ ... }` | set | `S{ "a" "b" }` |
| `M{ k v ... }` | mutable map | `M{ key: val }` |
| `W{ ... }` | word array (strings) | `W{ foo bar }` |
| `C{ r i }` | complex number | `C{ 3.0 4.0 }` |
| `nd{ ... }` | n-dimensional array | `nd{ 1 2 ; 3 4 }` |

See also: [Stack Fundamentals](tutorials/stack-fundamentals.md),
[The Type System](guides/type-system.md)

## Naming Conventions

| Pattern | Meaning | Examples |
|---------|---------|---------|
| `name:` | Symbol literal | `foo:`, `+:` |
| `#name` | Sequence operation | `#map`, `#len`, `#nth` |
| `@name` | Associative operation | `@get`, `@set`, `@keys` |
| `?name` | Option/result combinator | `?map`, `?and-then` |
| `>name` | Conversion (to target) | `>string`, `>float` |
| `name?` | Predicate | `fixnum?`, `empty?` |
| `name!` | Mutating operation | `@set!`, `#push!` |
| `>>name` | Struct setter | `>>foo` |
| `name>>` | Struct getter | `foo>>` |
| `<name>` | Smart constructor | `<range>`, `<channel>` |
| `make-name` | Raw constructor | `make-person` |
| `unmake-name` | Destructuring | `unmake-person` |
| `name(x)` | Variant/parameterized | `vector(fixnum)` |

## Word Definition

```
double: [ 2 * ] ;                        \ basic
double: ( n -- n ) [ 2 * ] ;             \ with stack effect
PI: const [ 3.14159 ] ;                  \ constant
describe: generic [ "unknown" ] ;        \ generic (dispatched)
H{: parse-time [ "}" parse-until ... ] ; \ parse-time word
dup: override [ ... ] ;                  \ replace an imported, prelude, or native word
```

See also: [Defining Words](tutorials/defining-words.md)

## Type System

```
person: struct{ name age } ;                           \ struct
duration: virtual{ fixnum } ;                          \ newtype
timestamp-inner: struct{ sec nsec } ;                  \ backing record for opaque wrapper
timestamp: virtual{ timestamp-inner } ;                \ opaque wrapper over inner struct
complex: H{ numeric: t } virtual{ struct{ real imag } } ; \ metadata-bearing virtual
color: enum{ red: unit green: unit blue: unit } ;      \ flat enum
shape: enum{ circle: circle-data point: unit } ;       \ data-carrying enum
iterable: protocol{ >iterator } ;                      \ protocol
vector(fixnum): vector fixnum define-parameterized-type \ parameterized type
```

Generated words per type:

| Type | Generated |
|------|-----------|
| `struct{ }` | `make-name`, `unmake-name`, `name>>`, `>>name`, `name?` |
| `virtual{ inner }` | `>name`, `unmake-name`, `name?` |
| `virtual{ struct{ } }` | `make-name`, `>name`, `unmake-name`, `name?`, `name>hash` |
| `enum{ }` | `enum:variant` constructors, `>enum:variant` wrap, `enum:variant>` unwrap, `enum:variant?`, `enum?` predicates |

Rule of thumb: use `struct{ }` for normal multi-field records; use `virtual{ }`
when you need a nominal wrapper, intentional opacity, or attached metadata.

See also: [The Type System](guides/type-system.md)

## Stack Manipulation

```
dup    ( a -- a a )          drop  ( a -- )
swap   ( a b -- b a )        over  ( a b -- a b a )
<rot-  ( a b c -- b c a )    -rot> ( a b c -- c a b )
nip    ( a b -- b )          tuck  ( a b -- b a b )
pick   ( a b c -- a b c a )  2dup  ( a b -- a b a b )
2drop  ( a b -- )            3drop ( a b c -- )
n pick-n                     \ copy nth element to top
```

See also: [Stack Fundamentals](tutorials/stack-fundamentals.md)

## Combinators

```
[ body ] dip          \ hide TOS, run body, restore
[ body ] keep         \ run body with TOS, restore TOS
[ body ] 2dip         \ hide top 2, run body, restore
[ body ] 3dip         \ hide top 3, run body, restore
[ p ] [ q ] bi        \ apply two quotations to same value
[ p ] [ q ] [ r ] tri \ apply three quotations to same value
{ [ q1 ] [ q2 ] } cleave \ apply array of quotations to same value
[ body ] curry        \ partially apply: [ x body ]
[ f ] [ g ] compose   \ function composition: [ f g ]
```

See also: [Quotations](tutorials/quotations.md),
[Stack Idioms cookbook](cookbook/stack-idioms.md)

## Control Flow

```
cond [ true-branch ] [ false-branch ] if
cond [ action ] when
cond [ action ] unless

value {
  { 1 [ "one" ] }
  { 2 [ "two" ] }
  [ drop "other" ]
} case

{
  { [ dup 0 > ] [ "positive" ] }
  { [ dup 0 = ] [ "zero" ] }
  [ "negative" ]
} cond

\ Parse-time exhaustive match on enums:
val match{
  enum:variant1: [ body1 ]
  enum:variant2: [ body2 ]
}

\ Runtime match (not validated):
val {
  enum:variant1: [ body1 ]
  enum:variant2: [ body2 ]
} unchecked-match
```

See also: [Control Flow](tutorials/control-flow.md)

## Loops

```
n [ body ] times               \ execute body n times
[ pred ] [ body ] while        \ loop while pred is true
[ pred ] [ body ] until        \ loop until pred is true
[ pred ] loop                  \ repeat pred; loop if true
[ pred ] [ body ] do while     \ execute body once before while
```

## Sequence Operations (`#`)

```
seq #len             \ length
seq n #nth           \ nth element (0-indexed)
seq #first           \ first element
seq #last            \ last element
seq1 seq2 #append    \ concatenate
seq start end #slice \ subsequence [start, end)
seq [ cmp ] #sort    \ sort with comparator quotation
seq [ f ] #sort-by   \ sort by key function (natural ordering)

\ Higher-order (return lazy iterators -- use #collect to materialize):
seq [ f ] #map       \ transform each element
seq [ p ] #filter    \ keep elements where p is true
iter n #take         \ first n elements of iterator
iter n #drop         \ skip n elements of iterator

\ Consumers:
seq [ f ] #each      \ iterate for side effects
seq init [ f ] #reduce \ fold
iter #collect        \ materialize iterator to array
iter #count          \ count elements (exhausts iterator)

\ Predicates:
seq [ p ] #any       \ any element satisfies p?
seq [ p ] #all       \ all elements satisfy p?
seq [ p ] #none      \ no element satisfies p?
seq val #in?         \ membership test
seq val #index-of    \ index of val (f if absent)
seq #empty?          \ length is 0?

\ Partitioning:
seq [ p ] #partition  \ split into { matches non-matches }
seq [ f ] #group-by   \ group by key function -> hash

\ Mutation (vectors/byte arrays only):
vec val #push!       \ append element
vec #pop!            \ remove and return last
vec val #unshift!    \ prepend element
vec #shift!          \ remove and return first
vec idx val #nth!    \ set element at index
vec seq #append!     \ append all elements
```

See also: [Iterators and Sequences](guides/iterators.md),
[Iterator Pipelines cookbook](cookbook/iterator-pipelines.md)

## Associative Operations (`@`)

```
assoc key @get       \ get value by key
assoc key @has?      \ test if key exists
assoc key val @set   \ set key (immutable -- returns new hash)
assoc @keys          \ array of keys
assoc @values        \ array of values
assoc key default @get-or \ get with fallback

\ Option-returning:
assoc key @get?      \ some(value) or none

\ Set operations:
set val @in?         \ membership test
set val @adjoin      \ add to set (immutable)
set val @remove      \ remove from set (immutable)
set1 set2 @union     \ set union
set1 set2 @intersection \ set intersection
set1 set2 @difference   \ set difference

\ Mutable map only:
mmap key val @set!   \ set key in place
mmap key @remove!    \ remove key in place
```

## Option and Result (`?`)

```
42 >option:some      \ wrap value
option:none          \ no value

opt default unwrap-or       \ extract or default
opt unwrap-or-throw         \ extract or throw

opt [ f ] ?map              \ transform if some/ok
opt [ f ] ?and-then         \ flatmap if some/ok
opt [ f ] ?or-else          \ fallback if none/err
nested ?flatten             \ unwrap one nesting layer

[ risky ] try               \ returns result:ok or result:err
res unwrap-or-throw         \ extract or re-throw
```

## Conversions (`>`)

```
>string    >float    >integer    >symbol
>iterator  >bytes    >char       >hash
>option:some         >result:ok  >result:err
```

## Modules

```
use "testing" ;                  \ load from lib/
use "./local.1z" ;               \ relative path
use { split: } "strings" ;      \ selective import
use "file.1z" shadow-ok ;       \ suppress shadow check
"file.1z" load reexport(shadow-ok)   \ reexport, shadow check suppressed
private(shadow-ok){ ... }        \ private block, shadow check suppressed

m: "math" load ;                 \ bind module to name
m.sin m.cos m.pi                 \ qualified access via dot notation
```

See also: [Modules](guides/modules.md),
[Redefinition and Shadowing](guides/redefinition-and-shadowing.md),
[Module Organization cookbook](cookbook/module-organization.md)

## Concurrency

```
\ Structured concurrency with task-scope:
[
  [ "hello" print ] spawn
  [ "world" print ] spawn
] task-scope

\ Channels:
<channel>                    \ unbuffered channel
10 <buffered-channel>        \ buffered channel
channel value send           \ send (blocks if full)
channel receive              \ receive (blocks if empty)
channel receive?             \ option-returning receive
channel close-channel        \ close channel

\ Select (multiplexed receive):
{ ch1 ch2 } select           \ receive from first ready: ( -- val ch )

\ Task control:
duration sleep                \ suspend for duration
task cancel-task              \ cancel a task
[ body ] duration with-timeout \ timeout a computation
task-self                    \ current task handle
[ body ] "name" spawn-named  \ named task
```

See also: [Concurrency](guides/concurrency.md),
[Concurrency Patterns cookbook](cookbook/concurrency-patterns.md)

## Error Handling

```
[ risky ] [ handler ] recover     \ catch errors
[ risky ] ignore-errors           \ silently discard errors
[ body ] [ cleanup ] cleanup      \ always-run cleanup
f "message" EUserThrown make-error throw  \ throw error

\ Error inspection:
error error-type: @get            \ get error type symbol
error message: @get               \ get error message

\ Exception-to-result:
[ risky ] try                     \ result:ok or result:err
```

See also: [Error Handling cookbook](cookbook/error-handling.md)

## Dynamic Variables

```
my-var: define-parameter [ 42 ] ;       \ define with default
my-var get                               \ read: 42
99 my-var [ my-var get ] with-parameter  \ temporarily rebound to 99
```

## FFI

```
use "ffi" ;

"libm" lib-open                          \ open shared library
dup "sqrt" lib-symbol ffi{ f64 -> f64 } bind-sig  \ bind function
2.0 swap ffi-call                        \ call it

\ Declarative block syntax:
"libm" lib-open ffi-def{
  sqrt: "sqrt" ffi{ f64 -> f64 }
} >module

\ Callbacks:
[ body ] ffi{ i32 -> i32 } ffi-callback  \ create C callback
```

FFI types: `i8`, `i16`, `i32`, `i64`, `u16`, `usize`, `isize`, `f32`, `f64`,
`bool`, `ptr`, `void`, `out-*`, `inout-*`.

See also: [Foreign Function Interface](guides/ffi.md)

## String Formatting

```
42 "The answer is {}." fmt                \ identity placeholder
H{ x: 1 y: 2 } "{x},{y}" fmt            \ named placeholders
{ 10 20 } "{0} + {1}" fmt                \ indexed placeholders
H{ n: 3 } "{n:width=2,fill=0}" fmt       \ format specifiers: "03"
```

See also: [String Processing cookbook](cookbook/string-processing.md)

## Metaprogramming

```
"1 2 +" eval-string             \ evaluate string as 1z code
parse-token                     \ read next token from input
parse-literal                   \ read and resolve next literal
"}" parse-until                 \ read values until delimiter
"}" parse-tokens-until          \ read raw tokens until delimiter
```

## Pragmas

```
pragma{ require-doc: relaxed }  \ file-scoped directive
pragma? require-doc:            \ query at parse time
```

## Tooling

```
1z --check file.1z              \ static analysis
1z --debug file.1z              \ interactive debugger
1z --break=word file.1z         \ break at word
1z --trace-words file.1z        \ execution tracing
1z --trace-modules file.1z      \ all module-trace categories
1z --trace-modules=source f.1z  \ just embedded vs filesystem source
1z --deadlock-detect file.1z    \ scheduler diagnostics
1z --benchmark file.1z          \ performance measurement
```
