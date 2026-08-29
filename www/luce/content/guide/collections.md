# Collection Types

Luce provides three collection types. Choose one from the relationship in
your data, not from which API looks familiar.

| Relationship | Type | Use it for |
|---|---|---|
| Values have an order and the count may change | `list[T]` | queues, records, children, tokens |
| Values are addressed by a runtime key | `map[K, V]` | indexes, counters, configuration |
| Numeric or tabular data has a fixed shape | `array[T, ...]` | vectors, images, matrices, grids |

All three are mutable reference types managed by ARC. Assignment and argument
passing share the same collection. A list slice creates a new list and
copies value elements while retaining shared reference elements. Read [Memory
and ARC](/guide/memory/) before choosing between sharing a collection and
creating an independent outer collection.

## Lists

A `list[T]` is a growable, ordered sequence. A nonempty literal infers its
element type. An empty literal needs an annotation, or you can use
`list[T]()`.

```luce run
func main():
    var values = [3, 1, 4, 1, 5]
    var names: list[str] = []

    values.append(9)
    values.insert(0, 2)
    values.remove(1)                 # remove by index
    names.append("Ada")

    print(f"{len(values)} numbers and {len(names)} name")
    print(f"first {values[0]}, last {values[len(values) - 1]}")
```

```output
6 numbers and 1 name
first 2, last 9
```

Indexing is zero-based. Reading or writing an index outside
`0 .. len(values)` traps. `pop()` removes and returns the last element;
`clear()` removes every element.

### Searching and sorting

`find(value)` returns `i64?`, which keeps absence separate from index
zero. `contains(value)` returns `bool`. `sort()` is stable and sorts
in place; `reverse()` reverses in place.

```luce run
func main():
    var values = [3, 1, 4, 1, 5]
    values.sort()
    print(f"first {values[0]}, four at {values.find(4) else -1}")
    print(str(values.contains(8)))
```

```output
first 1, four at 3
false
```

`std.lists.sort_by` accepts a named comparator, lambda, or capturing closure.
It is also stable, so elements that compare equally keep their input order.

```luce run
import std.lists

struct Player:
    let name: str
    let score: i64

func main():
    var players = [
        Player(name = "ada", score = 20),
        Player(name = "grace", score = 30),
        Player(name = "lin", score = 20),
    ]
    players.sort_by((a, b) => a.score > b.score)
    for player in players:
        print(f"{player.name}: {player.score}")
```

```output
grace: 30
ada: 20
lin: 20
```

### Slices and nested lists

`values[a:b]` creates a new list. Open ends mean the beginning or end, and
changing the slice does not resize the source.

```luce run
func main():
    var values = [10, 20, 30, 40, 50]
    var head = values[:2]
    let tail = values[3:]
    head.append(999)
    print(f"head {len(head)}, tail {len(tail)}, source {len(values)}")
```

```output
head 3, tail 2, source 5
```

A collection retains reference elements placed inside it. That makes nested
collections easy to share intentionally. Use a slice when one nested list must
be independently resizable.

```luce run
func main():
    var rows = list[list[i64]]()
    rows.append([1, 2])

    var loose: list[i64] = [3, 4]
    rows.append(loose)
    let independent = loose[0:len(loose)]
    rows.append(independent)

    loose.append(5)
    print(f"shared {len(rows[1])}, independent {len(rows[2])}")
```

```output
shared 3, independent 2
```

## Maps

A `map[K, V]` is an insertion-ordered dictionary. Keys are integers, `str`,
or enums. A literal creates a fresh mutable map; an empty map needs
`map[K, V]()`.

```luce run
func main():
    var ages = {"ada": 36, "grace": 45, "alan": 41}
    ages["ada"] += 1

    for name, age in ages:
        print(f"{name} is {age}")

    print(f"has grace: {ages.has("grace")}")
    print(f"unknown: {ages.get("unknown") else -1}")
```

```output
ada is 37
grace is 45
alan is 41
has grace: true
unknown: -1
```

Iteration preserves the first insertion order, including after an existing
key is updated. `remove(key)` removes a present entry and does nothing for
an absent key.

### Safe lookup

Indexing a missing key traps because it asserts that the key exists. Use
`has(key)` for a Boolean question or `get(key)` for an optional value.

```luce trap
func main():
    var ages = map[str, i64]()
    ages["ada"] = 36
    print(str(ages["unknown"]))
```

```output
loom: trap: key not found in map [key_missing]
    at main (main.luc:4:5)
```

A compound assignment is intentionally different: it declares a write, so
a missing key starts at the value type's zero before the operation. This is
the ordinary counting form.

```luce run
import std.strings

func main():
    let text = "the cat sat on the mat the end"
    var counts = map[str, i64]()
    for word in text.split(" "):
        counts[word] += 1

    for word, count in counts:
        if count > 1:
            print(f"{word}: {count}")
```

```output
the: 3
```

`keys()` and `values()` return fresh lists.

## Arrays

An `array` has a fixed shape chosen when it is created. Its elements begin
at the type's zero value. Use an array when shape is part of the algorithm
and resizing would be meaningless or harmful.

```luce run
func main():
    var row = array[i64](5)
    for index in range(0, len(row)):
        row[index] = index * index

    var flags = array[bool](3)
    print(f"{len(row)} elements, last {row[4]}")
    print(f"zero value is {flags[0]}")
```

```output
5 elements, last 16
zero value is false
```

Arrays have one to four dimensions. A type annotation uses `_` for each
runtime dimension; `dim(axis)` reports its size.

```luce run
func sum(grid: array[i64, _, _]) -> i64:
    var total: i64 = 0
    for row in range(0, grid.dim(0)):
        for column in range(0, grid.dim(1)):
            total += grid[row, column]
    return total

func main():
    var grid = array[i64](4, 4)
    for row in range(0, 4):
        for column in range(0, 4):
            grid[row, column] = row * column
    print(f"{grid.dim(0)}x{grid.dim(1)}, total {sum(grid)}")
```

```output
4x4, total 36
```

A rank-one array supports `sort`, `reverse`, `find`, `contains`, and
`fill`. Numeric operations such as `sum`, `mean`, `dot`, and `axpy`
are in [`std.math`](/library/math/). `fill` is available for value elements;
assign reference elements to individual slots.

## Iterating safely

`for value in collection` visits values. `for key, value in collection`
visits a list or array index, or a map key, with its value. The collection stays
alive while the loop runs. Do not change its size during that iteration;
element replacement is allowed where the element and loop-binding rules permit
it.

For exact construction, indexing, and ARC rules, see
[Types](/guide/reference/types/). For module-specific operations, see
[`std.lists`](/library/lists/) and [`std.math`](/library/math/).
