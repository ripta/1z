# The Type System

1z is dynamically typed -- every value carries its type at runtime. The
language gives you a rich set of built-in types and four ways to define your
own: record types, newtypes, sum types, and polymorphic dispatch. Protocols
tie these together into enforceable contracts.

## Built-in Types

These types are always available:

| Type | Examples | Predicate |
|------|----------|-----------|
| `fixnum` | `42`, `-1`, `0xFF` | `fixnum?` |
| `float` | `3.14`, `-0.5` | `float?` |
| `string` | `"hello"` | `string?` |
| `symbol` | `foo:`, `+:` | `symbol?` |
| `boolean` | `t`, `f` | `boolean?` |
| `array` | `{ 1 2 3 }` | `array?` |
| `hash` | `H{ name: "Jo" }` | `hash?` |
| `quotation` | `[ 2 * ]` | `quotation?` |
| `byte-array` | `B{ 0 255 }` | `byte-array?` |
| `vector` | `V{ 1 2 3 }` | `vector?` |
| `set` | `S{ 1 2 3 }` | `set?` |
| `mutable-map` | `M{ a: 1 }` | `mutable-map?` |

Every value responds to `type-of`, which returns a first-class type value,
and `type-name`, which returns a string:

```
42 type-of .
42 type-name .
```

Output:

```
<type:fixnum>
"fixnum"
```

Type values are real values -- you can compare them, store them, and pass them
to words like `instance-of?`.

## Record Types with `struct{`

`struct{` defines a record type with named fields:

```
point: struct{ x y } ;
```

This spins up several words automatically:

| Word | Stack Effect | Purpose |
|------|-------------|---------|
| `make-point` | `( x y -- point )` | Positional constructor |
| `unmake-point` | `( point -- x y )` | Destructure to fields |
| `>point` | `( hash -- point )` | Construct from hash |
| `point>hash` | `( point -- hash )` | Convert to hash |
| `x>>` | `( point -- point x )` | Get field (keeps struct) |
| `>>x` | `( point val -- point )` | Set field (returns new struct) |

```
1 2 make-point dup x>> . y>> .
```

Output:

```
1
2
```

`>hash` dispatches polymorphically on any struct or virtual type:

```
3 4 make-point >hash .
```

Output:

```
H{ x: 3 y: 4 }
```

## Newtypes with `virtual{`

`virtual{` wraps an existing type to mint a new, distinct type. The wrapped
value is identical at runtime, but the type system treats it as a separate
kind of thing.

A simple wrapper around a fixnum:

```
speed: virtual{ fixnum } ;
42 make-speed type-name .
42 make-speed unmake-speed .
```

Output:

```
"speed"
42
```

`make-speed` wraps, `unmake-speed` unwraps. The value inside is still a
fixnum, but `speed?` and `fixnum?` give different answers:

```
42 make-speed speed? .
42 make-speed fixnum? .
```

Output:

```
t
f
```

This is the point of newtypes: a `speed` is not a `fixnum`, even though it
contains one. You cannot accidentally pass a speed where a distance is
expected.

### Struct-Backed Virtual Types

Virtual types can wrap a struct for multi-field newtypes:

```
vec2: virtual{ struct{ vx vy } } ;
10 20 make-vec2 >hash vx: @get .
```

Output:

```
10
```

The hash-based constructor also works:

```
vec2: virtual{ struct{ vx vy } } ;
H{ vx: 10 vy: 20 } >vec2 type-name .
```

Output:

```
"vec2"
```

## Sum Types with `enum{`

`enum{` declares a type with multiple named variants. Each variant carries a
payload type -- `unit` for variants with no data.

A flat enum with no data:

```
color: enum{ red: unit green: unit blue: unit } ;
color:red .
color:green color? .
color:red color:red? .
```

Output:

```
<color:red red:>
t
t
```

Each variant gets a constructor (`color:red`), a predicate (`color:red?`),
and an aggregate predicate that catches the whole enum (`color?`).

### Data-Carrying Variants

Variants can carry structured data:

```
circle-data: struct{ radius } ;
rect-data: struct{ w h } ;
shape: enum{ circle: circle-data rect: rect-data dot: unit } ;

5 make-shape:circle shape:circle? .
5 make-shape:circle unmake-shape:circle .
```

Output:

```
t
5
```

Multi-field variants work the same way:

```
circle-data: struct{ radius } ;
rect-data: struct{ w h } ;
shape: enum{ circle: circle-data rect: rect-data dot: unit } ;

3 4 make-shape:rect unmake-shape:rect . .
```

Output:

```
4
3
```

### Introspection

`enum-variants` takes an enum name as a symbol and lists all its variants:

```
color: enum{ red: unit green: unit blue: unit } ;
color: enum-variants .
```

Output:

```
{ color:red: color:green: color:blue: }
```

`enum-of` goes the other direction -- given a variant value, it returns the
enum name as a string:

