# The Luce language

The reference for Luce as it exists in this tree.  docs/V2.md is the
project plan; this file is the language.  Luce is **statically typed**
with inference — every expression has one type known at compile time,
annotations are optional where the initializer decides
(`let n = 1` is an `int`; `let n: long = 1` says otherwise out loud),
and the implicit conversions are the ones in `types.Type.widensTo`:
along a ladder every rung reaches every rung above it — `byte` to
`short` to `int` to `long`, `half` to `float` to `double` — and across
the two ladders the answer is always `double` (docs/TYPES.md §2).
**Nothing narrows**, in any direction or context.

## Values and objects

Two kinds of data, with a deliberate line between them:

- **Values** — `bool`, the seven numbers, `string` (immutable UTF-8),
  and user `struct`s.  Values copy on assignment and call; nobody
  frees a value.  The numbers are two ladders, and four of them do
  arithmetic: `int` (signed 32-bit) and `long` (signed 64-bit) trap on
  overflow and on division by zero; `float` (IEEE binary32) and
  `double` (IEEE binary64) follow IEEE without traps.  `int` and
  `float` are what a literal takes when nothing tells it otherwise.
  The other three — `byte` (unsigned 8-bit), `short` (signed 16-bit)
  and `half` (IEEE binary16) — are **storage**: an operator widens
  them to `int` and `float` before it does anything, so no expression
  ever has one and there is no arithmetic at 8 or 16 bits to define.
  What they are for is `array(byte, n)` at one byte an element
  (docs/TYPES.md D5).
- **Heap objects** — `list(T)`, `map(K, V)`, `array(T, ...)`, and
  `builder`.  Variables hold *references*.  Objects are created with
  `new ...` or a literal and freed automatically by **scope
  ownership** (next section).  Copying a struct that contains a list
  copies the *reference* — both structs see the same list.

## Ownership

