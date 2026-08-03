# Lists, maps and arrays

Everything so far has been a **value**: it copies on assignment and
nobody frees it. The four collection types are **heap objects**.
A variable holds a reference to one, they are created with `new` or a
literal, and the scope that owns one frees it — which is
[the next chapter](../ownership/). This one is about what they do.

| Type | Shape |
|---|---|
| `List(T)` | A growable sequence. |
| `Map(K, V)` | An insertion-ordered dictionary; `K` is `Int` or `String`. |
| `Array(T, ...)` | Fixed shape, up to four dimensions, zero-initialized. |
| `Builder` | Accumulates text and hands back a `String`. |

Operations that belong to one type are written as methods —
`xs.append(v)`, `m.has(k)` — which is sugar for a plain function with
the receiver first, in the way Zig's `x.f()` is. The generic
cross-type builtins stay free functions: `len`, `str`, `print`.

## List

```luce run
func main():
    var xs = [3, 1, 2]           # List(Int), inferred from the elements
    var names: List(String) = [] # an empty literal needs its type

    xs.append(4)
    xs.insert(0, 99)
    print(f"{len(xs)} elements, first {xs[0]}, last {xs[len(xs) - 1]}")

    xs.sort()                    # in place, stable, O(n log n)
    print(f"sorted first {xs[0]} then {xs[1]}")
    print(f"find(3) = {xs.find(3)}, contains(42) = {xs.contains(42)}")

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

`find` answers `-1` when the value is absent. The full set is
`append`, `insert`, `remove`, `pop`, `sort`, `reverse`, `find`,
`contains`, `clear`, plus `len`, indexing and slicing.

## Slices

`xs[a:b]` is a **new list**, owned by whoever receives it — never a
view. Open ends default to the beginning and the end.

```luce run
func main():
    var xs = [10, 20, 30, 40, 50]
    let middle = xs[1:4]
    let tail = xs[3:]
    middle[0] = 999               # the copy changes; xs does not
    print(f"middle {middle[0]} {middle[1]} {middle[2]}")
    print(f"tail   {tail[0]} {tail[1]}")
    print(f"source {xs[1]}")
```

```output
middle 999 30 40
tail   40 50
source 20
```

Indexing is bounds-checked, always, in both build modes. Reading past
the end is a trap.

## Map

Keys are `Int` or `String`. Iteration is in insertion order, and the
lookups — index, `has`, `get`, index-set — are O(1) over a dense array
of entries with a hash index above it.

```luce run
func main():
    var stock = new Map(String, Int)
    stock["fig"] = 3
    stock["pear"] = 12
    stock["plum"] = 0
    stock["fig"] += 1

    for name, count in stock:
        print(f"{name}: {count}")

    print(f"has apple: {stock.has("apple")}")
    print(f"get apple: {stock.get("apple", -1)}")
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

Indexing a key that is not there is a trap, deliberately: it is a bug
in the program, not news from the world. Use `has` before the index,
or `get(key, default)` which cannot trap.

## Array

An `Array` has a fixed shape given at `new`, and its elements start at
the type's zero value. Up to four dimensions; in a type annotation the
shape is spelled with `_`.

```luce run
func total(grid: Array(Int, _, _)) -> Int:
    var sum = 0
    for row in range(0, grid.dim(0)):
        for column in range(0, grid.dim(1)):
            sum += grid[row, column]
    return sum

func main():
    var grid = new Array(Int, 3, 4)
    for row in range(0, 3):
        for column in range(0, 4):
            grid[row, column] = row * 10 + column
    print(f"{grid.dim(0)} by {grid.dim(1)}, corner {grid[2, 3]}")
    print(f"total {total(grid)}")

    var line = new Array(Float, 4)
    line.fill(1.5)
    print(f"rank-1 arrays sort and fill: {line[0]} {len(line)}")
```

```output
3 by 4, corner 23
total 138
rank-1 arrays sort and fill: 1.5 4
```

A rank-1 `Array` also has `sort`, `reverse`, `find`, `contains` and
`fill`. `len(a)` is the size of dimension 0, and `a.dim(axis)` gives
any of them.

## Builder

Repeated `+` on strings allocates every time. A `Builder` does not.

```luce run
func main():
    var out = new Builder()
    for i in range(0, 5):
        out.append(str(i))
        out.append(",")
    out.append_ascii(33)          # one ASCII byte, no String allocated
    print(str(out))
    print(f"{len(out)} bytes")
```

```output
0,1,2,3,4,!
11 bytes
```

`append_ascii` traps outside 0..127, because a Builder's bytes become
a `String` and a `String` is valid UTF-8. Wider characters go in with
`append(chr(code))`.

## Identity, not contents

`==` and `!=` on objects compare *identity* — whether two names are
the same object — and never their contents.

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
