# Redefinition and Shadowing

Redefining your own word is ordinary and silent. Two other collisions used
to be silent too, and are now loud: a definition and an import landing on
the same name, and a top-level definition shadowing a prelude or native
word. Both throw `import-conflict`. A third silent loss is loud as well: a
redefinition that drops registered methods throws `orphaned-methods`. This
guide covers the two collision kinds, the orphaned-method report, the
permission that escapes them, the release valve each importing construct
provides, and the two pragmas that relax the collision kinds for your own
environment.

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
never fires on it. Two separate diagnostics can still fire here: the arity
check, when both definitions declare stack effects and the arities
disagree, and the orphaned-method report below, when the word being
replaced owns registered methods.

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

## Redefinition That Drops Registered Methods

A word that owns `method{` registrations is a dispatch surface, not just a
binding. Redefining it in the same scope gives the name a fresh dispatch
identity, so every registered method becomes unreachable, and nothing
later throws to say so. That silent loss is reported at the redefinition,
naming how many methods it would drop:

```
area: generic ( x -- n ) [ drop 0 ] ;
area: method{ fixnum } [ drop 42 ] ;
area: ( x -- n ) [ drop 7 ] ;
```

Output:

```
main.1z:3: error 'orphaned-methods' redefining 'area' would drop 1 registered method at word ';'
  stack effect: ( name quot --  )
  hint: add the 'override' marker if intentional
```

A deliberate replacement claims `override`, exactly as with the collision
kinds:

```
area: override ( x -- n ) [ drop 7 ] ;
```

Two things distinguish this report from the collision kinds. There is no
generic exemption: a `generic` redefinition of a `generic` word drops the
methods all the same, so it throws too. And no pragma downgrades it, unlike
the arity check and both collision kinds. The collision kinds report a
visibility surprise the program survives, while this one reports a
correctness loss nothing later throws about, so a program that relaxed it
would never learn what it gave up.

A generated existing word is exempt, exactly as it is for the arity check.
Replacing a `virtual{` or `struct{` constructor with a convenience version
is an established pattern, and the entries the generator registered under
it are scaffolding of the word being replaced, not user methods.

A shadow in a nested frame is not a redefinition. It takes a fresh
identity of its own, leaves the outer generic's methods intact, and the
outer generic answers again when the frame pops.

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

`override` escapes all three definition-side guards: defining over an
import, shadowing a prelude or native word, and a redefinition that drops
registered methods. The claim sits in the source at the exact place the
overwrite happens, so a reader sees the intent without tracing any
imports.

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

## Relaxing the Guards for Your Own Environment

Every valve above is per-site. It is written where the collision happens,
so a reader of that line sees the claim. Two pragmas relax the collision
kinds per-environment instead. They exist for a user who wants their own
sessions looser, not for a program tuning its own severity.

### The Two Keys

One key per collision kind:

| Key | Guard it relaxes |
|-----|------------------|
| `dictionary-shadow` | a top-level definition shadowing a prelude or native word |
| `import-collision` | a definition and an import colliding, in either order |

Each takes a severity word -- `"error"`, `"warning"`, or `"off"` -- or an
array of word-name symbols. An unset key reads as `"error"`, which is the
severity both guards ship with.

```
\ ~/.config/1z/startup.1z
pragma{ dictionary-shadow: "warning" }
```

```
nip: ( -- n ) [ 9 ] ;
nip .
```

The definition stands and `9` prints. On stderr:

```
warning: defining 'nip' would shadow a word from "src/prelude.1z"
```

A warning carries no `override` hint. You already chose the relaxation, so
the marker is not what you are looking for.

An allowlist relaxes exactly the names on it:

```
\ ~/.config/1z/startup.1z
pragma{ dictionary-shadow: { nip: } }
```

`nip:` now defines silently, and `dup:` still throws. That is what a list
buys over a bare `"off"`: a word you meant to shadow goes quiet, and one
you mistyped does not. The list doubles as a record of what you shadowed.

The names are symbols rather than strings, because a word name is a symbol
everywhere else in the language. `{ "nip" }` is rejected.

