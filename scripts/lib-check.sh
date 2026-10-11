#!/usr/bin/env bash
# Run `1z check` over every module under lib/ and report each file it rejects, with the error
# lines that rejected it. Warnings and notes are left out, since they do not fail a check.
#
# Usage: scripts/lib-check.sh <1z-binary> <per-file-timeout-seconds>
set -uo pipefail

bin=$1
per_file_timeout=$2

failed=0
total=0

while IFS= read -r -d '' file; do
	total=$((total + 1))

	out=$(timeout "$per_file_timeout" "$bin" check --stdlib-path=lib "$file" 2>&1 >/dev/null)
	status=$?
	if [ "$status" -eq 0 ]; then
		continue
	fi

	failed=$((failed + 1))
	echo "FAIL: $file (exit $status)"
	grep -E ': err: |error ' <<<"$out" | sed 's/^/  /'
done < <(find lib -name '*.1z' -print0 | sort -z)

if [ "$failed" -gt 0 ]; then
	echo "FAIL: 1z check rejected $failed of $total lib files"
	exit 1
fi
echo "PASS: 1z check accepted all $total lib files"
