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
`func main(args: list(string)):`, and `args` is an ordinary
`list(string)` — `len`, indexing, slicing, `for … in`, everything.
`args[0]` is the first word the person typed **after** the program's
own name.

```luce run args=3 fig
func main(args: list(string)):
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

`exists` answers a plain `bool` and is the exception — but it is a
question about the past, never a guard for the call after it. Read the
file and handle what the read says; that window is one nothing can
close.

Paths resolve relative to the current directory.

## Bytes, and a handle that closes itself

Everything above is *text*, and a `string` is valid UTF-8 by
construction — so `files.read` on a JPEG answers no, honestly, because
it could not read it *as a string*. Underneath is a byte channel that
has no opinion about encoding.

```luce run
import std.files
import std.strings

func main() -> !:
    var bytes = new list(byte)
    bytes.append(byte(0x89))
    bytes.append(byte(0x50))
    bytes.append(byte(0x00))
    try files.write_bytes("image.bin", bytes)

    let back = try files.read_bytes("image.bin")
    print(f"{len(back)} bytes")
    print(strings.from_bytes(back) else "(not text)")
    print(files.read("image.bin") catch "(not text as a string either)")
    try files.delete("image.bin")
```

```output
3 bytes
(not text)
(not text as a string either)
```

`files.open(path)` answers a [`file`](/ref/types/#file), and a file is
a **scope-owned resource**: the binding that received it owns it, the
end of that scope closes it, `free(f)` closes it early, and using one
after it is closed traps `use_after_free` — because it is the same
mistake as any other use after free.

There is deliberately no `close`. A file you have to remember to close
is a file somebody will not, and [scope ownership](/ref/ownership/)
already knows where a name's life ends.

```luce run
import std.files

func main() -> !:
    try files.write("stock.txt", "fig\npear\nplum\n")
    var f = try files.open("stock.txt")
    var buffer = new array(byte, 4)
    print(string(try f.read(buffer)))
    print(string(try f.read(buffer)))
    print(string(int(buffer[0])))
```

```output
4
4
112
```

A read fills the buffer and answers **how many bytes landed**; zero is
the end of the file, and short is ordinary rather than a refusal. A
write says the same thing in the other direction. That is the C shape
on purpose — it is what a socket will want too — and
`files.read_bytes` and its siblings are the loop over it, written once.

## Standard input, standard error, the clock

Three more services, and each one's shape is a decision about what
kind of fact it is reporting.

`read_line(prompt)` writes the prompt and answers `string?`. End of
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

`env(name)` answers `string?`: one variable, or `none` when unset.

The machine itself is a host service too — how much memory it has, how
much is left, how many processors — read through
[`std.os`](/std/os/). Those are the one part of the surface that
answers neither `?` nor `!`: a fact the host knows is a number, and a
fact it does not know is a refusal, because a host is never made to
invent one.

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

It answers `string?`, not `string`. A keyboard runs dry when the pipe
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

Three things, and each was left out on purpose rather than not
reached.

**A wall clock and a calendar.** `clock_ms` is monotonic: it says only
that differences mean something, which is what a frame timer and a
benchmark need. Dates are a library rather than a builtin, and the
library does not exist yet.

**Setting an environment variable.** `env(name)` reads; nothing
writes. Process-global mutation is a large promise for a service no
program here has asked for.

**Reading the environment whole.** `env` answers one name at a time.
Enumerating every variable is a different shape — an owned
`list(string)` of pairs — and it waits for a program that wants it.

Two names that used to head this list have since shipped: `exit` is a
gated builtin like any other, and path manipulation turned out never
to be a host gap at all — joining and splitting a path is pure text,
so it is [`std.paths`](/std/paths/) over
[`std.strings`](/std/strings/). The [status page](/status/) keeps the
current list.