The two keys are separate because the two guards catch different mistakes.
Relaxing prelude shadowing must not also silence a definition and an import
colliding, which is a local mistake in nearly every instance.

### Where a Set Is Accepted

A startup file and a REPL prompt. Nothing else. A source file throws:

```
\ app.1z
pragma{ dictionary-shadow: "off" }
```

Output:

```
app.1z:2: error 'pragma-error' dictionary-shadow: may be set only from a startup file or a REPL prompt, not from a source file
```

An `eval` string is refused on the same terms. So is a module the startup
file loads, since a module is a source file whoever loads it.

The rule rests on the same argument as the `override` marker. A relaxation
written in program text is authorized by its author. It is met by every
later reader of that file, who inherits a dialect they did not choose. A
startup file is a preference you hold across sessions. A prompt is one you
hold for the next few minutes. Neither reaches anyone else.

A startup file that shadows a prelude word trips the guard itself, because
its own frame is the durable floor. `pragma{ }` takes effect while the file
is parsed, so put the key on a line above the definition it covers.

### What the Keys Do Not Reach

Neither key relaxes the orphaned-method error. A relaxed collision is a
visibility surprise the program survives once you accept it. Dropped
methods are a correctness loss nothing later throws about, so a user who
relaxed that would never learn what they gave up.

Neither key reaches a build artifact. `build` does not run the startup
file. A source file cannot set a key. Between them, a build reaches no set
at all. An AOT binary reads no startup file either, so both guards run at
their default severity for the life of the binary.

One consequence is worth stating plainly. A program that runs clean under
`1z run` with a relaxed startup file does not build. A build executes the
entry file's definition statements as it loads the program, so a top-level
collision throws during `1z build` itself and no binary is produced.

A collision the build does not reach waits for the binary to run instead. A
definition inside a word body is the shape that does this: the build defines
the enclosing word and records the call to it rather than making it.

Either way the failure is a loud throw naming the collision, never silence.
The preference belongs to you rather than to the artifact.

## The Interaction Matrix

A same-name collision between an existing word and an incoming binding --
a definition or an import -- resolves as follows:

| Condition | Outcome |
|-----------|---------|
| existing word is `const` | error -- no claim gets past it |
| incoming binding claims the permission (`shadow-ok` / `override`) | allowed |
| definition and import cross, no claim | `import-conflict` |
| top-level definition shadows a prelude or native word, no claim | `import-conflict` |
| same-scope redefinition drops registered methods, no claim | `orphaned-methods` |
| ordinary redefinition of your own word | silent |
| both existing and incoming are `generic` | exempt from the collision kinds -- method contributions merge |

`const` blocks absolutely, a claim allows, and otherwise the conflict rows
throw. The rules never contradict: `const` and a claim never both apply to
a permitted case.

The two `import-conflict` rows report at their key's severity, which is
`error` until a startup file or a prompt relaxes it. Nothing else in the
table moves. `const` still blocks, a claim still allows, and the
orphaned-method row has no key at all.

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
Both collision guards skip when the existing and the incoming word are
both `generic`, so a module contributing `method{` arms to a shared
generic imports cleanly.

The orphaned-method report does not share the exemption. A generic
redefinition of a generic word still gives the name a fresh dispatch
identity and drops the registered methods, so it throws without an
`override` claim.

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

The guards fire at the REPL exactly as they do in a file, and `override`
is the escape in each. Redefining your own word, which is what REPL
iteration consists of, stays silent. What the guard catches interactively
is the same thing it catches in a file: `dup: [ ... ] ;` throws until it
claims `override`. A session that works can therefore be pasted into a
file unchanged.

A prompt is also one of the two places the relaxing keys may be set, so
`pragma{ dictionary-shadow: "off" }` is a legal line to type. Setting
`"error"` again restores the default. A key set at a prompt lasts for the
session and no longer, so a session that leaned on one is the exception to
pasting out unchanged.

See also: [Modules](modules.md),
[Defining Words](../tutorials/defining-words.md)

The [next guide](iterators.md) covers lazy iteration and sequence
pipelines.