The memory model, in one paragraph (the full ratified specification —
43 numbered situations — is `docs/OWNERSHIP.md`; the compiler quotes
its numbers in diagnostics and `src/luce/specs/ownership_spec.zig` executes
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
  call site: `func stash(hits: give list(long))` /
  `stash(give mine)`.
- **`return` moves.**  Whatever a function returns, the caller owns —
  returning a borrow or alias is a compile error (`return copy x` is
  the escape hatch).
- **Values never take verbs.**  Ints, Floats, Bools, Strings,
  and plain-value structs copy freely.  A struct with object fields
  ("object-carrying") follows the object rules when *kept*.
- **`free(x)` survives as deliberate early release** on owned names,
  and poisons the name like `give`.
- **`var name: Type`** (no value) declares now, fills later: the slot
  holds the type's zero value — the null object for object types —
  and using it before assignment traps `null_object`.  A `T?` says
  "there may be nothing here" out loud instead (next section), and
  holding `none` owns nothing (S43), so a `list(T)?` obeys every rule
  above exactly as a `list(T)` does.

One dynamic backstop covers what static rules cannot see: every verb
demands a filled slot, or traps `null_object`.  The second one is
gone — `give` through an alias was a `not_owned` trap until
2026-08-04 and is now a compile error, because an alias is one at the
site (S23).  `not_owned` itself stays as defense against a module the
front end did not produce, and is no longer reachable from source.
Nothing can leak — loom's leak report is now a runtime self-check,
not a program diagnostic.

## Absence: `T?` and `none`

A trailing `?` makes a type nullable: `long?` is a `long` that may not
be there, and `none` is the value that is not.  `?` means nullable and
**only** nullable — failure is `!` and is never spelled with a `?`
(see the next section).

```luce
struct User:
    name: string

func main(args: list(string)):
    var user: User? = none
    var limit: long? = 10
    let parsed = parse_int(args[0])   # long?
```

`T?` may be a local, a parameter, a return type, or a struct field.
It may not be a container element or a map value, and there is no
`T??` — one `?` is all there is.

A struct field typed `Struct?` is how a value struct holds one of
itself: the recursion stops at absence rather than at a layout, so a
linked list of value structs needs no new machinery and no reference
counting.

```luce
struct Node:
    value: long
    next: Node?
```

That is one case of a rule the compiler applies at two scales: **a
struct's *unconditional* size must be finite, and small.**  A plain
field's payload is part of what the struct is, so it is counted, and
counted through — a struct of two struct fields doubles per level.
Past 4096 values the declaration is refused, exactly as a struct that
contains itself is refused for being infinite.  An optional field
counts as one whatever it holds, because its payload starts absent and
arrives only when a program builds one.  So `?` is the answer to both
refusals, and the diagnostics say so:

```luce refused
struct Big:                       # 4096 values
    ...

struct Pair:
    a: Big
    b: Big                        # refused: always holds 8192

struct Pair:
    a: Big?
    b: Big?                       # fine: holds two `none` until told otherwise
```

The other answer is a container — a `list`, `map` or `array` is one
reference however much it holds.

**Narrowing is the feature.**  After a test, the name *is* its
payload: no unwrapping operator, no second spelling.

```luce
struct User:
    name: string

func greet(user: User?):
    if user != none:
        print(user.name)          # user is User here, not User?
    else:
        print("nobody")           # and User? there
```

Five shapes narrow, and they are the ones real code writes:

```text
if x != none: …                   the then arm
if x == none: …                   the else arm
if x == none:                     an early-exit guard narrows
    return                          everything below it
                                    (break and continue too)
if x != none and x > 3: …         the rest of the condition
while x != none: …                the loop body
x = 3                             an assignment of a plain value
```

Narrowing applies to **locals and parameters only** — not to fields or
elements, which can change between the test and the use.  Bind one to
a name and test that.  It also stops at anything that could undo it: a
loop body that assigns the name re-enters with whatever it left, so
the name widens for the whole loop, and an `if` keeps only what both
arms agree on.

**`a else b`** supplies a fallback, evaluating `b` only when `a` is
absent.  It is the null-coalescing operator and costs no new token:
Python needs `??` because `or` is broken there by truthiness, and Luce
has no truthiness and no ternary.

```luce
func main(args: list(string)):
    let count = parse_int(args[0]) else 10
    let first = parse_int(args[1]) else parse_int(args[2]) else 0   # right-associative
    let must = parse_int(args[3]) else trap("not a number")
```

`else` binds looser than `+` and tighter than the comparisons, so
`x else 0 > 5` compares the fallback and `x else n + 1` falls back to
the sum.  `x else trap("…")` is the assert-unwrap, and it is
greppable — which is why there is no force-unwrap sigil.

Using a `T?` where a `T` belongs is `luce.sema.absent` (or a
`luce.sema.type` mismatch), and the message names the two ways out on
the name in front of you.  So is a test or a fallback that can never
fire: once a name is known to hold a value, saying so again is dead
code, not caution.

## Failure: `T!`, `try`, `catch`

A trailing `!` on a return type says the call may not succeed:
`string!` hands back a string or an error, and a bare `-> !` hands
back nothing or an error. `!` means *failure* and only failure — it is
never spent on absence, which is `?`'s job (docs/FAILURE.md).

```luce
import std.files

func read(path: string) -> string!:
    return try file_read(path)

func main(args: list(string)) -> !:
    let text = try files.read(args[0])
    let cfg  = files.read("settings") catch ""
```

**`T!` is not a type.** Fallibility is an attribute of the *function*,
so there is no `T!` to declare a variable of, put in a list, or write
in a struct field — and `return x` in a `-> T!` function just returns
`x`, with nothing to wrap it in.

**The rule that decides which failures are errors:**

> A failure is an **error** if and only if a correct program, given
> correct input, can still meet it — because the world decided, not the
> program. Everything else is a trap. **Traps are bugs. Errors are
> news.**

Operationally: could the caller have prevented it with a check that is
not racy? If yes, it is a trap and the check is the program's job. If
the check is inherently racy or impossible, it is an error. And if the
answer is simply "there is nothing there", with no reason worth
carrying, it is neither — it is `T?`.

That rule left nineteen of the twenty trap codes then in the language
exactly where they were. What it moves is the host's file boundary: a
read or a write the world refuses is an error, because `file_exists`
before `file_read` is a race no program can close. (Luce has **18**
trap codes today; the twentieth left with the step budget, for
reasons of its own.)

**A call that can fail must say which it means.** Ignoring the outcome
is not a spelling the grammar has:

The first of these is the one the grammar refuses:

```luce refused
import std.files

func main(path: string, text: string):
    files.write(path, text)        # luce.sema.fallible
```

The two that say which they mean:

```luce
import std.files

func pass_on(path: string, text: string) -> !:
    try files.write(path, text)    # pass it to my caller

func handle(path: string, text: string):
    files.write(path, text) catch:     # handle it here
        print("cannot write " + path)
```

`try` propagates: it releases what this frame owns, innermost scope
first, and leaves — the same three lines `return` ends with, with one
terminator changed. It needs a caller that said `!`, or it is
`luce.sema.fallible`.

`catch` handles. It has three spellings, for the shapes recovery
takes:

```luce
import std.files

func handle_both(path: string):
    let text = files.read(path) catch ""        # a fallback value

    files.write(path, text) catch:              # a handler block
        print("cannot write " + path)

    files.write(path, text) catch reason:       # …reading the error
        print(reason)

    var greeting = "old file"
    var opening = ""
    opening = files.read(path) catch:           # …after a plain assignment
        greeting = "new file"
    print(greeting + opening)
```

The block form guards exactly one call, which is what separates it
from an exception block: there is never a question about which
statement failed. It attaches to a call written as a statement and to
a plain assignment, and to nothing else — a `let` would need the
handler to supply the value the name binds, and only `catch EXPR` can
say that.

`catch NAME:` binds the error's **message** — a `string`, immutable,
scoped to the handler block and released with it like any other local.
It is not the code and not the raise position: a `catch` guards one
call, and one call raises with one code, so there is nothing to branch
on; the position belongs to the report an *uncaught* error gets. The
name obeys the no-shadowing rule, and reading it outside the block is
`luce.sema.name`. The expression form takes no binding — a fallback
that reads the reason is a message being built, which is a statement.

`catch` binds like `else`, between the comparisons and `+`, and
associates right. Both sides must agree on ownership: if the call
hands over a fresh object, the fallback must too.

**`error("…")` raises**, with the program's own words:

```luce
func check(n: long) -> long!:
    if n < 0:
        error("negative: " + string(n))
    return n
```

It never comes back, so — like `trap("…")` — it may stand where a
value belongs: `parse_int(digits) else error("not a number")`.

An error carries a stable code and a message. There are exactly two
codes: **`io_failed`**, which the host's file services raise, and
**`user_error`**, which `error(...)` raises. Not `not_found` and
`permission_denied`, because a host service answers yes, no, or out of
memory, and cannot tell those two apart — inventing the codes would be
inventing the distinction.

An uncaught error out of `main() -> !` ends the run, and loom prints
the words and the **one** place the error was raised:

```
loom: error: expected a number at position 4 [user_error]
    raised in Scan.number (calc.luc:35:13)
```

One line, not a stack. A trap is a bug and the stack is its diagnosis;
an error is news, and where it came from is the news. (Carrying a full
trace would also charge the *success* path for it, which docs/MODES.md
forbids.)

There is no `errdefer` and there never will be: Luce's cleanup is
scope ownership, which already knows that `return` moves what it hands
back and `try` moves nothing. The one bit `errdefer` encodes is
already a parameter of the unwinder (docs/OWNERSHIP.md S4).

`programs/calc.luc` is the worked example, and `docs/FAILURE.md` is
the decision record.

## Answering more than one thing

A function may answer more than one value.

```text
func minmax(xs: array(double, _)) -> (double, double):
    …
    return low, high

let low, high = minmax(temperatures)
```

**There is no tuple.**  `(double, double)` is a shape a *signature* has,
not a type a program can name: it cannot annotate a binding, fill a
parameter or a field, stand inside a container, nest inside itself, or
take a `?`, and there is no expression that produces one.  A pair that
travels together is a struct.

A call that answers more than one value may stand in **exactly two
places** — the right of a destructuring bind, and a statement of its
own — and nowhere else.  `print(minmax(xs))`, `minmax(xs) + 1`,
`return minmax(xs)` and `low, high = minmax(xs)` are all refused.  Go
allows the pass-through and pays for it with a rule in its
specification saying that a multi-valued call used as arguments must
be the *only* arguments; refusing it is what makes this rule one a
reader can hold, because it has no exceptions.  The cost is one line:

```luce
func minmax(xs: array(double, _)) -> (double, double):
    var low = xs[0]
    var high = xs[0]
    for x in xs:
        low = min(low, x)
        high = max(high, x)
    return low, high

func main():
    var xs = new array(double, 4)
    xs.fill(1.5)
    let low, high = minmax(xs)
    print(string(low) + " " + string(high))
```

**One keyword governs the whole bind**: `let a, b` makes both
immutable, `var a, b` makes both reassignable, and `let a, var b` is
refused.  A bind takes its types from the call, so it carries no
annotations.  There is no `_`: Luce has no unused-binding diagnostic,
so a name costs nothing and tells the next reader what was ignored.

`-> (A, B)!` is legal and composes with `try`; `catch` supplies one
value and so cannot supply a shape, which leaves a fallible
multi-return propagatable or discardable and not handleable with
values.  An element may be a `T?` — absence is an ordinary value — but
`-> (long, long)?` is refused, because there the `?` would be marking
the shape.

Ownership is `docs/OWNERSHIP.md` S45: each value moves independently
(S16 per value), each name owns what it received (S1 per name), a
borrow or an alias in any position is S17 exactly, and **no object may
travel twice** — `return xs, xs` is a compile error, because two moves
of one handle would free it twice.

## Calls: names at the site, defaults at the declaration

Every parameter has a name, and a call site may use it — never must
(docs/ARGS.md).  Positional arguments come first and fill slots left
to right; **the first named argument ends the positional run**, and
everything after it is named.  Named arguments may be written in any
order.  A parameter may declare a default, `= EXPRESSION` after its
type: the default is a **compile-time constant**, folded once at the
declaration by the same folder that folds file-scope `let`, and
materialised at each call site — the lowered program is byte-identical
to the one with the argument written out.  Defaults are trailing: a
parameter with one may be followed only by parameters with one.
Struct fields take the same clause, under the same rules, and a struct
every one of whose fields has a default constructs bare: `Options()`.

```luce
func grown(base: long, step: long = 5, twice: bool = false) -> long:
    var total = base + step
    if twice:
        total = total * 2
    return total

struct Options:
    depth: long = 3
    wide: bool = false

func main():
    assert(grown(1) == 6)                   # step and twice defaulted
    assert(grown(1, twice = true) == 12)    # named, skipping step
    assert(grown(step = 0, base = 2) == 2)  # names may reorder
    let plain = Options()                   # every field has a default
    assert(plain.depth == 3 and not plain.wide)
```

**Arguments are evaluated in the order they are written, and bound to
the slots they name.**  When a call reorders, evaluation order and
parameter order differ — `f(b = one(), a = two())` calls `one()`
first.  This sits beside the left-to-right rule above rather than
replacing it: an unreordered call evaluates exactly as it always did.

A positional argument may not follow a named one:

```luce refused
func size(width: long, height: long) -> long:
    return width * height

func main():
    let a = size(width = 1, 2)
```

The boundaries, each one sentence: `self` is the receiver, not a
nameable argument, and takes no default; a `give` parameter cannot
have a default, because it takes ownership of an object and an object
is never a constant; a default cannot read another parameter, because
it is folded before any call is made; and objects (`new list(long)`,
`[1, 2, 3]`) are not defaults, because a default with no owner would
need a second lifetime model.  Free builtins take names and defaults
from the table that is their signature — `term_style(fg, bg = -1,
bold = false)` — while **builtin value methods** (`xs.append`,
`m.get`) stay positional: their tables hold types computed from the
receiver, and no names.

Two pieces of guidance the compiler cannot check (docs/ARGS.md §7).
A default belongs on a slot whose omission cannot violate an
invariant — two knobs whose defaults are only jointly sensible are
the one real way this feature goes wrong in code that compiles (Zig's
*Faulty Default Field Values* rule, adopted).  And defaults must not
become the way an argument list grows: shipped Luce's arity histogram
tops out at one declaration of arity 5, and if arity ≥ 5 ever reaches
double figures, the right answer is a struct, not another default.

## Methods

A function declared inside a struct is a **method** exactly when its
first parameter is `self`.  Everything else in a struct is the
namespace function it has always been.

```luce
struct Point:
    x: double
    y: double

    func length(self) -> double:              # a method: reads self
        return sqrt(self.x * self.x + self.y * self.y)

    func scale(var self, factor: double):     # a method: writes self back
        self.x = self.x * factor
        self.y = self.y * factor

    func origin() -> Point:                  # a namespace function
        return Point(x = 0.0, y = 0.0)
```

`self` is a keyword, bare, and its type is the enclosing struct;
`self: Point` is refused, because inside `struct Point` it can be
nothing else.  `p.length()` **means** `Point.length(p)` — the same
call, resolved at compile time.  There is no dispatch, no reference
type, and no function value: `let f = p.length` is refused for the
same reason `let f = Point.length` is.

**The difference between a namespace and a method is visible in
exactly one place**, and it is worth saying plainly because a struct
in Luce is used for both:

> `Struct.func(x)` is a **namespace** call — the struct is a folder
> and `x` is an ordinary first argument.  `x.foo()` is a **method**
> call — the struct is a type and `x` is its receiver.  Luce has both,
> they share a syntax, and the only thing that tells them apart is
> whether the declaration's first parameter is the word `self`.

`Point.length(p)` stays callable and means what `p.length()` means,
which is what lets a struct convert one function at a time.

**`var self` writes the receiver back.**  `p.scale(2.0)` means
`p = Point.scale(p, 2.0)`: copy in, copy out, with no reference
anywhere.  The receiver must be a place whose root is a mutable local
— the rule an assignment target already keeps — so a `let` receiver
and a call result are both refused, and `Point.scale(p, 2.0)` is
refused too, because the static form has no place to write back to.
A `var self` struct must carry no objects, which is where S17 and S28
already put such code; a struct that does carry objects mutates
through its fields from a plain `self` (S38) and needs no write-back.

A `var self` method may answer values of its own, and then **its
receiver is result zero**: `let roll = rng.next()` means
`rng, roll = Rng.next(rng)` internally, and the two travel in one
return shape.  There is no receiver mechanism separate from the return
mechanism.  A method that raises leaves its receiver as it was — the
write-back stands on the returning edge only.

## Collections

```luce fragment
var xs = [1, 2, 3]                 # list(long), inferred from elements
var ys: list(string) = []          # empty literal needs an annotation
var m = new map(string, long)       # insertion-ordered dictionary
var grid = new array(long, 5, 5)    # fixed 5x5, zero-initialized
var b = new builder()              # string builder

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
let text = b.build()                  # builder -> string
# scope ownership frees xs, m, grid, and b here — no free() needed
```

Type-specific operations are **methods** (Python's split: `len`,
`string`, `print` and friends stay free functions; everything that
belongs to one type is called on it — and like Zig, `xs.append(v)` is
sugar for a plain function with the receiver first, not dispatch):

- `list(T)`: `append(v)`, `insert(i, v)`, `remove(i)`, `pop()` (traps
  when empty), `sort()` (in place, **stable**; long/double/string
  elements),
  `reverse()`, `find(v) -> long` (-1 when absent), `contains(v)`,
  `clear()`, plus `len`, index, slice.
- rank-1 `array(T, _)` shares `sort()`, `reverse()`, `find(v)`,
  `contains(v)`, `fill(v)` (value elements only — an array of
  objects stores each slot separately); every array has `dim(axis)`.
- `map(K, V)`: `K` is `long` or `string`.  Index get (traps on a
  missing key), index set (insert or update), `has(k)`, `get(k,
  default) -> V` (the value or the default — no trap), `remove(k)`
  (no-op when absent), `keys() -> list(K)`, `values() -> list(V)`,
  `clear()`, `len`.  Iteration order is insertion order, and the
  lookups (index, `has`, `get`, index-set) are O(1): the entries
  stay a dense array in arrival order with a hash index over it.
- `builder`: `append(text)`, `append_ascii(code)`, `clear()`, `len`,
  `b.build()`.  `append_ascii` puts one ASCII byte in without the string
  a `chr()` would allocate; it traps `bad_codepoint` outside 0..127,
  because a builder's bytes become a string and string is valid
  UTF-8.  Wider characters go through `append(chr(code))`.
- `array(T, ...)`: fixed shape, up to 4 dimensions, sizes are runtime
  values at `new`, elements zero-initialized (numbers 0, bool false,
  string "", structs zeroed field by field, object elements start null
  — using a null element traps until you store something).  In type
  annotations the shape is spelled with `_`:
  `func total(grid: array(long, _, _)) -> long`.
- `==` / `!=` on objects compare *identity* (same object), never
  contents.
- Slices copy: `xs[a:b]` allocates a new list the receiver owns —
  deeply, when elements are objects (two containers can never own one
  object); `s[a:b]` on a string stays a value.

## Iteration

```text
for i in range(0, 10):      ints, as before
for x in xs:                list / rank-1 array elements, in order
for key in m:               map keys, insertion order
for i, x in xs:             index and element together (enumerate)
for key, value in m:        both, no second lookup
```

The two-name form binds a *position* then a *payload*: a sequence's
long index and its element, or a map's key and its value.  Don't grow,
shrink, or free a collection while iterating it; bounds stay checked
per step, but which elements you visit is your problem.

## Strings

Strings are immutable UTF-8 values.  The *language* provides the
primitives — literals and f-strings, `+` concatenation, comparison,
UTF-8-boundary-checked slices `s[a:b]`, `len(s)` in bytes,
`s.byte_at(i)` for raw byte access — the one builtin that answers a
`byte` (docs/TYPES.md §9) — and `s.find_byte(byte, start)`
for raw byte *search* (the offset of the first `byte` at or after
`start`, or -1; the byte looked for is a `byte`, so being outside
0..255 is refused where it is written, and `start` must be within the
string, or it traps).  Search is a primitive for the same reason
access is: the library builds substring matching on it, and the
runtime is free to vectorize it.

A literal is written `"..."` and stays on one line; the escapes are
`\n`, `\t`, `\\` and `\"`, and there are no others — `\r`, `\0`, hex
and unicode escapes are all rejected by name (a codepoint goes in
with `chr(...)`).  Everything built on top of the primitives lives in
the standard library's `strings` module (docs/STD.md), written in
ordinary Luce:

```text
import std.strings

s.find(sub)          # byte offset of first occurrence, -1 if absent
s.find(sub, i)       # the same find: start defaults to 0
s.contains(sub)      # bool
s.starts_with(p)     # bool
s.ends_with(p)       # bool
s.count(sub)         # non-overlapping occurrences
s.trim()             # ASCII whitespace off both ends
s.lower()            # ASCII case fold down; multibyte passes whole
s.upper()            # ASCII case fold up
s.replace(old, replacement)  # every occurrence; empty old is a no-op
s.repeat(n)          # n copies (n <= 0 is "")
s.split(sep)         # list(string); empty sep splits on whitespace
s.pad_left(w)        # space-padded to w bytes
s.pad_right(w)
words.join(", ")     # list(string) -> string
strings.format_float(x, 2)   # fixed-point double display: "2.50"
```

The method spelling is the same sugar as everywhere else:
`s.find(x)` is `strings.find(s, x)` — a plain borrowed call with the
receiver first — whenever `import std.strings` is in scope, and a compile
error pointing at the missing import otherwise.  Only `byte_at` and
`find_byte` are built in.

**Interpolation.**  An `f"..."` string splices expressions in `{...}`,
each converted with `string(...)`:

```luce
import std.strings

struct User:
    name: string

func show(x: long, y: long, a: long, b: long, user: User, mean: double):
    print(f"x = {x}, y = {y}")       # "x = 7, y = 3"
    print(f"sum = {a + b}")          # any scalar expression: long, double,
                                     # bool, string — a list is a type error
    print(f"name is {user.name}")    # methods, calls, fields all work
    print(f"{{literal braces}}")     # double a brace for a literal { or }
    print(f"mean = {mean:.2f}")      # a double to two decimal places
```

The hole is one expression; nested `"..."` strings inside a hole are
fine.  `f"..."` desugars to plain `+` concatenation of `string(...)`
pieces, so it is a string like any other.

**Format specs.**  A hole may end `:.Nf` — N decimal places of a
`double`, rounded half away from zero (docs/NUMERICS.md §8).  That is
the whole spec language: no width, no fill, no alignment, no `%`, no
`e`, no thousands separator, and anything else is a
`luce.parse.fstring` naming the one form that exists.  The `f` is
redundant, since the compiler knows the operand's type, and is
required anyway — `{x:.2}` means *two significant digits* in Python,
and letting it mean two decimal places here would be a silent
divergence.

A spec lowers to `strings.format_float(value, N)`, so it needs
`import std.strings` for the same reason `s.split(",")` does, and says
so through the same diagnostic.  Formatting is where formatting
happens: there is no `string.format`, and `%` stays an arithmetic
operator.

A colon *inside* brackets belongs to the brackets, so `f"{s[1:3]}"` is
a slice and `f"{m[k]}"` a lookup.

## Conversions and generic builtins

**Three conversion constructors, each named for the type it
produces**: `long(x)`, `double(x)`, `string(x)` (docs/NUMERICS.md §7).
They are the only ones, and none of them is a builtin — the compiler
matches the three names before it resolves anything, which is why all
three are reserved.

`long(x)` **rounds half away from zero** — `long(2.5)` is `3` and
`long(-2.5)` is `-3`, the same rounding `math.round` does — and traps
`conversion_range` on NaN, an infinity, or a value outside the `long`
range.  `trunc(x)` is truncation toward zero, so `floor`, `ceil`,
`trunc` and round are four spellings for four different answers.
`double(x)` widens and never traps.  `string(x)` prints a `long`, a
`double`, a `bool` or a `string`, and takes a **scalar only**: a
`builder` is a heap object and hands over its text with `b.build()`.
An f-string hole is a `string(...)` the reader did not write, so the
same rule decides what may stand in one.

```luce fragment
string(42)          # "42"        (long, double, bool, builder, string)
parse_int("42")  # 42          long?   — none when the text is not a number
parse_float("2.5")               # double?
chr(955)         # "λ"         codepoint -> string; traps on invalid
ord("λ")         # 955         first codepoint; traps on empty
```

`parse_int` and `parse_float` answer a `T?` rather than trapping:
"not a number" is the same reason every time and the name already
implies it, so absence carries all the information there is
(docs/FAILURE.md).  Read the answer with `else`, or test it:

```luce
func main(args: list(string)):
    let count = parse_int(args[0]) else 10
    let text = args[1]
    let n = parse_int(text)
    if n == none:
        print("not a number: " + text)
        return
    print(string(n * 2) + string(count))
```

The free builtins are the generic, cross-type set — Python's own
split of capability: `len print range assert trap free abs
min max clamp sqrt floor ceil trunc chr ord parse_int parse_float`,
the
conversions `long(x)`/`double(x)`, and the host-gated file, argument,
terminal, and key builtins (see docs/V2.md).  Everything that belongs
to one type is a method on it.

## The host

**The command line is not one of them.**  A program that reads its
arguments declares them:

```luce
func main(args: list(string)):     # and `-> !` composes with it
    for name in args:
        print(name)
```

`args` is an ordinary `list(string)`, so `len`, indexing, slicing,
`for … in`, `contains` and `strings.join` all work on it, and
`args[0]` is the first word after the program's own name.  It is
*handed to* the program rather than called *by* it, which is why the
host gate does not cover it and why a host with no arguments to offer
supplies an **empty** list instead of a trap; reading past the end is
the language's own `index_bounds` (OWNERSHIP.md S44).  A program that
ignores its arguments writes `func main():` and says nothing false.

Every other effect is a host service, every service is optional, and
one the host does not offer traps `host_unavailable` rather than
touching anything.  The whole set, and what each answers:

```text
print(text)                  a line to standard output
print_error(text)            a line to standard error
read_line(prompt)            # string?  — none at end of input
env(name)                    # string?  — none when unset

clock_ms()                   # long, monotonic, unspecified origin
sleep_ms(milliseconds)       # waits at least that long

file_read(path)              # string!
file_write(path, content)    # !
file_append(path, content)   # !
file_delete(path)            # !
file_rename(from, to)        # !
file_exists(path)            # bool — a question, never a guard
dir_list(path)               # list(string)! — plain names, unsorted

term_rows()   term_cols()   term_clear()   term_move(row, col)
term_style(fg, bg, bold)   term_write(text)   term_flush()
key_read()   key_text()          # key_read is string?
```

Three shapes and one rule behind them (docs/FAILURE.md).  A file
operation is `!` because the world decides and no non-racy check
stands in for the result.  `read_line`, `env` and `key_read` are `?`
because "there is nothing there" is the whole of what they have to
say — end of input, and a variable nobody set, carry no reason worth a
message.  Everything else either cannot fail or is an effect.

`key_read` is `string?` for the same fact `read_line` is, off the same
descriptor: a keyboard runs dry when the pipe driving it ends or the
terminal closes, and the host cannot tell those apart and has no
reason to.  It is deliberately **not** one more name in the closed set
— an `"eof"` among `"enter"` and `"up"` would be a value a program can
fall past without the compiler saying so, and a draw loop that falls
past it asks for the next key forever.  `none` is refused where it is
written.

`sleep_ms` of a duration that has already elapsed — zero, or the
negative one that `deadline - clock_ms()` produces on a slow frame —
is **not** a trap.  There is no time left to wait, so the call
returns.  That is a deliberate reading of the rule: a frame-pacing
loop that traps only on a slow machine is a correct program made
flaky by its host.

`clock_ms` promises only that differences mean something.  It is a
monotonic reading, not a calendar, and there is no wall clock: dates
are a library that does not exist yet.

`read_line` takes its prompt as an argument rather than leaving it to
`print`, for the reason `key_read` presents the pending frame before
blocking — a prompt that is not on the screen when the program stops
for input is a program that looks hung, and only the host knows when
its own buffer goes out.  Pass `""` for no prompt.

Prompt text and `print_error` text are **sanitized**, exactly as
`term_write` text is: a program describes what it wants shown and the
host writes every control byte itself.  `print` is deliberately not —
standard output is the program's own channel and may be a pipe or a
file, where an escape sequence is simply bytes; standard error and the
terminal are shared with whoever ran the program.

### Paths are not confined, deliberately

**A program may name any path the process itself can.**  There is no
root it is chrooted to, no prefix its paths are checked against, and
no difference between `notes.txt`, `../notes.txt` and
`/etc/hosts` — relative paths resolve against the working directory
the program was started in, and that is the whole of the rule.

This is the unix-tool model and it is a decision, not an omission.
`loom` runs programs the way a shell runs processes: a Luce program
started by a person has that person's user, that person's working
directory and that person's permissions, exactly as `grep` does.
`allow_host` is the gate — it decides whether a program may reach the
world *at all*, and a program compiled without it cannot name a file,
open a terminal or read an argument — and the operating system is the
sandbox that decides which files.  Two mechanisms, each doing one
thing, both of them things a reader can check.

The alternative — a path prefix the host enforces — would be a third
mechanism that looks like security and is not: it has to canonicalize,
it has to follow symbolic links, it has to survive a rename between
the check and the open, and every one of those is a hole in something
the operating system already gets right.  A program that must not
touch a file should be run by a user that cannot, in a container that
does not have it, or under whatever the host system offers; nothing
Luce could add on top of that would make it safer, and a half-measure
would make people think it had.

The size cap on `file_read` is not a confinement and is not about
trust: it is a host policy that stops one call from asking for the
machine's memory (64 MiB; a larger file answers the same failure as an
unreadable one).  Streaming reads are the answer to wanting more, and
they are a service the host does not offer yet.

