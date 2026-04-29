#!/usr/bin/env bash
#
# Find duplicate assertion lines across integration test files.
#
# Extracts every line containing an assert word (`assert=`, `assert-true`, `assert-false`, `assert-error`),
# strips leading whitespace, and reports lines that appear in more than one file or more than once in the
# same file.
#
# Usage:
#   ./scripts/find-duplicate-tests.sh [directory]
#
# Defaults to tests/integration/ relative to the repo root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="${1:-$REPO_ROOT/tests/integration}"

if [[ ! -d "$TEST_DIR" ]]; then
  echo "error: directory not found: $TEST_DIR" >&2
  exit 1
fi

# Collect all assertion lines with their file and line number. Output format:
#
#   stripped_line<TAB>relative_path:line_number
collect_assertions() {
  local dir="$1"
  # Use grep to find assertion lines, then normalize whitespace.
  grep -rn \
    -e 'assert=' \
    -e 'assert-true' \
    -e 'assert-false' \
    -e 'assert-error' \
    --include='*.1z' \
    "$dir" \
  | while IFS=: read -r filepath lineno content; do
      # Strip leading/trailing whitespace from the assertion line.
      local stripped
      stripped="$(echo "$content" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

      # Skip blank lines, comments, and words that merely reference assert words
      [[ -z "$stripped" ]] && continue
      [[ "$stripped" == \\* ]] && continue

      # Skip bare assert words that are continuation lines of multi-line expressions
      case "$stripped" in
        assert=|assert-true|assert-false|assert-error) continue ;;
        "] assert-error") continue ;;
      esac

      local relpath
      relpath="${filepath#"$dir"/}"
      printf '%s\t%s:%s\n' "$stripped" "$relpath" "$lineno"
    done
}

echo "Scanning $TEST_DIR ..."
echo

assertions="$(collect_assertions "$TEST_DIR")"

echo "=== Crossfile duplicates ==="
echo

found_cross=0
echo "$assertions" \
| sort -t$'\t' -k1,1 \
| awk -F'\t' '
  {
    line = $1
    loc  = $2
    # Extract just the filename (before the colon).
    split(loc, parts, ":")
    file = parts[1]

    if (line != prev) {
      if (n > 1 && nfiles > 1) {
        printf "  %s\n", prev
        for (i = 1; i <= n; i++) printf "    - %s\n", locs[i]
        printf "\n"
        count++
      }
      prev = line
      n = 0
      nfiles = 0
      delete seen_files
      delete locs
    }
    n++
    locs[n] = loc
    if (!(file in seen_files)) {
      seen_files[file] = 1
      nfiles++
    }
  }
  END {
    if (n > 1 && nfiles > 1) {
      printf "  %s\n", prev
      for (i = 1; i <= n; i++) printf "    - %s\n", locs[i]
      printf "\n"
      count++
    }
    printf "Found %d cross-file duplicate(s).\n", count + 0
  }
'

echo
echo "=== Intrafile duplicates ==="
echo

echo "$assertions" \
| sort -t$'\t' -k1,1 \
| awk -F'\t' '
  {
    line = $1
    loc  = $2
    split(loc, parts, ":")
    file = parts[1]

    key = line SUBSEP file
    file_count[key]++
    if (file_count[key] == 1) {
      first_loc[key] = loc
    } else {
      extra_locs[key] = extra_locs[key] "    - " loc "\n"
    }
    all_lines[key] = line
    all_files[key] = file
  }
  END {
    for (key in file_count) {
      if (file_count[key] > 1) {
        printf "  %s\n", all_lines[key]
        printf "    - %s\n", first_loc[key]
        printf "%s", extra_locs[key]
        printf "\n"
        count++
      }
    }
    printf "Found %d intra-file duplicate(s).\n", count + 0
  }
'
