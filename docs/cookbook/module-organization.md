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

## Suppressing shadow warnings

If two modules export the same word, importing both raises a shadow warning.
Use `shadow-ok` when the shadowing is intentional:

```
use "strings" ;
use "strings" shadow-ok ;   \ no warning
```

See also: [Modules guide](../guides/modules.md)
