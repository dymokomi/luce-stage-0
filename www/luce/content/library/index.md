# Library

Luce has two kinds of reusable code. The standard library is a small set of
ordinary Luce modules embedded in the compiler: `import std.math` works
wherever the toolchain is available. Packages are ordinary source trees beside
an application until their author chooses to version and publish them. The
maintained `termui` package is documented here because it is a useful example
of that second kind.

Each module follows the same language rules as application code. Containers
have scope ownership, arithmetic is checked, and a host-facing module is
available only when the program has a host. `std.paths`, `std.math`,
`std.strings`, `std.lists`, `std.json`, and the byte-only parts of `std.zip`
are pure; `std.files`, `std.os`, `std.term`, `std.ui`, `std.gpu`, and the
file doors in `std.zip` use host services.

The low-level `std.ui` and `std.gpu` modules are host boundaries. On macOS an
installed runner may provide a Metal-backed implementation; a host without a
backend reports `host_unavailable`. Higher-level packages should keep that
fact at their boundary rather than making every application know the OS API.

## Choose a module

| Module | Use it for |
|---|---|
| [`std.math`](/library/math/) | scalar math, array reductions, and a seeded generator |
| [`std.strings`](/library/strings/) | search, splitting, formatting, characters, and UTF-8 bytes |
| [`std.files`](/library/files/) | text, bytes, directories, and scope-owned file handles |
| [`std.lists`](/library/lists/) | stable comparator sorting for lists |
| [`std.paths`](/library/paths/) | joining and inspecting path text without touching the host |
| [`std.os`](/library/os/) | memory, processor, shell, and terminal services |
| [`std.term`](/library/term/) | the shorter terminal drawing and input facade |
| [`termui`](/library/termui/) | a deterministic renderer, cell surface, views, layout, and events |
| [`std.zip`](/library/zip/) | ZIP/DEFLATE over byte lists, plus explicit file helpers |
| [`std.json`](/library/json/) | parse, inspect, build, and write JSON values |
| [`std.gpu`](/library/gpu/) | backend-neutral drawing surfaces |
| [`std.ui`](/library/ui/) | windows and their drawing surfaces |

Import only what a module needs. A module's public functions are documented
on its page with signatures and examples; implementation helpers remain
private and are not part of the API.

## Absence and failure

The library uses the language's two non-trap outcomes consistently. A
function that may have no answer returns `T?`; a function that asks the host
to do something and may be refused returns `T!` or `!`. For example,
`strings.find` and `json.parse` have different shapes because a missing match
is ordinary absence while malformed JSON has a reason worth reporting.

## Adding a module

A new standard module is written in `src/luce/std/NAME.luc`, added to the
compiler's embedded-module table and standard-library tests, then documented
here and on its own page. A package follows the project layout in the
[organization guide](/guide/organization/): source first, `luce.yaml` and a
version when it is ready to be shared. Each page describes the public surface
that the source actually exports; the site checks that named functions and
constants do not drift.
