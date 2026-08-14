# The Luce guide

The Guide is the practical language book. Read it in order when Luce is new;
each chapter answers one question that comes up while building a real
program. The [Tour](/tour/) is the one-page map. The [Reference](/reference/)
is the exhaustive rule book. The [Library](/library/) documents the modules
and packages you can import.

## Start here

1. [Build and run a Luce program](/guide/toolchain/) — install the release,
   compile an executable, and understand the few commands you need.
2. [Editor and VS Code](/guide/editor/) — use the shipped editor or the local
   extension without changing the build loop.
3. [Hello and arguments](/guide/first-program/) — write a complete program
   and read its command-line input.

## Learn the language

Read these chapters in order. They introduce one idea, then use it in the
next idea rather than making you learn the whole grammar first.

- [Values and types](/guide/values/) — literals, inference, numeric promotion,
  strings and function values.
- [Control flow](/guide/control/) — conditions, loops, matching and the
  explicit forms the parser refuses to guess at.
- [Functions and structs](/guide/functions/) — parameters, returns, methods,
  function values and value structs.
- [Enums](/guide/enums/) — named sets and exhaustive `match`.
- [Collections](/guide/collections/) — choose a list, map or fixed-shape array
  by the question your data needs to answer; then read the focused chapters
  for [lists](/guide/lists/), [maps](/guide/maps/) or [arrays](/guide/arrays/).
- [Text processing](/guide/text/) and [files](/guide/files/) — work with
  text and cross the host boundary deliberately.
- [Constants and shared tables](/guide/constants/) — immutable file-scope
  data and program-root identity.
- [Modules](/guide/modules/) and [visibility](/guide/visibility/) — split a
  program without making its dependencies mysterious.

## Design larger programs

- [Organize a project and make a package](/guide/organization/) — keep a
  source package as a direct subfolder, add `luce.yaml` when it needs a
  version, and use the package commands.
- [Structures](/guide/structures/) — keep data and invariants together.
- [Interfaces](/guide/interfaces/) — share behavior across different structs,
  including multi-value methods and heterogeneous collections.
- [Strings and copies](/guide/strings/), [memory](/guide/memory/) and
  [`give`, `copy`, `free`](/guide/ownership-example/) — make ownership visible.
- [Optionals](/guide/optionals/), [errors](/guide/errors/) and
  [failure boundaries](/guide/failure/) — distinguish absence, recoverable
  failure and a bug.
- [Unions](/guide/unions/) — model several valid shapes explicitly.
- [Concurrency and workers](/guide/concurrency/) — build multi-threaded work
  with share-nothing runtimes and structured joins.
- [Testing](/guide/testing/) — keep behavior repeatable as the program grows.
- [The outside world](/guide/host/) — arguments, terminals and host services.
- [Bundled programs](/guide/programs/) and [performance](/guide/performance/)
  — study complete programs and measure the code you care about.

When a chapter leaves a question about exact syntax, go to the matching
article in the [Reference](/reference/). It is intentionally boring: its job
is to be trusted lookup material, not to teach by surprise.
