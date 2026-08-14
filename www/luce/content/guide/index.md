# The Luce guide

The Guide is the language book. Read the early chapters in order when you
are learning Luce; later chapters help you design larger programs. The final
section is deliberately slower and more exact: it is where you look up a rule
when a program is surprising.

The [Tour](/tour/) is the one-page overview. The [Command Line Tool](/command-line/)
covers installation, building, the editor, packages, and tests. The
[Library](/library/) is the API reference for shipped modules.

## 1. Write useful programs

Start with a program that accepts input, repeats work, and stores data:

- [Hello and arguments](/guide/first-program/) — the smallest complete
  program and its command-line input.
- [Loops and ranges](/guide/loops/) — `range`, `for`, `while`, `break`, and
  `continue`.

The language chapters then fill in the core ideas in the order a program uses
them:

- [Values and types](/guide/language/values/) — literals, numeric promotion,
  strings, enums, and function values.
- [Control flow](/guide/language/control/) — conditions, loops, and the
  parser's deliberately explicit forms.
- [Functions and structs](/guide/language/functions/) — parameters, returns,
  function values, lambdas, and value structs.
- [Enums](/guide/language/enums/) — named sets and exhaustive `match`.
- [Lists, maps and arrays](/guide/language/collections/) — the collection
  shapes and how iteration sees each one.
- [Constants and shared tables](/guide/language/constants/) — file-scope
  `const`, program-root identity, and immutable data.
- [Modules](/guide/language/modules/) — imports and the `std` namespace.
- [Visibility](/guide/language/visibility/) — public and private boundaries.
- [The outside world](/guide/language/host/) — arguments, files, terminals,
  and host services.

- [Lists](/guide/lists/) — build, sort, search, and slice a sequence.
- [Maps](/guide/maps/) — keep insertion-ordered key/value data.
- [Arrays and grids](/guide/arrays/) — use fixed-shape storage for numeric
  work.
- [Text processing](/guide/text/) — split, join, trim, search, and format
  text.
- [Files](/guide/files/) — cross the host boundary through `std.files`.

## 2. Shape data and control its lifetime

Once the basic operations feel familiar, choose data shapes and make their
ownership visible:

- [Structures: keep data and invariants together](/guide/structures/) — decide
  which fields belong together and where behavior should live.
- [Structs](/guide/structs/) — value aggregates, methods, static functions,
  and structs that carry objects.
- [Strings and copies](/guide/strings/) — immutable UTF-8 values, slices, and
  builders without hidden borrowing.
- [Memory without a collector](/guide/memory/) — scope ownership, aliases,
  and the cost of moving or copying objects.
- [`give`, `copy`, and `free`](/guide/ownership-example/) — see ownership
  decisions in complete programs.
- [Unions: make alternatives explicit](/guide/unions/) — model several valid
  shapes and keep payload ownership explicit.

## 3. Handle the outcomes of a computation

Luce makes absence, recoverable failure, and bugs different types of outcome:

- [Optionals](/guide/optionals/) — represent a value that may not be there.
- [Errors](/guide/errors/) — propagate and handle fallible operations.
- [Traps are bugs, errors are news](/guide/failure/) — choose the right
  boundary before writing recovery code.
- [Traps](/guide/traps/) — read stable codes, source locations, and traces.

## 4. Build larger programs

These chapters apply the language to a project rather than a single file:

- [Concurrency and workers](/guide/concurrency/) — use share-nothing runtimes,
  explicit ownership, and structured joins for multi-threaded work.
- [The bundled programs](/guide/programs/) — study complete multi-file
  programs, including utilities, games, and the editor.
- [Performance](/guide/performance/) — measure a real workload and understand
  what the current benchmark snapshot does and does not promise.

## 5. Exact language rules

These chapters are the reference part of the Guide. They are intentionally
plain and complete rather than motivational:

- [Source text and lexical elements](/guide/reference/lexical/) — encoding,
  indentation, comments, literals, keywords, and operators.
- [Types](/guide/reference/types/) — every value, object, resource, and
  expression type.
- [Expressions](/guide/reference/expressions/) — operators, precedence,
  calls, lambdas, indexing, slicing, and refused shapes.
- [Statements and declarations](/guide/reference/statements/) — `let`, `var`,
  assignment, control flow, functions, structs, and constants.
- [Ownership](/guide/reference/ownership/) — the complete ratified model,
  S1–S46.
- [Traps and errors](/guide/reference/failure/) — every runtime code and
  recoverable error code.
- [Modules](/guide/reference/modules/) — imports, visibility, and the `std`
  namespace.
- [Builtins](/guide/reference/builtins/) — every free function and method
  signature.
