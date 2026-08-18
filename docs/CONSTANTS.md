# File-scope constants

A file-scope `const` declares a name whose value is computed once, at
compile time. A constant may hold a folded scalar — a number, a `bool`,
a `str`, an enum member, an object-free value struct — or a flat
container: a `list`, a `map`, or a rank-1 `array`. Function scope keeps
`let` and `var`; file scope declares with `const`, and there is no
top-level `var`.

The memory model is `docs/MEMORY.md`. A scalar constant folds to a value
that inlines wherever it is used. A **constant container** is a
reference object materialized once, before `main`, and held by the
program root for the whole run: it is the program, not the run, so it is
never rebuilt per call and never reaches its last reference until the
program ends.

## Scalar constants

```luce
const answer: i64 = 42
const pi = 3.14159
const greeting = "hello"

func main():
    print(str(answer))
    print(greeting)
```

A constant has no type until it lands on one. `const xs = 3` is `i64` by
the literal default; an annotation supplies the landing type, and the
rule carries to the elements of a container (`docs/TYPES.md`). Anything
the folder can compute is a constant: literals, other constants and
their struct fields, arithmetic and comparison, string concatenation,
the numeric conversions, and value-struct construction. A `new`, a call,
an index, or a slice is not a constant — those belong in a function.

## Constant containers

A bracket or brace literal at file scope is a constant container. It is
folded into the artifact beside the interned strings, materialized once
before `main`, and held by the program root.

```luce
const crc_table: list[i64] = [0, 1996959894, 3993919788]
const length_bases: array[i64, _] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13]
private const keywords = {"and": true, "break": true, "catch": true}
```

The three written shapes:

| written | what it is |
|---|---|
| `const xs = [a, b, c]` | a `list[T]`, `T` from the elements or the annotation |
| `const xs: array[i64, _] = [...]` | a rank-1 `array`, the literal supplying the dimension |
| `const m = {k: v, ...}` | a `map[K, V]` |

A bracket literal is a `list` unless an `array[T, _]` annotation makes it
a rank-1 array. An empty `[]` needs a `list[T]` or `array[T, _]`
annotation to say which and to give the element type.

**Elements are flat.** A constant container holds scalars, strings, enum
members, or object-free value structs — anything the folder produces per
element. It may **not** hold another container: `list[list[i64]]` and a
rank-2 array literal are refused, naming flatness. An element may not be
optional (`T?`); a present value, or an optional tucked inside an
object-free struct, stands instead.

```luce
enum Mode:
    idle
    ready

const modes: list[Mode] = [Mode.idle, Mode.ready]
const reals = [1.0, 2.5, 3.75]

func main():
    print(str(len(modes)))
    print(str(reals[0]))
```

Constant containers **index, slice, and iterate** like any container. A
slice of a `list` constant copies and answers a fresh mutable `list`;
iteration reads the shared object. Constant arrays index and iterate,
and a program can build a fresh mutable copy from one, but there is no
array slice expression.

### Identity

The compiler emits one pool row per written construction. An alias, an
import, a use, and a shared parameter default all name that one row and
compare equal; two separately written but equal constructions are
distinct objects.

```luce
const numbers: list[i64] = [5, 8]
const same_numbers = numbers
const equal: list[i64] = [5, 8]

func main():
    assert(numbers == same_numbers)
    assert(numbers != equal)
```

## The map literal

Braces write a map — `{key: value}`, the same sense as a Python dict.
The literal is legal in both positions: at file scope it folds into a
constant map; inside a function it builds a fresh, mutable map.

```luce
private const keywords: map[str, bool] = {
    "and": true, "break": true, "catch": true,
}
const method_names = {0: "stored", 8: "deflated"}

func main():
    print(method_names[0])
```

Keys are `i64`, `str`, or an enum, as map keys always are. An
unannotated integer key lands on `i64`. A **constant** map refuses a
duplicate key at compile time, naming the key and both lines
(`map key "same" is duplicated`) — a check a runtime map cannot give.

