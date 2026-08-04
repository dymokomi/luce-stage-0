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
  `String` (immutable UTF-8), and user `struct`s.  Values
  copy on assignment and call; nobody frees a value.
- **Heap objects** — `List(T)`, `Map(K, V)`, `Array(T, ...)`, and
  `Builder`.  Variables hold *references*.  Objects are created with
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
  call site: `func stash(hits: give List(Int))` /
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
  holding `none` owns nothing (S43), so a `List(T)?` obeys every rule
  above exactly as a `List(T)` does.

Two dynamic backstops cover what static rules cannot see: `give`
through an alias of a container-owned object traps `not_owned`
(S23), and every verb demands a filled slot (`null_object`
otherwise).  Nothing can leak — loom's leak report is now a runtime
self-check, not a program diagnostic.

## Absence: `T?` and `none`

A trailing `?` makes a type nullable: `Int?` is an `Int` that may not
be there, and `none` is the value that is not.  `?` means nullable and
**only** nullable — failure is `!` and is never spelled with a `?`
(see the next section).

```luce
var user: User? = none
var limit: Int? = 10
let parsed = parse_int(text)      # Int?
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
    value: Int
    next: Node?
```

**Narrowing is the feature.**  After a test, the name *is* its
payload: no unwrapping operator, no second spelling.

```luce
if user != none:
    print(user.name)              # user is User here, not User?
else:
    print("nobody")               # and User? there
```

Five shapes narrow, and they are the ones real code writes:

```luce
if x != none: ...                 # the then arm
if x == none: ...                 # the else arm
if x == none:                     # an early-exit guard narrows
    return                        #   everything below it
print(str(x))                     #   (break and continue too)
if x != none and x > 3: ...       # the rest of the condition
while x != none: ...              # the loop body
x = 3                             # an assignment of a plain value
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
let count = parse_int(arg(0)) else 10
let first = parse_int(a) else parse_int(b) else 0   # right-associative
let must = parse_int(text) else trap("not a number")
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
`String!` hands back a String or an error, and a bare `-> !` hands
back nothing or an error. `!` means *failure* and only failure — it is
never spent on absence, which is `?`'s job (docs/FAILURE.md).

```luce
func read(path: String) -> String!:
    return try file_read(path)

func main() -> !:
    let text = try files.read(arg(0))
    let cfg  = files.read("settings") catch ""
```

**`T!` is not a type.** Fallibility is an attribute of the *function*,
so there is no `T!` to declare a variable of, put in a List, or write
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

```luce
files.write(path, text)            # luce.sema.fallible
try files.write(path, text)        # pass it to my caller
files.write(path, text) catch:     # handle it here
    print("cannot write " + path)
```

`try` propagates: it releases what this frame owns, innermost scope
first, and leaves — the same three lines `return` ends with, with one
terminator changed. It needs a caller that said `!`, or it is
`luce.sema.fallible`.

`catch` handles, and deliberately discards the reason. It has two
forms, for the two shapes recovery takes:

```luce
let text = files.read(path) catch ""        # a fallback value

files.write(path, text) catch:              # a handler block
    print("cannot write " + path)

opening = files.read(path) catch:           # …after a plain assignment
    greeting = "new file"
```

The block form guards exactly one call, which is what separates it
from an exception block: there is never a question about which
statement failed. It attaches to a call written as a statement and to
a plain assignment, and to nothing else — a `let` would need the
handler to supply the value the name binds, and only `catch EXPR` can
say that.

`catch` binds like `else`, between the comparisons and `+`, and
associates right. Both sides must agree on ownership: if the call
hands over a fresh object, the fallback must too.

**`error("…")` raises**, with the program's own words:

```luce
func check(n: Int) -> Int!:
    if n < 0:
        error("negative: " + str(n))
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
  when empty), `sort()` (in place, **stable**; Int/Float/String
  elements),
  `reverse()`, `find(v) -> Int` (-1 when absent), `contains(v)`,
  `clear()`, plus `len`, index, slice.
- rank-1 `Array(T, _)` shares `sort()`, `reverse()`, `find(v)`,
  `contains(v)`, `fill(v)` (value elements only — an array of
  objects stores each slot separately); every Array has `dim(axis)`.
- `Map(K, V)`: `K` is `Int` or `String`.  Index get (traps on a
  missing key), index set (insert or update), `has(k)`, `get(k,
  default) -> V` (the value or the default — no trap), `remove(k)`
  (no-op when absent), `keys() -> List(K)`, `values() -> List(V)`,
  `clear()`, `len`.  Iteration order is insertion order, and the
  lookups (index, `has`, `get`, index-set) are O(1): the entries
  stay a dense array in arrival order with a hash index over it.
