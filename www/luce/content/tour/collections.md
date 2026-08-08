# Lists, maps and arrays

Everything so far has been a **value**: it copies on assignment and
nobody frees it. The four collection types are **heap objects**.
A variable holds a reference to one, they are created with `new` or a
literal, and the scope that owns one frees it — which is
[the next chapter](../ownership/). This one is about what they do.

| Type | Shape |
|---|---|
| `list(T)` | A growable sequence. |
| `map(K, V)` | An insertion-ordered dictionary; `K` is `long` or `string`. |
| `array(T, ...)` | Fixed shape, up to four dimensions, zero-initialized. |
| `builder` | Accumulates text and hands back a `string`. |

Operations that belong to one type are written as methods —
`xs.append(v)`, `m.has(k)` — which is sugar for a plain function with
the receiver first, in the way Zig's `x.f()` is. The generic
cross-type builtins stay free functions: `len`, `string`, `print`.

## list

```luce run
func main():
    var xs = [3, 1, 2]           # list(int), inferred from the elements
    var names: list(string) = [] # an empty literal needs its type

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
`append`, `insert`, `remove`, `pop`, `sort`, `sort_by`, `reverse`,
`find`, `contains`, `clear`, plus `len`, indexing and slicing.

`sort_by` takes a named function or a capture-free lambda and lives in
the standard library rather than the language. Import `std.lists`
before using it; the comparator answers whether its first argument
belongs before its second.

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

Like `sort`, it is in place, stable and O(n log n). Unlike `sort`, it
works for every element type, including structs and heap objects;
object elements move and are never copied.

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

## map

Keys are `long` or `string`. Iteration is in insertion order, and the
lookups — index, `has`, `get`, index-set — are O(1) over a dense array
of entries with a hash index above it.

```luce run
func main():
    var stock = new map(string, long)
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

A **compound** store is the exception, and it is not one: `stock[k] +=
1` on a key that is not there defines the entry at the value type's
zero and then applies, because the operator says the statement is a
write. `counts[word] += 1` is the whole of the counting idiom.
`stock[k] = stock[k] + 1` still traps — the read is on the right of
the `=` and declares nothing.

## array

An `array` has a fixed shape given at `new`, and its elements start at
the type's zero value. Up to four dimensions; in a type annotation the
shape is spelled with `_`.

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

A rank-1 `array` also has `sort`, `reverse`, `find`, `contains` and
`fill`. `len(a)` is the size of dimension 0, and `a.dim(axis)` gives
any of them.

## builder

Repeated `+` on strings allocates every time. A `builder` does not.

```luce run
func main():
    var out = new builder()
    for i in range(0, 5):
        out.append(string(i))
        out.append(",")
    out.append_ascii(33)          # one ASCII byte, no string allocated
    print(out.build())
    print(f"{len(out)} bytes")
```

```output
0,1,2,3,4,!
11 bytes
```

`append_ascii` traps outside 0..127, because a builder's bytes become
a `string` and a `string` is valid UTF-8. Wider characters go in with
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
