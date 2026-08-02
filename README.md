# LuciaOS

LuciaOS v2 is a small computing environment built language-first:
**Luce**, a statically typed, Python-looking-but-not-Python language,
and **loom**, the terminal that runs compiled Luce programs against
ordinary files on Linux and macOS.

v1 — the persistent Fabric of Texels and Fibers — lives on the
`main-v1` branch and in [docs/v1/](docs/v1/).  Its lesson drives v2:
the language is the part that enables everything else, so the language
comes first and the Fabric returns later on top of it.  The plan is
[docs/V2.md](docs/V2.md); the language itself is
[docs/LANGUAGE.md](docs/LANGUAGE.md).

## Build and test

Everything is Zig 0.16 and runs on any host OS.  LLVM is a build
prerequisite — Luce's one code generator calls libLLVM in process
(`brew install llvm`, `apt install llvm-dev`, or point the build at
an installation with `-Dllvm-config=/path/to/llvm-config`):

```sh
./build.sh         # installs build/luce, build/loom, and build/programs/*.lc
zig build test     # language suite + compiler suite + terminal suite
```

## Try it

```sh
build/luce build programs/hello.luc   # hello.luc -> hello.lc
build/loom run programs/hello.lc you  # hello, you
build/loom                            # the interactive shell
build/loom edit programs/hello.luc    # the editor, written in Luce
```

The compiler:

```text
luce build FILE.luc [-o FILE.lc] [--release] [--backend=llvm]
                                   compile and write a module
luce check FILE.luc                compile, report, write nothing
luce ir FILE.luc [--full]          compile and dump readable IR
```

Builds are debug by default: the module carries source locations,
so a runtime trap prints `file:line:column` and a call trace.
`--release` strips them for a smaller module — the program itself
behaves identically (docs/MODES.md).

`--backend=llvm` compiles the same program through LLVM and writes a
relocatable object exporting `luce_main`, to be linked against the
published host ABI.  That path is real but partial — no floats,
structs, or host services beyond `print` yet — so the interpreter is
still what runs a `.lc`.  [docs/CODEGEN.md](docs/CODEGEN.md) is the
current state and [docs/CODEGEN.md](docs/CODEGEN.md) the decision
behind it.

The terminal:

```text
loom                        interactive shell (help lists commands)
loom run PROGRAM.lc [ARGS]  run a compiled program
loom luce PROGRAM.luc [..]  compile a source file and run it
loom edit FILE              open the Luce editor
loom PROGRAM.lc [ARGS]      shorthand for run
```

A Luce program is a script with a `main` entry.  The language is
statically typed with inference, has structs, `List`/`Map`/`Array`/
`Builder` heap objects with explicit `new`/`free` (loom reports what
you leak), slices, and checked traps — `docs/LANGUAGE.md` is the
reference.  Effects — console,
files, arguments, the screen — only exist as host builtins that loom,
the trusted boundary, implements; the language itself stays pure:

```python
func main():
    var name = "loom"
    if arg_count() > 0:
        name = arg(0)
    print("hello, " + name)
```

## The editor

`programs/editor.luc` is a full-screen terminal editor written
entirely in Luce: movement, editing, scrolling, line numbers, a status
bar, and per-line Luce syntax highlighting.  Its source ships embedded
in the loom binary (`loom edit` always works); set
`LOOM_EDITOR=path/to/editor.luc` to hack on your own copy without
rebuilding loom.  `Ctrl-S` saves, `Ctrl-Q` quits.

## Packages

```text
src/luce/                 the Luce language, one numbered folder per
                          pipeline stage (01_source .. 08_llvm, driven
                          by compile.zig — docs/PIPELINE.md), plus
                          libluce_rt (the semantics as a linkable
                          library) and the interpreter over it
src/apps/luce/            the luce compiler CLI
src/apps/loom/            the loom terminal: shell, program runner,
                          and the trusted host behind the Luce host
                          builtins
programs/                 userland, written in Luce: the editor,
                          hello, sort, wordcount, a calculator,
                          Conway's Life, stats (a two-file module
                          demo), dice, and a Brainfuck interpreter
bench/                    paired C/Luce benchmarks, same algorithm
                          and same output, cross-checked before timed
tools/vscode-luce/        VS Code syntax highlighting for .luc
docs/                     V2.md is the plan; LANGUAGE.md the language;
                          v1/ preserves the Fabric era
build.sh  build.zig       ./build.sh installs, zig build test proves
```

## Deferred scope

Persistence images, the Fabric (Texels, Fibers, Views, capabilities),
the C ABI, braids/synchronization, multi-user collaboration, and the
agent all stay deferred until the language and terminal are excellent.
