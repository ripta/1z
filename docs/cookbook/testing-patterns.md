# Testing Patterns

The testing library provides assertion words and test grouping. Every test
file is a runnable program -- no test harness needed.

## Equality assertions

`assert=` checks that the top two stack values are equal. The third value
is a message shown on failure:

```
use "testing" ;

4 2 2 + "two plus two" assert=
"hello" "hel" "lo" #append "string concatenation" assert=
```

Output:

```
PASS: two plus two
PASS: string concatenation
```

## Boolean assertions

`assert-true` and `assert-false` check truthiness:

```
use "testing" ;

t 1 0 > "one is greater" assert-true
f 1 0 < "one is not less" assert-false
```

Output:

```
PASS: one is greater
PASS: one is not less
```

## Error assertions

`assert-error` checks that a quotation throws any error.
`assert-error-type` checks for a specific error type:

```
use "testing" ;

[ 1 0 / ] "division by zero throws" assert-error
[ 1 0 / ] division-by-zero: "specific error type" assert-error-type
```

Output:

```
PASS: division by zero throws
PASS: specific error type
```

## Grouping with `test-section`

`test-section` prints a header to organize test output. Each section is
independent -- a failure in one does not prevent later sections from running:

```
use "testing" ;

"arithmetic" test-section
4 2 2 + "addition" assert=

"comparisons" test-section
t 1 0 > "greater than" assert-true
```

Output:

```
=== arithmetic ===
PASS: addition
=== comparisons ===
PASS: greater than
```

## Running tests

Save any test file as `.1z` and run it directly:

```
./zig-out/bin/1z my-tests.1z
```

Integration tests in the project live under `tests/integration/`. Run them
all with `make integration-test`, or the full suite with `make test`.
