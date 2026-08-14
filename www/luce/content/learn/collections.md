# Lists, maps and arrays

Luce has four container types. They are mutable objects with one owner;
their variables hold references. [Ownership](../ownership/) explains what
happens when a container is copied, moved, or leaves a scope.

| Type | Use |
|---|---|
| `list(T)` | Growable sequence. |
| `map(K, V)` | Insertion-ordered dictionary. Keys are `long`, `string`, or an enum. |
| `array(T, ...)` | Fixed shape, up to four dimensions. |
| `builder` | Incremental construction of a string. |

Methods such as `xs.append(v)` are receiver-first functions. Cross-type
operations such as `len`, `string`, and `print` remain free functions.

## Lists

```luce run
func main():
    var xs = [3, 1, 2]
    var names: list(string) = []

    xs.append(4)
    xs.insert(0, 99)
    print(f"{len(xs)} elements, first {xs[0]}, last {xs[len(xs) - 1]}")

    xs.sort()
    print(f"sorted first {xs[0]} then {xs[1]}")
    print(f"find(3) = {xs.find(3) else -1}, contains(42) = {xs.contains(42)}")

    let taken = xs.pop()
    print(f"popped {taken}, {len(xs)} left")

    names.append("ada")
    names.append("grace")
    print(f"{names[0]} and {names[1]}")
```

```output
5 elements, first 99, last 4
sorted first 1 then 2
find(3) = 2, contains(42) = false
popped 99, 4 left
ada and grace
```

The list methods are `append`, `insert`, `remove`, `pop`, `sort`,
`sort_by`, `reverse`, `find`, `contains`, and `clear`. Indexing and slicing
are bounds checked. `sort` and `sort_by` sort in place.

`sort_by` is in the standard library and accepts a named function or a
capture-free lambda:

```luce run
import std.lists

func main():
    var xs = [4, 1, 3, 2]
    xs.sort_by((a, b) -> a > b)
    print(f"{xs[0]} {xs[1]} {xs[2]} {xs[3]}")
```

```output
4 3 2 1
```

## Slices

`xs[a:b]` creates a new list and copies its elements. Open bounds mean the
beginning or end. It is not a view of the source list:

```luce run
func main():
    var xs = [10, 20, 30, 40, 50]
    let middle = xs[1:4]
    let tail = xs[3:]
    middle[0] = 999
    print(f"middle {middle[0]} {middle[1]} {middle[2]}")
    print(f"tail   {tail[0]} {tail[1]}")
    print(f"source {xs[1]}")
```

```output
middle 999 30 40
tail   40 50
source 20
```

Resource-carrying elements cannot be copied into a slice except for a
statically empty slice. The compiler checks this before execution.

## Maps

Maps preserve insertion order. Indexing a missing key traps; use `has` or
the optional result from `get` when absence is expected.

```luce run
func main():
    var stock = {"fig": 3, "pear": 12, "plum": 0}
    stock["fig"] += 1

    for name, count in stock:
        print(f"{name}: {count}")

    print(f"has apple: {stock.has("apple")}")
    print(f"get apple: {stock.get("apple") else -1}")
    stock.remove("plum")
    print(f"{len(stock)} kinds left")
```

```output
fig: 4
pear: 12
plum: 0
has apple: false
get apple: -1
2 kinds left
```

`map[key] += value` defines a missing key at the value type's zero before
applying the operator. A read on the right side of `=` still traps. An
empty map needs an explicit type: `new map(string, long)`.

## Arrays

An array's shape is fixed when it is created. Elements start at their type's
zero value. A type annotation uses `_` for dimensions whose sizes vary:

```luce run
func total(grid: array(long, _, _)) -> long:
    var sum: long = 0
    for row in range(0, grid.dim(0)):
        for column in range(0, grid.dim(1)):
            sum += grid[row, column]
    return sum

func main():
    var grid = new array(long, 3, 4)
    for row in range(0, 3):
        for column in range(0, 4):
            grid[row, column] = row * 10 + column
    print(f"{grid.dim(0)} by {grid.dim(1)}, corner {grid[2, 3]}")
    print(f"total {total(grid)}")

    var line = new array(double, 4)
    line.fill(1.5)
    print(f"rank-1 arrays sort and fill: {line[0]} {len(line)}")
```

```output
3 by 4, corner 23
total 138
rank-1 arrays sort and fill: 1.5 4
```

`len(a)` is the first dimension. `dim(axis)` reads another dimension;
rank-one arrays also provide `sort`, `reverse`, `find`, `contains`, and
`fill`.

## Builders

Use a builder when many pieces of text are assembled. `build()` returns the
finished immutable string:

```luce run
func main():
    var out = new builder()
    for i in range(0, 5):
        out.append(string(i))
        out.append(",")
    out.append_ascii(33)
    print(out.build())
    print(f"{len(out)} bytes")
```

```output
0,1,2,3,4,!
11 bytes
```

`append_ascii` accepts only 0 through 127. Use `append(chr(code))` for a
larger Unicode code point.

## Identity

Container equality compares object identity, not element contents:

```luce run
func main():
    var a = [1, 2, 3]
    var b = [1, 2, 3]
    let same = a
    print(f"a == b: {a == b}")
    print(f"a == same: {a == same}")
```

```output
a == b: false
a == same: true
```

Next: [Constants and shared tables](../constants/).
