# Where Luce stands

This page separates three things that are easy to confuse:

1. what you can use today;
2. what Luce intentionally does not include; and
3. what is being considered or built next.

The rest of the site documents the first category. The [Guide](/guide/)
teaches the language and closes with its exhaustive Language Reference; the
[Tour](/tour/) is the short introduction.

## Available today

### Language

- Static types with inference, checked arithmetic and explicit numeric
  promotion.
- Values, structs, enums, unions, functions, interfaces and capture-free
  lambdas.
- Lists, maps, arrays and builders.
- `T?` for absence, with narrowing and `else`.
- `T!` for recoverable failure, with `try`, `catch` and `error(...)`.
- Scope ownership for heap objects and resources, with `give`, `copy`,
  `free` and `new`.
- Modules, visibility, file-scope constants and named/default arguments.
- Methods with implied `self`, `static` functions and multiple returns.
- Explicit nominal interfaces with read-only method dispatch; interface
  values can be mixed in lists, maps, arrays and struct fields.
- Workers with scope-owned `task` values and joins.

These are not separate implementations on separate execution paths. The
compiler, shared runtime and differential specification suite test the
same observable behavior together.

### Toolchain

The repository builds two programs:

- `luce` builds a standalone executable by default, or explicitly emits a
  loadable `.lc` artifact or relocatable object, prints IR, and runs Luce test
  functions.
- `loom` runs an existing `.lc`, or compiles a `.luc` file and runs it. It
  provides the terminal and file services used by a program.

A `.lc` file is native machine code. Running one does not invoke the
compiler or LLVM. A source file does need the compiler and the C linker
during its build. [Command-Line Tools](/guide/command-line/) gives the exact
commands and failure modes.

### Standard library and complete programs

The compiler ships these standard modules: `std.math`, `std.files`,
`std.strings`, `std.lists`, `std.paths`, `std.os`, `std.term`, `std.zip`,
`std.json`, `std.gpu` and `std.ui`. They are written in Luce and embedded
in the toolchain.

The repository also contains complete programs, including a parser,
archive tool, file utilities, games and a terminal editor. The
[Guide](/guide/) includes them as runnable programs because they use the same
language and libraries available to you; they are not special cases in the
compiler.

## Deliberately outside the language

These are design decisions, not missing documentation:

- garbage collection, reference counting, shared ownership and weak
  references;
- implicit narrowing, shadowing, truthiness and a ternary operator;
- tuples as a type, user-defined generics, interface inheritance and operator
  overloading;
- exceptions, `errdefer`, asynchronous functions and reflection;
- capturing closures. Use a struct with a method when state must travel
  with behavior.

[Memory and Ownership](/guide/memory/), [Error Handling](/guide/errors/),
and the [exact language rules](/guide/reference/) explain the alternatives
Luce chose and the rules that follow from them.

## Not shipped yet

The following work is intentionally separate from the language core:

- typed channels between workers;
- package fetching and publishing (the consuming package layout exists,
  but the tool does not fetch a registry);
- cross-compilation and sharing one runtime library between artifacts;
- a formatter, language server and debugger;
- additional library conveniences such as direct code-point iteration and
  character-class helpers.

An item here is not a promise about a release date. It is a boundary around
what the current toolchain supports. When a boundary changes, the complete
programs, reference coverage checks and this page should change together.

## Keeping the page honest

Every runnable Luce block on this site is compiled and run during the site
build. Expected traps, errors and refused programs use their corresponding
toolchain path. The build also checks links and selected compiler-to-
reference name lists. This catches stale code and API tables; it does not
replace a human reading the surrounding explanation.