A runtime map literal is a fresh mutable object; its entries evaluate in
written order and a later equal key replaces the earlier value.

```luce
func main():
    var numbers = {1: "one", 1: "last", 2: "two"}
    assert(len(numbers) == 2 and numbers[1] == "last")
    numbers[3] = "three"
    numbers.remove(2)
    print(str(len(numbers)))
```

Empty `{}` has no literal: it is refused with a sentence naming
`map[K, V]()`, which spells the key and value types out. That keeps
`{}` unclaimed. There is no `set` type; a constant `map[T, bool]` is the
constant-time membership test, and it comes with the duplicate-key
refusal for free.

Compile time never hashes. A constant map stores its entries in written
order, and the materialization pass inserts them one at a time through
the runtime's own map exports, so its hashing and probing are the same
as every other map's. The only compile-time judgment is duplicate
detection.

## Immutability

A constant container is read-only. A `list` constant answers `find`,
`contains`, `len`, `[i]`, `[a:b]`, and iteration; a `map` answers `has`,
`get`, `keys`, `values`, `len`, `[k]`, and iteration; an `array` answers
`dim`, `find`, `contains`, `len`, `[i]`, and iteration. `keys()` and
`values()` allocate fresh mutable lists, and a slice copies, so those results
are independently writable. A `builder` cannot be a constant at all: it is a
mutable reference object, and an empty text constant is simply `""`.

Every operation that would **write** a constant — `append`, `insert`,
`remove`, `pop`, `clear`, `sort`, `reverse`, `fill`, `sort_by`, an
element store `TABLE[i] = v`, a map store `TABLE[k] = v`, or writing into
one through `file.read` — traps `immutable_object` (`constant container
is immutable`), on both engines. A program that wants a mutable object
builds one the ordinary way and fills it from the constant:

```luce
const seed: list[i64] = [1, 2, 3]

func main():
    var working: list[i64] = []
    for value in seed:
        working.append(value)
    working.append(4)
    print(str(len(working)))
```

Because a constant container is a shared reference, passing one to a
function shares the same object, and a mutation attempted through the
parameter traps `immutable_object` just as a direct one would.

## Visibility, imports, and threads

A constant container obeys the ordinary file boundary (`private const`,
`docs/VISIBILITY.md`), reachable through an import exactly as a scalar
constant is. A public container may not expose a private element or
map-value type; marking the container private, or making the type
public, closes the surface. A public folded scalar may still be computed
from a private constant, because the value crosses the boundary, not the
name.

A file-scope `const` container may be a parameter default — the same
program-root reference at every call site (`docs/ARGS.md`) — and a
capture-free lambda may name one, because reaching a program-root
constant captures nothing (`docs/FUNCTIONS.md`).

Each worker runtime materializes its own constants, since nothing
allocated in one runtime is addressable from another
(`docs/THREADS.md`).

## How the object travels

The serialized module carries a `container_constants` pool beside the
scalar-constant pool: each row records the heap type (element type, rank,
dimensions), the element kind, and the elements as folded constants — or,
for a map, the key/value pairs in written order. One MIR instruction,
`const_container K`, answers a handle for pool row `K`; the verifier
checks the row is in range and that its heap type matches the register.

Both engines materialize the surviving rows the same way: a synthesized
prologue calls the ordinary runtime exports (`new list`, `list_append`,
`map_put`) once per element, in pool order, before `main`. Because both
run the same prologue against the same exports, what a constant container
*is* has one implementation, and the differential oracle compares it for
free.

- **Eager, not lazy.** Materialization is a fixed cost before the first
  line of `main` and nothing after it.
- **`prune` extends to the pool.** A constant no reachable function names
  is dropped from the artifact and never materialized, so an unused
  constant costs nothing to ship or to start.
- **`allocation_failed` may trap before `main`**; debug builds report it
  at the constant's declaration site.
- **The leak census excludes them.** A constant container is deliberately
  live for the whole run, so it is not a leak; teardown releases it with
  the rest of the heap.
