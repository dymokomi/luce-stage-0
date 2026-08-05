# The outside world

The Luce language itself is pure. It cannot print, read a file, or
touch a screen. Every effect is a **host service**, and the program
that runs your code — `loom`, or a standalone executable built with
`--emit=exe` — is the trusted boundary that implements them.

A missing service does not silently do nothing: it traps
`host_unavailable`. Effects fail closed.

## Printing and arguments

The command line is not a service the program asks for: it is handed
to it. A program that reads one declares
`func main(args: List(String)):`, and `args` is an ordinary
`List(String)` — `len`, indexing, slicing, `for … in`, everything.
`args[0]` is the first word the person typed **after** the program's
own name.

```luce run args=3 fig
func main(args: List(String)):
    print(f"{len(args)} arguments")
    for name in args:
        print(f"  {name}")

    let count = parse_int(args[0]) else 1
    for i in range(0, count):
        print(args[1])
```

```output
2 arguments
  3
  fig
fig
fig
fig
```

A program that never reads a command line writes `func main():` and
says nothing about one. Reading past the end of `args` is the
language's own `index_bounds` trap — `len(args)` is right there to
check against.

## Files

The host's raw file builtins are `file_read`, `file_write`,
`file_append`, `file_delete`, `file_rename`, `file_exists` and
`dir_list`, and [`std.files`](/std/files/) is the honest layer over
them. Everything that changes a file is **fallible**: the world decides
whether it lands, so they answer `!` and you `try` or `catch`.

```luce run
import std.files

func main() -> !:
    try files.write("stock.txt", "fig\npear\nplum\n")

    let lines = try files.read_lines("stock.txt")
    print(f"{len(lines)} lines")
    for index, line in lines:
        print(f"  {index}: {line}")

    let whole = try files.read("stock.txt")
    print(f"{len(whole)} bytes on disk")

    print(f"exists: {files.exists("stock.txt")}, missing: {files.exists("nope.txt")}")

    let text = files.read("nope.txt") catch "(could not read)"
    print(text)
```

```output
3 lines
  0: fig
  1: pear
  2: plum
14 bytes on disk
exists: true, missing: false
(could not read)
```

`exists` answers a plain `Bool` and is the exception — but it is a
question about the past, never a guard for the call after it. Read the
file and handle what the read says; that window is one nothing can
close.

Paths resolve relative to the current directory.

## Standard input, standard error, the clock

Three more services, and each one's shape is a decision about what
kind of fact it is reporting.

`read_line(prompt)` writes the prompt and answers `String?`. End of
input is **absence**, not failure — nothing went wrong, there is just
nothing more — so it is `T?` and not `T!`, and `else` is the whole
handling.

`print_error(text)` writes a line to standard error. Unlike `print`,
it is always sanitized: standard output is the program's own channel
and may be a pipe, while standard error is shared with the runner.

`clock_ms()` reads a **monotonic** clock in milliseconds and
`sleep_ms(ms)` waits. Neither can fail, and `sleep_ms` of an
already-elapsed duration — zero, or the negative left by
`deadline - clock_ms()` after a frame overran — simply returns. There
is no time left to wait, so an animation loop subtracts without
guarding. That is exactly what `programs/life.luc` does.

`env(name)` answers `String?`: one variable, or `none` when unset.

```luce run
func main():
    let started = clock_ms()
    print(f"PATH is set: {env("PATH") != none}")
    print(f"nonsense: {env("LUCE_NOT_A_REAL_VARIABLE") else "(unset)"}")
    print(f"typed: {read_line("") else "(end of input)"}")
    sleep_ms(started - clock_ms())
    print_error("this line went to standard error")
```

```output
PATH is set: true
nonsense: (unset)
typed: (end of input)
this line went to standard error
```

The generator ran that program with nothing on standard input, which
is why `read_line` answered `none`.

## The terminal

`loom` also offers a screen: `term_rows`, `term_cols`, `term_clear`,
`term_move`, `term_style`, `term_write`, `term_flush`, plus `key_read`
and `key_text` for input. The host owns raw mode, the alternate
screen, frame buffering and every escape byte — `term_write` text is
sanitized, so a Luce program can never emit a control sequence.

`key_read` presents the pending frame before it blocks, so a draw loop
needs no explicit flush, and it returns stable key names — `"text"`,
`"enter"`, `"up"`, `"ctrl_s"` — with `key_text()` carrying the
payload when the name is `"text"`.

It answers `String?`, not `String`. A keyboard runs dry when the pipe
driving the program ends or the terminal closes, and that is the same
"nothing there" `read_line` answers `none` for off the same input — so
a draw loop writes `if name == none: break` and stops, instead of
asking for the next key forever.

Those cannot be demonstrated on a web page, because they need a real
terminal. What they are enough for is the repository's
[flagship program](/examples/programs/): a full-screen editor with
scrolling, line numbers, a status bar and per-line Luce syntax
highlighting, written entirely in Luce.

```sh
build/loom edit notes.txt
```

## The host gate

Every one of those builtins is gated. A program compiled with the
gate off cannot name them at all, and saying one is a
`luce.sema.host` diagnostic rather than a runtime surprise.
That is what keeps "the language is pure" a statement about the
language rather than about good behaviour.

## What is missing

Two things, and both were left out on purpose rather than not reached.

**`exit`.** It is not one builtin: it is a fourth way for a run to
end, and every party needs an answer for it — the status the entry
point returns, the leak census, and what "scope ownership" means for a
scope that never closes. `main() -> !` already ends a program early
with a reason and a status a shell can read, which is what the corpus
actually wanted.

**Path manipulation.** Not a host gap at all — joining and splitting a
path is pure text, so it belongs in a std module over
[`std.strings`](/std/strings/), designed against a program that needs
one.

Also absent, smaller: a wall clock and a calendar (`clock_ms` is
monotonic and says only that differences mean something — dates are a
library, and the library does not exist), setting an environment
variable, and reading the environment whole. The
[status page](/status/) keeps that list.
