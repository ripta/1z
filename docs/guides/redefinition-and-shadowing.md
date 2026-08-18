# Redefinition and Shadowing

Redefining your own word is ordinary and silent. Two other collisions used
to be silent too, and are now loud: a definition and an import landing on
the same name, and a top-level definition shadowing a prelude or native
word. Both throw `import-conflict`. This guide covers the two collision
kinds, the permission that escapes them, and the release valve each
importing construct provides.

## Ordinary Redefinition Stays Silent

Redefining a word you defined yourself, in the same scope, is not a
collision:

```
counter: ( -- n ) [ 0 ] ;
counter: ( -- n ) [ 1 ] ;
counter .
```

Output:

```
1
```

This is how iterative development works, especially at the REPL. The guard
never fires on it. The only diagnostic that can fire here is the separate
arity check, when both definitions declare stack effects and the arities
disagree.

## The Two Collision Kinds

### A Definition and an Import Collide

The first collision kind is a definition and an import occupying one name
in one scope. It has two orders, and both throw.

An import landing on an existing definition is caught by the import-side
check:

```
\ helpers.1z
double: ( n -- n ) [ 2 * ] ;
```

```
double: ( n -- n ) [ 2 + ] ;
use "./helpers.1z" ;
```

Output:

```
main.1z:2: error 'import-conflict' use would shadow existing words: double
```

The check runs before anything is written, so a failing import leaves the
scope untouched. It also reports every conflicting name at once, not just
the first.

A definition landing on an existing import is the symmetric order, caught
when `;` finalizes the definition:

```
use "./helpers.1z" ;
double: ( n -- n ) [ 2 + ] ;
```

Output:

```
main.1z:2: error 'import-conflict' defining 'double' would overwrite a word imported from "helpers.1z" at word ';'
  stack effect: ( name quot --  )
  hint: add the 'override' marker if intentional
```

Generated definitions are not exempt. A `struct{` field accessor, an enum
variant word, or a virtual type constructor landing on an imported name
throws like any other definition. A generated word has no place to claim
`override`, so the escape is structural: rename the field, or narrow the
import so the name is not taken.

### Shadowing a Prelude or Native Word

The second collision kind is a top-level definition whose name resolves in
the base scope -- the prelude or the native dictionary:

```
dup: ( -- x ) [ 0 ] ;
```

Output:

```
main.1z:1: error 'import-conflict' defining 'dup' would shadow a native word at word ';'
  stack effect: ( name quot --  )
  hint: add the 'override' marker if intentional
```

A prelude word reports its source file instead:
`defining 'nip' would shadow a word from "src/prelude.1z"`.

This guard exists because an unmarked shadow breaks a program partially.
Call sites that resolved before the shadow keep the original behavior,
while code parsed after it sees the new binding. The failure then shows up
far from the definition that caused it, often as a stack underflow in an
unrelated expression.

The guard applies to definitions that land in the durable top-level scope:
a file's top level, a module's top level, and definitions made inside a
word body, which persist after the word returns.

### What Stays Legal

A binding in a transient frame is a new binding, not a collision. A
definition inside a quotation invoked with `call` lands in the quotation's
own frame and disappears when the frame pops:

```
[ nip: ( -- y ) [ 42 ] ; nip ] call .
1 2 nip .
```

Output:

```
42
2
```

A module defining a name the loading file also defines is not a collision
either. Each file's own top level is compared against the scopes below it,
not against its loaders.

## The `override` Marker

A deliberate replacement says so at the definition, with the `override`
marker between the name and the body:

```
use "./helpers.1z" ;
double: override ( n -- n ) [ 2 + ] ;
5 double .
```

Output:

```
7
```

`override` escapes both definition-side guards: defining over an import,
and shadowing a prelude or native word. The claim sits in the source at the
exact place the overwrite happens, so a reader sees the intent without
tracing any imports.

## Release Valves

Each construct that runs the shadow check has a valve for the deliberate
case. The valve's form follows the construct's shape: a construct
terminated by `;` takes a trailing `shadow-ok`, and an unterminated one
takes a variant word.

