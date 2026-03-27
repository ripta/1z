# Stack Idioms

Shuffle words (`swap`, `<rot-`, `-rot>`) get tangled fast. Combinators
express the same operations declaratively -- you say *what* you want to
preserve or transform, not *how* to rearrange the stack. When even
combinators start nesting, define a helper word instead.

## `dip` -- access buried values

`dip` hides the top of stack, runs a quotation, then restores the hidden
value. It reaches one level down without a `swap` chain.

```
1 2 [ 10 + ] dip
```

Output:

```
\ stack: 11 2
```

The body ran on 1 (producing 11), and 2 was preserved on top.

`2dip` and `3dip` reach further:

```
1 2 3 [ 10 * ] 2dip
```

Output:

```
\ stack: 10 2 3
```

## `keep` -- use a value without consuming it

`keep` runs the quotation with the top value, then pushes that value back.
You get both the computed result and the original.

```
5 [ 2 * ] keep
```

Output:

```
\ stack: 10 5
```

Handy for computing a derived value while preserving the source:

```
"hello" [ #len ] keep
```

Output:

```
\ stack: 5 "hello"
```

## `bi` and `tri` -- multiple views of one value

`bi` duplicates the top value and applies two quotations. `tri` does the
same with three. Both avoid the `dup ... swap` dance.

```
10 [ 2 * ] [ 3 + ] bi
```

Output:

```
\ stack: 20 13
```

```
6 [ 2 * ] [ 3 + ] [ 1 - ] tri
```

Output:

```
\ stack: 12 9 5
```

`cleave` generalizes to an array of quotations:

```
10 { [ 2 * ] [ 3 + ] [ 1 - ] } cleave
```

Output:

```
\ stack: 20 13 9
```

## `curry` and `compose`

`curry` partially applies a value to a quotation. `compose` chains two
quotations into one.

```
10 [ + ] curry    \ produces [ 10 + ]
5 swap call .
```

Output:

```
15
```

```
[ 2 * ] [ 1 + ] compose    \ produces [ 2 * 1 + ]
3 swap call .
```

Output:

```
7
```

## When to define a helper

If you find yourself writing `swap rot swap dip swap`, stop. Define a word:

```
add-to-each: ( n seq -- seq ) [
  swap [ + ] curry #map #collect
] ;

5 { 1 2 3 } add-to-each .
```

Output:

```
{ 6 7 8 }
```

A named word with a stack effect is always clearer than a deep shuffle.

See also: [Quotations tutorial](../tutorials/quotations.md),
[Stack Fundamentals tutorial](../tutorials/stack-fundamentals.md)