## Arithmetic and assignment

**A literal has no type until it lands on one** (docs/TYPES.md §1).
It is read from its text at the width of the place it reaches — an
annotation, an argument, a return, a struct field, a container
element, a subscript, a conversion constructor — so no decimal ever
travels through binary64 on its way to a binary32, and `double(0.1)`
is binary64's 0.1 rather than binary32's widened.  With no place to
land on, `12` is an `int` and `1.5` is a `float`; a literal past the
width it landed on is refused at compile time by a message naming the
width that would hold it.

Number literals are decimal, and a fraction or an exponent makes a
float (`1.5`, `1e10`, `1.5e-3`).  A `.` only starts
a fraction when a digit follows it.  There are no hexadecimal,
binary or octal literals and no `_` digit separators — writing one
is a `luce.lex.number` error naming the reason, not a silent
misreading (docs/MISSING.md tier 3, item 11).

Binary operators are `+ - * / // %`, the comparisons
`== != < <= > >=` (ordering on long, double, string), and `and or not`
(short-circuit).

**`/` is real division and always answers a double**, whatever it
divides (docs/NUMERICS.md §2): `1 / 2` is `0.5`, `total / len(xs)` is
the average, and there is no integer `/` in the language at all.  It
follows IEEE without traps — `1 / 0` is `inf` and `0 / 0` is NaN —
because the operators that trap are the ones that answer a long, and
`/` is not one of them.  `n /= 2` on a long place is therefore a
compile error naming `//=`, which is the whole of what the change
costs and the whole of why it is safe.

