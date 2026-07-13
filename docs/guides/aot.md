# Ahead-of-Time Compilation

`1z build` turns a `.1z` entry file into a native executable. It does this by
running the language's normal parser and parse-time machinery, freezing the
resulting program graph, translating the compilable parts to C, and invoking a
C compiler to produce the final binary.

This guide follows that process end to end. It explains what freezing means,
which words become part of the binary, how quotations and generated words are
handled, when runtime support or interpreter fallback is needed, and how names
appear in the generated C and native symbol table.

For advice on choosing between the interpreter, JIT, and AOT artifact classes,
see [Execution and Compilation Modes](execution-modes.md). For profiler-specific
details, see [AOT Symbol Names for Profilers](aot-symbols.md).

## The Short Version

An AOT build has two large stages:

```text
source and imports
       |
       v
parse and execute definitions at build time
       |
       v
freeze reachable words, quotations, methods, and values
       |
       v
infer effects and trial-compile the frozen graph
       |
       v
emit C functions, tables, metadata, and optional runtime image
       |
       v
invoke zig cc (or $CC) and link the runtime
       |
       v
native executable
```

The important consequence is that AOT compilation is not a textual scan for
word names. The build loads the program with the normal language frontend and
executes its definition-time behavior. It then follows resolved calls from the
top-level entry code to construct a concrete compilation manifest.

## Building a Program

Given this program:

```1z
double: ( n -- n ) [ 2 * ] ;

21 double .
```

build and run it with:

```sh
1z build example.1z -o example
./example
```

If `-o` is omitted, the output name is the source path with its `.1z` suffix
removed.

`1z build --help` lists all build flags. The flags most useful while learning
or debugging the pipeline are:

| Flag | Purpose |
|---|---|
| `--save-temps` | Keep the generated C and other temporary build files |
| `--compilation-stats` | Report which words compiled and why others did not |
| `--trace-aot` | Trace freezing, code generation, and effect discovery |
| `--trace-aot=CATS` | Select `freeze`, `codegen`, `effect`, or `instr` traces |
| `--trace-aot-word=PAT` | Restrict traces to comma-separated exact word names |
| `--compile-all-prelude` | Add every eligible prelude word to the manifest |
| `--allow-interpreter-fallback` | Suppress warnings about quotation fallback; it does not enable fallback by itself |
| `--emit-runtime-image` | Embed frozen dictionary and program-image state |
| `--dump-aot-image-classification` | Show how image words are classified |
| `--dump-aot-image-c` | Print the generated runtime-image C |

## Stage 1: Load and Parse the Entry File

The build starts with a fresh runtime context and loads the prelude. It resolves
the target before parsing, so parse-time words such as `target-os` and
`target-arch` observe the requested `--target`, not necessarily the host.

The entry file is then read through the same statement processor used by normal
execution. Statements may span lines; this is not a line-by-line semantic
evaluation even though the reader feeds lines to the statement processor.
Source positions are retained for diagnostics and for `#line` directives in
the generated C.

Each complete top-level statement is treated in one of two ways:

- Definition statements are executed immediately at build time. This installs
  their words, runs parse-time defining words, loads requested modules, creates
  generated accessors and constructors, and registers method dispatch entries.
- Non-definition statements are saved as instructions. Together they become a
  synthetic word named `__entry__`, which is the program's native entry body.

For example, freezing the earlier program installs `double` while parsing its
definition, but saves `21 double .` as the body of `__entry__`.

Imports are therefore resolved while the source is loaded. Imported modules
run their own definition-time behavior and enter the module cache before
reachability analysis starts. Build-time module lookup follows the same module
and dependency scopes as ordinary execution.

### Build-time execution is real execution

Freezing can fail before native code generation begins. A missing import, parse
error, or error raised by a parse-time word is a build error. Parse-time code
can also observe the selected build target.

This is why it is useful to think of the first part of AOT as *loading the
program into a build-time interpreter*, rather than as a conventional compiler
frontend that only constructs an inert syntax tree.

