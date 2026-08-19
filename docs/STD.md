# The standard library

The standard library is ordinary Luce source embedded in the compiler from
`src/luce/std/*.luc`. A program imports it through the reserved `std.`
namespace:

```luce
import std.math
import std.strings

func main():
    let power = math.ipow(3, 2)
    print(strings.upper("luce") + " " + str(power))
```

An import binds the module's final name (`math`, `strings`). `import math`
still means a project or sibling module; it never searches the standard
library. This prevents a local file from shadowing a standard module and
prevents a standard name from hiding local source.

The public [Library](https://luce.luciaos.com/library/) is the user-facing API
reference. This document owns the compiler integration, module boundaries, and
cost of changing the embedded library.

## Shipped modules

| Import | Purpose | Main public surface |
|---|---|---|
| `std.io` | the pure byte-stream contract | interfaces `Reader` (`read`) and `Writer` (`write`, `flush`); the `drain` and `send` loops over them |
| `std.math` | scalar math, array reductions, deterministic random values | constants `pi`, `tau`, `e`; rounding, exp/log/power, trigonometry, vector reductions and transforms, `Rng` |
| `std.strings` | operations built above core UTF-8 scalar primitives | find/count/prefix/suffix, character classes, trim/case/replace/repeat, split/join, width/take/pad, decimal formatting, byte conversion |
| `std.lists` | element-type-specialized list algorithms | stable `list.sort_by(func(T, T) -> bool)` routed as a method after import |
| `std.paths` | pure path-name manipulation | absolute check, join/joined, base, directory, extension, stem |
| `std.files` | fallible whole-file, directory, and open-file APIs | kind/existence, text/line/byte reads and writes, append/delete/rename/mkdir, `Mode` and the `File` class (fallible `init(path, mode)`, conforming to `io.Reader`/`io.Writer`), entries/list |
| `std.os` | console, time, environment, process and machine services | line input, standard error, clocks, environment, `os.run` (with an optional stdin feed), `Process` (a held child: feed/read/ready/wait), `stdin`/`stdout`/`stderr` as `io` streams, memory and CPU facts |
| `std.term` | the terminal | frame drawing (rows/cols, clear/move/style/write/flush), `copy` to the system clipboard, one typed `Event` stream behind `read()`, border glyphs and `junction` |
| `std.json` | RFC 8259 tree, parser, and writer | `Json` union, `parse`, `quote`, typed accessors, compact and pretty writing |
| `std.zip` | ZIP/DEFLATE in Luce | archive read/write, entries/extract, CRC, writer, inflate/deflate, text/byte conversion |
| `std.gpu` | backend-neutral low-level drawing surface | backend identity and `Surface` operations |
| `std.network` | TCP transport | `Connection` (static `dial`, read/write/flush, conforming to `io.Reader`/`io.Writer`), `Listener` (fallible `init(port)`, accept/port) |
| `std.http` | HTTP/1.1 client in pure Luce | `get`, `post`, `Client` (base URL + default headers), `Response` with `ok`/`text`/`json`; status codes are data |
| `std.ui` | low-level native windows | `Window` with a fallible init (`try ui.Window(...)`) and a window-owned GPU surface |
| `std.build` | the plan a `build.luc` declares | `Plan` (program/library/object/command steps, `default`, `emit` printing versioned JSON), `Step.needs` edges; the luce tool executes the plan (docs/BUILD.md) |

`termui` is a maintained package, not an embedded `std` module. It appears in
the public Library because it ships with the release, while keeping package
resolution and standard-module embedding as two honest mechanisms.

## Pure and hosted modules

Most standard code is pure Luce. `io`, `math`, `strings`, `lists`, `paths`,
`json`, and the codec portions of `zip` use language operations only. `files`, `os`, `term`,
`ui`, `gpu`, and `network` reach host services through `Builtin.NAME`, a synthetic
compiler namespace accepted only in embedded standard-library source.

`Builtin` is not importable and the spelling has no compiler privilege in
project or package source; a program may even declare its own type by that
name. Its rows live in `semantics/builtins.zig` separately from the public
prelude, so adding a host operation does not reserve, highlight, or document
its implementation name. Public standard declarations are the only
supported surface; the raw names are an implementation seam between stage 4
and MIR.

Importing a hosted module does not grant host access. The semantic host gate
checks the actual reached operation, and a missing runtime service traps
`host_unavailable`. Unused functions are removed by MIR reachability pruning,
so an imported module costs only the declarations the program reaches.

## Type and ownership rules

Standard functions use the same explicit type vocabulary and ARC rules as user
code:

- text is `str`, scalar positions are `i64`, and binary data is `list[u8]` or
  immutable `bytes` where the API says so;
- arrays state rank as `array[T, _, ...]` and receive dimensions at
  construction;
- functions use ordinary `T?` absence and `T!` recoverable errors;
- lists, maps, arrays, files, tasks, classes, windows, and surfaces are shared
  references; returned fresh outer containers still retain shared reference
  elements; and
- standard code has no privileged ownership syntax, unchecked arithmetic, or
  implicit numeric conversion.

Whole-file text APIs validate UTF-8. Byte APIs preserve arbitrary data.
File-handle and task cleanup follows last-release ARC; a standard wrapper must
not add a competing manual lifetime convention.

## Compiler-routed methods

Some library operations read naturally as methods while remaining standard
source. After the relevant import, semantics routes the receiver syntax to the
module function or a type-specialized template. `values.sort_by(before)` is
the canonical example: `std.lists` contains one template, and the compiler
specializes it for the concrete element type and comparator signature.

The route is visible in diagnostics. Calling a routed method without importing
its owning module reports the missing import rather than pretending the method
is a builtin. Core operations such as `append`, indexing, and `len` remain
language/runtime primitives.

## Adding or changing a module

A new embedded module costs all of these surfaces:

1. Add `src/luce/std/name.luc` with ordinary public/private declarations.
2. Add exactly one embedded-module row in the source loader's standard module
   table.
3. Add positive and negative differential specifications. Pure and hosted
   behavior both run on the compiled path and oracle; hosted tests use explicit
   host fixtures.
4. Add compiler routing only when receiver syntax materially improves a real
   generic operation. Keep the standard source as the implementation.
5. Add or update the public Library page. The site coverage audit compares the
   embedded module's public roster with documented signatures.
6. Run focused std/spec/site lanes, then the complete release gate at the phase
   boundary.

A public function rename is a language-facing change even though it lives in
`.luc`. A compiler-only `Builtin` row or host-table change additionally pays
the runtime/ABI cost described in [CODEGEN.md](CODEGEN.md). An internal helper
remains `private` and does not belong in the public coverage roster.

## Verification boundary

The standard library is tested at three levels:

- ordinary compiler/spec tests prove imports, visibility, specialization,
  effects, ARC, and both-engine behavior;
- package/editor/example suites prove real userland customers; and
- the documentation generator compiles and runs Library examples and rejects
  undocumented or stale public surface entries.

Do not duplicate a standard algorithm in the runtime merely for speed. Measure
first; when a primitive is justified, keep the language-visible semantics in
one runtime operation, preserve the standard wrapper, and prove the optimized
path against the ordinary behavior.
