#!/usr/bin/env bash
#
# Detect em-dash characters and prose-style double-dashes in comments under
# src/ and lib/, while leaving legitimate uses of `--` alone:
#
#   - stack effects, e.g. `( a b -- sum )`, including nested quotation effects
#   - CLI flag names, e.g. `--trace-modules` (no space after the dashes)
#   - decorative dividers, e.g. `--- Section ---` (three-or-more dashes)
#   - example stack-effect notation inside a quoted string, e.g.
#     `"seq quot: ( elem -- elem' ) -- seq'"`
#
# What's left is a `--` (or a real em-dash character) used as English
# punctuation, which this project's style guide reserves for genuine
# parenthetical asides -- not clause-joining or specifics.
#
# Usage:
#   ./scripts/lint-dashes.sh

set -euo pipefail

if ! command -v rg >/dev/null 2>&1; then
  echo "error: ripgrep (rg) is required" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Strips quoted substrings and balanced (possibly nested) parens from the
# comment text, then flags a surviving `--` flanked by real words, or a
# literal em-dash character anywhere in the original text.
FILTER='
{
  full = $0
  match(full, /^[^:]*:[^:]*:/)
  prefix = substr(full, 1, RLENGTH)
  text = substr(full, RLENGTH + 1)
  loc = substr(prefix, 1, length(prefix) - 1)

  if (index(text, "\xe2\x80\x94")) {
    print loc ": [em-dash] " text
  }

  work = text
  while (gsub(/"[^"]*"/, "", work)) {}
  while (gsub(/\([^()]*\)/, "", work)) {}
  if (work ~ /[[:alnum:]][ \t]+--[ \t]+[[:alnum:]]/) {
    print loc ": [double-dash] " text
  }
}
'

scan() {
  local dir="$1" glob="$2" comment_regex="$3"
  rg -n -o "$comment_regex" "$dir" -g "$glob" 2>/dev/null | awk "$FILTER"
}

findings="$(
  {
    scan "$REPO_ROOT/src" '*.zig' '//.*$'
    scan "$REPO_ROOT/lib" '*.1z' '\\{1,2} .*$'
  }
)"

if [[ -n "$findings" ]]; then
  echo "Found em-dash / prose double-dash usage in comments:"
  echo
  echo "$findings"
  echo
  echo "Rewrite these per the sentence-structure style (split into two sentences, or use a semicolon/colon)."
  exit 1
fi

echo "No em-dash or prose double-dash usage found in src/ or lib/ comments."
