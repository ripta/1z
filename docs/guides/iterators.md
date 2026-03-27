# Iterators and Sequences

Most sequence operations in 1z are lazy -- they produce values on demand
rather than building intermediate collections. This makes it natural to work
with large or infinite sequences, and to chain multi-step transformations
without allocating throwaway arrays.

## The Iterator Protocol

Any collection can be turned into an iterator with `>iterator`:

```
{ 10 20 30 } >iterator type-name .
```

Output:

```
"iterator"
```

An iterator is a mutable cursor. Each call to `#next` advances it and
pops the next value out:

```
{ 10 20 30 } >iterator
dup #next .
dup #next .
#next .
```

Output:

```
10
20
30
```

Once exhausted, `#next` throws. Use `#next?` for safe access -- it returns
an option value:

```
{ 1 } >iterator
dup #next? .
#next? .
```

Output:

```
<option:some 1>
<option:none none:>
```

Iterators are consumed. Calling `#next` on a shared reference (via `dup`)
advances the same underlying cursor.

## Lazy Adapters

Adapters wrap an iterator into a new iterator without doing any work until
something pulls values out.

### `#map`

`#map` fires a quotation on each element as it is pulled:

```
{ 1 2 3 } >iterator [ 10 * ] #map #collect .
```

Output:

```
{ 10 20 30 }
```

The `#map` call itself is instant -- it hands back a new iterator. The
multiplication only fires when `#collect` (or another consumer) pulls
values.

### `#filter`

`#filter` keeps only elements that pass a predicate:

```
{ 1 2 3 4 5 } >iterator [ 3 > ] #filter #collect .
```

Output:

```
{ 4 5 }
```

### `#take` and `#drop`

`#take` limits an iterator to the first N elements:

```
{ 1 2 3 4 5 } >iterator 3 #take #collect .
```

Output:

```
{ 1 2 3 }
```

`#drop` skips the first N elements:

```
{ 1 2 3 4 5 } >iterator 2 #drop #collect .
```

Output:

```
{ 3 4 5 }
```

Both return iterators when called on iterators.

## Eager Consumers

Consumers drain values from an iterator until it is exhausted.

| Word | Stack Effect | Purpose |
|------|-------------|---------|
| `#each` | `( iter quot -- )` | Execute quotation per element |
| `#reduce` | `( iter init quot -- value )` | Fold with accumulator |
| `#collect` | `( iter -- array )` | Materialize to array |
| `#count` | `( iter -- n )` | Count elements |

`#each` fires a side effect for every element:

```
{ 1 2 3 } >iterator [ . ] #each
```

Output:

```
1
2
3
```

`#reduce` folds elements with an accumulator. The accumulator starts as
the second argument; the quotation receives `( acc elem -- acc' )`:

```
{ 1 2 3 4 5 } >iterator 0 [ + ] #reduce .
```

Output:

```
15
```

`#count` exhausts the iterator and pushes the number of elements:

```
{ 1 2 3 4 5 } >iterator [ 3 > ] #filter #count .
```

Output:

```
2
```

## Chaining Pipelines

Adapters compose left-to-right. Each one wraps the previous iterator:

```
{ 1 2 3 4 5 6 7 8 9 10 } >iterator
  [ 2 * ] #map
  [ 10 > ] #filter
  2 #take
  #collect .
```

Output:

```
{ 12 14 }
```

The chain is fully lazy -- `#map` and `#filter` only run for elements that
`#take` actually pulls. Elements 1 through 5 are doubled and rejected by the
filter; element 6 produces 12 (passes); element 7 produces 14 (passes); then
`#take` stops. Elements 8-10 are never touched.

You can also combine `#drop` and `#take` for slicing:

```
{ 1 2 3 4 5 6 7 8 9 10 } >iterator 3 #drop 4 #take #collect .
```

Output:

```
{ 4 5 6 7 }
```

## Short-Circuit Consumers

`#any` and `#all` stop as soon as the answer is known:

```
{ 1 2 3 4 5 } [ 3 = ] #any .
{ 1 2 3 } [ 0 > ] #all .
{ 1 -1 3 } [ 0 > ] #all .
```

Output:

```
t
t
f
```

`#any` bails out with `t` when the predicate first succeeds; `#all` bails
out with `f` when the predicate first fails. Neither touches more elements
than necessary.

## Arrays vs Iterators

`#map` and `#filter` always return lazy iterators, even when called directly
on an array:

```
{ 1 2 3 } [ 2 * ] #map type-name .
```

Output:

```
"iterator"
```

Use `#collect` to materialize the result into an array.

`#take` and `#drop` behave differently depending on the input:

| Input | `#take` returns | `#drop` returns |
|-------|----------------|----------------|
| Array | Array | Array |
| Iterator | Iterator | Iterator |

```
{ 1 2 3 4 5 } 3 #take .
{ 1 2 3 4 5 } >iterator 3 #take #collect .
```

Output:

```
{ 1 2 3 }
{ 1 2 3 }
```

Same result, but the array version allocates immediately while the iterator
version is lazy.

## User-Defined Iterables

Any type can participate in the iterator protocol by implementing
`>iterator` via `method{`. Here is a wrapper type that iterates over its
inner array:

```
use "testing" ;

my-list: virtual{ array } ;

>iterator: method{ my-list } [
  unmake-my-list >iterator
] ;

{ 10 20 30 } >my-list >iterator [ 2 * ] #map #collect
{ 20 40 60 } "user-defined iterable pipeline" assert=
```

Once `>iterator` is registered, the full suite of adapters and consumers
works on `my-list` values.

## Iterator Cleanup

Some iterators hold resources -- file handles, database cursors, network
connections. `close-iterator` frees the iterator's resources without
draining remaining elements:

```
{ 1 2 3 } >iterator
dup #next drop
close-iterator
```

`with-iterator` fires a quotation and guarantees the iterator is closed
afterward, even if the quotation throws:

```
use "testing" ;

{ 1 2 3 4 5 } >iterator [ 2 #take #collect ] with-iterator
{ 1 2 } "with-iterator collects then closes" assert=
```

For simple array iterators the cleanup is a no-op, but the pattern matters
for resource-backed iterators -- file line iterators, database row iterators,
and similar.

See also: [Iterator Pipelines cookbook](../cookbook/iterator-pipelines.md)

The [next guide](concurrency.md) covers green threads and structured
concurrency.
