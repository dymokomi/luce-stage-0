# LuciaOS

> **This tree is frozen as `luce-stage-0` (2026-08-23).** The Luce
> language is locked here as the stage-0 seed and oracle; the next
> Luce compiler is written in Luce itself, in its own repository.
> Toolchain fixes are welcome; language changes are over.
> docs/SELFHOST.md records the program.

**Good for humans. Good for computers.**

LuciaOS v2 is a small computing environment built language-first:
**Luce**, a statically typed, Python-looking-but-not-Python language,
and **loom**, the terminal that runs compiled Luce programs against
ordinary files on Linux and macOS.

**The documentation is [luce.luciaos.com](https://luce.luciaos.com)** —
a Learn path, thematic Guides with complete programs, an exhaustive
Reference, the standard Library, and a Status page that says out loud what
the language cannot yet do. It is built from
[`www/luce/`](www/luce/) in this repository.  **Every Luce sample on it is
checked by the freshly built toolchain**: runnable examples execute,
their printed output is compared byte for byte, and expected traps,
raises and refusals are checked as such.  A broken sample or mismatched
claimed result fails the build.  Links, anchors and selected
compiler-to-reference vocabulary are checked too; prose beyond those
checks remains human-reviewed.

The current release notes are in [`CHANGELOG.md`](CHANGELOG.md). Luce is
pre-1.0, so the notes describe the candidate surface rather than promise
source compatibility.

v2 is language-first: the language is the part that enables everything
else, so it comes first and the environment is built on top of it.  The
plan is [docs/V2.md](docs/V2.md); the language itself is
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
zig build test     # the complete owner-grouped release gate; long targets
                   # print bounded progress and a 15-second heartbeat
```

`VERSION` is the shared public release label, currently `0.25`. During the
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

The published release supports macOS 15 or newer on Apple Silicon and glibc
Linux 2.28+ on ARM64 and x86-64. It also installs the Luce VS Code and Cursor
syntax extension in one step:

```sh
curl -fsSL https://luce.luciaos.com/install/0.23/install.sh | bash
```

The script selects the platform archive, verifies its checksum and contents,
and replaces `~/.local/luce` only after every check passes. The compiler has
its pinned LLVM linked in. A working `cc` remains the explicit system boundary
for native linking; the installer checks it and prints the appropriate package
command when it is absent.

## Try it

```sh
build/luce build examples/hello/hello.luc   # examples/hello/hello.luc -> examples/hello/hello
./examples/hello/hello you                  # hello, you
build/loom                            # the interactive shell
build/loom run build/examples/editor/editor.lc notes.txt  # the editor, in Luce
build/editor notes.txt                      # the same editor, standalone
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
exe      FILE       a standalone native executable (default)
library  FILE.lc    a native artifact loom runs
object   FILE.o     a relocatable object; you link it
```

`FILE` may also be a `.lcm`: the serialized module, which is the front
end's hand-over to the back end rather than something to ship.  It is
how `loom` gets a program compiled without carrying a code generator.

Builds are debug by default: the artifact carries source locations,
so a runtime trap prints `file:line:column` and a call trace.
`--release` strips them for a smaller artifact — the program itself
behaves identically (docs/MODES.md).

All three compile through LLVM, which measures at 0.78-1.07x of C on
five of the nine benchmarks; `strings` (3.87x), `lists` (2.61x),
`arrays32` (7.77x compute), and `stats` (1.34x) are the four rows still
behind — `arrays32` is the price of checked integer arithmetic in a
reduction, which is what [docs/VECTOR.md](docs/VECTOR.md) is about, and what is left of
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
build/luce build examples/hello/hello.luc --emit=library -o hello.lc
build/loom run hello.lc you           # hello, you — the loadable form
```

The terminal:

```text
loom                        interactive shell (help lists commands)
loom run PROGRAM.lc [ARGS]  run a compiled program
loom luce PROGRAM.luc [..]  compile a source file and run it
loom PROGRAM.lc [ARGS]      shorthand for run
editor FILE [FILE ...]      the editor, an ordinary installed program
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

A Luce program is a script with a `main` entry. The language is
statically typed with inference and has value `struct`s,
`list`/`map`/`array`/`builder` reference containers created with `new`
or literals, and `file`/`task` reference resources. ARC shares references,
destroys objects on last release, closes or joins resources deterministically,
and copies permitted object graphs safely across worker runtimes
(docs/MEMORY.md). Final class references, `weak` fields and captures,
block closures, and nominal interfaces are part of that same current model.
The language also has slices and
checked traps — `docs/LANGUAGE.md` is the reference. Effects — console,
files and the screen — only exist as host builtins that loom, the
trusted boundary, implements; arguments are instead handed to `main` as
its parameter.  The language itself stays pure:

```python
func main(args: list[str]):
    var name = "loom"
    if len(args) > 0:
        name = args[0]
    print("hello, " + name)
```

## The editor

`examples/editor/editor.luc` is a full-screen terminal editor written
entirely in Luce: movement, editing, scrolling, line numbers, panes, a
status bar, and per-line Luce syntax highlighting.  It is the first
Luce program to carry a **dependency** — it draws through the `termui`
package (`packages/termui-0.5.0`, docs/TERMUI.md). The editor is a
retained tree of components — `FileList`, `Editor`, `Console`,
`StatusBar`, and a layout-reshaping `Workbench` — sharing one model;
termui owns the loop, terminal lifecycle, layout, input routing, cursor, and
cell diff. `./build.sh` installs it
twice: `build/examples/editor/editor.lc`, which `loom run` starts like
any other artifact, and the standalone `build/editor` command.  It is a
program, not a feature of loom, so replacing it is writing another one.
`Ctrl-S` saves, `Ctrl-Q` quits.

## Packages

```text
src/luce/                 the Luce language, one named stage surface
                          (source through codegen, folder or barrel, driven
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
  stats/                  stats.luciaos.com: private-by-design log counts
                          and the collector that produces them
  deploy/                 publish.sh: the one rsync all four go out by
tools/vscode-luce/        VS Code highlighting and brace-aware indentation;
                          the grammar is generated from compiler tables by
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
and [docs/MISSING.md](docs/MISSING.md) is the list of confirmed bugs. Open
language and tooling ideas live in their decision records, not in the
bug list.

## Deferred scope

Persistence images, a user-facing C FFI/ABI for Luce programs,
network synchronization, multi-user collaboration, and the agent all
stay deferred until the language and terminal are excellent.  The
runtime and host C ABI used internally by compiled artifacts is
already built.

## Support and security

Support requests follow [SUPPORT.md](SUPPORT.md). Please report
vulnerabilities privately through [SECURITY.md](SECURITY.md), not in a public
issue or discussion.

## License

Luce and loom are distributed under the terms of both the MIT license
and the Apache License (Version 2.0), at your option.

See [LICENSE-APACHE](LICENSE-APACHE) and [LICENSE-MIT](LICENSE-MIT).
Release archives also carry the exact notices listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for statically linked LLVM,
Zig runtime, and Linux GCC runtime components.
