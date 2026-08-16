# std.paths

`std.paths` treats a path as text. It never checks the filesystem, so every
function is total and can be used in a host-less program. Paths use `/`.
There is no normalization of `.` or `..`, no globbing, and no platform drive
letter handling.

This separation is deliberate. `paths.join` answers how names combine;
`files.exists` or `files.read` asks the host what those names refer to. A pure
path operation cannot race with the filesystem or fail because a file changes
between two calls.

```text
import std.paths
```

## Inspect a path

| Signature | Result |
|---|---|
| `paths.is_absolute(path: str) -> bool` | whether `path` starts with `/` |
| `paths.base(path: str) -> str` | the last non-empty component; `/` is the base of the root |
| `paths.dir(path: str) -> str` | everything before the last component; a bare name and an empty path answer `.` |
| `paths.extension(path: str) -> str` | the final suffix including its dot, or `""`; a leading dot is not an extension |
| `paths.stem(path: str) -> str` | the base without its extension |

For a normal path, `paths.stem(path) + paths.extension(path)` is
`paths.base(path)`. Trailing separators are ignored when selecting the base
and directory.

```luce run
import std.paths

func main():
    let path = "src/luce/main.luc"
    print(str(paths.is_absolute(path)))
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

Important edge cases are defined rather than trapped:

| Input | `base` | `dir` | `extension` | `stem` |
|---|---|---|---|---|
| `""` | `""` | `"."` | `""` | `""` |
| `"/"` | `"/"` | `"/"` | `""` | `"/"` |
| `"notes"` | `"notes"` | `"."` | `""` | `"notes"` |
| `".env"` | `".env"` | `"."` | `""` | `".env"` |
| `"archive.tar.gz"` | `"archive.tar.gz"` | `"."` | `".gz"` | `"archive.tar"` |

A leading dot belongs to a hidden file's name, not its extension. Only the
last dot after the first character of the base begins the reported suffix.

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

An absolute component resets everything accumulated before it. This is useful
when configuration may provide either a relative or absolute path, but it is
also a reason to validate untrusted components before joining them.

## Paths do not provide containment

Neither `join` nor `joined` removes `.` or `..`, resolves symbolic links, or
proves that a result remains under a directory. For example,
`paths.join("uploads", "../private")` returns `"uploads/../private"` exactly as
text. Do not use a string-prefix check or this module alone as a filesystem
sandbox.

The functions also do not expand `~`, environment variables, wildcard
patterns, or backslashes. Convert an external path convention at the boundary
that receives it, then keep one convention inside the program.

`join` does not resolve `..` or ask whether the resulting path exists. Use
[`std.files`](/library/files/) when the next operation is a filesystem
operation. Path strings follow ordinary immutable `str` value semantics; no
resource is opened and no ARC object is created by inspection.