- `Builder`: `append(text)`, `append_ascii(code)`, `clear()`, `len`,
  `str(b)`.  `append_ascii` puts one ASCII byte in without the String
  a `chr()` would allocate; it traps `bad_codepoint` outside 0..127,
  because a Builder's bytes become a String and String is valid
  UTF-8.  Wider characters go through `append(chr(code))`.
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
for i, x in xs:             # index and element together (enumerate)
for key, value in m:        # both, no second lookup
```

The two-name form binds a *position* then a *payload*: a sequence's
Int index and its element, or a map's key and its value.  Don't grow,
shrink, or free a collection while iterating it; bounds stay checked
per step, but which elements you visit is your problem.

## Strings

Strings are immutable UTF-8 values.  The *language* provides the
primitives — literals and f-strings, `+` concatenation, comparison,
UTF-8-boundary-checked slices `s[a:b]`, `len(s)` in bytes,
`s.byte_at(i)` for raw byte access, and `s.find_byte(byte, start)`
for raw byte *search* (the offset of the first `byte` at or after
`start`, or -1; the byte must be 0..255 and `start` within the
string, or it traps).  Search is a primitive for the same reason
access is: the library builds substring matching on it, and the
runtime is free to vectorize it.

A literal is written `"..."` and stays on one line; the escapes are
`\n`, `\t`, `\\` and `\"`, and there are no others — `\r`, `\0`, hex
and unicode escapes are all rejected by name (a codepoint goes in
with `chr(...)`).  Everything built on top of the primitives lives in
the standard library's `strings` module (docs/STD.md), written in
ordinary Luce:

```luce
import std.strings

s.find(sub)          # byte offset of first occurrence, -1 if absent
s.find_from(sub, i)  # first occurrence at or after offset i
s.contains(sub)      # Bool
s.starts_with(p)     # Bool
s.ends_with(p)       # Bool
s.count(sub)         # non-overlapping occurrences
s.trim()             # ASCII whitespace off both ends
s.lower()            # ASCII case fold down; multibyte passes whole
s.upper()            # ASCII case fold up
s.replace(old, replacement)  # every occurrence; empty old is a no-op
s.repeat(n)          # n copies (n <= 0 is "")
s.split(sep)         # List(String); empty sep splits on whitespace
s.pad_left(w)        # space-padded to w bytes
s.pad_right(w)
words.join(", ")     # List(String) -> String
strings.format_float(x, 2)   # fixed-point Float display: "2.50"
```

The method spelling is the same sugar as everywhere else:
`s.find(x)` is `strings.find(s, x)` — a plain borrowed call with the
receiver first — whenever `import std.strings` is in scope, and a compile
error pointing at the missing import otherwise.  Only `byte_at` and
`find_byte` are built in.

**Interpolation.**  An `f"..."` string splices expressions in `{...}`,
each converted with `str(...)`:

```luce
f"x = {x}, y = {y}"       # "x = 7, y = 3"
f"sum = {a + b}"          # any str-able expression: Int, Float, Bool,
                          # String, Builder — a List is a type error
f"name is {user.name}"    # methods, calls, fields all work
f"{{literal braces}}"     # double a brace for a literal { or }
```

The hole is one expression; nested `"..."` strings inside a hole are
fine.  `f"..."` desugars to plain `+` concatenation of `str(...)`
pieces, so it is a String like any other.

## Conversions and generic builtins

```luce
str(42)          # "42"        (Int, Float, Bool, Builder, String)
parse_int("42")  # 42          Int?   — none when the text is not a number
parse_float("2.5")               # Float?
chr(955)         # "λ"         codepoint -> String; traps on invalid
ord("λ")         # 955         first codepoint; traps on empty
```

`parse_int` and `parse_float` answer a `T?` rather than trapping:
"not a number" is the same reason every time and the name already
implies it, so absence carries all the information there is
(docs/FAILURE.md).  Read the answer with `else`, or test it:

```luce
let count = parse_int(arg(0)) else 10
let n = parse_int(text)
if n == none:
    print("not a number: " + text)
    return
print(str(n * 2))
```

The free builtins are the generic, cross-type set — Python's own
split of capability: `len str print range assert trap free abs
min max clamp sqrt floor ceil chr ord parse_int parse_float`, the
conversions `Int(x)`/`Float(x)`, and the host-gated file, argument,
terminal, and key builtins (see docs/V2.md).  Everything that belongs
to one type is a method on it.

