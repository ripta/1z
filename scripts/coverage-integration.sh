#!/usr/bin/env bash
#
# Measure coverage of the Zig interpreter sources under src/ from the file-driven
# test corpora that all run the real `1z` binary: the integration tests, the
# formatter inputs, and the lib/ unit tests. These reach interpreter paths the
# unit suite never touches, and since they share one binary their coverage
# merges into a single report.
#
# Integration entries replay the sidecar handling from configureIntegrationRun
# in build.zig (subcommand detection, flag forwarding, @raw mode with the {file}
# token, .args, .stdin, .env). Formatter entries run `fmt --stdout`; lib entries
# run the `test` subcommand. Everything is run under kcov, sharded across $JOBS
# workers and merged at the end.
#
# Coverage only needs lines to execute, not output to match a golden, so this
# script does not compare against golden files. kcov also masks the child exit
# code, so pass/fail cannot be asserted here regardless; error paths still run
# and are counted.
#
# Network- and concurrency-heavy tests are EXCLUDED from the default run.
# Sockets, TLS, UDP, HTTP servers, deadlock detection, the file watcher, OS
# signals, the timeout fixtures, and the task/scheduler suite bind ports, depend
# on wall-clock timing, or deliberately run to a timeout. Under kcov's ptrace
# instrumentation they are slow and flaky while adding little interpreter-source
# coverage, so they are skipped by default. They remain reachable by name via
# TEST_FILTER when you specifically want them, and the per-file `timeout` below
# is the backstop for anything that slips through. The long-running HTTP-server
# fixtures (marked direct_run in their .zon) are always skipped.

set -o pipefail

ONEZ=${ONEZ:-./zig-out/bin/1z}
KCOV=${KCOV:-kcov}
KCOV_ARGS=${KCOV_ARGS:---include-path=src}
COVERAGE_DIR=${COVERAGE_DIR:-zig-out/coverage}
TESTDIR=${TESTDIR:-tests/integration}
JOBS=${JOBS:-4}
TEST_CASE_TIMEOUT=${TEST_CASE_TIMEOUT:-10}   # inner 1z --test-timeout
COVERAGE_TIMEOUT=${COVERAGE_TIMEOUT:-60}     # outer per-file wall-clock backstop
TEST_FILTER=${TEST_FILTER:-}
STDLIB="$PWD/lib"

# kcov's ptrace machinery is flaky on macOS under heavy parallelism: a small,
# nondeterministic fraction of concurrent runs crash (SIGSEGV / SIGBUS), though
# the same files pass reliably when run alone. The default JOBS is therefore
# kept modest (set by the Makefile) and any crashed file is retried serially
# below, where it almost always succeeds. On Linux kcov is stable and JOBS can
# be raised.
MAX_RETRIES=${COVERAGE_RETRIES:-2}

# Names matching this pattern are skipped by default; see the header note.
NETWORK_EXCLUDE_RE='^(sockets|tls-|udp|http_|net_http|deadlock|task_|cooperative_cancel|test_timeout|watch_|signal_)'

out_dir="$COVERAGE_DIR/integration"
work_dir="$COVERAGE_DIR/.integration-shards"
failures_file="$work_dir/failures.tsv"
# Drop any combined report: it is a union of this dir and the unit dir, so
# regenerating integration coverage leaves it stale. Only `make coverage`
# rebuilds it.
rm -rf "$out_dir" "$work_dir" "$COVERAGE_DIR/combined"
mkdir -p "$out_dir" "$work_dir"
: > "$failures_file"

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

is_subcommand() {
  case "$1" in
    run|eval|test|check|repl|version|fmt|lint|build) return 0 ;;
    *) return 1 ;;
  esac
}

