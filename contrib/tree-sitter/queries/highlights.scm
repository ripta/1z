; Structural highlighting only, driven by syntax the grammar can see.
; No semantic word-role classification; that stays the language server's job.

(comment) @comment
(doc_comment) @comment.documentation

(string) @string
(escape_sequence) @string.escape
(integer) @number
(float) @number.float

; `symbol` (`name:`) tokens default to the atom-like capture. A
; word_definition's own name overrides it below to @function -- query order
; matters here, since overlapping captures on the same node resolve
; last-pattern-wins.
(symbol) @string.special.symbol
(word_definition name: (symbol) @function)

["(" ")" "[" "]" "{" "}"] @punctuation.bracket
[";" "--"] @punctuation.delimiter
["&" "|" "*"] @operator

; Every brace-suffixed prefix (`H{`, `struct{`, a user's own `C{`, ...) is
; one token type, `brace_prefixed_open` -- the grammar can't tell a data
; constructor from a parse-time definition form without looking at the text.
; Container literals join the bracket punctuation above; parse-time
; definition/dispatch forms are keywords. Anything outside both lists (a
; user-defined prefix) stays uncaptured.
((brace_prefixed_open) @punctuation.bracket
  (#any-of? @punctuation.bracket "H{" "V{" "M{" "B{" "S{" "W{"))

((brace_prefixed_open) @keyword
  (#any-of? @keyword
    "struct{" "enum{" "match{" "method{" "virtual{" "pragma{" "protocol{" "private{"))

; The stable parse-time non-brace words, wherever they appear. `const` also
; shows up as a word_definition marker, aliased to a distinct `marker` node
; type that the `word` pattern above can't reach, hence the second rule.
((word) @keyword
  (#any-of? @keyword "use" "reexport" "const" "load" "if" "when" "unless"))

((marker) @keyword
  (#any-of? @keyword "use" "reexport" "const" "load" "if" "when" "unless"))