## The host

Every effect is a host service, every service is optional, and one the
host does not offer traps `host_unavailable` rather than touching
anything.  The whole set, and what each answers:

```luce
print(text)                  # a line to standard output
print_error(text)            # a line to standard error
read_line(prompt)            # String?  — none at end of input
env(name)                    # String?  — none when unset

clock_ms()                   # Int, monotonic, unspecified origin
sleep_ms(milliseconds)       # waits at least that long

arg_count()   arg(index)     # the command line
file_read(path)              # String!
file_write(path, content)    # !
file_append(path, content)   # !
file_delete(path)            # !
file_rename(from, to)        # !
file_exists(path)            # Bool — a question, never a guard
dir_list(path)               # List(String)! — plain names, unsorted

term_rows()   term_cols()   term_clear()   term_move(row, col)
term_style(fg, bg, bold)   term_write(text)   term_flush()
key_read()   key_text()          # key_read is String?
```

Three shapes and one rule behind them (docs/FAILURE.md).  A file
operation is `!` because the world decides and no non-racy check
stands in for the result.  `read_line`, `env` and `key_read` are `?`
because "there is nothing there" is the whole of what they have to
say — end of input, and a variable nobody set, carry no reason worth a
message.  Everything else either cannot fail or is an effect.

`key_read` is `String?` for the same fact `read_line` is, off the same
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

Number literals are decimal: `12` is an Int, and a fraction or an
exponent makes a Float (`1.5`, `1e10`, `1.5e-3`).  A `.` only starts
a fraction when a digit follows it.  There are no hexadecimal,
binary or octal literals and no `_` digit separators — writing one
is a `luce.lex.number` error naming the reason, not a silent
misreading (docs/MISSING.md tier 3, item 11).

Binary operators are `+ - * / %` (Int truncates toward zero, `%`
follows the dividend's sign; Float is IEEE), the comparisons
`== != < <= > >=` (ordering on Int, Float, String), and `and or not`
(short-circuit).  There is no implicit numeric conversion — mixing
Int and Float is a compile error; convert with `Int(x)`/`Float(x)`.

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
both operands are Bool.  Writing it bare is `luce.parse.precedence`;
write `(not a) == b` or `not (a == b)`.

**Chained comparison.**  `a < b < c` is one comparison in Python
(`a < b and b < c`, with `b` evaluated once) and two in C
(`(a < b) < c`, comparing a Bool with an Int).  Luce has neither: the
comparisons are **non-associative**, and chaining them is
`luce.parse.chain`.  Write `a < b and b < c`.  This costs nothing —
`(a < b) < c` was always a type error one stage later, and comparing
two Bools with `(a < b) == (c < d)` is still legal, because the
parentheses start a new chain.

Compound assignment applies an operator in place: `n += 1`, `n -= 1`,
`n *= 2`, `n /= 2`, `n %= 3`, and `s += "!"` (String concat).  It is
value-only arithmetic — the place is a number (or a String for `+=`),
never an object — and the place is evaluated once, so
`grid[row, col] += 1` reads and writes the same slot:

```luce
var total = 0
total += 5          # total == 5
var s = "a"
s += "b"            # s == "ab"
counts[key] += 1    # key evaluated once
```

Assignment targets a **place**: a name, a field, or an index, nested
freely — `p.inner.n = 1`, `cells[0].value += 5`, `grid[r, c].tag =
"x"`.  The place is read once (every subscript evaluated once), then
rebuilt: value structs update functionally up to their root binding,
and the innermost container element is written in place.  A nested
place assigns a **value** (a number, String, or plain struct); to
restock an *object* field use the single-level form
(`bag.items = [1, 2]`).

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

A trap is a **bug**: deterministic, with a stable code, and it aborts
the program without publishing anything.  What a correct program can
meet anyway is an *error* and is not here (see the section above).
New codes in this round:
`index_bounds`, `key_missing`, `empty_collection`, `use_after_free`,
`null_object`, `not_owned`, `bad_codepoint`.
Long-standing codes:
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

First-class functions, closures, user-defined methods/receivers
(`x.f()` is builtin sugar, not dispatch), exceptions (traps are
final), implicit conversions, shadowing, mutable file-scope `var`
(top-level `let` constants exist; mutable globals are a separate
decision), `errdefer` and error return traces (docs/FAILURE.md
refuses both, with reasons), typed error sets and error payloads
beyond the message, garbage collection and reference counting (scope
ownership is the model — docs/OWNERSHIP.md), operator overloading,
and enums/unions.  (String interpolation shipped: see f-strings
above.)
