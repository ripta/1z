# Iterator Pipelines

Higher-order sequence words (`#map`, `#filter`, etc.) return lazy iterators.
Chain them freely -- no intermediate arrays are allocated until you
materialize with `#collect`. This makes pipelines efficient and composable.

## Map, filter, collect

A typical pipeline: transform, filter, materialize.

```
{ 1 2 3 4 5 }
  [ 2 * ] #map
  [ 5 > ] #filter
  #collect .
```

Output:

```
{ 6 8 10 }
```

## Reduce for aggregation

`#reduce` folds left-to-right with an initial accumulator:

```
{ 1 2 3 4 5 } 0 [ + ] #reduce .
```

Output:

```
15
```

## Take and drop for windowing

`#take` returns the first N elements. `#drop` skips them:

```
use "sequences" ;

{ 10 20 30 40 50 } >iterator 3 #take #collect .
{ 10 20 30 40 50 } >iterator 2 #drop #collect .
```

Output:

```
{ 10 20 30 }
{ 30 40 50 }
```

## Partition and group-by

`#partition` splits a sequence into two arrays based on a predicate.
The true-arr (passing elements) sits deeper; the false-arr is on top:

```
use "sequences" ;

{ 1 2 3 4 5 6 } [ even? ] #partition
\ stack: true-arr false-arr
```

`#group-by` returns a hash keyed by whatever the quotation computes:

```
{ "apple" "avocado" "banana" "cherry" }
  [ 0 #nth >string ] #group-by
"a" @get .
```

Output:

```
{ "apple" "avocado" }
```

## Infinite ranges

`range-from` creates an infinite range. Convert to an iterator, chain
adapters, then `#take` to bound it:

```
use "ranges" ;

0 range-from >iterator [ 2 * ] #map 5 #take #collect .
```

Output:

```
{ 0 2 4 6 8 }
```

## Composing adapters

Stack multiple lazy adapters before materializing. Nothing runs until
`#collect` pulls values through the entire pipeline:

```
use "ranges" ;
use "sequences" ;

10 iota >iterator
  [ 2 * ] #map
  [ 3 % 0 = ] #filter
  2 #drop
  #collect .
```

Output:

```
{ 12 18 }
```

## `#each` vs `#reduce`

Use `#reduce` when you want a single computed value. Use `#each` when you
want side effects (printing, accumulating into a mutable container):

```
\ Compute a sum:
{ 1 2 3 } 0 [ + ] #reduce .
```

Output:

```
6
```

See also: [Iterators and Sequences guide](../guides/iterators.md)