## Stage 2: Freeze the Reachable Program Graph

After loading the entry file, the build freezes the program. In 1z, freezing
means converting the build-time context into a stable description of the code
and values that the native artifact needs.

This compiler term is unrelated to the user-level `freeze` word that converts
a mutable vector into an array.

The initial roots are the call instructions in `__entry__`. The freezer follows
them with a worklist traversal and records:

- reachable compound words;
- reachable native words and their stable word IDs;
- literal and nested quotations;
- registered method bodies reached through generic dispatch;
- generated words already materialized by parse-time constructs;
- resolved call targets and quotation paths used for diagnostics;
- source file, line, and column information; and
- values and type descriptors that compiled code must recover at runtime.

When a newly reached compound word calls other words, those callees are added
to the worklist. This continues until no new reachable words remain.

### Reachability is semantic, not textual

The freezer follows parsed `call_word` instructions and resolved definitions.
A word name in a comment or string does not make that word reachable. Conversely,
a method body or quotation can be reachable even when its name does not appear
as a simple top-level call.

Module scope is part of word identity during traversal. If two modules define
same-named private words or generated accessors, the freezer resolves the name
in the defining word's module context rather than treating every spelling as a
single global symbol.

By default, an unused user word or prelude word is not included merely because
it exists in the build-time dictionary. `--compile-all-prelude` is the explicit
exception: it adds eligible prelude words even when the entry graph does not
reach them.

### Stack effects are part of the AOT contract

Reachable compound words need stack-effect declarations. Effects give codegen
the input and output shape from which it constructs an abstract stack and
native function boundary. A reachable word with no required effect declaration
causes a build error naming the word.

Quotations do not always have an explicit declaration. The compiler first tries
to infer their concrete effects by abstract simulation. In strict builds it can
also try candidate input arities for quotations whose effects involve stack-row
behavior that the simpler inference pass could not express.

### Quotations

Every discovered quotation receives a build-wide quotation ID. When its effect
is known and its body is compilable, codegen emits a native function and places
its address in a quotation table. Materializing the quotation at runtime then
attaches that native `code_ptr`.

The freezer also walks quotations nested inside known composite values. Some
runtime-selected container shapes, such as registered dispatch entries, need
their nested quotation callees promoted into the compiled graph. Other composite
quotations may be retained in an image without promoting every word they call.
This boundary keeps an incidental value in the frozen context from pulling an
unbounded portion of the module cache into the must-compile set.

### Generated words and methods

Words generated by `struct{`, `virtual{`, enum definitions, and similar
parse-time constructs already exist as normal dictionary definitions when the
reachability walk begins. The freezer can therefore discover their bodies and
the native helpers they call just like user-authored words.

`method{` entries are different: a method is registered in a dispatch table
rather than installed as an independent dictionary word. The freezer walks the
registered entries of a reached generic and records their quotation bodies. A
generic with one applicable method may also be devirtualized to that method
body during AOT processing.

### What the frozen result contains

At the end of this stage, the source program has become a manifest of word and
quotation descriptors. Each descriptor carries such information as:

- the original 1z name;
- a numeric word or quotation ID;
- its instruction body;
- declared or inferred stack effect;
- native, prelude, and generated-word classification;
- dispatch metadata; and
- source provenance.

This manifest, rather than the original source text, is the input to native
code generation.

## Stage 3: Discover What Can Compile

Code generation is deliberately multi-pass. A call can be emitted as a direct
native call only when the compiler knows that the callee itself will compile,
so the compiler first discovers the compilable set before producing the final
bodies.

The main passes are:

1. Compute a fixpoint for special row-returning effects used by abstract-stack
   analysis.
2. Trial-compile every non-native word. Successful trials enter the compilable
   word map; failures retain a structured reason for diagnostics.
3. Infer or discover quotation effects and trial-compile quotation bodies.
4. Compile words again using only the confirmed compilable set.
5. Compile confirmed quotation bodies and populate literal and slot tables.