**`//` and `%` are the integer pair and they floor together**
(docs/NUMERICS.md §3).  `//` is floor division — the floor of the
quotient — and `%` is the modulus that pairs with it, so it takes the
sign of the **divisor** and `b * (a // b) + (a % b) == a` holds for
every pair of operands that does not trap:

| `a` | `b` | `a // b` | `a % b` |
|---:|---:|---:|---:|
| 7 | 3 | 2 | 1 |
| −7 | 3 | −3 | 2 |
| 7 | −3 | −3 | −2 |
| −7 | −3 | 2 | −1 |

A positive divisor therefore never yields a negative answer, which is
what makes `x % 256` a byte wrap for every `x` and `(row - 1) % height`
a torus.  `//` and `%` by zero trap; on Floats they are IEEE and do
not, and double `%` floors with the integer one so promotion crosses
the line without a seam in it.

There is no `//` comment: a comment runs from `#` to the end of the
line, and a line beginning `//` is answered by name
(`luce.parse.comment`).

**Numbers that mix** (docs/TYPES.md §2, docs/NUMERICS.md).  Seven
types on two ladders, four of which do arithmetic, and the implicit
conversions stated once: along a ladder every rung reaches every rung
above it, and a mixed pair meets at `double` whichever way round it
was written.  That is the whole of it — everywhere a value meets a
type, from both operands of `+ - * / %` to a `let` annotation, an
argument, a return, a struct field, a list element, a compound
assignment and `min`/`max`/`clamp`.  A storage width is promoted
before any of that happens, so `byte + byte` is an `int` and
`half * half` a `float`.

