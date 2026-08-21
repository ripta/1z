# User Startup Configuration

A startup file is ordinary 1z source the interpreter runs before your program.
It is where a word, an import, or a pragma you want in every session lives.
This guide covers where the file is looked for, which commands run it, what a
fault in it costs, and why it has nothing to do with `--prelude`.

## Where the File Lives

The interpreter takes the first of these it can determine:

1. `$ONEZ_STARTUP`, used exactly as given.
2. `$XDG_CONFIG_HOME/1z/startup.1z`.
3. `~/.config/1z/startup.1z`.

Two details are easy to guess wrong. `ONEZ_STARTUP` is a complete path rather
than a directory, so nothing appends `1z/startup.1z` to it and nothing checks
the extension. And the chain stops at the first rule that yields a path, not
at the first path that exists, so setting `XDG_CONFIG_HOME` retires the
`~/.config` branch whether or not the XDG file is there.

With neither `XDG_CONFIG_HOME` nor `HOME` set, there is no startup file. A
path that names nothing is silent: having no startup file is the common case,
not an error.

No command-line flag names the path, and there is no project-local startup
file. A user-level file is trusted because you wrote it, and that argument
does not carry over to a file that arrives with a repository you cloned.

The name ends in `.1z` because the file is source you will want to lint and
format like any other. Scanning a directory, `1z lint` takes files by that
suffix and skips dot-prefixed names, so a `~/.1zrc` would be invisible to it
twice over.

## What It May Contain

Anything you could type at the prompt. There is no restricted vocabulary and
no sandbox.

```
\ ~/.config/1z/startup.1z
pragma{ redefinition-arity-mismatch: "error" }

use "math" ;

half: ( n -- n ) [ 2 / ] ;
```

With that file in place:

```
./zig-out/bin/1z eval '10 half >string print-line 2.7 floor >string print-line'
```

Output:

```
5
2.0
```

The word it defined, the pragma it set, and the module it imported are all
live for the rest of the invocation.

Pragmas are the reason a startup file changes behavior rather than only adding
words. The REPL relaxes `redefinition-arity-mismatch` to `warning`, so
redefining a word at a different arity while iterating is quiet. It applies
that only when the startup file has not already set the key, so the file above
keeps the strict setting at the prompt.

Two keys go further. `dictionary-shadow` and `import-collision` relax the
redefinition collision guards. This file and a REPL prompt are the only two
places either may be set, and a source file that sets one throws. A relaxation
is a preference you hold for yourself, and program text is where it would stop
being one.

## Which Commands Run It

| Command | Runs the startup file |
|---------|-----------------------|
| `run`, including bare `1z <file>` and shebang scripts | yes |
| `eval` | yes |
| `test` | yes |
| `check` | yes |
| `repl`, interactive or piped | yes |
| `lint`, `highlight` | no |
| `fmt` | no |
| `build` | no |
| `inspect` | no |
| `version` | no |

One question decides the column: does the command execute code you wrote? If
it does, your configuration applies. If it exists to inspect, format, analyze
on the tool's own behalf, or produce an artifact, it does not.

That boundary is what makes a startup file safe to write. `lint` and
`highlight` are themselves 1z programs, so a redefinition reaching inside them
would break the tool rather than serve you. `build` freezes a program into an
executable, and a preference that entered there would ship to everyone who
runs the binary.

`check` is the placement that looks surprising, since it does not run your
program. It does run inference against the live dictionary, so leaving it out
would produce this on every caller of a startup-defined word:

```
\ app.1z
quarter: ( n -- n ) [ half half ] ;
```

```
./zig-out/bin/1z check --no-startup app.1z
```

Output:

```
app.1z:2: warning: quarter: cannot verify quarter: callee half has unknown effect
```

Drop the `--no-startup` and the warning goes with it, because `half` is now a
word the checker can see. A checker that disagrees with the runtime about what
exists is worse than one that sees a little more.

## When Something Goes Wrong

A fault prints one diagnostic naming the startup file, abandons the rest of
the file, and lets the invocation continue. The exit code reflects your
program rather than the startup file.

Given a file that faults partway through:

