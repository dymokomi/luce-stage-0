# Host Effects

Luce programs reach the operating system through host services. `loom` and
standalone executables provide those services; a host without a service
fails closed with `host_unavailable` rather than silently doing nothing.

## Arguments and output

A program that accepts command-line arguments declares
`main(args: list[str])`. The list contains the words after the program's
own name.

```luce run args=3 fig
func main(args: list[str]):
    print(f"{len(args)} arguments")
    for name in args:
        print(f"  {name}")

    let count = parse_i64(args[0]) else 1
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

Use `len(args)` before indexing. An invalid index is the same checked
`index_bounds` trap as any other list.

## Files

`std.files` is the user-facing file API. Operations whose result depends on
the host are fallible, so use `try` or `catch`:

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

    let there = try files.exists("stock.txt")
    let missing = try files.exists("nope.txt")
    print(f"exists: {there}, missing: {missing}")
    let plain = try files.is_file("stock.txt")
    let folder = try files.is_dir("stock.txt")
    print(f"is_file: {plain}, is_dir: {folder}")

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
is_file: true, is_dir: false
(could not read)
```

`exists`, `is_file`, and `is_dir` can themselves fail when the host cannot
answer. `files.kind` returns an optional enum when the path is absent and a
kind when it is present:

```luce run
import std.files

func main() -> !:
    try files.write("stock.txt", "fig\n")
    try files.make_directory("basket")

    for name in ["stock.txt", "basket", "nope.txt"]:
        let what = try files.kind(name)
        if what == none:
            print(f"{name}: nothing there")
            continue
        match what:
            file:
                print(f"{name}: a file")
            directory:
                print(f"{name}: a directory")
            other:
                print(f"{name}: something else")
```

```output
stock.txt: a file
basket: a directory
nope.txt: nothing there
```

Directory entries include their names, paths, and kinds:

```luce run
import std.files

func main() -> !:
    try files.make_directory("garden/beds")
    try files.write("garden/plan.txt", "rows\n")

    for entry in try files.entries("garden"):
        match entry.kind:
            directory:
                print(f"{entry.name}/ at {entry.path}")
            file:
                print(f"{entry.name} at {entry.path}")
            other:
                print(f"{entry.name}: another kind")
```

```output
beds/ at garden/beds
plan.txt at garden/plan.txt
```

Paths in these examples are relative to the process's current directory.

## Bytes and file handles

`str` is UTF-8 text. Use byte operations when a file may contain arbitrary
binary data:

```luce run
import std.files
import std.strings

func main() -> !:
    var data = new list[u8]
    data.append(u8(0x89))
    data.append(u8(0x50))
    data.append(u8(0x00))
    try files.write_bytes("image.bin", data)

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

`try new files.File(path)` opens a `File`, an ordinary `std.files` class
that owns the open descriptor; a second `files.Mode` argument chooses
`Mode.read`, `Mode.create`, or `Mode.append`, and reading is the default.
ARC closes the descriptor after the last strong reference goes away. A
file read fills a byte array and returns the number of bytes read:

```luce run
import std.files

func main() -> !:
    try files.write("stock.txt", "fig\npear\nplum\n")
    var f = try new files.File("stock.txt")
    var buffer = new array[u8](4)
    print(str(try f.read(buffer)))
    print(str(try f.read(buffer)))
    print(str(i32(buffer[0])))
```

```output
4
4
112
```

## Input, errors, and time

These services live in `std.os`; they are not global names.
`os.read_line(prompt)` returns `str?`, with `none` at end of input, and
`os.env(name)` returns `str?` for one environment variable.
`os.print_error` writes to standard error. `os.clock_ms` is monotonic and
`os.sleep_ms` waits for a duration.

```luce run
import std.os

func main():
    let started = os.clock_ms()
    print(f"PATH is set: {os.env("PATH") != none}")
    print(f"nonsense: {os.env("LUCE_NOT_A_REAL_VARIABLE") else "(unset)"}")
    print(f"typed: {os.read_line("") else "(end of input)"}")
    os.sleep_ms(started - os.clock_ms())
    os.print_error("this line went to standard error")
```

```output
PATH is set: true
nonsense: (unset)
typed: (end of input)
this line went to standard error
```

## The terminal

Terminal dimensions, drawing, and input live in their own module,
[`std.term`](/library/term/). `term.read()` returns a typed
`term.Event?` — a key, typed text, a mouse action, or a resize — with
`none` at end of input, so an empty input stream ends a draw loop
cleanly. Terminal output is sanitized by the host. These services need
a real terminal and are not demonstrated by the site's non-interactive
examples. The [editor example](/tools/programs/) uses them in a
complete program.

## The host gate

Host-dependent names are gated at compile time. Compiling without the
corresponding service produces a `luce.sema.host` diagnostic instead of a
runtime surprise. The [standard-library pages](/library/) document each module's
available host surface. The next part of this book begins with
[The `luce` and `loom` Commands](/tools/command-line/).
