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
  `Builder`.  Variables hold *references*.  Objects are created with
  `new ...` or a literal and freed automatically by **scope
  ownership** (next section).  Copying a struct that contains a list
  copies the *reference* — both structs see the same list.

## Ownership

The memory model, in one paragraph (the full ratified specification —
43 numbered situations — is `docs/OWNERSHIP.md`; the compiler quotes
its numbers in diagnostics and `src/luce/ownership_spec.zig` executes
it):

- **The binding that received a fresh object owns it**, and the
  owning scope frees it — at the block end, at early `return`/`break`/
  `continue`, and immediately on reassignment of the owning `var`.
  Casual code never writes a memory word:

  ```luce
  func main():
      var xs = [1, 2, 3]        # xs owns the list
      xs.append(4)
      xs = [5, 6]               # old list freed right here
      # scope ends: everything owned here is freed
  ```

- **`let y = x` is an alias** — two names, one object, no tracking.
  An alias that outlives the object traps `use_after_free` at use
  (safe builds; the Zig posture).
- **Keeping a *named* object needs a verb.**  Storing into a
  container or struct field, or passing to a `give` parameter, takes
  something fresh, `give x` (transfer; `x` is poisoned — a compile
  error — to the end of its scope), or `copy x` (deep copy).
  Containers therefore *always* own their object elements: `pop()`
  hands the element out; overwrite/`remove`/`clear` free the old one;
  freeing a container frees everything it owns.
- **Calls borrow by default.**  A borrowed parameter may read and
  mutate contents but never keep, give, free, or return its object.
  Taking ownership is declared in the signature *and* echoed at the
  call site: `func stash(hits: give List(Int))` /
  `stash(give mine)`.
- **`return` moves.**  Whatever a function returns, the caller owns —
  returning a borrow or alias is a compile error (`return copy x` is
  the escape hatch).
- **Values never take verbs.**  Ints, Floats, Bools, Strings, Bytes,
  and plain-value structs copy freely.  A struct with object fields
  ("object-carrying") follows the object rules when *kept*.
- **`free(x)` survives as deliberate early release** on owned names,
  and poisons the name like `give`.
- **`var name: Type`** (no value) declares now, fills later: the slot
  holds the type's zero value — the null object for object types —
  and using it before assignment traps `null_object`.  There is no
  null literal and no nullable type; optionals are a future, separate
  decision.

Two dynamic backstops cover what static rules cannot see: `give`
through an alias of a container-owned object traps `not_owned`
(S23), and every verb demands a filled slot (`null_object`
otherwise).  Nothing can leak — loom's leak report is now an
interpreter self-check, not a program diagnostic.

## Collections

```luce
var xs = [1, 2, 3]                 # List(Int), inferred from elements
var ys: List(String) = []          # empty literal needs an annotation
var m = new Map(String, Int)       # insertion-ordered dictionary
var grid = new Array(Int, 5, 5)    # fixed 5x5, zero-initialized
var b = new Builder()              # string builder

xs.append(4)                       # [1, 2, 3, 4]
let first = xs[0]                  # index (bounds-checked)
xs[1] = 20                         # index assignment
let mid = xs[1:3]                  # slice -> a NEW list, owned by mid
let tail = xs[2:]                  # open ends default to 0 / len
m["one"] = 1                       # insert or update
let n = m["one"]                   # missing key traps; guard with has
if m.has("one"):
    m.remove("one")
grid[2, 3] = 7                     # multi-dimensional index
let rows = grid.dim(0)             # dimension size; len(grid) == dim 0
b.append("hello, ")
b.append("world")
let text = str(b)                  # builder -> String
# scope ownership frees xs, m, grid, and b here — no free() needed
```

Type-specific operations are **methods** (Python's split: `len`,
`str`, `print` and friends stay free functions; everything that
belongs to one type is called on it — and like Zig, `xs.append(v)` is
sugar for a plain function with the receiver first, not dispatch):

- `List(T)`: `append(v)`, `insert(i, v)`, `remove(i)`, `pop()` (traps
  when empty), `sort()` (in place; Int/Float/String elements),
  `reverse()`, `find(v) -> Int` (-1 when absent), `contains(v)`,
  `clear()`, plus `len`, index, slice.
- rank-1 `Array(T, _)` shares `sort()`, `reverse()`, `find(v)`,
  `contains(v)`, `fill(v)` (value elements only — an array of
  objects stores each slot separately); every Array has `dim(axis)`.
- `Map(K, V)`: `K` is `Int` or `String`.  Index get (traps on a
  missing key), index set (insert or update), `has(k)`, `remove(k)`
  (no-op when absent), `keys() -> List(K)`, `clear()`, `len`.
  Iteration order is insertion order.
