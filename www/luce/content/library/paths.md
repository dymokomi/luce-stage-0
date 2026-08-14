# std.paths

`std.paths` treats a path as text. It never checks the filesystem, so every
function is total and can be used in a host-less program. Paths use `/`.
There is no normalization of `.` or `..`, no globbing, and no platform drive
letter handling.

```text
import std.paths
```

## Inspect a path

| Signature | Result |
|---|---|
| `paths.is_absolute(path: string) -> bool` | whether `path` starts with `/` |
| `paths.base(path: string) -> string` | the last non-empty component; `/` is the base of the root |
| `paths.dir(path: string) -> string` | everything before the last component; a bare name and an empty path answer `.` |
| `paths.extension(path: string) -> string` | the final suffix including its dot, or `""`; a leading dot is not an extension |
| `paths.stem(path: string) -> string` | the base without its extension |

For a normal path, `paths.stem(path) + paths.extension(path)` is
`paths.base(path)`. Trailing separators are ignored when selecting the base
and directory.

```luce run
import std.paths

func main():
    let path = "src/luce/main.luc"
    print(string(paths.is_absolute(path)))
    print(paths.base(path))
    print(paths.dir(path))
    print(paths.extension(path))
    print(paths.stem(path))
```

```output
false
main.luc
src/luce
.luc
main
```

## Join components

`paths.join(head, tail)` inserts one `/` at the seam. An empty side returns
the other side. An absolute `tail` starts a new path, and repeated separators
at the seam collapse while the root slash is retained.

`paths.joined(parts)` folds the same rules from left to right. An empty list
returns `""`; an empty part contributes nothing.

```luce run
import std.paths

func main():
    print(paths.join("/usr/local/", "bin"))
    print(paths.join("src", "main.luc"))
    print(paths.joined(["build", "out", "main.o"]))
    print(paths.joined(["ignored", "/etc", "hosts"]))
```

```output
/usr/local/bin
src/main.luc
build/out/main.o
/etc/hosts
```

`join` does not resolve `..` or ask whether the resulting path exists. Use
`std.files` when the next operation is a filesystem operation.
