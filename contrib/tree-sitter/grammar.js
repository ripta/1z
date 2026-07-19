/**
 * @file Tree-sitter grammar for the 1z programming language
 * @license MIT
 *
 * Structural highlighting only: this grammar recognizes syntax (comments,
 * strings, numbers, symbols, brackets, definitions), not semantic word
 * roles. It shares no code with the 1z interpreter's own tokenizer
 * (src/tokenizer.zig) or parser (src/parser.zig); it mirrors their observed
 * lexical rules from scratch in tree-sitter's DSL.
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

export default grammar({
  // tree-sitter's grammar.js validator rejects a `name` starting with a
  // digit, so the literal "1z" cannot be used here -- this becomes the
  // generated `tree_sitter_onez()` entry point. "onez" matches the C
  // symbol/build namespace this project already uses elsewhere (e.g.
  // `onez_n_stream_write`, `onez_image_header_t`).
  name: "onez",

  // Whitespace is a global extra, but `comment`/`doc_comment` deliberately
  // are NOT.
  //
  // A global extra is tried as a candidate at every lexer position
  // regardless of grammar context. `token.immediate` on the string-internal
  // rules only suppresses a gap being inserted before those specific rules;
  // it does not stop a competing extra match from starting at the same
  // position.
  //
  // An escaped backslash inside a string (`\\`) followed by whitespace is
  // lexically identical to a doc-comment opener, and `doc_comment`'s
  // fallback body can run all the way to the next real newline. That extra
  // would out-length the 2-character escape match and hijack the rest of
  // the string.
  //
  // Comments are instead threaded explicitly into `_item`,
  // `_stack_effect_param`, and `word_definition`'s repeat, which covers
  // every context comments should appear in without ever making them a
  // candidate inside `string`.
  extras: $ => [
    /[ \t\r\n]/,
  ],

  conflicts: $ => [
    [$._item, $.word_definition],
  ],

  rules: {
    source_file: $ => repeat($._item),

    // A generic pushed value or statement. `word_definition` and `$.symbol`
    // share the same leading token (a symbol), which is a genuine parser-level
    // ambiguity resolved by `prec.dynamic` on `word_definition`, not a lexical
    // one -- see the conflicts declaration above.
    _item: $ => choice(
      $.comment,
      $.doc_comment,
      $.word_definition,
      $.quotation,
      $.array,
      $.brace_form,
      $.stack_effect,
      $.string,
      $.float,
      $.integer,
      $.symbol,
      $.word,
    ),

    // `name: (effect | marker | brace-form)* quotation? ;` -- a convention,
    // not an enforced language grammar (`;` is an ordinary runtime word that
    // pops a symbol and quotation off the stack). Real prelude usage puts
    // markers before, after, or interleaved with the stack effect, and some
    // definitions (`struct{`, `enum{`, `protocol{`) have no quotation body at
    // all, just a brace form before the terminating `;`. This rule stays
    // permissive on both counts rather than assuming one fixed shape.
    word_definition: $ => prec.dynamic(1, seq(
      field('name', $.symbol),
      repeat1(choice(
        $.comment,
        $.doc_comment,
        field('marker', alias($.word, $.marker)),
        field('effect', $.stack_effect),
        field('form', $.brace_form),
        field('body', $.quotation),
      )),
      ';',
    )),

    quotation: $ => seq('[', repeat($._item), ']'),

    array: $ => seq('{', repeat($._item), '}'),

    brace_form: $ => seq($.brace_prefixed_open, repeat($._item), '}'),

    // Any word-shaped run immediately followed by `{` (e.g. `H{`, `struct{`,
    // a user-defined `C{`) is one atomic token. Deliberately not an
    // enumerated prefix list -- container-literal prefixes are ordinary,
    // user-extensible parse-time words in 1z, not fixed syntax.
    //
    // `"` is excluded from the prefix run for the same reason it's excluded
    // from `word`: a string containing a `{` later on (e.g. a `\u{...}`
    // escape) must not let this pattern reach back across the opening quote
    // and swallow it as part of the "prefix".
    //
    // Known limitation: a word whose *name* ends in `{` but whose body does
    // not actually collect tokens until a matching `}` (i.e. it isn't a
    // real container-literal word, just an ordinary parse-time word that
    // happens to be named that way) is misparsed when invoked, since this
    // rule can't distinguish the two without dictionary/semantic
    // information. `tests/integration/emit_call.1z`'s `add1{` is a real
    // example: defining it parses fine, but `5 add1{ 6 ...` with no
    // matching `}` anywhere opens a `brace_form` that never closes.
    brace_prefixed_open: $ => token(/[^\s{}"]+\{/),

    stack_effect: $ => seq(
      '(',
      repeat($._stack_effect_param),
      optional(seq('--', repeat($._stack_effect_param))),
      ')',
    ),

    _stack_effect_param: $ => choice(
      $.comment,
      $.doc_comment,
      $.stack_effect_annotation,
      $.stack_effect_wildcard,
      $.word,
    ),

    // `name: ( nested effect )` or `name: constraint-chain`. Row variables
    // (`..a`) get no dedicated rule; they are lexically ordinary words.
    stack_effect_annotation: $ => seq(
      field('name', $.symbol),
      field('value', choice(
        $.stack_effect,
        $.constraint_expression,
      )),
    ),

    // A flat `&`/`|` chain of type/protocol names. `&` binding tighter than
    // `|` is not modeled -- structural highlighting has no use for the
    // grouping, only the chain members.
    //
    // Left-recursive with explicit precedence, the standard tree-sitter
    // idiom for an operator chain: after `name: fixnum`, a following
    // `| bignum` is ambiguous between "continue this chain" and "start a
    // fresh bare stack_effect_wildcard + word back at the enclosing
    // stack_effect's param list" (both are grammatically valid
    // completions). `prec.left` on the recursive alternative resolves the
    // ambiguity toward extending the chain, where a `repeat()`-based
    // formulation left it unresolved toward stopping early.
    constraint_expression: $ => choice(
      $.word,
      prec.left(1, seq($.constraint_expression, choice('&', '|'), $.word)),
    ),

    // A bare `*` output marks never-returns; a bare `|` output marks
    // variable arity (`( scanner -- new-scanner token | f )`).
    stack_effect_wildcard: $ => choice('*', '|'),

    string: $ => seq(
      '"',
      repeat(choice(
        $.escape_sequence,
        $._string_content,
      )),
      token.immediate('"'),
    ),

    // `token.immediate` here prevents whitespace (the sole remaining
    // extra) from being silently inserted inside a string's content.
    _string_content: $ => token.immediate(/[^"\\]+/),

    escape_sequence: $ => token.immediate(choice(
      /\\[nrt\\"']/,
      /\\x[0-9a-fA-F]{2}/,
      /\\u\{[0-9a-fA-F]+\}/,
      /\\[\s\S]/,
    )),

    integer: $ => token(seq(
      optional('-'),
      choice(
        /0[xX]_?[0-9a-fA-F](_?[0-9a-fA-F])*/,
        /0[oO]_?[0-7](_?[0-7])*/,
        /0[bB]_?[01](_?[01])*/,
        /\d(_?\d)*/,
      ),
    )),

    float: $ => token(seq(
      optional('-'),
      choice(
        seq(/\d(_?\d)*/, '.', /\d(_?\d)*/, optional(/[eE][+-]?\d(_?\d)*/)),
        seq(/\d(_?\d)*/, /[eE][+-]?\d(_?\d)*/),
      ),
    )),

    // A symbol is any token of length > 1 whose last character is `:`; a
    // bare `:` stays a word. Direct transcription of `classifyLiteral`.
    //
    // `"` is excluded from the leading character for the same reason as
    // `word` and `brace_prefixed_open`: a string whose content contains a
    // `:` before its closing quote (e.g. `"Coordinates:"`) must not let
    // this pattern match a prefix ending at that internal colon and leave
    // the real closing quote to start a new, wrongly-unterminated string.
    symbol: $ => token(/[^\s"][^\s]*:/),

    // `\` opens a line comment, `\\` a doc-comment, only when immediately
    // followed by space/tab/CR/newline/EOF. `\word`/`\\word` are ordinary
    // words, not comments -- the `choice(pattern, '')` empty alternative
    // lets the pattern lose cleanly to `word` in that case, with no
    // lookahead assertion needed.
    comment: $ => token(seq(
      '\\',
      choice(/[ \t\r][^\n]*/, ''),
    )),

    doc_comment: $ => token(seq(
      '\\\\',
      choice(/[ \t\r][^\n]*/, ''),
    )),

    // The catch-all: any run of non-whitespace characters. Given negative
    // precedence, so it only wins when no more specific rule spans the same
    // whitespace-bounded run -- this single rule reproduces the real
    // tokenizer's "bound by whitespace, then classify the whole token" model
    // without a second grammar layer.
    //
    // A leading `"` is excluded: the real tokenizer checks for a string
    // unconditionally, before general word-boundary scanning, so a word can
    // never start with a quote. Without this exclusion, `word`'s greedy
    // match would out-length `string`'s single-character opening-quote
    // token whenever the string body contains no internal whitespace (e.g.
    // `"hello"`), since the lexer only sees the string rule's first
    // terminal, not its eventual full span, when comparing candidates.
    word: $ => token(prec(-1, /[^\s"][^\s]*/)),
  },
});