The trial output is discarded. Its purpose is to learn which direct calls are
safe and to collect facts such as peak stack depth. The final pass uses those
facts to emit stack-capacity checks and actual function bodies.

Common reasons a body may not compile include an abstract stack mismatch, an
unsupported dynamic call shape, a non-serializable literal, or a nested local
definition whose scope cannot be represented by the AOT resolver. Use
`--compilation-stats` or `--trace-aot=codegen,effect` for the exact reason in a
particular build.

Native primitives are not translated from their Zig implementations into C.
Compiled code calls the AOT runtime surface or a generated direct native
wrapper. These calls still run native code; a native callback is not the same
thing as interpreting a compound word.

## Stage 4: Decide Fallback and Artifact Capabilities

Not every frozen instruction sequence is necessarily compiled. What happens to
an uncompiled path depends on the fallback policy and whether a full runtime
image is present.

The main policy flag is:

```sh
--interpreter-fallback=true|false|auto
```

- `true` permits the full interpreter to be linked for runtime fallback.
- `false` requests strict AOT handling and rejects an uncompiled compound-word
  fallback.
- `auto`, the default, links the interpreter only when emitted callbacks
  actually require it.

`--lock-interpreter-setting` prevents the produced program from changing that
choice through `ONEZ_INTERPRETER_FALLBACK`. With an unlocked hosted binary, the
environment variable may set runtime fallback to `0` or `1`.

An explicit `false` rejects uncompiled compound-word fallback even without the
lock. Adding the lock also rejects residual interpreter callback requirements,
such as a quotation path that could not receive a native code pointer. The
similarly named `--allow-interpreter-fallback` flag only suppresses quotation
fallback warnings; it does not change this policy.

Fallback sites are classified separately:

| Site | Runtime path | Strict behavior |
|---|---|---|
| Compilable compound word | Direct generated C call | Allowed |
| Native primitive | Native wrapper/runtime native dispatch | Allowed |
| Uncompiled compound word | Interpreter word call | Rejected with fallback `false` |
| Uncompiled/dynamic quotation | Quotation runtime callback | Must be supported by the selected artifact |

The build inventories fallback sites and cross-checks that inventory against
the assembled C. A strict rejection reports the caller, callee, source line,
and compilation reason where available.

### Artifact classes

The final class describes what was actually linked, not just which flag the
user supplied:

| Class reported by `1z inspect` | Contents and capability |
|---|---|
| `interpreter` | Native code plus the full interpreter; broadest dynamic behavior |
| `runtime-image-aot` | Native code plus a full frozen program image, without the full interpreter linkage |
| `interpreter-free-aot` | Native code and supporting runtime, but neither full interpreter fallback nor executable image bodies |

Interpreter linkage takes precedence in classification. A binary that contains
an image but also links the interpreter is reported as `interpreter`, because
that is its maximum runtime capability.

“Interpreter-free” does not mean “no runtime library.” Compiled code still
needs stack storage, allocation, errors, native primitives, dispatch helpers,
safepoints, and value lifetime management. It means that arbitrary compound
instruction arrays cannot fall back to the full source interpreter.

## Runtime Images

Use `--emit-runtime-image` when execution needs frozen dictionary or module
state in addition to native function tables:

```sh
1z build --emit-runtime-image app.1z -o app
```

A full runtime image serializes the relevant build-time module and dictionary
state, word metadata, interpretable bodies where needed, dispatch registrations,
and supported literal objects. At startup, the generated `main` rehydrates that
image before it invokes `__entry__`.

This provides the state needed by operations such as runtime quotation
construction and runtime module loading. The full-image freeze policy also
allows dynamic evaluation to proceed to codegen, but the callbacks emitted for
a particular program can still require the interpreter. If so, the finished
binary is classified as `interpreter`, even though it also contains an image.
Runtime JIT compilation through `compile!` is a different capability and is
rejected for every AOT build.

Even without `--emit-runtime-image`, current interpreter-free builds can emit a
metadata-only image. It preserves read-only word metadata needed by
introspection but contains no executable bytecode bodies. A metadata-only image
does not change the artifact class to `runtime-image-aot`.

