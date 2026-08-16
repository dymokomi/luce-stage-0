# Global Constants

`const` is the file-scope declaration. Luce evaluates a constant when it
compiles the program. A flat list, map, or rank-one array is materialized
once in the program root and is read-only.

Use a constant for a value that is part of the program definition: a numeric
limit, an enum choice, a lookup table, or immutable seed data. Use a local
`let` for a value computed while the program runs. Constants are conventionally
written in `UPPER_SNAKE_CASE`, which makes the file-scope, compile-time choice
visible at a use site.

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

An annotation is optional when the initializer determines one concrete type.
Add it when an empty container needs an element type, when a narrow numeric
width matters, or when the declaration is a public boundary readers should
not have to infer.

## The foldable boundary

Constants may contain scalar values, strings, enum members, and value
structs that contain no objects. An optional field in such a struct may be
`none`. A container constant is flat: its elements cannot themselves be
containers or top-level optionals. Empty list and array literals need an
annotation, such as `list[i64]` or `array[i64, _]`.

The compiler folds literals, constant names, numeric conversions, unary and
binary constant operators, enum members, structure construction, and the
flat container forms supported by the program root. The same checked rules
apply as at runtime: overflow, division by zero, an invalid shift, a duplicate
constant-map key, or an out-of-range conversion is a compile-time diagnostic
rather than a latent trap.

Builders, reference-carrying structs, multidimensional arrays, function values,
and ordinary function calls do not fold. Constants may
refer to one another in any order, but a cycle is an error.

Evaluation order therefore does not depend on declaration order. The compiler
resolves the dependency graph, evaluates each constant once, and reports a
cycle with the names involved. There is no module-initialization routine and
no observable “first access” side effect.

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

Runtime list and map literals create fresh mutable containers on each
evaluation. Constant container literals instead create one root object. This
is why two calls to a function containing `[1, 2]` do not share that list,
while two reads of `NUMBERS` do share one immutable root.

## The immutable boundary

The program root lives for the lifetime of the runtime. Reads, indexing,
iteration, and operations that return fresh values are allowed. Mutating a
root directly is a compile-time error. Take a list slice when you need an
independent mutable list.

Reference equality makes sharing visible: a second constant assigned from a
container constant is the same root object, while a separately written
literal is another root object even when its elements compare the same. This
identity is not an invitation to mutate either root; it lets the runtime keep
one canonical immutable allocation.

The compiler enforces the boundary, and the runtime checks it again for
paths that reach generated stores. Each worker has its own runtime and its own
copy of the roots.

Constants obey ordinary module visibility. A public file-scope constant is
used as `module.NAME` after import; `private const` stays inside its file. A
public constant cannot expose a private nominal type through its declaration.

See the [statement reference](/guide/reference/statements/#file-scope-constants)
and [memory rule M11](/guide/reference/memory/#m11). Continue with [Modules
and Imports](/guide/modules/).
