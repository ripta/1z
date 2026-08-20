# The REPL

Start the REPL by running `1z` with no arguments:

```
./zig-out/bin/1z
```

You see a banner and a `>` prompt.

## Pushing Values and Arithmetic

Type a number and press Enter. The REPL shows the stack after each input:

```
> 3
Stack: [ 3 ]
> 7
Stack: [ 3 7 ]
> +
Stack: [ 10 ]
```

Values pile up on the stack. `+` pops two and pushes the sum.

## Printing

`.` (dot) pops and prints the top value:

```
> 42 .
42
Stack: [ ]
```

`print-line` prints a string with a newline:

```
> "hello" print-line
hello
Stack: [ ]
```

## Seeing the Stack

The REPL displays the stack after every input. Leftmost is bottom; rightmost
is top.

```
> 1 2 3
Stack: [ 1 2 3 ]
```

## Defining Words

Define a word at the prompt just like in a file:

```
> double: [ dup + ] ;
Stack: [ ]
> 21 double
Stack: [ 42 ]
```

## Multiline Input

If a line ends with an unclosed `[`, `{`, or other bracket, the REPL
switches to a continuation prompt (`+`) and waits for more input:

```
> greet: [
+   "hello" print-line
+ ] ;
Stack: [ ]
> greet
hello
Stack: [ ]
```

## Quiet Modes

- `-q` suppresses the startup banner.
- `-qq` suppresses the banner, prompts, stack display, and goodbye message.
  Useful for scripting.

```
./zig-out/bin/1z -q
./zig-out/bin/1z -qq
```

## Startup File

Words, imports, and pragmas you want in every session go in
`~/.config/1z/startup.1z`. The REPL runs it before the first prompt:

```
\ ~/.config/1z/startup.1z
use "math" ;
```

```
> 2.7 floor
Stack: [ 2.0 ]
```

`--no-startup` skips it for one run. The
[User Startup Configuration](../guides/startup-config.md) guide covers the
full path chain and which other commands run the file.

## Exiting

Ctrl-D on an empty line. The REPL prints "Goodbye!" and exits.

## Next Steps

Write your [first program](first-program.md) in a file.
