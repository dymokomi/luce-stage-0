# LuciaOS

**Good for humans. Good for computers.**

LuciaOS v2 is a small computing environment built language-first:
**Luce**, a statically typed, Python-looking-but-not-Python language,
and **loom**, the terminal that runs compiled Luce programs against
ordinary files on Linux and macOS.

**The documentation is [luce.luciaos.com](https://luce.luciaos.com)** —
a tour, worked examples, a reference, and a status page that says out
loud what the language cannot yet do.  It is built from
[`www/luce/`](www/luce/) in this repository.  **Every Luce sample on it is
checked by the freshly built toolchain**: runnable examples execute,
their printed output is compared byte for byte, and expected traps,
raises and refusals are checked as such.  A broken sample or mismatched
claimed result fails the build.  Links, anchors and selected
compiler-to-reference vocabulary are checked too; prose beyond those
checks remains human-reviewed.

v1 — the persistent Fabric of Texels and Fibers — lives on the
`main-v1` branch and in [docs/v1/](docs/v1/).  Its lesson drives v2:
the language is the part that enables everything else, so the language
comes first and the Fabric returns later on top of it.  The plan is
[docs/V2.md](docs/V2.md); the language itself is
[docs/LANGUAGE.md](docs/LANGUAGE.md), and
[docs/README.md](docs/README.md) indexes the rest.  To make a change,
[CONTRIBUTING.md](CONTRIBUTING.md).

## Build and test

Everything is Zig 0.16 and runs on any host OS.  LLVM is a build
prerequisite — Luce's one code generator calls libLLVM in process, and
the `luce` compiler links it (`brew install llvm`, `apt install
llvm-dev`, or point the build at an installation with
`-Dllvm-config=/path/to/llvm-config`).  When the system LLVM is the
wrong one, [`./vendor-llvm.sh`](vendor-llvm.sh) builds a pinned one
from source and `./build.sh` picks it up automatically.  `loom` does
not link LLVM, and neither does anything it loads, so a machine that
only *runs* Luce programs needs none at all.  `cc` is a prerequisite
of building at all, because compiling a bundled program is a link:

```sh
./build.sh         # installs build/luce, build/loom, build/editor, libraries, and bundled examples
./install.sh       # builds ReleaseSafe and installs a user-local snapshot
zig build test     # ~5 min: the executable specification (every program
                   # run on both the compiled path and the test suite's
                   # reference implementation, and compared) + language,
                   # compiler, terminal and documentation-site suites
```

`VERSION` is the shared public release label, currently `0.18`. During the
0.x series it intentionally has two numeric components: increment the second
component for each release, and reserve `1.0` for the point where the public
interface is considered stable. `luce --version` and `loom --version` report
the same label; it is separate from the serialized module format and host ABI
versions.

For daily use on macOS or Linux, `./install.sh` copies `luce`, `loom`,
`editor`, `libluce_rt.a`, and `libluce_start.a` to `~/.local/bin` and `~/.local/lib`,
then adds the bin directory to the appropriate user shell profile. It never
needs `sudo`. Use `./install.sh --no-build` to install an existing `build/`
tree, or `--no-path` to leave shell profiles unchanged. Tests and benchmarks
continue to invoke `build/luce` and `build/loom` explicitly, so installing a
snapshot cannot change what repository development exercises.

## Try it

```sh
build/luce build examples/hello/hello.luc   # hello.luc -> hello.lc (machine code)
build/loom run examples/hello/hello.lc you  # hello, you
build/loom                            # the interactive shell
build/loom edit examples/editor/editor.luc  # the editor, written in Luce
build/editor examples/editor/editor.luc       # standalone editor command
```

The compiler:

```text
luce --version                     print the release label
luce build FILE.luc [-o OUT] [--release] [--emit=WHAT]
                                   compile and write an artifact
luce check FILE.luc                compile, report, write nothing
luce ir FILE.luc [--full]          compile and dump readable IR
```

`--emit` says which shape, and nothing else differs between them —
the same program walks the same pipeline either way:

```text
library  FILE.lc    a native artifact loom runs (default)
object   FILE.o     a relocatable object; you link it
exe      FILE       a standalone native executable
```

`FILE` may also be a `.lcm`: the serialized module, which is the front
end's hand-over to the back end rather than something to ship.  It is
how `loom` gets a program compiled without carrying a code generator.

Builds are debug by default: the artifact carries source locations,
so a runtime trap prints `file:line:column` and a call trace.
`--release` strips them for a smaller artifact — the program itself
behaves identically (docs/MODES.md).

All three compile through LLVM, which measures at 0.78-1.06x of C on
six of the nine benchmarks; `strings` (2.67x), `lists` (2.60x) and
`arrays32` (8.66x compute) are the three rows still behind — `arrays32`
is the price of checked integer arithmetic in a reduction, which is
what [docs/VECTOR.md](docs/VECTOR.md) is about, and what is left of
`lists` is `append` alone, which has to keep a list's length in its
row where C keeps it in a register
([docs/CODEGEN.md](docs/CODEGEN.md)).  Those are
`bench/run.sh`'s floor-subtracted `compute` column,
the one a code-generation change moves; the table and the host it was
taken on are in [docs/CODEGEN.md](docs/CODEGEN.md).  They are stamped with the
machine, the host ABI and the code generator they were built for, so a
loader refuses the wrong one by name rather than crashing.  Linking
uses `cc`; `LUCE_CC` names another driver and `LUCE_LIB` the directory
holding `libluce_rt.a`.

```sh
build/luce build examples/hello/hello.luc --emit=exe -o hello
./hello you                           # hello, you — no loom, no runtime
```

The terminal:

```text
loom                        interactive shell (help lists commands)
loom run PROGRAM.lc [ARGS]  run a compiled program
loom luce PROGRAM.luc [..]  compile a source file and run it
loom edit FILE              open the embedded Luce editor
editor FILE                 open the standalone editor
loom PROGRAM.lc [ARGS]      shorthand for run
```

**A `.lc` is machine code.**  `loom run FILE.lc` is one `dlopen`, one
symbol lookup and one call; nothing is compiled and nothing has to be
installed.  There is no second engine to fall back to and nothing to
fall back from: the artifact's tag is read first, and a file built for
another machine, another host ABI or another code generator is refused
with a sentence saying which.  `loom luce FILE.luc` compiles first and
caches the result as `FILE.lc` beside the source, keyed on the
program's bytes.

**loom carries no code generator.**  Building is `luce`'s job, so loom
runs that binary — found beside its own executable first and on `PATH`
after — and links nothing itself.  libLLVM is 164 MB and dyld binds it
before `main`, which cost every `loom` invocation 5.7 ms for nothing;
loom now starts in 3 ms against a C do-nothing binary's 2.4.  It also
means **a machine that only runs Luce programs needs neither LLVM nor
`luce` installed** — a shipped `.lc` needs a loader and nothing else.

A Luce program is a script with a `main` entry.  The language is
statically typed with inference, has structs, `list`/`map`/`array`/
`builder` container objects created with `new` or literals, and `file`/
`task` resources, all released by scope ownership. Containers may
`give` or `free`, and may `copy` when their whole graph is resource-free;
resources may `give` or `free` but never copy (docs/OWNERSHIP.md). The
language also has slices and checked traps —
`docs/LANGUAGE.md` is the reference.  Effects — console, files and the
screen — only exist as host builtins that loom, the trusted boundary,
implements; arguments are instead handed to `main` as its owned
parameter.  The language itself stays pure:

```python
func main(args: list(string)):
    var name = "loom"
    if len(args) > 0:
        name = args[0]
    print("hello, " + name)
```

## The editor

`examples/editor/editor.luc` is a full-screen terminal editor written
entirely in Luce: movement, editing, scrolling, line numbers, panes, a
status bar, and per-line Luce syntax highlighting.  Its source ships
embedded in the loom binary (`loom edit` always works), and `./build.sh`
also produces the standalone `build/editor` command.  Set
`LOOM_EDITOR=path/to/editor.luc` to hack on your own copy without
rebuilding loom.  `Ctrl-S` saves, `Ctrl-Q` quits.

## Packages

```text
src/luce/                 the Luce language, one numbered stage surface
                          (01_source .. 08_llvm, folder or barrel, driven
                          by compile.zig — docs/PIPELINE.md), plus
                          libluce_rt (the semantics as a linkable
                          library) and the test suite's differential
                          oracle over it, which ships in nothing
src/apps/luce/            the luce compiler CLI
src/apps/loom/            the loom terminal: shell, program runner,
                          palette — the trusted host behind the Luce
                          host builtins is one level up in src/apps/,
                          shared with the compiler
examples/                 userland, written in Luce: the editor,
                          hello, sort, wordcount, a calculator,
                          Conway's Life, stats (a two-file module
                          demo), dice, a Brainfuck interpreter,
                          zipper (list, extract and build real ZIP
                          archives over std.zip and std.files), and
                          adventure (five files, the largest program
                          here, and the one that found a real bug in
                          the oracle)
bench/                    paired C/Luce benchmarks, same algorithm
                          and same output, cross-checked before timed
www/                      everything published to the web, one folder
                          per site plus the shared publisher
                          (www/README.md)
  luce/                   luce.luciaos.com: the documentation, and the
                          generator that compiles and runs every
                          sample on it (www/luce/README.md)
  loom/                   loom.luciaos.com: the tool's own pages, one
                          HTML fragment each, links and anchors checked
  luciaos/                the luciaos.com landing page, hand-written
  deploy/                 publish.sh: the one rsync all three go out by
tools/vscode-luce/        VS Code syntax highlighting for .luc,
                          generated from the compiler's own tables by
                          `zig build grammar` and pinned by a test
docs/                     the decision records and references, indexed
                          by docs/README.md; v1/ preserves the Fabric
                          era, audit/ holds point-in-time reviews
VERSION   install.sh      the shared release label and user-local installer
build.sh  build.zig       ./build.sh installs, zig build test proves
vendor-llvm.sh            build a pinned libLLVM from source, for when
                          the system one is not the one you want
```

`CONTRIBUTING.md` is the short version of all of it; the coding
conventions themselves are [docs/CODING_GUIDE.md](docs/CODING_GUIDE.md),
and [docs/MISSING.md](docs/MISSING.md) is the honest list of what is
not built.

## Deferred scope

Persistence images, the Fabric (Texels, Fibers, Views, capabilities),
a user-facing C FFI/ABI for Luce programs, braids/synchronization,
multi-user collaboration, and the agent all stay deferred until the
language and terminal are excellent.  The runtime and host C ABI used
internally by compiled artifacts is already built.

## License

Luce and loom are distributed under the terms of both the MIT license
and the Apache License (Version 2.0), at your option.

See [LICENSE-APACHE](LICENSE-APACHE) and [LICENSE-MIT](LICENSE-MIT).