| Construct | Valve |
|-----------|-------|
| `use` | `use "mod" shadow-ok ;` |
| `borrow` | `borrow "mod" shadow-ok ;` |
| `reexport` | `"mod" load reexport(shadow-ok)` |
| `private{ ... }` | `private(shadow-ok){ ... }` |
| definition (`name:`) | `name: override [ ... ] ;` |
| raw `import`, `import-locals` | none -- these are the unguarded bypass |

Every valve is a word reference, not a string the construct compares. A
misspelled valve like `private(shadowok){` is therefore an `unknown-word`
error rather than a check that silently fails open.

The raw `import` native and `import-locals` run no check by design. They
are the low-level seam the guarded constructs are built from, and the
bypass of last resort.

## One Permission, on the Incoming Binding

All five valves spell one concept: this incoming binding may overwrite.
The permission always sits on the thing being introduced -- the import
claims `shadow-ok`, the definition claims `override`.

There is deliberately no permission on the existing word, no "I may be
overwritten" marker. A relaxation placed there would disable the guard for
every future overwriter of that word, so the person authorizing the
surprise would not be the person meeting it. The guard exists to make a
collision loud at the site that causes it, and only a claim on the
overwriter preserves that.

`const` on the existing word is not that permission's opposite number. It
is a restriction, and adding it can only make a program fail earlier.

If what you want is a word others extend deliberately, redefinition is the
wrong tool. Define the word `generic` and let extenders register `method{`
arms; no name is overwritten and no valve is needed.

## The Interaction Matrix

A same-name collision between an existing word and an incoming binding --
a definition or an import -- resolves as follows:

| Condition | Outcome |
|-----------|---------|
| existing word is `const` | error -- no claim gets past it |
| incoming binding claims the permission (`shadow-ok` / `override`) | allowed |
| definition and import cross, no claim | `import-conflict` |
| top-level definition shadows a prelude or native word, no claim | `import-conflict` |
| ordinary redefinition of your own word | silent |
| both existing and incoming are `generic` | exempt -- method contributions merge |

`const` blocks absolutely, a claim allows, and otherwise the two conflict
rows throw. The rules never contradict: `const` and a claim never both
apply to a permitted case.

## `const` Is Absolute

`const` beats every claim, `override` included. An imported word's `const`
marker travels into the importing scope and keeps blocking there, so an
imported `const` consumes that name permanently.

The escape is structural rather than a marker: a selective import leaves
the name free.

```
\ limits.1z defines: LIMIT: const [ 42 ] ; and plain: [ 1 ] ;
use { plain: } "./limits.1z" ;
LIMIT: [ 99 ] ;
LIMIT .
```

Output:

```
99
```

## The Generic Exemption

Two `generic` words of one name are one extension point, not a collision.
Every guard skips when both the existing and the incoming word are
`generic`, so a module contributing `method{` arms to a shared generic
imports cleanly.

The exemption is not an override claim, and the two do opposite things. On
an import, the exemption keeps the existing binding and drops the incoming
one; nothing is lost, because methods live in the dispatch table rather
than on the binding. A claim lets the incoming binding win. For the same
reason, `generic` does not imply the claim: a generic definition landing on
a plain word, or a plain definition landing on a generic one, still throws.

## Re-importing Is Not a Conflict

A name already bound from the same source module is skipped by the check,
so importing one module twice is silent:

```
use "time" ;
use "time" ;
```

The same rule covers the diamond, where a module you import and your own
file both `use` a third module. `shadow-ok` is only needed when two
different modules export the same name and the shadowing is intentional.

## The REPL Behaves Like a File

Both guards fire at the REPL exactly as they do in a file, and `override`
is the escape in both. Redefining your own word, which is what REPL
iteration consists of, stays silent. What the guard catches interactively
is the same thing it catches in a file: `dup: [ ... ] ;` throws until it
claims `override`. A session that works can therefore be pasted into a
file unchanged.

See also: [Modules](modules.md),
[Defining Words](../tutorials/defining-words.md)

The [next guide](iterators.md) covers lazy iteration and sequence
pipelines.
