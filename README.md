# LuciaOS

LuciaOS v2 is a small computing environment built language-first:
**Luce**, a statically typed, Python-looking-but-not-Python language,
and **loom**, the terminal that runs compiled Luce programs against
ordinary files on Linux and macOS.

v1 — the persistent Fabric of Texels and Fibers — lives on the
`main-v1` branch and in [docs/v1/](docs/v1/).  Its lesson drives v2:
the language is the part that enables everything else, so the language
comes first and the Fabric returns later on top of it.  The plan is
[docs/V2.md](docs/V2.md); the language itself is documented in
[docs/v1/LUCE.md](docs/v1/LUCE.md).

## Build and test

Everything is Zig 0.16 and runs on any host OS:

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
luce build FILE.luc [-o FILE.lc]   compile and write a module
luce check FILE.luc                compile, report, write nothing
luce ir FILE.luc                   compile and dump readable IR
```

The terminal:

```text
loom                        interactive shell (help lists commands)
loom run PROGRAM.lc [ARGS]  run a compiled program
loom luce PROGRAM.luc [..]  compile a source file and run it
loom edit FILE              open the Luce editor
loom PROGRAM.lc [ARGS]      shorthand for run
```

A Luce program is a script with a `main` entry.  Effects — console,
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
src/luce/                 the Luce language: lexer, parser, analyzer,
                          typed IR + verifier, the .lc module format,
                          and the interpreter behind the backend
                          boundary
src/apps/luce/            the luce compiler CLI
src/apps/loom/            the loom terminal: shell, program runner,
                          and the trusted host behind the Luce host
                          builtins
programs/                 userland, written in Luce (editor, hello)
tools/vscode-luce/        VS Code syntax highlighting for .luc
docs/                     V2.md is the plan; v1/ preserves the Fabric
                          era (LOOM.md, LUCE.md, CODING_GUIDE.md)
build.sh  build.zig       ./build.sh installs, zig build test proves
```

## Deferred scope

Persistence images, the Fabric (Texels, Fibers, Views, capabilities),
the C ABI, braids/synchronization, multi-user collaboration, and the
agent all stay deferred until the language and terminal are excellent.