```
color: enum{ red: unit green: unit blue: unit } ;
color:red enum-of .
```

Output:

```
"color"
```

## Exhaustive Dispatch with `match{`

`match{` dispatches on an enum value with compile-time exhaustiveness
checking. Every variant must be covered, or a `_` default must catch the
rest:

```
color: enum{ red: unit green: unit blue: unit } ;

describe-color: ( color -- str ) [
  match{
    color:red:   [ "red" ]
    color:green: [ "green" ]
    color:blue:  [ "blue" ]
  }
] ;

color:red describe-color .
color:blue describe-color .
```

Output:

```
"red"
"blue"
```

For data-carrying variants, `match{` peels off the enum wrapper and dumps
the payload onto the stack:

```
circle-data: struct{ radius } ;
shape: enum{ circle: circle-data point: unit } ;

42 >shape:circle match{
  shape:circle: [ 2 * ]
  shape:point:  [ 0 ]
} .
```

Output:

```
84
```

The `_` default catches any unmatched variants:

```
color: enum{ red: unit green: unit blue: unit } ;

color:green match{
  color:red: [ "red" ]
  _ [ drop "other" ]
} .
```

Output:

```
"other"
```

## Polymorphic Dispatch with `method{`

`generic` creates a word with a default body. `method{` hooks in
type-specific implementations that override the default:

```
describe: ( value -- string ) generic [ inspect " (default)" #append ] ;

describe: method{ fixnum } [ inspect " (fixnum)" #append ] ;
describe: method{ boolean } [ [ "yes" ] [ "no" ] if ] ;

42 describe .
t describe .
"hello" describe .
```

Output:

```
"42 (fixnum)"
"yes"
"\"hello\" (default)"
```

Strings fall through to the default because no `method{ string }` is registered.

### Virtual Type Dispatch

User-defined types participate in dispatch the same way:

```
duration: virtual{ fixnum } ;
describe: ( value -- string ) generic [ inspect ] ;
describe: method{ duration } [ unmake-duration inspect " ns" #append ] ;

100 >duration describe .
```

Output:

```
"100 ns"
```

### Binary Dispatch

Methods can dispatch on two types at once:

```
combine: ( a b -- result ) generic [ + ] ;
combine: method{ string string } [ #append ] ;

10 32 combine .
"hello" " world" combine .
```

Output:

```
42
"hello world"
```

## Interface Contracts with `protocol{`

A protocol pins down a set of methods that a type must implement. Validation
fires at parse time -- if a method is missing, you get an error immediately.

Define a protocol and validate a type against it:

```
shapeful: protocol{ perimeter: area: } ;

circle: virtual{ fixnum } ;

perimeter: generic ( shape -- n ) [ drop 0 ] ;
area: generic ( shape -- n ) [ drop 0 ] ;

perimeter: method{ circle } [ unmake-circle 2 * 314 * 100 / ] ;
area: method{ circle } [ unmake-circle dup * 314 * 100 / ] ;

circle: shapeful

10 >circle perimeter .
10 >circle area .
```

Output:

```
62
314
```

The line `circle: shapeful` checks that `circle` has implementations for
both `perimeter` and `area`. If either were missing, 1z would throw a
`protocol-error` at parse time.

### Typed Protocols

Protocol methods can specify argument types using `self` (the type being
validated) and `any` (any type):

```
self-addable: protocol{ add: ( a: self b: self -- result ) } ;

my-num: virtual{ fixnum } ;
add: generic ( a b -- c ) [ drop ] ;
add: method{ my-num my-num } [
  unmake-my-num swap unmake-my-num + >my-num
] ;

my-num: self-addable
```

This checks that `add` is registered for `my-num` in both argument
positions. The `any` marker accepts any type in that slot.

## Putting It Together

Here is a small shape library that combines structs, enums, methods, and
match:

```
use "testing" ;

circle-d: struct{ radius } ;
rect-d: struct{ w h } ;
shape: enum{ circle: circle-d rect: rect-d } ;

area: generic ( shape -- n ) [ drop 0 ] ;

area: method{ shape:circle } [
  unmake-shape:circle dup * 314 * 100 /
] ;

area: method{ shape:rect } [
  unmake-shape:rect *
] ;

name: ( shape -- str ) [
  match{
    shape:circle: [ drop "circle" ]
    shape:rect:   [ drop drop "rectangle" ]
  }
] ;

5 make-shape:circle area 78 "circle area" assert=
3 4 make-shape:rect area 12 "rect area" assert=
5 make-shape:circle name "circle" "circle name" assert=
3 4 make-shape:rect name "rectangle" "rect name" assert=
```

Structs define the data, enums define the variants, methods provide
polymorphic behavior, and `match{` handles exhaustive case analysis.

See also: [Data Structures cookbook](../cookbook/data-structures.md)

The [next guide](modules.md) covers how to organize code into modules.
