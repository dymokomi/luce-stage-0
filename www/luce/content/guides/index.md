# Guides

Guides are thematic, but their order is deliberate: start with a working
program, add data and control flow, then learn the ownership and failure
rules that make larger programs safe. The final pages cover packages,
testing, workers, and performance.

## 1. Start with a working program

Install the tools, compile an executable, and make a small program respond
to its inputs before taking on a larger design.

- [Build and run Luce programs](/command-line/build/) — install the compiler,
  editor, VS Code extension, and the commands that turn source into a program.
- [Hello and arguments](/guide/first-program/) — the smallest program and
  its command-line input.
- [Loops and ranges](/guide/loops/) — repeat work with `range`, `for`,
  `while`, `break`, and `continue`.

## 2. Work with data

- [Lists](/guide/lists/) — build, sort, search, and slice a growable sequence.
- [Maps](/guide/maps/) — keep insertion-ordered key/value data and count it.
- [Arrays and grids](/guide/arrays/) — use fixed-shape storage for numeric work.
- [Text processing](/guide/text/) — split, join, trim, search, and format text.
- [Files](/guide/files/) — read and write through `std.files`, handling the
  fallible boundary.

## 3. Shape the program

- [Structures: keep data and invariants together](/guide/structures/) —
  decide which fields belong together and where behavior should live.
- [Structs](/guide/structs/) — build value aggregates, methods, static
  functions, and structs that carry objects.
- [Interfaces](/guide/interfaces/) — share a small behavior across different
  structs, including multi-value methods and heterogeneous collections.
- [Strings and copies](/guide/strings/) — understand immutable UTF-8 values,
  slices, and builders without hidden borrowing.
- [Memory without a collector](/guide/memory/) — learn scope ownership,
  aliases, and the cost of moving or copying objects.
- [give, copy and free](/guide/ownership-example/) — see the ownership words
  in complete programs.

## 4. Handle absence and failure

- [Optionals](/guide/optionals/) — represent a value that may not be there.
- [Errors](/guide/errors/) — propagate and handle failures from the outside
  world with `try` and `catch`.
- [Traps are bugs, errors are news](/guide/failure/) — choose between an
  optional, a fallible error, and a trap before writing recovery code.
- [Traps](/guide/traps/) — read the stable code, source location, and trace
  when a program violates a checked precondition.
- [Unions: make alternatives explicit](/guide/unions/) — model several valid
  shapes and keep payload ownership explicit.

## 5. Build maintainable programs

- [Organize a project and make a package](/command-line/packages/) — author in a
  direct source subfolder, version it, and promote it to an installed package.
- [Testing](/command-line/testing/) — write ordinary `test_*` functions and keep
  tests close to the behavior they specify.
- [Concurrency and workers](/guide/concurrency/) — build multi-threaded work
  with share-nothing runtimes, explicit ownership, and structured joins.
- [The bundled programs](/guide/programs/) — study complete multi-file
  programs, including utilities, games, and the editor.
- [Performance](/guide/performance/) — measure the program you care about and
  understand what the current benchmark snapshot does and does not promise.

Start with [Tour](/tour/) if you want a guided language course. Use the
[Guide](/guide/) for an exact rule and the [Library](/library/) for a
module's complete API.