What is deliberately *not* there is Java's `int → float` and
`long → float`, which lose everything above 2^24 from sources that
reach it routinely; a program that wants a narrow float writes
`float(x)` and says so.

**Narrowing is implicit in no direction and no context** — not `long`
into `int`, not `double` into `float`, not at a store, an argument or
a return.  A value that reached somewhere narrower than itself is
refused at the first place it did not fit, by a message naming the
constructor that would do it.

Promotion needs a place that expects a `double`.  `let xs = [1, 2, 3]`
is still a `list(long)`; `let xs: list(double) = [1, 2, 3]` is a
`list(double)`, and `[1, 2.5]` is one too, because one `double` among
numbers makes them all `double`s wherever it stands.

**Comparison across the line is exact.**  `1 < 1.5` is `true`, and so
is `9007199254740993 != 9007199254740992.0` — those are two different
numbers, and the first does not survive being widened.  Approximation
in `+` is expected and understood; an `==` that answers `true` for two
different numbers is a defect, so a mixed comparison compares the
numbers rather than a conversion of them.  (The consequence, which
Python has too: `a == b` is exact while `a + 0.0 == b` is not, because
the addition really did widen.)

### Precedence, and the two places Luce refuses to guess

Loosest to tightest: `or`, `and`, the comparisons, `else`, `+ -`,
`* / %`, then the prefix operators `not` `-` `give` `copy`, then
postfix `.field` `[index]` `(call)`.  Same-precedence binary operators
associate to the left — except `else`, which associates to the right
so `a else b else c` is a real chain — and the prefix operators to the
right.

