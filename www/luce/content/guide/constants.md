# Constants

`const` is the file-scope declaration. Luce evaluates a constant when it
compiles the program. A flat list, map, or rank-one array is materialized
once in the program root and is read-only.

```luce run
struct Entry:
    label: str
    fallback: i64?

const WIDTH = 80
const NUMBERS: list[i64] = [3, 1, 2]
const ALIAS = NUMBERS
const EQUAL: list[i64] = [3, 1, 2]
const AGES = {"ada": 36, "alan": 41}
const METHODS = {0: "stored", 8: "deflated"}
const ORDER: array[i64, _] = [16, 17, 18, 0]
const ENTRIES = [
    Entry(label = "missing", fallback = none),
    Entry(label = "present", fallback = 9),
]

func first(values: list[i64] = NUMBERS) -> i64:
    return values[0]

func main():
    let ada_age = AGES["ada"]
    let deflated = METHODS[8]
    print(f"{WIDTH // 2} {ada_age} {deflated}")
    print(f"{NUMBERS == ALIAS} {NUMBERS == EQUAL} {first()}")
    print(f"{ORDER.dim(0)} {ENTRIES[1].fallback else 0}")
    var editable = NUMBERS[0:len(NUMBERS)]
    editable.sort()
    editable.append(4)
    print(f"{editable[0]} {len(editable)} {NUMBERS[0]}")
```

```output
40 36 deflated
true false 3
4 9
1 4 3
```

`ALIAS` refers to the same root object as `NUMBERS`; the separately written
`EQUAL` is a different object. A list slice creates the independent mutable
list used by `editable`. A default parameter shares the same constant root on
every omitted call.

## The foldable boundary

Constants may contain scalar values, strings, enum members, and value
structs that contain no objects. An optional field in such a struct may be
`none`. A container constant is flat: its elements cannot themselves be
containers or top-level optionals. Empty list and array literals need an
annotation, such as `list[i64]` or `array[i64, _]`.

Builders, reference-carrying structs, multidimensional arrays, function values,
and ordinary function calls do not fold. Constants may
refer to one another in any order, but a cycle is an error.

## Map literals

`{key: value, ...}` is a map literal in an expression. Entries are evaluated
in order; a later equal key replaces the earlier value. Runtime maps are
fresh and mutable:

```luce run
func main():
    var stock = {"fig": 3, "fig": 4, "pear": 2}
    stock["plum"] = 7
    for name, count in stock:
        print(f"{name}: {count}")
```

```output
fig: 4
pear: 2
plum: 7
```

An empty `{}` has no key or value type. Use `new map[K, V]` for an empty
mutable map. A duplicate key in a constant map is rejected because the
constant must describe one stable table.

## The immutable boundary

The program root lives for the lifetime of the runtime. Reads, indexing,
iteration, and operations that return fresh values are allowed. Mutating a
root directly is a compile-time error. Take a list slice when you need an
independent mutable list.

The compiler enforces the boundary, and the runtime checks it again for
paths that reach generated stores. Each worker has its own runtime and its own
copy of the roots.

See the [statement reference](/guide/reference/statements/#file-scope-constants)
and [memory rule M11](/guide/reference/memory/#m11).
