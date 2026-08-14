# Constants

`const` is the file-scope declaration. Luce evaluates a constant when it
compiles the program. A flat list, map, or rank-one array is materialized
once in the program root and is read-only.

```luce run
struct Entry:
    label: string
    fallback: long?

const WIDTH = 80
const NUMBERS: list(long) = [3, 1, 2]
const ALIAS = NUMBERS
const EQUAL: list(long) = [3, 1, 2]
const AGES = {"ada": 36, "alan": 41}
const METHODS = {0: "stored", 8: "deflated"}
const ORDER: array(long, _) = [16, 17, 18, 0]
const ENTRIES = [
    Entry(label = "missing", fallback = none),
    Entry(label = "present", fallback = 9),
]

func first(values: list(long) = NUMBERS) -> long:
    return values[0]

func main():
    let ada_age = AGES["ada"]
    let deflated = METHODS[8]
    print(f"{WIDTH // 2} {ada_age} {deflated}")
    print(f"{NUMBERS == ALIAS} {NUMBERS == EQUAL} {first()}")
    print(f"{ORDER.dim(0)} {ENTRIES[1].fallback else 0}")
    var editable = copy NUMBERS
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
`EQUAL` is a different object. `copy` explicitly creates a mutable owned
copy. A default parameter can borrow a constant root in the same way.

## The foldable boundary

Constants may contain scalar values, strings, enum members, and value
structs that contain no objects. An optional field in such a struct may be
`none`. A container constant is flat: its elements cannot themselves be
containers or top-level optionals. Empty list and array literals need an
annotation, such as `list(long)` or `array(long, _)`.

Builders, object-carrying structs, multidimensional arrays, function values,
ordinary function calls, and ownership verbs do not fold. Constants may
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

An empty `{}` has no key or value type. Use `new map(K, V)` for an empty
mutable map. A duplicate key in a constant map is rejected because the
constant must describe one stable table.

## The immutable boundary

The program root lives for the lifetime of the runtime. Reads, indexing,
iteration, and operations that return fresh values are allowed. Mutating a
root directly, transferring its ownership, or freeing it is a compile-time
error. The diagnostic recommends `copy` when a mutable object is intended.

The compiler enforces the boundary, and the runtime checks it again for
paths that reach inline generated stores. Each worker has its own runtime
and its own copy of the roots.

See the [statement reference](/guide/reference/statements/#file-scope-constants)
and [ownership rule S46](/guide/reference/ownership/#s46).