Two shapes are legal in a language Luce reads like and mean something
different here, so rather than pick a winner the parser refuses them
and names both readings.  Both are `luce.parse.*` diagnostics, and
both are fixed by one pair of parentheses.

**`not` in front of a comparison.**  `not` is a prefix operator, so it
binds *tighter* than `==` — the C, Zig and Rust reading.  Python's
`not` binds *looser* than comparison, so a Python reader reads
`not a == b` as `not (a == b)` and gets the opposite answer whenever
both operands are bool.  Writing it bare is `luce.parse.precedence`;
write `(not a) == b` or `not (a == b)`.

**Chained comparison.**  `a < b < c` is one comparison in Python
(`a < b and b < c`, with `b` evaluated once) and two in C
(`(a < b) < c`, comparing a bool with a long).  Luce has neither: the
comparisons are **non-associative**, and chaining them is
`luce.parse.chain`.  Write `a < b and b < c`.  This costs nothing —
`(a < b) < c` was always a type error one stage later, and comparing
two Bools with `(a < b) == (c < d)` is still legal, because the
parentheses start a new chain.

Compound assignment applies an operator in place: `n += 1`, `n -= 1`,
`n *= 2`, `n /= 2`, `n //= 2`, `n %= 3`, and `s += "!"` (string
concat).  It is
value-only arithmetic — the place is a number (or a string for `+=`),
never an object — and the place is evaluated once, so
`grid[row, col] += 1` reads and writes the same slot:

```luce fragment
var total = 0
total += 5          # total == 5
var s = "a"
s += "b"            # s == "ab"
var counts = new map(string, long)
counts["k"] += 1    # the key is evaluated once, and defined at 0
```

A **storage-width place combines at its arithmetic type and narrows
back** (docs/TYPES.md D5): no operator computes at 8 or 16 bits, so
`b += 1` on a `byte` is `b = byte(b + 1)` exactly — promoted to `int`,
added, and narrowed through the same checked conversion.  Nothing is
narrowed silently: at 255 it traps `conversion_range` rather than
wrapping to zero.  A plain `b = b + 1` has nowhere to write the
narrowing down and is still refused.

Assignment targets a **place**: a name, a field, or an index, nested
freely — `p.inner.n = 1`, `cells[0].value += 5`, `grid[r, c].tag =
"x"`.  The place is read once (every subscript evaluated once), then
rebuilt: value structs update functionally up to their root binding,
and the innermost container element is written in place.  A nested
place assigns a **value** (a number, string, or plain struct); to
restock an *object* field use the single-level form
(`bag.items = [1, 2]`).

### Zero values

**Every type has a zero value.**  It is what `var name: Type` with no
initializer starts at, what every cell of a fresh `array` holds, and
what a `struct` with no explicit field is built out of, field by
field.  The numbers are `0`, `bool` is `false`, `string` is `""`, a
`T?` is `none`, and an object reference is null and traps on use until
something assigns over it.

A zero is normally something a place *starts* at.  One rule makes one
appear later: **a compound store into a map key that does not exist
defines the entry at the value type's zero, and then applies.**

```luce fragment
var counts = new map(string, long)
counts["fig"] += 1      # defined at 0, then incremented: 1
var notes = new map(string, string)
notes["fig"] += "ripe"  # defined at "", then concatenated
```

The zero is the *value*, not an identity element chosen per operator:
`counts["pear"] *= 2` on a key that is not there is `0`, because the
entry is brought into existence at zero and multiplied afterwards.

**A plain read still traps.**  `counts[word]` on an absent key is
`key_missing`, and so is `counts[word] = counts[word] + 1` — which
reads before it writes.  The two spellings diverge on purpose.  What
separates them is not how much they do but what they *say*: the
operator in `+=` stands to the left of the read and declares a write,
while a read on the right of an `=` declares nothing at all.  A map
that invented values on being asked would answer zero for every
mistyped key, which is the bug the trap exists to catch; a map that
defines what it is plainly told to write is how a map has always
grown.  It is the distinction an operating system draws when it maps a
page of zeroes on the first *write* and faults on a wild read.

Use `get(key, default)` for a read with an explicit fallback; it never
traps and never defines.

**Maps only.**  A list or an array index keeps its bounds trap under
every operator — `xs[0] += 1` on an empty list is `index_bounds`.  An
index is a position in something that already has a shape, not a name
that can be called into being, and `append` is the verb that grows a
list.

**Only a map index that is itself the place defines.**
`t.counts[word] += 1` defines, because `t.counts[word]` is the place.
`m[key].field += 1` does not: the place is the *field*, and the map
index in front of it is a step on the way down — asking, not writing.
Defining it would have to invent a whole struct nobody wrote, so it
keeps `key_missing`.

## Scope

One scope per **file** (top-level constants, structs, and functions),
per **struct** (its namespaced functions: `Text.width(...)`), and per
**function** (parameters and every indented block; `if`/`while`/`for`
bodies open nested scopes).  No shadowing anywhere; `let` is
immutable; `var` is mutable; loop variables are immutable inside the
body.  Structs contain plain functions — there are no methods, no
receivers, no inheritance; `Struct.func(...)` is a name, not a
dispatch.

### Unreachable code is refused

A statement below one that never comes back — `return`, `break`,
`continue`, `trap(...)`, `error(...)`, or an `if` whose arms all leave
— is a compile error naming the terminator and its line.

This follows from the compiler having **one severity**: every
diagnostic stops the compile, because a warning is a rule the language
did not commit to.  So the question is only which side of the line
unreachable code falls on, and the line the language already draws is
between code that is *misleading* and code that is merely *redundant*.
`a < b < c` and `not a == b` are refused because the way they read and
the way they run disagree; an unused local is accepted, because the
program means what it says and does what it says.  A statement after
`return` is the first kind: the author wrote it believing it runs.

One terminator is one report, however many lines it stranded.  An `if`
counts only when **every** arm leaves, so the ordinary early-return
guard is untouched:

