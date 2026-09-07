# Code Formatting

The formatter rewrites source to one canonical shape: indentation, spacing
around brackets and stack effects, blank-line compression, and two alignment
passes that line up inline comments and definition columns. Run it with no
configuration and every 1z file in the world comes out the same way.

A project that wants different rules puts a `.fmt.1z` file in its root. This
guide covers what goes in that file and how the formatter finds it.

The rules here are read by the `formatter` library, described under
[Formatting from 1z](#formatting-from-1z) below. The `1z fmt` subcommand still
runs the interpreter's own built-in formatter, which always applies the
defaults and does not read `.fmt.1z`.

## The config file

`.fmt.1z` holds a single hash literal whose keys name formatting rules:

```
H{
  "indent-size"    4
  "align-symbols"  f
}
```

Every key is optional. A key the file omits keeps its default, so the file
above changes two rules and leaves the other five alone.

The file is read as data, not run as a program. It may hold literals and
parse-time constructors -- `H{ }`, `V{ }`, `S{ }`, arrays -- and nothing else.
A word call in it is rejected, so a config file can never execute anything.

## The rules

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `indent-size` | number | `2` | Spaces per nesting level |
| `max-blank-lines` | number | `1` | Consecutive blank lines preserved |
| `align-comments` | flag | `t` | Line up a run of inline comments on one column |
| `align-symbols` | flag | `t` | Line up a run of definitions on shared columns |
| `align-min-group` | number | `3` | Consecutive lines needed before symbol alignment runs |
| `align-max-padding` | number | `15` | How far names may diverge inside one aligned group |
| `trailing-newline` | flag | `t` | End the file with a newline |

Numbers must be non-negative. Flags must be `t` or `f`.

Spacing inside a stack effect -- `( a b -- c )` -- has one canonical form and is
not configurable.

### `max-blank-lines`

The cap counts blank lines, not line breaks. At `1`, any run of blank lines
between two statements collapses to one. At `0`, statements end up adjacent. At
`3`, up to three survive.

Two positions ignore the cap because they are structural rather than
stylistic. No blank line is ever inserted before a `;` or inside a stack
effect, and a blank line never separates a definition's name from its body.

### `align-min-group`

Symbol alignment only fires on a run of consecutive, similarly-shaped lines.
Below the minimum, the lines come out exactly as they went in. Lowering it to
`2` aligns pairs; raising it past a run's length turns alignment off for that
run.

### `align-max-padding`

Inside an aligned run, a name much longer than its neighbours would push every
other line far to the right. The formatter splits the run instead. A candidate
joins the group while the spread between the longest and shortest name so far
stays within the limit.

The effective limit is the smaller of this value and the shortest name in the
group so far, so raising it above `15` only changes runs whose names are all
long. Lowering it to `0` splits on any difference at all, which turns symbol
alignment off in practice.

### `trailing-newline`

At `t`, a formatted file ends with exactly one newline. At `f`, it ends with
none, whatever the source did. An empty or whitespace-only file formats to
nothing under both settings.

## How the file is found

The formatter starts at the directory of the file it is formatting and walks
upward, taking the first `.fmt.1z` it meets. Formatting `lib/net/http.1z` from
a project root therefore picks up the project's `.fmt.1z`, and so does
formatting `main.1z` beside it.

The walk stops at the filesystem root for an absolute path, and at the working
directory for a relative one. Formatting `lib/net/http.1z` from the project
root will not reach a `.fmt.1z` above that root.

Nothing is merged. The first file found supplies every key it names, and the
defaults supply the rest. A `.fmt.1z` in a subdirectory replaces the project's
rather than layering on top of it.

## Errors

A config file is checked before any of it takes effect. Three things are
rejected, each naming the key and the file:

An unknown key. This catches a typo, which would otherwise leave a rule at its
default with no sign that anything went wrong:

```
unknown key 'indent-sizes' in .fmt.1z; known keys are align-comments,
align-max-padding, align-min-group, align-symbols, indent-size,
max-blank-lines, trailing-newline
```

A value of the wrong type:

```
key 'indent-size' in .fmt.1z must be a non-negative fixnum, got "four"
key 'align-symbols' in .fmt.1z must be t or f, got 1
```

And a negative number, which reaches the same message as a wrong type.

A file that evaluates to something other than a hash is rejected too, by the
config reader underneath.

## Formatting from 1z

The formatter is a library, and a program can call it directly:

```
use "formatter" ;

"tests/fixtures/example.1z" format-file print
```

`format-file` finds and applies the `.fmt.1z` for the path it is given.
`format-source` formats a string in hand and applies whatever config is bound
around it, which is the defaults unless you say otherwise:

```
use "formatter" ;

"double: ( n -- n ) [ 2 * ] ;" format-source print
```

To format under rules of your own, bind `current-fmt-config`:

```
use "formatter" ;

default-fmt-config >hash "indent-size" 4 @set >fmt-config
current-fmt-config
[ "foo: [\n1\n] ;\n" format-source print ]
with-parameter
```

`fmt-config` is immutable, so the round trip through its hash is how one rule
gets varied. `load-fmt-config` reads a config from a path you name, and
`fmt-config-for` runs the upward search over a directory and falls back to the
defaults.
