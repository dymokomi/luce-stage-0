# Hello, Luce

Luce comes as two programs. `luce` is the compiler: it turns `.luc`
source into something you can run. `loom` is the terminal that runs
it — an interactive shell, and a command line.

## Getting the toolchain

There is no installer and no package. You build it from the
repository, with [Zig 0.16](https://ziglang.org/) and LLVM:

```sh
git clone https://github.com/dymokomi/luciaos
cd luciaos
./build.sh
```

That writes `build/luce`, `build/loom` and `build/lib/libluce_rt.a`.
LLVM is needed to build `luce`, because Luce's one code generator
calls libLLVM in process — `brew install llvm` or `apt install
llvm-dev` is enough, and `zig build -Dllvm-config=/path/to/llvm-config`
points the build at an installation somewhere unusual. `loom` links no
LLVM at all, so a machine that only *runs* Luce programs needs none.

## The smallest program

A program is a file with a function called `main`.

```luce run
func main():
    print("hello, loom")
```

```output
hello, loom
```

Blocks are introduced by `:` and marked by indentation, which is four
spaces and nothing else — a tab or a three-space indent is a compile
error naming the reason. There are no semicolons, and braces are map
literals rather than block delimiters.

## Compiling and running it

Put this in `hello.luc` and hand it to the compiler.

```luce module file=hello.luc
func main(args: list(string)):
    var name = "loom"
    if len(args) > 0:
        name = args[0]
    print("hello, " + name)
```

```console
$ luce build hello.luc
hello.luc -> hello.lc
$ loom run hello.lc
hello, loom
$ loom run hello.lc world
hello, world
```

That transcript is real: this site's build ran those three commands in
a scratch directory and captured what they printed.

`luce build` writes `hello.lc`, and a `.lc` is machine code — a small
shared library holding the compiled program and the runtime it calls.
`loom run` opens it and calls it: nothing is compiled, nothing is
interpreted, and the whole startup is a couple of milliseconds.

While you are writing something, one command is shorter:

```console
$ loom luce hello.luc there
hello, there
```

`loom luce` compiles and runs in one step, always as a debug build, so
a mistake reports the line it happened on.

## The compiler's three commands

| Command | What it does |
|---|---|
| `luce build FILE [-o OUT] [--release] [--emit=WHAT]` | compile and write an artifact |
| `luce check FILE` | compile, report problems, write nothing |
| `luce ir FILE [--full]` | compile and print the readable intermediate form |

`--emit` chooses which shape `build` writes — `library` (the default
`.lc` that `loom` runs), `object` (a relocatable `.o`), or `exe` (a
standalone binary that needs neither `loom` nor a runtime beside it).
Nothing else differs between them; the same program walks the same
pipeline either way.

Builds are debug by default, which means the artifact carries source
locations so a runtime failure can say `file:line:column`.
`--release` strips those and changes nothing else — in particular it
does not turn off a single safety check. See
[the compiler and the terminal](/guide/toolchain/).

## Errors, at compile time

Luce is statically typed with inference, and the only conversion it
makes on its own is widening a `long` to a `double`. Mistakes are
caught before anything runs, and the message tries to name the fix
rather than the parser's predicament:

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

Every diagnostic carries a stable code — `luce.lex.*`, `luce.parse.*`,
`luce.sema.*` — and a byte span, so tools can act on them and you can
search for them.

Next: what those types are.
