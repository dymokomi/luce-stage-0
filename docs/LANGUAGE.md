# The Luce language

The reference for Luce as it exists in this tree.  docs/V2.md is the
project plan; this file is the language.  Luce is **statically typed**
with inference — every expression has one type known at compile time,
annotations are optional where the initializer decides
(`let n = 1` is an Int; `let n: Int = 1` says so out loud), and there
are no implicit conversions (`Int(x)` / `Float(x)` are spelled).

## Values and objects

Two kinds of data, with a deliberate line between them:

- **Values** — `Bool`, `Int` (checked i64), `Float` (IEEE f64),
  `String` (immutable UTF-8), `Bytes`, and user `struct`s.  Values
  copy on assignment and call; nobody frees a value.
- **Heap objects** — `List(T)`, `Map(K, V)`, `Array(T, ...)`, and
  `Builder`.  Variables hold *references*.  Objects are created
  explicitly (`new ...` or a literal) and released explicitly
  (`free(x)`).  **Memory is explicit**: using an object after `free`
  traps (`use_after_free`), freeing twice traps, and loom reports
  anything still alive when a program ends ("leaked N objects").
  Copying a struct that contains a list copies the *reference* — both
  structs see the same list.

## Collections

```luce
var xs = [1, 2, 3]                 # List(Int), inferred from elements
var ys: List(String) = []          # empty literal needs an annotation
var m = new Map(String, Int)       # insertion-ordered dictionary
var grid = new Array(Int, 5, 5)    # fixed 5x5, zero-initialized
var b = new Builder()              # string builder

append(xs, 4)                      # [1, 2, 3, 4]
let first = xs[0]                  # index (bounds-checked)
xs[1] = 20                         # index assignment
let mid = xs[1:3]                  # slice -> NEW list (you free it)
let tail = xs[2:]                  # open ends default to 0 / len
m["one"] = 1                       # insert or update
let n = m["one"]                   # missing key traps; guard with has
if has(m, "one"):
    remove(m, "one")
grid[2, 3] = 7                     # multi-dimensional index
let rows = dim(grid, 0)            # dimension size; len(grid) == dim 0
append(b, "hello, ")
append(b, "world")
let text = str(b)                  # builder -> String
free(xs)
free(m)
free(grid)
free(b)
```

- `List(T)`: growable.  `append`, `insert(xs, i, v)`, `remove(xs, i)`,
  `pop(xs)` (traps when empty), `len`, index, slice.
- `Map(K, V)`: `K` is `Int` or `String`.  Index get (traps on a
  missing key), index set (insert or update), `has`, `remove`, `len`.
  Iteration order is insertion order.
- `Array(T, ...)`: fixed shape, up to 4 dimensions, sizes are runtime
  values at `new`, elements zero-initialized (numbers 0, Bool false,
  String "", structs zeroed field by field, object elements start null
  — using a null element traps until you store something).  In type
  annotations the shape is spelled with `_`:
  `func total(grid: Array(Int, _, _)) -> Int`.
- `Builder`: append-only text accumulator; `append(b, s)`, `len`,
  `str(b)`.  Exists so building big strings isn't O(n²).
- `==` / `!=` on objects compare *identity* (same object), never
  contents.
- Slices copy: `xs[a:b]` allocates a new list; `s[a:b]` on a String is
  the existing checked `slice` and stays a value.

## Iteration

```luce
for i in range(0, 10):      # ints, as before
for x in xs:                # list / rank-1 array elements, in order
for key in m:               # map keys, insertion order
```

Don't grow, shrink, or free a collection while iterating it; bounds
stay checked per step, but which elements you visit is your problem.

## Conversions and text

```luce
str(42)          # "42"        (Int, Float, Bool, Builder, String)
parse_int("42")  # 42          traps parse_failed on garbage
parse_float("2.5")
chr(955)         # "λ"         codepoint -> String; traps on invalid
ord("λ")         # 955         first codepoint; traps on empty
```

These are pure builtins (always available, no host gate), joining the
existing set: `abs min max clamp sqrt floor ceil len slice byte_at
assert trap` and the host-gated `print`, file, argument, terminal, and
key builtins (see docs/V2.md).

## Scope

One scope per **file** (top-level structs and functions), per
**struct** (its namespaced functions: `Text.width(...)`), and per
**function** (parameters and every indented block; `if`/`while`/`for`
bodies open nested scopes).  No shadowing anywhere; `let` is
immutable; `var` is mutable; loop variables are immutable inside the
body.  Structs contain plain functions — there are no methods, no
receivers, no inheritance; `Struct.func(...)` is a name, not a
dispatch.

## Traps

Errors are traps: deterministic, with stable codes, and they abort the
program without publishing anything.  New codes in this round:
`index_bounds`, `key_missing`, `empty_collection`, `use_after_free`,
`null_object`, `parse_failed`, `bad_codepoint`.  Long-standing codes:
integer overflow, divide by zero, conversion range, assertion failed,
string bounds/boundary, step budget, call depth.  The interpreter runs
on an explicit frame stack, so call depth is a *policy* limit, not a
native-stack accident.

## Modules

A file is a module, like Zig.  `import name` binds the sibling file
`name.luc` as a namespace: `name.func(...)`, `name.Struct(x = ...)`,
`name.Struct.member(...)`, and `p: name.Struct` annotations reach its
top level.  Scope stays per file — nothing is visible without an
import, and using a namespace you didn't import is a compile error
(`luce.sema.import`).  Modules may import each other; the graph loads
each file once, so cross-file mutual recursion just works.  The
compiler loads imports through the host (the CLI and loom resolve
them beside the root file), compiles the whole graph as one program,
and writes one .lc module; errors inside an imported file render as
`name.luc:line:column`.  Deliberately absent: package managers,
search paths, conditional imports, re-exports.

## Deliberately absent (for now)

First-class functions, closures, methods/receivers, exceptions
(traps are final), implicit conversions, shadowing, globals, garbage
collection (free is yours), operator overloading, string
interpolation, and enums/unions (likely next after modules).
