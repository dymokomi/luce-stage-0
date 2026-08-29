# Testing

`luce test` runs tests written in Luce. There is no test framework to learn:
a test is a top-level function whose name starts with `test_`.

Use tests to state behavior at the same boundary a caller sees. A pure
function test calls the function directly. A module test imports the module
normally. A host-facing test may use the same standard-library service as the
program, but it should keep files and other external state explicit.

## Write a test

The runner discovers `pub`, top-level, zero-parameter `func test_*()`
declarations. A test returns nothing, or declares `-> !` when it needs to
propagate a fallible operation. Helpers can have any other name.

```luce module file=tests/geometry_test.luc
func square(side: i64) -> i64:
    return side * side

pub func test_square_of_three():
    assert(square(3) == 9)

pub func test_square_of_zero():
    assert(square(0) == 0)
```

Put tests under `tests/` beside the code they exercise. `luce test` with no
paths searches `./tests`; passing files or directories narrows the search.
Directories are walked recursively in sorted order. Imports resolve as they
do for any Luce module, including a project's `luce.yaml` root when one is
present.

A small project commonly looks like this:

```text
sample/
├── luce.yaml
├── main.luc
├── geometry.luc
└── tests/
    ├── geometry_test.luc
    └── support.luc
```

`geometry_test.luc` imports `geometry` from the project root. `support.luc`
may define shared helpers without declaring tests; the runner reports it as a
file without tests rather than pretending it ran. Keep unrelated module,
standard-library, editor, and integration concerns in separate files so a
failure names the surface it proves.

## Arrange data without a test DSL

Tests use ordinary structures, lists, loops, and helper functions. A compact
table of cases avoids repeating the assertion while keeping each input
visible:

```luce module file=tests/parse_test.luc
struct Case:
    let text: str
    let expected: i64

pub func test_valid_integers():
    let cases = [
        Case(text = "0", expected = 0),
        Case(text = "-7", expected = -7),
        Case(text = "42", expected = 42),
    ]
    for item in cases:
        let actual = parse_i64(item.text) else trap("expected an integer")
        assert(actual == item.expected)
```

There is no parameterized-test declaration or hidden fixture lifecycle. When
setup can fail, put it in a fallible helper or in a `test_*() -> !` function;
normal scope cleanup and ARC still run on every ordinary return or propagated
error.

## A test either passes or reports its failure

`assert(condition)` uses the language's own assertion. A trap reports its
stable code, location, and call trace. An uncaught error reports its message
and raise location. Leaks and a program that calls `exit` also fail the test.
The process exits non-zero when compilation, discovery, or any test fails.

One failed test does not prevent later discovered tests from running. The
report names each source file, flushes a `test` line before entering every
call, prints `ok` or `FAIL` when that call finishes, and ends with passed,
failed, test, and file counts. A slow or hung test therefore identifies itself.
Compile or discovery failures are counted as files not run, so a partially
executed suite cannot finish green.

If a test is checking a fallible operation, handle it explicitly:

```luce module file=tests/files_test.luc
import std.files

pub func test_missing_file_is_reported():
    let text = files.read("does-not-exist.txt") catch ""
    assert(text == "")

pub func test_writes_a_file() -> !:
    try files.write("result.txt", "ok")
```

The runner isolates the Luce runtime, not the operating-system working
directory. A test that creates `result.txt` must choose a collision-free test
path and remove it when the test owns it. Compiler scratch artifacts are
claimed under unique names and removed by the runner; files created by the
program remain the program's responsibility.

The runner gives each test call a fresh runtime. Its heap, reference census,
call-depth budget, and trap report do not carry into the next test. Fresh
runtime state makes an accidental reference leak a failure of the one test
that created it. It does not reorder tests or make external services
deterministic. Prefer pure tests for language and data behavior, then keep the
smaller set of filesystem, terminal, or process tests in clearly named files.

## Discovery errors are not skips

The runner refuses a `test_*` declaration that could never be called:

- a function that is not `pub`;
- a function with parameters;
- a function that returns a value instead of nothing or `!`;
- a function nested in a `struct`, `class`, `enum`, or `union`.

It also refuses a malformed file. A file named on the command line must
contain tests, and a swept `*_test.luc` file must contain tests. Other files
under the search directory may be helper modules without tests; they are
reported as such rather than silently disappearing.

A named path is a claim: `luce test tests/support.luc` refuses when the file
has no runnable tests. This prevents a misspelled function or stale test file
from turning into a successful zero-test run. A bare `luce test` also refuses
when no `tests/` directory exists.

## How the runner executes tests

Each source file is compiled once. The compiler synthesizes an entry point
that receives one test name, and the runner opens the compiled artifact once
for each discovered test. Calls run in declaration order, files in sorted
order, and tests are not parallelized. `luce test` always builds debug
artifacts so trap locations are available, and it accepts no build options.

The file name and each test's progress line are flushed before the test enters.
Output produced by the test appears after that line and before its verdict. A
result line is printed when the test returns, traps, or raises. Color is used
only on a terminal and `NO_COLOR` disables it, so redirected reports retain the
same stable text layout.

This design keeps tests ordinary Luce programs. They use normal imports and
the normal host gate; the runner adds discovery and isolation, not another
language or assertion model.

Run the narrowest useful path while editing, then the project suite before a
commit:

```text
luce test tests/geometry_test.luc
luce test
```

The command takes paths, not name filters. Keep a source file cohesive enough
that choosing the file is a useful testing boundary. [Packages and
Projects](/tools/packages/) explains project roots and imports; [Error
Handling](/guide/errors/) distinguishes the failures and traps the report
shows.
