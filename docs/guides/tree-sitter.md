# Tree-sitter Grammar for 1z

`contrib/tree-sitter/` ships a tree-sitter grammar for 1z: structural syntax
highlighting with no running language server. It covers comments, strings,
numbers, symbol tokens, brackets, and word-definition forms. It does not
classify a word by role -- flow word, stack word, user word all look the same
to a context-free grammar. That semantic layer is the LSP's job.

This guide covers installing the shipped grammar in Neovim, Helix, and Zed.

## Naming: `onez` the Grammar, `1z` the Language

Every config below splits one identifier into two. tree-sitter's `grammar.js`
name validator rejects a name starting with a digit, so the grammar's internal
name is `onez` and its compiled entry point is `tree_sitter_onez()` --
confirmed in `contrib/tree-sitter/tree-sitter.json`'s `"name": "onez"`. The
language identifier, scope, and file association stay `1z`-facing:
`"scope": "source.1z"`, `"file-types": ["1z"]`.

So every editor config points the *grammar* at `onez` while keeping the
*language* name, scope, and filetype at `1z`. Getting this split right also
matters for a feature you don't configure directly: a fenced ` ```1z ` block in
a markdown file highlights through the markdown grammar's own dynamic
injection, which resolves the fence's info string (`1z`) against the
registered language name. Miss the alias step in each section below and
fenced 1z code blocks stay plain text even after the parser is installed.

## Neovim

This targets `nvim-treesitter`'s current, rewritten `main` branch, not the
legacy `master` branch -- the parser-registration API changed incompatibly
between them.

Register the grammar in a `User TSUpdate` autocommand, in your Neovim config:

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'TSUpdate',
  callback = function()
    require('nvim-treesitter.parsers').onez = {
      install_info = {
        url = 'https://github.com/ripta/1z',
        location = 'contrib/tree-sitter',
        files = { 'src/parser.c' },
      },
    }
  end,
})

vim.filetype.add({ extension = { ['1z'] = '1z' } })
vim.treesitter.language.register('onez', { '1z' })
```

`location` is the subdirectory field: it tells nvim-treesitter the grammar
sources sit under `contrib/tree-sitter/` in the cloned repository, the same
mechanism `tree-sitter-typescript` uses to ship its `typescript/` and `tsx/`
subdirectories from one repo. `vim.filetype.add` is only needed if `.1z`
isn't already mapped to the `1z` filetype in your config. The
`vim.treesitter.language.register` call is the language-alias step from the
Naming section above: it associates the `1z` filetype with the `onez` parser,
which is also what lets markdown injection route fenced ` ```1z ` blocks to
it.

For a local checkout instead of a fresh git fetch, use `path` in place of
`url`:

```lua
install_info = {
  path = '/path/to/1z',
  location = 'contrib/tree-sitter',
  files = { 'src/parser.c' },
},
```

Then install and check:

```
:TSInstall onez
```

Open a `.1z` file and run `:InspectTree` to confirm a real parse tree appears,
or `:Inspect` under the cursor to confirm a highlight capture resolves there.

### Parser ABI and Neovim version

The committed `src/parser.c` targets tree-sitter language ABI 15, the current
tree-sitter CLI's default. Neovim's own bundled tree-sitter runtime needs to
support that ABI to load it; on an older Neovim build (0.10 and earlier bundle
a tree-sitter runtime capped at ABI 14) `:TSInstall onez` fails with
`ABI version mismatch: supported between 13 and 14, found 15`. Upgrading
Neovim resolves it -- the fix is not on the grammar side.

## Helix

Add both a `[[language]]` and a `[[grammar]]` entry to your `languages.toml`
(`~/.config/helix/languages.toml`):

```toml
[[language]]
name = "1z"
scope = "source.1z"
injection-regex = "1z"
file-types = ["1z"]
comment-token = "\\ "
grammar = "onez"

[[grammar]]
name = "onez"
source = { git = "https://github.com/ripta/1z", rev = "<commit-sha>", subpath = "contrib/tree-sitter" }
```

The `[[language]]` table's `grammar` field decouples the two names, the same
way Helix's own `jsx` language points its `grammar` field at `javascript`.
`[[grammar]].source.subpath` is the subdirectory field, Helix's equivalent of
Neovim's `location`. For a local checkout, use a `path` source instead of
`git`/`rev`:

```toml
[[grammar]]
name = "onez"
source = { path = "/path/to/1z/contrib/tree-sitter" }
```

Fetch and build:

```
hx --grammar fetch
hx --grammar build
```

Highlight queries are not fetched automatically; copy them into your Helix
runtime directory yourself. The directory is keyed by the *language* name
(`1z`), not the grammar name (`onez`) -- the same split `jsx` uses for its own
`runtime/queries/jsx/`, even though its grammar is named `javascript`:

```
mkdir -p ~/.config/helix/runtime/queries/1z
cp contrib/tree-sitter/queries/highlights.scm ~/.config/helix/runtime/queries/1z/highlights.scm
```

`~/.config/helix/runtime` is the standard per-user runtime location; run
`hx --health` afterward to confirm Helix finds both the grammar and the
query directory for `1z`.

## Zed

Zed loads a grammar from a git `repository` plus `rev`, with an optional
`path` field for a subdirectory inside that repository -- the field isn't
documented on Zed's extension-authoring page, but it's a real field on the
extension manifest's grammar entry, which is what makes an in-repo grammar
like this one usable from an extension at all.

Lay out a dev extension directory:

```
zed-1z/
├── extension.toml
└── languages/
    └── 1z/
        ├── config.toml
        └── highlights.scm
```

`extension.toml`:

```toml
id = "1z"
name = "1z"
version = "0.0.1"
schema_version = 1
authors = ["Your Name <you@example.com>"]
description = "1z language support"
repository = "https://github.com/ripta/1z"

[grammars.onez]
repository = "https://github.com/ripta/1z"
rev = "<commit-sha>"
path = "contrib/tree-sitter"
```

`languages/1z/config.toml`:

```toml
name = "1z"
grammar = "onez"
path_suffixes = ["1z"]
line_comments = ["\\ "]
```

Copy `contrib/tree-sitter/queries/highlights.scm` to
`zed-1z/languages/1z/highlights.scm`.

Install it locally through the command palette action `zed::InstallDevExtension`
and pick the `zed-1z/` directory. Building a dev extension needs Rust
installed via `rustup`; a Homebrew-installed Rust toolchain fails silently
here, so if the install doesn't take, that's the first thing to check.

## Pinning a Revision

Every `rev` / commit SHA above needs a real, immutable revision -- these
installers pin a commit, they don't track a branch. Get one from this repo
with:

```
git rev-parse HEAD
```

## Developing the Grammar

Changing `grammar.js` or `queries/highlights.scm` needs the tree-sitter CLI to
regenerate the parser and run the test suite:

```
cd contrib/tree-sitter
npm install
npm run generate
```

`make tree-sitter-test` (also reachable via the `make contrib` umbrella
target) runs `tree-sitter test` over `test/corpus/` and `test/highlight/`
without needing an editor at all.