```
\ ~/.config/1z/startup.1z
before-fault: ( -- s ) [ "defined before the fault" ] ;

1 0 /

after-fault: ( -- s ) [ "never defined" ] ;
```

Any command in the executing set reports the fault on stderr and carries on:

```
/home/u/.config/1z/startup.1z:4: error 'division-by-zero' at word '/'
  stack effect: ( a b -- a/b )
```

`before-fault` is defined for the session and `after-fault` is not. Statements
above the fault have already applied and nothing rolls them back, so a
`pragma{ }` on an earlier line stays in effect. Reading stops at the fault
rather than continuing statement by statement, because a broken import makes
every line below it fail too and only the first message would tell you
anything.

A path the chain names but that does not exist is silent. A path that exists
and cannot be read is not:

```
Error: cannot read startup file '/home/u/.config/1z/startup.1z': error.AccessDenied
```

## Skipping It

Two controls, both meaning skip:

- `--no-startup`, a global flag every subcommand accepts.
- `ONEZ_NO_STARTUP`, for a harness that sets it once for a whole run instead
  of threading a flag through every invocation it makes.

The variable skips on presence. Its value is never read, so
`ONEZ_NO_STARTUP=0` and `ONEZ_NO_STARTUP=` skip exactly as `ONEZ_NO_STARTUP=1`
does.

A skip beats an explicit `ONEZ_STARTUP`, with no exception. Skip means skip,
so a harness that sets the variable has a guarantee with no cases in it.

The flag's everyday use is bisecting. When a program behaves oddly, run it
once with `--no-startup`. If the oddity goes away, your configuration caused
it.

```
./zig-out/bin/1z run --no-startup app.1z
```

## It Gets Its Own Scope

The startup file executes in a frame of its own, pushed above the prelude's
and never popped. That frame is both the import target for the file's `use`
statements and the floor that later definitions land on.

The payoff is attribution. A definition that collides with a startup word
names the startup file by path:

```
> half: ( n -- n ) [ 3 / ] ;
<repl>:1: error 'import-conflict' defining 'half' would shadow a word from "/home/u/.config/1z/startup.1z" at word ';'
  stack effect: ( name quot --  )
  hint: add the 'override' marker if intentional
```

Defining into the prelude's own frame would have been simpler, and would have
made that message blame the prelude. The hazard a startup file carries is that
your own configuration silently changes what a program means, so being able to
trace a word back to it is worth the frame.

The frame has a consequence for the file itself. Being the floor is what makes
a startup file that shadows a prelude word trip the guard on its own
definition. `dictionary-shadow` is the way out. `pragma{ }` takes effect while
the file is parsed, so put the key on a line above the definition it covers.

[Redefinition and Shadowing](redefinition-and-shadowing.md) covers that error,
the `override` marker that escapes it, and both relaxing keys.

## Independent of `--prelude`

`--prelude=PATH`, and its `ONEZ_PRELUDE` equivalent, substitutes the prelude:
the file of core word definitions the interpreter loads before anything else.
It is the nearest-looking mechanism, and it is a different one.

The two do not interact. A substituted prelude neither suppresses the startup
file nor changes how it is read, and skipping the startup file has no effect
on which prelude loads.

The ordering between them is forced rather than chosen. The startup file runs
after whatever prelude loaded, because it needs prelude words. `use` is itself
defined in the prelude.

That has one visible consequence. `--prelude=/dev/null` gives you a bare
interpreter with no prelude words at all, so the startup file above fails at
its first one:

```
./zig-out/bin/1z eval --prelude=/dev/null '1 2 +'
```

Output:

```
/home/u/.config/1z/startup.1z:4: error 'unknown-word' at word 'use'
```

The expression still evaluates. Bare mode costs one line on stderr rather than
becoming conditional on having no startup file. A startup file written against
the primitives works there instead: `import`, `load-file`, and `>module` are
all native, and only the `use` sugar over them is prelude.

See also: [Modules](modules.md),
[Redefinition and Shadowing](redefinition-and-shadowing.md),
[Standard Library Resolution](stdlib-resolution.md)