- `Builder`: `append(text)`, `clear()`, `len`, `str(b)`.
- `Array(T, ...)`: fixed shape, up to 4 dimensions, sizes are runtime
  values at `new`, elements zero-initialized (numbers 0, Bool false,
  String "", structs zeroed field by field, object elements start null
  — using a null element traps until you store something).  In type
  annotations the shape is spelled with `_`:
  `func total(grid: Array(Int, _, _)) -> Int`.
- `==` / `!=` on objects compare *identity* (same object), never
  contents.
- Slices copy: `xs[a:b]` allocates a new list the receiver owns —
  deeply, when elements are objects (two containers can never own one
  object); `s[a:b]` on a String stays a value.

## Iteration

```luce
for i in range(0, 10):      # ints, as before
for x in xs:                # list / rank-1 array elements, in order
for key in m:               # map keys, insertion order
```

Don't grow, shrink, or free a collection while iterating it; bounds
stay checked per step, but which elements you visit is your problem.

## Strings

Strings are immutable values with methods (all pure, all allocate
fresh values):

```luce
s.find(sub)          # byte offset of first occurrence, -1 if absent
s.contains(sub)      # Bool
s.starts_with(p)     # Bool
s.ends_with(p)       # Bool
s.trim()             # ASCII whitespace off both ends
s.lower()            # ASCII case fold down
s.upper()            # ASCII case fold up
s.replace(old, fresh)  # every occurrence; empty old is a no-op
s.repeat(n)          # n copies (n <= 0 is "")
s.split(sep)         # List(String); empty sep splits on whitespace
s.byte_at(i)         # the byte value at offset i
words.join(", ")     # List(String) -> String
```

`s[a:b]` slices (UTF-8-boundary-checked); `len(s)` is bytes.

## Conversions and generic builtins

```luce
str(42)          # "42"        (Int, Float, Bool, Builder, String)
parse_int("42")  # 42          traps parse_failed on garbage
parse_float("2.5")
chr(955)         # "λ"         codepoint -> String; traps on invalid
ord("λ")         # 955         first codepoint; traps on empty
```

The free builtins are the generic, cross-type set — Python's own
split of capability: `len str print range assert trap free abs
min max clamp sqrt floor ceil chr ord parse_int parse_float`, the
conversions `Int(x)`/`Float(x)`, and the host-gated file, argument,
terminal, and key builtins (see docs/V2.md).  Everything that belongs
to one type is a method on it.

## Scope

One scope per **file** (top-level constants, structs, and functions),
per **struct** (its namespaced functions: `Text.width(...)`), and per
**function** (parameters and every indented block; `if`/`while`/`for`
bodies open nested scopes).  No shadowing anywhere; `let` is
immutable; `var` is mutable; loop variables are immutable inside the
body.  Structs contain plain functions — there are no methods, no
receivers, no inheritance; `Struct.func(...)` is a name, not a
dispatch.

### File-scope constants

`let` at the top level declares a **compile-time constant**:

```luce
let width = 80
let tau = 2.0 * pi          # constants may reference each other,
let pi = 3.14159            # in any order — never in a cycle
let banner = "loom " + version
let theme = Theme(keyword = 176, comment = 244)   # value structs too
```

Initializers fold at compile time: literals, other constants
(including `module.constant` through imports), arithmetic,
comparisons, `and`/`or`, string concatenation, `Int()`/`Float()`,
and value-struct construction.  Calls, objects (`List`, `Map`,
`Array`, `Builder`, object-carrying structs), and verbs are not
constant — constants are values, so ownership never applies to them.
Constants share the file's one namespace with structs and functions,
are reachable as `module.name` through imports, and cannot be
assigned or shadowed.  Every use site inlines the folded value.
Top-level `var` does not exist (whether mutable file scope ever
arrives is a separate decision — docs/V2.md).

## Traps

Errors are traps: deterministic, with stable codes, and they abort the
program without publishing anything.  New codes in this round:
`index_bounds`, `key_missing`, `empty_collection`, `use_after_free`,
`null_object`, `not_owned`, `parse_failed`, `bad_codepoint`.
Long-standing codes:
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

First-class functions, closures, user-defined methods/receivers
(`x.f()` is builtin sugar, not dispatch), exceptions (traps are
final), implicit conversions, shadowing, mutable file-scope `var`
(top-level `let` constants exist; mutable globals are a separate
decision), optionals and nullable types (Phase 3, designed with
error handling), garbage collection and reference counting (scope
ownership is the model — docs/OWNERSHIP.md), operator overloading,
string interpolation, and enums/unions.
