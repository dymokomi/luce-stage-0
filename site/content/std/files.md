# std.files

A thin, honest layer over the host's file builtins. Paths resolve
relative to the current directory.

```
import std.files
```

The module is **host-gated**, like the builtins under it: `import
std.files` inside a program compiled without host access is a compile
error, because file access genuinely does not exist there.

## The surface

| Signature | Notes |
|---|---|
| `files.exists(path) -> Bool` | a question, not a guard |
| `files.read(path) -> String!` | the whole file |
| `files.write(path, text) -> !` | |
| `files.read_lines(path) -> List(String)!` | newlines stripped; a trailing final newline adds no phantom empty line |
| `files.write_lines(path, lines) -> !` | joined with newlines, ends with one; an empty list writes an empty file |

## Everything that touches a file says `!`

The world decides whether a read or a write lands, so every one of
these is fallible: `try` it to pass the failure on, or `catch` it to
handle it here. Ignoring the outcome is `luce.sema.fallible` — there
is no spelling that drops it silently.

```luce run
import std.files

func main() -> !:
    try files.write("stock.txt", "fig\npear\nplum\n")

    let whole = try files.read("stock.txt")
    print(f"{len(whole)} bytes")

    let lines = try files.read_lines("stock.txt")
    print(f"{len(lines)} lines, last is {lines[len(lines) - 1]}")

    var kept: List(String) = []
    for line in lines:
        if line != "pear":
            kept.append(line)
    try files.write_lines("kept.txt", kept)
    print(f"kept {len(try files.read_lines("kept.txt"))}")
```

```output
14 bytes
3 lines, last is plum
kept 2
```

## exists is the exception, and it is not a guard

`exists` answers a plain `Bool`, because asking whether a path is
there is not itself an operation that can half-succeed. But it is a
question about the **past**, never a guard for the call after it:
there is a window between the two that nothing can close, and a guard
could not tell "not there" from "would not open" anyway.

Read the file and handle what the read says.

```luce run
import std.files

func main():
    print(f"before: {files.exists("report.txt")}")

    let missing = files.read("report.txt") catch "(nothing yet)"
    print(missing)

    files.write("report.txt", "written\n") catch:
        print("could not write")

    print(f"after: {files.exists("report.txt")}")
    print(files.read("report.txt") catch "(still nothing)")
```

```output
before: false
(nothing yet)
after: true
written
```

## Handling versus propagating

```luce run
import std.files

func load_or_default(path: String) -> String:
    return files.read(path) catch "default contents\n"

func load_or_fail(path: String) -> String!:
    return try files.read(path)

func main() -> !:
    try files.write("present.txt", "real contents\n")
    print(load_or_default("present.txt"))
    print(load_or_default("absent.txt"))
    print(try load_or_fail("present.txt"))
    print(load_or_fail("absent.txt") catch "(handled at the top)")
```

```output
real contents

default contents

real contents

(handled at the top)
```

## What is missing

There is no append mode, no delete, no rename, no directory listing
and no path manipulation. There is also no standard input, no clock
and no `sleep`. Each of those is one host builtin plus one wrapper
here, and none of them is built. The [status page](/status/) keeps the
list.
