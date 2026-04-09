#!/usr/bin/env bash

for file in tests/integration/*.1z; do
  base=${file:t:r}
  sub=run
  if [[ -f tests/integration/$base.subcommand ]]; then
    sub=$(tr -d ' \t\r\n' < tests/integration/$base.subcommand)
    [[ -z $sub ]] && sub=run
  fi
  cmd=(timeout 8 ./zig-out/bin/1z $sub)
  show_stack=1
  if [[ -f tests/integration/$base.flags ]]; then
    while IFS= read -r flag || [[ -n $flag ]]; do
      flag=${flag//$'\r'/}
      flag=${flag##[[:space:]]}
      flag=${flag%%[[:space:]]}
      [[ -z $flag ]] && continue
      if [[ $flag == --no-show-stack ]]; then
        show_stack=0
        continue
      fi
      if [[ $flag == --no-jit ]]; then
        continue
      fi
      cmd+=($flag)
    done < tests/integration/$base.flags
  fi
  if (( show_stack )); then
    cmd+=(--show-stack)
  fi
  cmd+=(--stdlib-path=lib "$file")
  if [[ -f tests/integration/$base.args ]]; then
    while IFS= read -r arg || [[ -n $arg ]]; do
      arg=${arg//$'\r'/}
      [[ -z $arg ]] && continue
      cmd+=($arg)
    done < tests/integration/$base.args
  fi
  envcmd=(env)
  if [[ -f tests/integration/$base.env ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      line=${line//$'\r'/}
      [[ -z $line ]] && continue
      envcmd+=($line)
    done < tests/integration/$base.env
  fi
  printf 'RUN %s\n' "$base"
  if [[ -f tests/integration/$base.stdin ]]; then
    "${envcmd[@]}" "${cmd[@]}" < tests/integration/$base.stdin > /tmp/1z-scan.out 2> /tmp/1z-scan.err
  else
    "${envcmd[@]}" "${cmd[@]}" > /tmp/1z-scan.out 2> /tmp/1z-scan.err
  fi
  rc=$?
  if [[ $rc -eq 124 ]]; then
    echo "TIMEOUT $base"
    break
  fi
  expected=0
  if [[ -f tests/integration/$base.exitcode ]]; then
    expected=$(tr -d ' \r\n' < tests/integration/$base.exitcode)
  elif [[ -f tests/integration/$base.stderr.golden ]]; then
    expected=1
  fi
  if [[ $rc -ne $expected ]]; then
    echo "UNEXPECTED $base rc=$rc expected=$expected"
    sed -n '1,40p' /tmp/1z-scan.err
    break
  fi
done
