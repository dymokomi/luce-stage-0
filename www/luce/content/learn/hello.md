# Hello, Luce

## Install the tools

The released installer currently supports macOS on Apple Silicon. It
downloads the compiler, runner, editor and runtime libraries into
`~/.local/luce`, installs Luce syntax highlighting for local VS Code or
Cursor, checks the archive, and adds `~/.local/luce/bin` to your shell's
startup profile:

```sh
curl -fsSL https://luce.luciaos.com/install/0.18/install.sh | bash
```

Open a new shell (or source the profile named by the installer), then check
that the tools are available:

```text
luce --version
loom --version
```

Running the installer again downloads a fresh copy of the same release and
replaces the previous `~/.local/luce` tree only after the archive has passed
its checksum and contents checks.

This chapter gets a program from source to output. It assumes only that
you can open a terminal and edit a text file.

## The smallest program

Every executable Luce program has a `main` function. A block starts after
`:` and is indented by four spaces. Luce does not use semicolons or braces
for blocks; `{...}` is map-literal syntax.

```luce run
func main():
    print("hello, loom")
```

```output
hello, loom
```

## Compile and run

Save this as `hello.luc`:

```luce module file=hello.luc
func main(args: list(string)):
    var name = "loom"
    if len(args) > 0:
        name = args[0]
    print("hello, " + name)
```

Compile it to a `.lc` artifact and run that artifact:

```console
$ luce build hello.luc
hello.luc -> hello.lc
$ loom run hello.lc
hello, loom
$ loom run hello.lc world
hello, world
```

`luce build` writes machine code. `loom run` loads that artifact; it does
not compile or interpret the source. While editing, `loom luce` combines
the two steps:

```console
$ loom luce hello.luc there
hello, there
```

## The compiler commands

| Command | Purpose |
|---|---|
| `luce build FILE [-o OUT] [--release] [--emit=WHAT]` | Compile and write an artifact. |
| `luce check FILE` | Check a source file without writing an artifact. |
| `luce ir FILE [--full]` | Print the compiler's intermediate form. |

`--emit=library` (the default) writes the `.lc` form used by `loom`.
`--emit=object` writes a relocatable object, and `--emit=exe` writes a
standalone executable. Debug builds include source locations in runtime
diagnostics; `--release` removes those locations but does not disable
safety checks.

## Errors are reported before execution

Luce checks types before it runs the program. The diagnostic includes a
stable code and a source span:

```luce fail
func main():
    let n: long = 1
    let s: string = "two"
    print(string(n + s))
```

```output
luce: compile failed
main.luc:4:18: operands of + are long and string, and there is no conversion between them [luce.sema.type]
        print(string(n + s))
                     ^~~~~
```

Next, learn what the values and types mean: [Values and types](../values/).
