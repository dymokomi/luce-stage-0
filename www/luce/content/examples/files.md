# Files

`std.files` is a thin layer over the host's file services. Everything
that touches a file says `!`, because the world decides whether a read
or a write lands.

```luce run
import std.files

func main() -> !:
    try files.write("notes.txt", "fig\npear\nplum\n")

    let whole = try files.read("notes.txt")
    print(f"{len(whole)} bytes")

    let lines = try files.read_lines("notes.txt")
    print(f"{len(lines)} lines")
    for index, line in lines:
        print(f"  {index}: {line}")

    var kept: list(string) = []
    for line in lines:
        if line != "pear":
            kept.append(line)
    try files.write_lines("kept.txt", kept)
    print(f"kept {len(try files.read_lines("kept.txt"))} lines")
```

```output
14 bytes
3 lines
  0: fig
  1: pear
  2: plum
kept 2 lines
```

`read_lines` strips newlines and adds no phantom empty line for a
trailing one. `write_lines` joins with newlines, ends with one, and
writes an empty file for an empty list.

## Handling the failure

```luce run
import std.files

func main():
    let text = files.read("does-not-exist.txt") catch "(nothing there)"
    print(text)

    files.write("/nowhere/at/all/x.txt", "data") catch:
        print("could not write outside the sandbox")

    print(f"exists: {files.exists("does-not-exist.txt")}")
```

```output
(nothing there)
could not write outside the sandbox
exists: false
```

`exists` answers a plain `bool` and is the one call here that is not
fallible — but it is a question about the past, never a guard for the
call after it. There is a window between the two that nothing can
close, and a guard could not tell "not there" from "would not open"
anyway. Read the file and handle what the read says.

## A word count

Reading, splitting, counting and sorting, with the failure carried to
the top by `try`.

```luce module file=input.txt
the quick brown fox
jumps over the lazy dog
the fox and the dog
```

```luce run args=input.txt
import std.files
import std.strings

func main(args: list(string)) -> !:
    if len(args) == 0:
        print("usage: wc FILE")
        return

    let path = args[0]
    let text = try files.read(path)

    var counts = new map(string, long)
    for line in text.split("\n"):
        for word in line.split(""):
            counts[word] += 1

    print(f"{len(counts)} distinct words in {path}")
    for word, seen in counts:
        if seen > 1:
            print(f"  {seen}  {word}")
```

```output
9 distinct words in input.txt
  4  the
  2  fox
  2  dog
```
