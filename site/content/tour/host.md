# The outside world

The Luce language itself is pure. It cannot print, read a file, or
touch a screen. Every effect is a **host service**, and the program
that runs your code — `loom`, or a standalone executable built with
`--emit=exe` — is the trusted boundary that implements them.

A missing service does not silently do nothing: it traps
`host_unavailable`. Effects fail closed.

## Printing and arguments

```luce run args=3 fig
func main():
    print(f"{arg_count()} arguments")
    for index in range(0, arg_count()):
        print(f"  {index}: {arg(index)}")

    let count = parse_int(arg(0)) else 1
    for i in range(0, count):
        print(arg(1))
```

```output
2 arguments
  0: 3
  1: fig
fig
fig
fig
```

`arg(i)` outside the range traps — the count is right there to check.

## Files

The host's raw file builtins are `file_read`, `file_write` and
`file_exists`, and `std.files` is the honest layer over them. Reading
and writing are **fallible**: the world decides whether they land, so
they answer `!` and you `try` or `catch`.

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

There is no standard input, no clock, no `sleep`, no `exit`, no
environment access, no stderr, no directory listing, no delete or
rename, and no path manipulation. Each is one builtin plus one
wrapper, and none of them is built yet. The
[status page](/status/) keeps that list.