### Why images use slot tables

Some literals are process-local pointers at freeze time: type values, struct
descriptors, markers, parameters, tagged values, mutable maps, struct instances,
vectors, protocol descriptors, and constraint combinators. Baking those pointer
values into machine code would make them invalid in the produced executable.

Instead, codegen assigns stable slot indices. The image loader reconstructs or
finds each live runtime object, patches the corresponding slot, and compiled
code loads through that slot. This also preserves identity and aliasing where
the language semantics require it; for example, two references to the same
mutable freeze-time object remain references to one reconstructed object.

Use `--dump-aot-image-classification` to see which words are compiled, retained
for runtime interpretation, metadata-only, or omitted. Use
`--dump-aot-image-c` when debugging the serialized representation itself.

## Dynamic Features and the Frozen Boundary

The freezer recognizes capability markers on reachable native words. These
markers let it reject a build early instead of producing a binary that reaches
missing runtime machinery later.

The principal capabilities are:

| Capability | Example | Interpreter-linked build | Full-image freeze policy | Strict interpreter-free |
|---|---|---:|---:|---:|
| Runtime evaluation | `eval-string` | Supported | Allowed; emitted callbacks may promote the artifact to `interpreter` | Rejected |
| Runtime module loading | `load`, `load-file` | Supported | Allowed | Rejected |
| Runtime quotation construction | `>quotation` | Supported | Allowed | Rejected |
| Runtime compilation | `compile!` | Yes | Rejected | Rejected |

Literal quotations are different from runtime quotation construction. If the
word is known while building, prefer:

```1z
[ known-word ]
```

over constructing the quotation from a runtime string with `>quotation`.

To find why a source file reaches a dynamic capability, use:

```sh
1z inspect --reach eval app.1z
1z inspect --reach load app.1z
1z inspect --reach quotation-construction app.1z
```

The report freezes with permissive capability policy and prints every
transitive compound-word chain leading to the marked native. The
`dynamic-` prefix is optional in the feature argument.

## Stage 5: Emit a C Translation Unit

Once the compiled set and artifact policy are known, codegen assembles one C
translation unit containing:

1. platform-appropriate headers and runtime declarations;
2. literal data and optional image data;
3. forward declarations for compiled words and quotations;
4. one C function for each successfully compiled body;
5. a word dispatch table and word-name table;
6. a compiled-quotation function table;
7. embedded build and artifact metadata; and
8. `main`, or `kernel_main` for a freestanding target.

Generated word functions return a status code and receive the runtime context.
They manipulate an abstracted 1z stack, call other compiled functions directly
where possible, and call the runtime surface for primitives and operations that
need managed runtime state.

The dispatch table is indexed by frozen word ID. Compiled entries contain a
function pointer; unavailable entries are null. The parallel name table is
kept in every artifact for native dispatch and trace attribution, even when
compound interpreter fallback is absent.

The generated entry point:

- initializes the runtime, skipping prelude source evaluation when the artifact
  is interpreter-free;
- registers compiled quotation functions;
- loads a metadata or full runtime image when present;
- installs command-line arguments and optional static FFI libraries;
- configures fallback and tracing from the environment;
- registers compiled word functions; and
- invokes the frozen `__entry__` word.

Errors continue to use 1z source locations because emitted functions carry C
`#line` directives pointing back to the defining `.1z` file.

## Stage 6: Compile and Link

The second large build stage invokes a C compiler. By default the command is
`zig cc`; setting `CC` selects another command. The generated translation unit
is linked with `lib1z.a`, requested static FFI libraries, and any objects passed
with `--link-object`.

Hosted builds produce a normal executable. A freestanding `--target` changes
the entry point and compiler/linker flags, omits hosted C facilities, and uses
the objects and linker script supplied by the platform build. See
[Bare-Metal AOT Builds](bare-metal.md) for the supported bare-metal workflow.

Temporary generated files are removed after a successful normal build. Pass
`--save-temps` to retain them for inspection.

## Names: 1z, C, and Native Symbols

