# Data Structures

Constructing and querying hashes, structs, virtual types, enums, vectors,
and sets.

## Hash tables

`H{ }` creates an immutable hash with symbol keys. `@get` retrieves,
`@set` returns a new hash with the key added:

```
H{ name: "Alice" age: 30 }
dup name: @get .
dup age: @has? .
role: "admin" @set role: @get .
```

Output:

```
"Alice"
t
"admin"
```

## Option-returning lookup

`@get?` returns an option instead of throwing on missing keys. Chain with
`unwrap-or` for a default:

```
H{ x: 1 } y: @get? 0 unwrap-or .
```

Output:

```
0
```

## Structs

`struct{ }` generates a constructor, getters, and a predicate:

```
point: struct{ x y } ;

10 20 make-point
dup x>> .
dup y>> .
point? .
```

Output:

```
10
20
t
```

Mutable structs also generate setters (`>>field`):

```
mpoint: mutable struct{ mx my } ;

10 20 make-mpoint
99 >>mx mx>> .
```

Output:

```
99
```

## Virtual types (newtypes)

`virtual{ }` wraps an existing type with a distinct identity. Useful for
domain modeling -- a `celsius` is not a bare `float`, even though it is
backed by one:

```
celsius: virtual{ float } ;

100.0 >celsius
dup celsius? .
unmake-celsius .
```

Output:

```
t
100.0
```

## Enums and match

Flat enums carry no data. Every variant requires an explicit type; `unit`
means the variant is empty:

```
direction: enum{ north: unit south: unit east: unit west: unit } ;

direction:east match{
  direction:north: [ "N" ]
  direction:south: [ "S" ]
  direction:east:  [ "E" ]
  direction:west:  [ "W" ]
} .
```

Output:

```
"E"
```

`match{` validates exhaustiveness at parse time -- missing a variant is a
compile error.

## Vectors (mutable arrays)

```
V{ 1 2 3 }
dup 4 #push!
dup #len .
#pop! .
```

Output:

```
4
4
```

## Sets

```
S{ "a" "b" "c" }
dup "a" @in? .
dup "z" @in? .
"d" @adjoin "d" @in? .
```

Output:

```
t
f
t
```

Set operations (`@union`, `@intersection`, `@difference`) return new sets.

See also: [The Type System guide](../guides/type-system.md)
