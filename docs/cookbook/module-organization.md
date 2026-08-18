# Module Organization

Modules split code across files, prevent name collisions, and keep the
global scope clean.

## Standard library imports

`use` loads a module from `lib/` by name:

```
use "strings" ;
use "math" ;
use "testing" ;
```

All exported words are brought into scope.

## Relative path imports

Load a local file with a relative path:

```
use "./helpers.1z" ;
```

## Selective imports

Import only the words you need. Names are symbols (trailing `:`):

```
use { split: trim: } "strings" ;
```

Only `split` and `trim` are in scope; other words from `strings` are not.

## Qualified access

Bind a module to a name with `load`, then use dot notation:

```
m: "math" load ;
m.pi .
m.sin
m.cos
```

Output:

```
3.141592653589793
```

Dot notation accesses module words without importing them into the current
scope. This avoids collisions when two modules export the same name.

## Re-importing a module

Importing the same module twice is not a conflict. The shadow check skips
names already bound from the same source module:

```
use "strings" ;
use "strings" ;   \ silent
```

If two different modules export the same word, importing both throws
`import-conflict`. Use `shadow-ok` when that shadowing is intentional:

```
use "./first.1z" ;
use "./second.1z" shadow-ok ;   \ second's words win
```

## Private helpers

Top-level definitions in a module are exported by default. Wrap helpers in a
`private{ ... }` block to keep them out of the module's public surface:

```
\ data/html.1z
use "strings" ;

private{
  (escape-char): ( char -- string ) [
    \ map a char to its HTML entity, or pass through
  ] ;
}

escape: ( string -- string ) [
  [ (escape-char) ] #map #collect "" #join
] ;
```

The public `escape` word can call `(escape-char)`, but a caller that does
`use "data/html"` sees only `escape`. Wrapping helper names in parens is a
stdlib convention that flags privacy at the call site; the language treats
`(foo)` as an ordinary identifier.

See also: [Modules guide](../guides/modules.md),
[Redefinition and Shadowing guide](../guides/redefinition-and-shadowing.md)