A 1z word can contain characters that are illegal or meaningful in C
identifiers. Codegen therefore gives every compiled word an internal C name
beginning with `onez_w_`.

ASCII letters, digits, and underscores pass through. Common punctuation uses
short escapes:

| 1z character | C identifier fragment |
|---|---|
| `-` | `_` |
| `#` | `_H` |
| `@` | `_A` |
| `?` | `_Q` |
| `!` | `_B` |
| `*` | `_S` |
| `+` | `_P` |
| `/` | `_D` |
| `<` | `_L` |
| `>` | `_G` |
| `=` | `_E` |
| `.` | `_O` |
| `:` | `_C` |

Other bytes use `_xNN_` hexadecimal escapes. Examples include:

```text
double       -> onez_w_double
#map         -> onez_w__Hmap
?or-else     -> onez_w__Qor_else
@set!        -> onez_w__Aset_B
```

These are C linkage identifiers, not normally the names users see in a native
profile. Forward declarations use an `asm("...")` name override so the linker
symbol is the original 1z word name where the object format permits it.

Generated words use a qualified display name based on their parent, such as
`person/id>>`. Compiled quotations use a source-derived name of the form:

```text
defining-word/quot@line:column
```

Some debugger views still show the mangled C/DWARF name, and ELF treats `@` as
symbol-version syntax. Those toolchain-specific details and the verification
commands are covered in [AOT Symbol Names for Profilers](aot-symbols.md).

## Inspecting a Produced Binary

Every AOT executable carries a self-describing metadata block in read-only
data. Inspect it with:

```sh
1z inspect ./app
```

The report includes the target triple, compiler/build provenance, artifact
class, requested fallback mode, whether that setting is locked, actual
interpreter linkage, runtime or metadata image presence, dynamic-feature
touchpoints, and a hash of the prelude used during the build.

This distinction is useful with the default `auto` policy: the command line
records intent, while the linkage and artifact fields report what codegen
actually needed.

## Debugging an AOT Build

A practical sequence is:

```sh
# See the broad outcome and failure inventory.
1z build --compilation-stats app.1z -o app

# Follow reachability and compilation decisions for selected words.
1z build --trace-aot=freeze,codegen,effect \
  --trace-aot-word=main-loop,parse-item app.1z -o app

# Add per-instruction abstract-stack traces when needed.
1z build --trace-aot=instr \
  --trace-aot-word=parse-item app.1z -o app

# Inspect the exact C sent to the compiler.
1z build --save-temps app.1z -o app

# Confirm the capability class of the result.
1z inspect ./app
```

The trace categories answer different questions:

- `freeze`: Why is this word or quotation in the manifest?
- `codegen`: Did the body compile, and if not, what rejected it?
- `effect`: Which quotation input/output arities were inferred or tried?
- `instr`: What operation, call target, stack depth, and source line was being
  compiled at each step?

For a strict build failure caused by a dynamic feature, use `inspect --reach`
before reading generated C. It usually identifies the relevant call chain more
directly.

## Design Consequences

The end-to-end design leads to a few useful rules of thumb:

- Keep important runtime paths reachable through ordinary calls or registered
  dispatch structures. Constructing names dynamically needs a runtime image or
  interpreter support.
- Give compound words accurate stack effects. They are both documentation and
  native compilation boundaries.
- Prefer literal quotations when the target word is known at build time.
- Treat parse-time code as part of the build. Its errors and target-dependent
  decisions happen while freezing, not when the produced executable starts.
- Use strict interpreter-free builds to expose unsupported compound fallbacks;
  use runtime-image builds when the application intentionally needs frozen
  dictionary or dynamic loading state.
- Inspect the produced binary rather than inferring its class from the build
  command, especially when using `auto` fallback.

The AOT compiler is therefore best understood as a partial evaluator and graph
compiler around the existing 1z runtime: it executes definition-time language
semantics, freezes the concrete result, compiles the portions with known stack
behavior, and packages exactly the remaining runtime support selected by the
artifact policy.