# Run one corpus entry under kcov into a shard dir. Entry is "kind<TAB>token":
# int = integration test (sidecar replay), fmt = formatter input run through
# `fmt --stdout`, lib = a lib/ unit test run through `test`. All three exercise
# the same interpreter binary, so their coverage merges into one report.
run_one() {
  local entry="$1" shard_dir="$2"
  local kind="${entry%%$'\t'*}" token="${entry#*$'\t'}"

  case "$kind" in
    fmt)
      timeout "$COVERAGE_TIMEOUT" "$KCOV" $KCOV_ARGS "$shard_dir" "$ONEZ" \
        fmt --stdout "$token" > /dev/null 2>&1
      return $?
      ;;
    lib)
      timeout "$COVERAGE_TIMEOUT" "$KCOV" $KCOV_ARGS "$shard_dir" "$ONEZ" \
        test "--stdlib-path=$STDLIB" "--test-timeout=$TEST_CASE_TIMEOUT" --threads=1 "$token" > /dev/null 2>&1
      return $?
      ;;
  esac

  # kind == int: replay the integration sidecars for tests/integration/<token>.
  local name="$token"
  local base="$TESTDIR/$name" file="$TESTDIR/$name.1z"
  local flags_file="$base.flags"
  local raw=0 subcommand="" show_stack=1 has_test_timeout=0 has_threads=0
  local -a argv=() env_assign=()
  local line t a

  if [[ -f "$flags_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      t="$(trim "$line")"; [[ -z "$t" ]] && continue
      case "$t" in
        @raw) raw=1 ;;
        --no-show-stack) show_stack=0 ;;
        --test-timeout|--test-timeout=*) has_test_timeout=1 ;;
        --threads=*) has_threads=1 ;;
      esac
      if [[ -z "$subcommand" ]] && is_subcommand "$t"; then subcommand="$t"; fi
    done < "$flags_file"
  fi

  if [[ -f "$base.env" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      t="$(trim "$line")"; [[ -z "$t" ]] && continue
      [[ "$t" == *=* ]] && env_assign+=( "$t" )
    done < "$base.env"
  fi

  if [[ $raw -eq 1 ]]; then
    env_assign=( "ONEZ_STDLIB=$STDLIB" "${env_assign[@]}" )
    if [[ -f "$flags_file" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        t="$(trim "$line")"; [[ -z "$t" ]] && continue
        [[ "$t" == "@raw" ]] && continue
        if [[ "$t" == "{file}" ]]; then argv+=( "$file" ); else argv+=( "$t" ); fi
      done < "$flags_file"
    fi
  else
    argv=( "${subcommand:-run}" )
    [[ $show_stack -eq 1 ]] && argv+=( --show-stack )
    argv+=( "--stdlib-path=$STDLIB" )
    [[ $has_test_timeout -eq 0 ]] && argv+=( "--test-timeout=$TEST_CASE_TIMEOUT" )
    [[ $has_threads -eq 0 ]] && argv+=( "--threads=1" )
    if [[ -f "$flags_file" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        t="$(trim "$line")"; [[ -z "$t" ]] && continue
        case "$t" in
          --no-show-stack|--no-jit|@raw) continue ;;
        esac
        is_subcommand "$t" && continue
        argv+=( "$t" )
      done < "$flags_file"
    fi
    argv+=( "$file" )
    if [[ -f "$base.args" ]]; then
      while IFS= read -r a || [[ -n "$a" ]]; do
        a="${a%$'\r'}"; [[ -n "$a" ]] && argv+=( "$a" )
      done < "$base.args"
    fi
  fi

  # kcov masks the child's own exit code, so a non-zero status here means kcov
  # itself failed: either it timed out or it crashed under ptrace. Return that
  # status so the caller can record or retry the file. The shell job-death
  # notice for a crash is suppressed by redirecting the worker's stderr.
  local rc=0
  if [[ -f "$base.stdin" ]]; then
    timeout "$COVERAGE_TIMEOUT" env "${env_assign[@]}" \
      "$KCOV" $KCOV_ARGS "$shard_dir" "$ONEZ" "${argv[@]}" < "$base.stdin" > /dev/null 2>&1
    rc=$?
  else
    timeout "$COVERAGE_TIMEOUT" env "${env_assign[@]}" \
      "$KCOV" $KCOV_ARGS "$shard_dir" "$ONEZ" "${argv[@]}" > /dev/null 2>&1
    rc=$?
  fi
  return $rc
}

# Build the eligible entry list across three corpora that all drive the same
# interpreter binary: integration tests (with sidecar replay), formatter inputs,
# and lib/ unit tests. TEST_FILTER scopes every corpus by name.
declare -a eligible=()
skipped_network=0 skipped_direct=0
count_int=0 count_fmt=0 count_lib=0

# Integration corpus.
while IFS= read -r path; do
  name="$(basename "$path" .1z)"
  if [[ -n "$TEST_FILTER" ]]; then
    case "$name" in *"$TEST_FILTER"*) ;; *) continue ;; esac
  fi
  if [[ -f "$TESTDIR/$name.zon" ]] && grep -q 'direct_run' "$TESTDIR/$name.zon"; then
    skipped_direct=$((skipped_direct + 1)); continue
  fi
  # The network exclusion is bypassed when TEST_FILTER explicitly selects names.
  if [[ -z "$TEST_FILTER" && "$name" =~ $NETWORK_EXCLUDE_RE ]]; then
    skipped_network=$((skipped_network + 1)); continue
  fi
  eligible+=( "int"$'\t'"$name" ); count_int=$((count_int + 1))
done < <(rg --files -g '*.1z' "$TESTDIR" | sort)

# Formatter corpus: each input is reformatted via `fmt --stdout`.
while IFS= read -r path; do
  name="$(basename "$path" .txt)"
  if [[ -n "$TEST_FILTER" ]]; then
    case "$name" in *"$TEST_FILTER"*) ;; *) continue ;; esac
  fi
  eligible+=( "fmt"$'\t'"$path" ); count_fmt=$((count_fmt + 1))
