# String Processing

Splitting, joining, formatting, and character-level operations. String
utilities live in `lib/strings.1z`.

## Splitting and joining

`split` breaks a string by a delimiter, keeping empty segments. `#join`
reassembles:

```
use "strings" ;

"a,b,c" "," split .
{ "a" "b" "c" } ", " #join .
```

Output:

```
{ "a" "b" "c" }
"a, b, c"
```

Empty segments are preserved:

```
use "strings" ;

"a,,b" "," split .
```

Output:

```
{ "a" "" "b" }
```

## Trimming

`trim`, `ltrim`, and `rtrim` strip ASCII whitespace:

```
use "strings" ;

"  hello  " trim .
```

Output:

```
"hello"
```

## Template formatting

`fmt` parses a template string and interpolates values from the source on
the stack.

Identity placeholder -- uses the source value directly:

```
42 "The answer is {}." fmt .
```

Output:

```
"The answer is 42."
```

Named placeholders -- keys from a hash:

```
H{ item: "widget" qty: 5 } "Order: {qty}x {item}" fmt .
```

Output:

```
"Order: 5x widget"
```

Indexed placeholders -- positions from an array:

```
{ "Alice" "Bob" } "{0} and {1}" fmt .
```

Output:

```
"Alice and Bob"
```

## Format specifiers

Width and fill for padding:

```
H{ n: 7 } "{n:width=3,fill=0}" fmt .
```

Output:

```
"007"
```

## Character iteration

Strings are sequences. `#len`, `#nth`, `#map`, and `#each` all work:

```
"hello" #len .
"abc" [ ] #map #collect .
```

Output:

```
5
{ "a" "b" "c" }
```

## Case conversion

```
"hello" uppercase .
"HELLO" lowercase .
```

Output:

```
"HELLO"
"hello"
```