```luce
func floor_at_zero(n: long) -> long:
    if n < 0:
        return 0
    return n                  # reachable: the guard has no else
```

### File-scope constants

`let` at the top level declares a **compile-time constant**:

```luce
struct Theme:
    keyword: long
    comment: long

let width = 80
let tau = 2.0 * pi          # constants may reference each other,
let pi = 3.14159            # in any order — never in a cycle
let version = "2"
let banner = "loom " + version
let theme = Theme(keyword = 176, comment = 244)   # value structs too
let missing: long? = none   # a typed absence: the annotation says
                            # what is absent (docs/ARGS.md D9)
```

Initializers fold at compile time: literals, other constants
(including `module.constant` through imports), arithmetic,
comparisons, `and`/`or`, string concatenation, `long()`/`double()`,
value-struct construction — and `none`, when a `T?` annotation says
what it is absent of; a bare `let x = none` is still refused, because
nothing does.  Calls, objects (`list`, `map`,
`array`, `builder`, object-carrying structs), and verbs are not
constant — constants are values, so ownership never applies to them.
Constants share the file's one namespace with structs and functions,
are reachable as `module.name` through imports, and cannot be
assigned or shadowed.  Every use site inlines the folded value.
Top-level `var` does not exist (whether mutable file scope ever
arrives is a separate decision — docs/V2.md).

## Traps

A trap is a **bug**: deterministic, with a stable code, and it aborts
the program without publishing anything.  What a correct program can
meet anyway is an *error* and is not here (see the section above).
New codes in this round:
`index_bounds`, `key_missing`, `empty_collection`, `use_after_free`,
`null_object`, `not_owned`, `bad_codepoint`.
One of those is **defense-only**: no source program can still reach
`not_owned`, because S23's alias case became a compile error on
2026-08-04.  It remains in the runtime for a module the front end did
not produce, which is a real thing to defend against — the IR
verifier trusts instruction types, and a `.lc` is an executable.
long-standing codes:
integer overflow, divide by zero, conversion range, assertion failed,
string bounds/boundary, call depth.  Call depth is a
*policy* limit, not a native-stack accident: compiled code carries
its remaining depth as a hidden argument and refuses the call that
would exhaust it (docs/CODEGEN.md).  Runaway recursion is a trap with
a message and a call stack, never a segfault.

## Modules

A file is a module, like Zig.  `import name` binds the sibling file
`name.luc` as a namespace: `name.func(...)`, `name.Struct(x = ...)`,
`name.Struct.member(...)`, and `p: name.Struct` annotations reach its
top level.  Scope stays per file — nothing is visible without an
import, and using a namespace you didn't import is a compile error
(`luce.sema.import`).  Modules may import each other; the graph loads
each file once, so cross-file mutual recursion just works.  A module
importing *itself* is a mistake rather than a cycle, and says so
(`luce.import.self`).  The
compiler loads imports through the host (the CLI and loom resolve
them beside the root file), compiles the whole graph as one program,
and writes one .lc module; errors inside an imported file render at
the path it was really opened from, with the source line and a caret.

A sibling import must name the file **exactly**, including its case,
and the file must be an ordinary one.  A case-insensitive filesystem would
happily open `Geo.luc` for `import geo`, so the directory entry is
checked rather than the open: a program that builds on a Mac builds
on the machine that ships it.  Deliberately absent: package managers,
search paths, conditional imports, re-exports.

**The standard library lives under `std.`** — `import std.math`,
`import std.strings`, `import std.files` reach modules embedded in the
compiler itself, so they work everywhere with no install path (see
docs/STD.md).  The import **binds the bare name**, so call sites read
`math.sqrt(x)` and only the import line says where the module came
from; this is Rust's shape (`use std::fs;` then `fs::read`).

The two namespaces are disjoint, and that is the point: `std` is
reserved, no *module name* is, so a `math.luc` beside your program is
exactly what `import math` reaches.  Python's `random.py` problem — a
neighbouring file silently taking the library's name — cannot be
written here, and neither can its opposite, a file that is
unreachable because the library got there first.

Three rules keep the namespace honest:

* `import std.nope` names a module the library does not have, and the
  error lists the ones it does (`luce.import.standard`).
* `import std` names the namespace, which is not a module, so a
  `std.luc` beside the program can never be imported
  (`luce.import.reserved`).
* `import std.math` and `import math` both bind `math`, so a program
  with both has one name for two modules and is refused
  (`luce.import.collision`) — rename the file.  There is no `as`
  clause to alias one of them.

**A source file** is UTF-8 text.  Lines end with LF or CRLF (a file
edited on Windows compiles identically, and reports the same line
numbers), a leading byte-order mark is ignored, and a file may be up
to 64 MiB.  What is *not* text is refused before anything is parsed,
once, naming the file and the line and column inside it: invalid
UTF-8 (`luce.source.utf8`, which prints the byte that broke it), a
NUL byte (`luce.source.binary`), a carriage return that does not end
a line (`luce.source.line_ending`), a UTF-16 or UTF-32 byte-order
mark (`luce.source.encoding` — PowerShell's `>` writes these), an
oversized file (`luce.source.too_large`).

The program itself may also come from standard input: `luce check -`,
or any pipe or process substitution.  Diagnostics then name it
`<stdin>`, and imports resolve beside the current directory.

## Deliberately absent (for now)

First-class functions, closures, **tuples** (a return shape is not a
type — see "Answering more than one thing"), exceptions (traps are
final), implicit *narrowing* of a `double` to a `long`, shadowing,
mutable file-scope `var`
(top-level `let` constants exist; mutable globals are a separate
decision), `errdefer` and error return traces (docs/FAILURE.md
refuses both, with reasons), typed error sets and error payloads
beyond the message, garbage collection and reference counting (scope
ownership is the model — docs/OWNERSHIP.md), operator overloading,
enums/unions, and **positional-only and keyword-only parameter
markers** (Python's `/` and `*`, Dart's `{}` section): one kind of
parameter, and the trailing-defaults rule is what keeps a
must-be-named parameter from arriving by accident (docs/ARGS.md D6).
(string interpolation shipped: see f-strings above; named and default
arguments shipped: see "Calls" above.)
