# Modules

Modules let you split code across files and control what names are visible
where. A module is a first-class value -- you can store it, inspect it, and
import words from it selectively.

## Importing with `use`

The simplest way to load a module is `use`:

```
use "testing" ;
```

This loads `lib/testing.1z` from the standard library search path, runs it,
and pulls all of its exported words into the current scope. The `;` at the
end is required.

Relative paths work too:

```
use "./helpers.1z" ;
```

`use` is strict by default -- if an imported word would shadow an existing
name in scope, it throws. This catches accidental name collisions early.

## Loading Without Importing

`load` drops the module on the stack as a value without importing anything:

```
"module_lib.1z" load
```

The module sits on the stack. You can stash it in a variable:

```
math: "module_lib.1z" load ;
```

Then import from it explicitly:

```
math: "module_lib.1z" load ;
math import
5 double .
```

Output:

```
10
```

The separation matters when you want to control exactly when and what gets
imported.

## Qualified Access

Bind a module to a name with `load`, then use dot notation to call its words
without importing them:

```
math: "module_lib.1z" load ;
5 math.double .
3 math.triple .
```

Output:

```
10
9
```

Qualified access keeps your local scope clean. The module's words are
reachable but do not pollute your namespace. Referencing a word that does not
exist in the module throws.

## Selective Import

Import only the words you need:

```
use { double: triple: } "module_lib.1z" ;
5 double .
```

Output:

```
10
```

Or with `import` on a loaded module:

```
math: "module_lib.1z" load ;
math { squared: } import
4 squared .
```

Output:

```
16
```

Only the named words land in scope. Everything else in the module stays
hidden. Requesting a word that does not exist throws `EKeyNotFound`.

## Shadowing and `shadow-ok`

By default, `use` refuses to pull in a word that already exists in scope:

```
double: ( n -- n ) [ 2 + ] ;
use "module_lib.1z" ;  \ error: use would shadow existing words: double
```

The check throws `import-conflict` before anything is imported, and it
names every conflicting word at once. The `shadow-ok` marker silences it:

```
double: ( n -- n ) [ 2 + ] ;
use "module_lib.1z" shadow-ok ;  \ fine; the module's double wins
```

Importing the same module twice is not a conflict. Names already bound
from the same source module are skipped, so `shadow-ok` is only needed
when the shadowing crosses modules and is intentional.

`borrow`, `private{`, and `reexport` run the same check, each with its own
release valve. The [Redefinition and Shadowing
guide](redefinition-and-shadowing.md) covers the full model, including the
definition-side guards and the `override` marker.

## Private Helpers

Top-level definitions in a module file are exported. If you want a helper
that the module's own public words can call but importers cannot, wrap it in
a `private{ ... }` block:

```
\ data/html.1z
use "strings" ;

private{
  (escapes): H{
    "&" "&amp;"
    "<" "&lt;"
    ">" "&gt;"
    "\"" "&quot;"
    "'" "&#39;"
  } ;

  (escape-char): ( char -- string ) [
    dup (escapes) -rot> @get-or
  ] ;
}

escape: ( string -- string ) [
  [ (escape-char) ] #map #collect "" #join
] ;
```

A caller that does `use "data/html"` gets `escape` in scope, but not
`(escapes)` or `(escape-char)`. The parens around helper names are a
convention used throughout the standard library to flag privacy visually at
every call site; the language treats `(foo)` as an ordinary identifier.

Private names land in the same scope as the module's public words, so a
helper colliding with a public word throws `import-conflict`, and a
failing block imports nothing. When the collision is intentional, the
`private(shadow-ok){ ... }` variant suppresses the check.

`private(shadow-ok){` is sugar over the prelude word `import-locals`,
which itself wraps `local-scope`. `local-scope` snapshots the topmost
local frame as a module value; `import-locals` runs a quotation in a
fresh frame and routes the snapshot into the enclosing module's private
deps. The plain `private{` runs the shadow check between the snapshot and
the import. Reach for `import-locals` directly when you need to build a
private scope dynamically rather than through the block syntax, keeping
in mind that it runs no shadow check.

## Module Introspection

Modules respond to the standard collection accessors:

| Word | Stack Effect | Purpose |
|------|-------------|---------|
| `@has?` | `( module key -- bool )` | Check if word exists |
| `@keys` | `( module -- array )` | List exported word names |
| `#len` | `( module -- n )` | Count exported words |
| `@get` | `( module key -- quot )` | Retrieve word as quotation |
| `@get-or` | `( module key fallback -- quot/fallback )` | Retrieve with fallback |

Keys can be symbols or strings:

```
math: "module_lib.1z" load ;
math double: @has? .
math @keys .
math #len .
```

Output:

```
t
{ double: triple: squared: }
3
```

You can pluck a word out and fire it dynamically:

```
math: "module_lib.1z" load ;
math double: @get 5 swap call .
```

Output:

```
10
```

## Hierarchical Paths

Module paths can include subdirectories. The resolver searches the standard
library and the current directory:

```
use "net/tcp" ;
```

This loads `lib/net/tcp.1z`. Subdirectories group related modules without
flattening everything into one directory.

## `export` and `reexport`

By default, every word defined at the top level of a module file is exported.
`reexport` reëxports all words from another module as though they were
defined locally:

```
\ in facade.1z
"helpers.1z" load reexport
```

Now anyone who imports `facade.1z` gets the helpers module's words too. Handy
for assembling a public API from multiple internal pieces.

`reexport` runs the shadow check like `use` does. Because it is an inline
expression with no terminating `;`, its release valve is a variant word
rather than a trailing marker: `"helpers.1z" load reexport(shadow-ok)`.

## Caching and `reload`

Modules are cached after the first `load`. Loading the same path twice
returns the same module value -- the file is not reëxecuted:

```
"module_lib.1z" load
"module_lib.1z" load
\ same module value both times
```

`reload` bypasses the cache and reëxecutes the file:

```
"module_lib.1z" reload
```

Mostly useful during REPL development when you are editing a module and want
to pick up changes without restarting.

See also: [Module Organization cookbook](../cookbook/module-organization.md)

The [next guide](redefinition-and-shadowing.md) covers the collision guard
that backs the shadow check, and the `override` marker.
