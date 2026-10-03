# Data-Only Config Files

Several tools read settings from a file written in 1z literal syntax. The
formatter reads `.fmt.1z`, `1z highlight` reads a theme file, `load-catalog`
reads one message file per locale, and the API reference generator reads
`1z.conf`. All of them go through the same reader, `parse-config-data` in the
`config` library, and this guide describes what that reader accepts.

The file is read as data and never run. The reader tokenizes it and builds
values from the grammar below. It does not hand the text to the language's
parser, so no word in the file executes, parse-time words such as `use`
included. A file that reaches for anything outside the grammar is rejected
rather than partly honoured.

`load-config-eval` is the other loader in the `config` library. It runs its
file as a program inside a sandbox the caller supplies, and nothing here
applies to it.

## The grammar

A file holds exactly one value:

```
config := value
value  := string | number | symbol | t | f
        | "{"  value* "}"
        | "H{" (key value)* "}"
        | "S{" value* "}"
        | "V{" value* "}"
key    := string | symbol
```

The scalars are spelled as in 1z source:

| Form | Examples | Reads as |
|------|----------|----------|
| string | `"localhost"`, `"a\tb"` | a string, with escapes processed |
| number | `8080`, `-1`, `0xff`, `1_000`, `1.5e3` | a fixnum, a bignum when it overflows, or a float |
| symbol | `parse-time:` | the symbol, without its colon |
| `t`, `f` | | the booleans |

The containers nest to any depth, and every position takes the full set of
values:

| Form | Reads as |
|------|----------|
| `{ 1 2 }` | an array |
| `H{ "port" 8080 host: "localhost" }` | a hash |
| `S{ red: green: }` | a set |
| `V{ 1 2 }` | a mutable vector |

A hash key is a string or a symbol, and the two spellings name the same key,
so `"port"` and `port:` are interchangeable. A key that appears twice keeps its
last value.

Whitespace, line breaks, `\` comments and `\\` doc comments may appear between
any two tokens.

## What the reader rejects

Everything outside the grammar is rejected:

- Any word other than `t` and `f`, wherever it appears. A `use` statement is a
  word, so a file opening with one is rejected before anything is loaded.
- Any other constructor, such as `M{`, `B{` or `C{`.
- A quotation, a stack effect, or a `;`.
- A malformed number such as `1_`, or an unterminated string.
- A hash key that is not a string or a symbol, or a key with no value.
- An empty file, and a file holding more than one value.

Earlier releases read these files by evaluating them, and accepted some of
these. A `use` at the top of the file loaded the named module and ran its top
level. A file holding several values silently kept the last one. Both now fail
to load.

## Errors

A rejection raises a `parse-error:` error. Its message names what was wrong
and the position, which counts characters from the start of the file, from
zero:

```
unexpected word 'use' at position 0 in .fmt.1z
```

The same position is in the error's data, under `offset:`:

```
[ "H{ a: foo }" parse-config-data ] [ data: @get offset: @get ] recover
\ => 6
```

`parse-config-data` reads a string and has no file to name. `read-config-file`
reads a file and adds its path to the message. `load-config-data` reads a file
the same way and wraps the hash it holds in a `config`.

Each tool then checks the value's shape for itself. The formatter rejects an
unknown key or a mistyped value, as [Code Formatting](formatting.md#errors)
describes. `load-config-data` and the catalog loader both require a hash.
