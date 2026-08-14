# Guides

Guides are thematic. They take a problem that crosses several language
features and explain how to reason about it, make a design choice, and
build a maintainable program. They are not a second syntax reference and
they are not a linear course.

## Language design

- [Structures](/guides/structures/) — choose fields and methods, preserve
  invariants, and decide when a struct should own an object.
- [Unions](/guides/unions/) — model a value with several valid shapes,
  match it safely, and keep payload ownership explicit.
- [Memory without a collector](/guides/memory/) — scope ownership, aliases,
  `give`, `copy`, and early release.
- [Traps are bugs, errors are news](/guides/failure/) — choose absence,
  fallible errors, or a trap before writing recovery code.
- [Strings and copies](/guides/strings/) — immutable UTF-8, slices, and
  builders without hidden borrowing.

## Building programs

- [Organize a project and make a package](/guides/organization/) — establish
  a project root, author in a direct source subfolder, and promote the package
  to the installed store with the package commands.
- [Testing](/guides/testing/) — the ordinary Luce functions that `luce test`
  discovers, and how to keep tests close to the behavior they specify.
- [The compiler and the terminal](/guides/toolchain/) — source, artifacts,
  `luce`, `loom`, and debug/release behavior.
- [Performance](/guides/performance/) — what the current measurements say,
  which choices affect a program, and where to measure instead of guess.

## Complete programs

When you want code to copy, run, and change, these pages keep the same
reader-first explanations but use a complete program as their centre:

- [Hello and arguments](/guides/first-program/) — the smallest program and
  its command-line input.
- [Loops and ranges](/guides/loops/), [lists](/guides/lists/),
  [maps](/guides/maps/), and [arrays](/guides/arrays/) — the core collection
  shapes in working programs.
- [Text processing](/guides/text/) and [files](/guides/files/) — common
  host-facing tasks with the standard library.
- [Structs](/guides/structs/) and [ownership in context](/guides/ownership-example/)
  — values, objects, and the words that move or release them.
- [Optionals](/guides/optionals/), [errors](/guides/errors/), and
  [traps](/guides/traps/) — the three different failure outcomes.
- [Complete bundled programs](/guides/programs/) — multi-file programs,
  including the editor, games, and utilities.

Start with [Learn](/learn/) if you are new to Luce. Use the
[Reference](/reference/) for an exact rule and the [Library](/library/)
for a module's complete API.
