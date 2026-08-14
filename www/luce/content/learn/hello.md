# Hello, Luce

You are going to write a tiny program, turn it into a native executable,
and run it. The first useful Luce program is deliberately small: one file,
one function, one line of output.

## Install the tools

The released installer currently supports macOS on Apple Silicon. It puts
the Luce compiler, editor, runtime libraries, and local VS Code syntax
highlighting in `~/.local/luce`, then adds the compiler to your shell's
startup profile:

```sh
curl -fsSL https://luce.luciaos.com/install/0.18/install.sh | bash
```

Open a new shell (or source the profile named by the installer), then check
the compiler:

```text
luce --version
```

Running the installer again downloads a fresh copy and replaces the previous
installation only after the archive has passed its checksum and contents
checks.

## Write your first program

Create a file named `hello.luc` in a new folder. You can use the installed
editor or any text editor:

```luce module file=hello.luc
func main():
    print("Hello, Luce!")
```

Every executable Luce program starts at `main`. A block begins after `:` and
is indented by four spaces. There are no semicolons or braces to remember.

## Check, compile, and run

Ask the compiler to check the file before it writes anything:

```console
$ luce check hello.luc
hello.luc: ok
```

Now make a native executable:

```console
$ luce build hello.luc --emit=exe -o hello
hello.luc -> hello
```

Run the file your operating system can launch directly:

```console
$ ./hello
Hello, Luce!
```

`--emit=exe` is the important part. It tells `luce` to produce a standalone
program rather than an intermediate library. Once it has been built, the
program does not need a second Luce command to start.

## Try the same loop in the editor

Open the file with the Luce editor:

```sh
editor hello.luc
```

Press Ctrl-B. The editor saves the file, compiles a standalone executable
beside it with a `.run` suffix, and runs that executable. Its output and any
diagnostic appear in the output pane. Ctrl-S saves without running; Ctrl-Q
quits.

This is the same source-to-executable loop as the terminal commands above,
with the edit-and-run steps kept close together.

## When something is wrong

Luce checks types before it runs a program. A mistake points to the source
span and includes a stable diagnostic code:

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

The next chapter explains the [values and types](../values/) that make this
check possible.
