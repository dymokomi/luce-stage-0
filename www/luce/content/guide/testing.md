# Testing

`luce test` runs tests written in Luce. There is no test framework to learn:
a test is a top-level function whose name starts with `test_`.

## Write a test

The runner discovers public, top-level, zero-parameter `func test_*()`
declarations. A test returns nothing, or declares `-> !` when it needs to
propagate a fallible operation. Helpers can have any other name.

```luce module file=tests/geometry_test.luc
func square(side: long) -> long:
    return side * side

func test_square_of_three():
    assert(square(3) == 9)

func test_square_of_zero():
    assert(square(0) == 0)
```

Put tests under `tests/` beside the code they exercise. `luce test` with no
paths searches `./tests`; passing files or directories narrows the search.
Directories are walked recursively in sorted order. Imports resolve as they
do for any Luce module, including a project's `luce.yaml` root when one is
present.

## A test either passes or reports its failure

`assert(condition)` uses the language's own assertion. A trap reports its
stable code, location, and call trace. An uncaught error reports its message
and raise location. Leaks and a program that calls `exit` also fail the test.
The process exits non-zero when compilation, discovery, or any test fails.

If a test is checking a fallible operation, handle it explicitly:

```luce module file=tests/files_test.luc
import std.files

func test_missing_file_is_reported():
    let text = files.read("does-not-exist.txt") catch ""
    assert(text == "")

func test_writes_a_file() -> !:
    try files.write("result.txt", "ok")
```

The runner gives each test call a fresh runtime. A heap, ownership scopes,
call-depth budget, trap report, and leak census from one test do not carry
into the next test.

## Discovery errors are not skips

The runner refuses a `test_*` declaration that could never be called:

- a private function;
- a function with parameters;
- a function that returns a value instead of nothing or `!`;
- a function nested in a `struct`, `enum`, or `union`.

It also refuses a malformed file. A file named on the command line must
contain tests, and a swept `*_test.luc` file must contain tests. Other files
under the search directory may be helper modules without tests; they are
reported as such rather than silently disappearing.

## How the runner executes tests

Each source file is compiled once. The compiler synthesizes an entry point
that receives one test name, and the runner opens the compiled artifact once
for each discovered test. Calls run in declaration order, files in sorted
order, and tests are not parallelized. `luce test` always builds debug
artifacts so trap locations are available, and it accepts no build options.

This design keeps tests ordinary Luce programs. They use normal imports and
the normal host gate; the runner adds discovery and isolation, not another
language or assertion model.