done < <(rg --files -g '*.txt' tests/formatting | sort)

# Lib unit-test corpus: each file is run via the `test` subcommand.
while IFS= read -r path; do
  name="$(basename "$path" .1z)"
  if [[ -n "$TEST_FILTER" ]]; then
    case "$name" in *"$TEST_FILTER"*) ;; *) continue ;; esac
  fi
  eligible+=( "lib"$'\t'"$path" ); count_lib=$((count_lib + 1))
done < <(rg --files -g '*_test.1z' lib | sort)

if [[ ${#eligible[@]} -eq 0 ]]; then
  echo "No eligible coverage entries (filter='$TEST_FILTER')." >&2
  exit 1
fi

echo "Interpreter coverage: $count_int integration + $count_fmt formatter + $count_lib lib" \
     "across $JOBS workers (skipped $skipped_network network, $skipped_direct direct_run)"

# Round-robin shard the eligible files across JOBS background workers. Each
# worker accumulates into its own shard dir (kcov merges serial runs to the
# same dir); the shards are merged after all workers finish.
declare -a shard_dirs=() pids=()
for ((s = 0; s < JOBS; s++)); do
  shard_dir="$work_dir/shard-$s"
  mkdir -p "$shard_dir"
  shard_dirs+=( "$shard_dir" )
  # Worker stderr is discarded: per-run output already goes to /dev/null, and
  # this absorbs the shell's job-death notice when kcov crashes on a file
  # (crashed files are recorded for the serial retry pass below).
  (
    for ((i = s; i < ${#eligible[@]}; i += JOBS)); do
      run_one "${eligible[$i]}" "$shard_dir" || printf '%s\n' "${eligible[$i]}" >> "$failures_file"
    done
  ) 2>/dev/null &
  pids+=( $! )
done
for pid in "${pids[@]}"; do wait "$pid"; done

# Retry pass: the parallel run's failures are almost all kcov flaking under
# concurrency, so re-run each one serially (single retry dir, no other kcov
# processes competing), up to MAX_RETRIES attempts. Whatever still fails is a
# genuine straggler and is reported.
declare -a still_failed=()
retry_dir="$work_dir/retry"
if [[ -s "$failures_file" ]]; then
  mapfile -t failed_entries < <(sort -u "$failures_file")
  echo "Retrying ${#failed_entries[@]} crashed entry(ies) serially (up to $MAX_RETRIES attempts each)..."
  mkdir -p "$retry_dir"
  for entry in "${failed_entries[@]}"; do
    ok=0
    for ((attempt = 1; attempt <= MAX_RETRIES; attempt++)); do
      if ( run_one "$entry" "$retry_dir" ) 2>/dev/null; then ok=1; break; fi
    done
    [[ $ok -eq 0 ]] && still_failed+=( "$entry" )
  done
fi

# Merge every shard plus the retry dir that produced kcov output.
declare -a merge_inputs=()
for d in "${shard_dirs[@]}" "$retry_dir"; do
  if [[ -d "$d/1z" ]]; then merge_inputs+=( "$d" ); fi
done

if [[ ${#merge_inputs[@]} -eq 0 ]]; then
  echo "No coverage produced; nothing to merge." >&2
  exit 1
fi

"$KCOV" --merge "$out_dir" "${merge_inputs[@]}"

# Report only files that still failed after retries: they ran but contributed
# no coverage, so the report understates by exactly these.
if [[ ${#still_failed[@]} -gt 0 ]]; then
  printf '%s\n' "${still_failed[@]}" | sort > "$out_dir/failed-runs.txt"
  echo "WARNING: ${#still_failed[@]} file(s) still crashed or timed out under kcov after $MAX_RETRIES retries"
  echo "         and contributed no coverage. See $out_dir/failed-runs.txt."
fi

rm -rf "$work_dir"

pct=$(grep -o '"percent_covered": "[0-9.]*"' "$out_dir/kcov-merged/coverage.json" | tail -1 | grep -o '[0-9.]*')
echo "Integration coverage (integration + formatter + lib): ${pct:-?}%, report at $out_dir/index.html"
