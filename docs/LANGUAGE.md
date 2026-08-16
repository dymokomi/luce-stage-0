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

> **Memory model.** Values copy. References share identity and are reclaimed
> by ARC after their last strong reference. Files close and unfinished tasks
> join on that same last-release path. ARC does not collect strong cycles;
> `weak` is planned but is not current syntax. `docs/MEMORY.md` is the full
> contract.

## Values and references

Every type is one of two kinds, and the line between them is deliberate
(the full model is `docs/MEMORY.md`):

- **Values** — `bool`, the seven numbers, `string` (immutable UTF-8),
  user `struct`s and `union`s, `enum`s,
  and function values.  A value copies on assignment and call, lives
  inline, and costs nothing at runtime; nobody frees a value.  The
  numbers are two ladders, and four of them do
  arithmetic: `int` (signed 32-bit) and `long` (signed 64-bit) trap on
  overflow and on division by zero; `float` (IEEE binary32) and
  `double` (IEEE binary64) follow IEEE without traps.  `int` and
  `float` are what a literal takes when nothing tells it otherwise.
  The other three — `byte` (unsigned 8-bit), `short` (signed 16-bit)
  and `half` (IEEE binary16) — are **storage**: an operator widens
  them to `int` and `float` before it does anything, so no expression
  ever has one and there is no arithmetic at 8 or 16 bits to define.
  What they are for is `array(byte, _)` at one byte an element, with
  the extent supplied at construction (docs/TYPES.md).
- **References** — the container objects `list(T)`, `map(K, V)`,
  `array(T, ...)` and `builder`, and the resources `file`
  and `task(...)`.  A reference is a shared, reference-counted object:
  created with `new ...` or a literal, named by a variable that holds a
  *reference*. ARC frees it when its last reference
  goes away. Assigning or passing one shares the same object — both
  names see it, and a mutation through either is seen through both.  A
  flat list, map, or rank-1 array declared with file-scope `const` is
  instead materialized once into the program root and stays there until
  that runtime ends.

`file` and `task(...)` are references too, but not containers: there is
no `new file` or `new task`.  The raw `file_open` host builtin is the
primitive file door, which `std.files` wraps as `open`, `create`, and
`append_to`; `spawn` is the task door. ARC closes a file and joins an
unfinished task at the last release.

A `struct` is always a value: it copies field by field. When a field
holds a reference — a `list`, a `file`, a `task` — the copy shares
that reference, exactly as a bare reference does, so both struct values
see one object through that field while their scalar fields stay
independent. User-defined class references and `weak` do not exist as
complete language features yet; `class` is only a front-end scaffold
whose target semantics are in `docs/ROADMAP.md`.

## Type aliases

`alias Name = Type` declares a transparent second spelling for a type. The
alias and target are interchangeable: aliases work in annotations,
signatures, fields, containers, optionals, interface conformances,
constructors, conversions, enum and union member namespaces, static
functions, constants, and imports.

`alias` is file-scoped and public by default; `private alias` follows the
ordinary module rule. Forward references and chains are allowed. Direct or
indirect cycles, unknown targets, double optionals hidden by an alias, private
cross-module access, and collisions with any top-level declaration are
refused during checking, including when the alias is unused.

An alias has no runtime identity. Stage 4 resolves it to its target, and HIR,
MIR, serialized modules, both engines, and ARC never receive an alias tag.
`docs/ALIASES.md` is the complete current contract.

## Memory

Memory syntax is automatic, and the model is one paragraph (the full contract
is in `docs/MEMORY.md`; both engines implement the same semantics):

- **A value copies; a reference is shared and counted.**  Assigning or
  passing a value — a number, `bool`, `string`, `enum`, plain `struct`,
  or function value — makes an independent copy.  Assigning or passing a
  reference — a container, a `file`, or a `task` — shares the
  one object. Reference objects carry a count the compiler maintains.
  Casual code never writes a memory word:

  ```luce
  func main():
      var xs = [1, 2, 3]        # a fresh list; xs references it
      xs.append(4)
      xs = [5, 6]               # the old reference is released
      # ARC destroys each object after its last release
  ```

- **`let y = x` shares a reference or copies a value.** For a
  container or resource, `x` and `y` name one object, and
  a mutation through either is seen through both.  For a value struct,
  `y` is an independent copy.  There is no ownership verb of any kind:
  keeping a reference in a field, a container, or another scope simply
  shares it, and the object lives as long as any reference to it does.
  Containers hold references like anything else: `pop()` hands an
  element out; overwrite, `remove`, or `clear` releases the reference
  that was there, freeing its object if it was the last.

- **A call shares, it does not take.**  A parameter that is a reference
  names the same object the caller holds; mutating it is visible to the
  caller, as everyone expects, and returning a reference simply shares
  it onward.  A value parameter is a copy, so a function cannot reach
  the caller's value through it.

- **ARC does not collect strong cycles.** A recursive struct can already
  point back through a container, so avoid strong back-edges today. Classes
  and closure environments make such graphs routine; the `weak` reference
  that safely breaks them is therefore part of their completion milestone
  (`docs/ROADMAP.md`).

- **Deterministic release is the resource contract.** ARC
  closes a `file` and joins an unfinished `task` at the last release, so no
  separate `close` or `with` language is required.

- **`var name: Type`** (no value) declares now, fills later: the slot
  holds the type's zero value — a null handle for a reference type —
  and using that handle before assignment traps `null_object`.  That
  stable trap name uses the runtime's broad “object” term.  A `T?` says
  "there may be nothing here" out loud instead (next section), so a
  `list(T)?` obeys every rule above exactly as a `list(T)` does.

Every successful differential specification must leave no live objects. A
surviving strong cycle is a leak, not something ARC silently claims to
collect.

## Absence: `T?` and `none`

A trailing `?` makes a type nullable: `long?` is a `long` that may not
be there, and `none` is the value that is not.  `?` means nullable and
**only** nullable — failure is `!` and is never spelled with a `?`
(see the next section).

```luce
struct User:
    name: str

func main(args: list[str]):
    var user: User? = none
    var limit: i64? = 10
    let parsed = parse_int(args[0])   # i64?
```

`T?` may be a local, a parameter, a return type, or a struct field.
It may not be a container element or a map value, and there is no
`T??` — one `?` is all there is.

The one optional that *is* a container element is a **function value**:
`(func(...) -> R)?` is the form a function value takes in any slot
that exists before something fills it, because a function value has no
zero and absence is that zero (docs/BINDING.md).  The parentheses
are the general rule below.

A struct field typed `Struct?` is how a value struct holds one of
itself: the recursion stops at absence rather than at a layout, so a
linked list of value structs needs no new machinery and no reference
counting.

```luce
struct Node:
    value: i64
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
    name: str

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
```

An assignment of a plain value narrows too: after `x = 3` the name is
its payload until something widens it again.

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
func main(args: list[str]):
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

func read(path: str) -> str!:
    return try file_read(path)

func main(args: list[str]) -> !:
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

The shared vocabulary currently carries **eighteen trap codes**.  This
rule moved the host's file boundary out of that set: a read or a write
the world refuses is an error, because asking whether a file is there
before `file_read` is a race no program can close.  Later language features
added their own traps without changing the rule — checked shifts,
allocator refusal, and mutation hidden behind a constant reference
remain bugs rather than recoverable news.

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

func pass_on(path: str, text: str) -> !:
    try files.write(path, text)    # pass it to my caller

func handle(path: str, text: str):
    files.write(path, text) catch:     # handle it here
        print("cannot write " + path)
```

`try` propagates: it releases this frame's references, innermost scope
first, and leaves — the same three lines `return` ends with, with one
terminator changed. It needs a caller that said `!`, or it is
`luce.sema.fallible`.

`catch` handles. It has three spellings, for the shapes recovery
takes:

```luce
import std.files

func handle_both(path: str):
    let text = files.read(path) catch ""        # a fallback value

    files.write(path, text) catch:              # a handler block
        print("cannot write " + path)

    files.write(path, text) catch reason:       # …reading the error
        print(reason)

    var greeting = "old file"
    var opening = ""
    opening = files.read(path) catch:           # …after an assignment
        greeting = "new file"
    print(greeting + opening)
```

The block form guards exactly one call, which is what separates it
from an exception block: there is never a question about which
statement failed. It attaches to a call written as a statement, a
plain assignment, or an existing-name multi-return assignment, and to
nothing else — a `let` would need the handler to supply the value the
name binds, and only `catch EXPR` can say that. On multi-return failure
none of the assignment's replacement stores has happened when the
handler begins. Ordinary side effects from evaluating the call and its
arguments have happened normally.

`catch NAME:` binds the error's **message** — a `string`, immutable,
scoped to the handler block and released with it like any other local.
It is not the code and not the raise position: a `catch` guards one
call, and one call raises with one code, so there is nothing to branch
on; the position belongs to the report an *uncaught* error gets. The
name obeys the no-shadowing rule, and reading it outside the block is
`luce.sema.name`. The expression form takes no binding — a fallback
that reads the reason is a message being built, which is a statement.

`catch` binds like `else`, between the comparisons and `+`, and
associates right. Both sides must agree on type: the fallback yields a
value of the same type the call would have.

**`error("…")` raises**, with the program's own words:

```luce
func check(n: i64) -> i64!:
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

There is no `errdefer` and there never will be: cleanup is automatic
reference counting, which already releases every reference a frame
holds as `try` unwinds it and shares onward whatever `return` hands
back. The one bit `errdefer` encodes the unwinder already has.

`examples/calc/calc.luc` is the worked example, and `docs/FAILURE.md` is
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

A call that answers more than one value has three statement roles: the
right of a destructuring `let`/`var`, the right of an existing-name
assignment, or a statement of its own with every value discarded.
Direct calls, namespace calls and method calls all have the same
surface:

```text
let low, high = minmax(xs)
low, high = Bounds.minmax(xs)
low, high = source.minmax()
rng.next()
```

It is still not an ordinary value. `print(minmax(xs))`,
`minmax(xs) + 1` and `return minmax(xs)` are refused; bind or assign
the values and then use or return the names.

```luce
func minmax(xs: array[f64, _]) -> (f64, f64):
    var low = xs[0]
    var high = xs[0]
    for x in xs:
        low = min(low, x)
        high = max(high, x)
    return low, high

func main():
    var xs = new array[f64](4)
    xs.fill(1.5)
    let low, high = minmax(xs)
    print(str(low) + " " + str(high))
```

**One keyword governs the whole bind**: `let a, b` makes both
immutable, `var a, b` makes both reassignable, and `let a, var b` is
refused.  A bind takes its types from the call, so it carries no
annotations.  There is no `_`: Luce has no unused-binding diagnostic,
so a name costs nothing and tells the next reader what was ignored.

`a, b = f()` is narrower than ordinary assignment. It takes two or
more **distinct, existing, mutable bare names** and one call on the
right. Fields and indexes are not targets, there is no compound form,
and `_` is still only the array-shape wildcard. The number of names
must be the call's arity, and every returned value must fit its target.

The assignment is parallel and two-phase. Every target is checked;
then the right side is evaluated and every returned value is extracted
and prepared for storage; only then are the old values replaced, left
to right. Thus `a, b = swapped(a, b)` is a swap rather than two
sequential assignments, and no target's old reference is released
before every replacement is ready. Ordinary side effects while
evaluating the right side still happen before that commit.

`-> (A, B)!` is legal and composes with `try`:
`a, b = try read_pair()`. A block handler also composes:
`a, b = read_pair() catch:`. If the call fails, neither replacement
store occurs; side effects already performed while evaluating the
right side remain visible to the handler. A successful call replaces
both. `catch VALUE` still supplies one value and cannot supply a return
shape. An element may be a `T?` — absence is an ordinary value — but
`-> (long, long)?` is refused, because there the `?` would be marking
the shape.

Each returned value copies or shares as its kind dictates — a value is
copied out, a reference is shared onward — and each existing `var`
target releases its old reference and adopts its answer only after the
whole shape is ready.  `return xs, xs` is fine: it shares one list
twice, and both results name the same object.  Evaluation stays
left-to-right, so a writer to the left is legal and its effect is
visible when the later operands are staged.  Put the writing operation
first, then return the current values.

## Function values and lambdas

A function may travel as a value.  Its type is the signature with the
parameter names removed:

```text
func(long, long) -> bool
func(string)
func(list(long)) -> long
```

The result is omitted when the function answers nothing.  Parameter
names, defaults, and `!` are all left off — a fallible function is not a
value in this run, because a function type has nowhere to carry the
obligation to write `try` or `catch`.

A function type may annotate a parameter or local, may be a function's
result, and may nest inside another function signature.  File-scope
`const` is a compile-time fold, and neither a function declaration nor
a lambda is a constant expression, so a `const` cannot hold one.

**A slot holds the optional form.**  A struct field, a list element,
an array cell and a union payload field all exist before anything
fills them, and a function value has no zero — every value of the type
names a function, and an empty slot names none.  So the type is
written `(func(...) -> R)?` there, absence is the zero, and reaching
the value takes the narrowing or the `else` any other optional takes.
A late `var` is the same slot and takes the same form.  A **map
value** is the one exception and is written bare: `m.get(k)` already
answers `V?`, so the absence is the missing key.

```luce
struct Button:
    label: str
    on_click: (func(i64) -> i64)?

func main():
    let wired = Button(label = "double", on_click = (n) -> n * 2)
    let action = wired.on_click
    if action != none:
        print(wired.label + " " + str(action(21)))
```

**Parentheses in a type are grouping, and a parenthesized type is that
type.**  They are accepted wherever a type may stand and required
nowhere: `long?` and `(long)?` are one type, and `func(string) ->
long?` still means *a function answering a `long?`* — which is how
`parse_int` is written as a value.  The one thing they make writable
is the optional function, where the `?` would otherwise be consumed by
the result type: `(func(string) -> long)?`.  After `->` in a
declaration the arity decides which production a `(` opened — one type
is a parenthesized type, two or more is a return shape.

```luce
func ascending(a: i64, b: i64) -> bool:
    return a < b

func pick(before: func(i64, i64) -> bool, a: i64, b: i64) -> i64:
    if before(a, b):
        return a
    return b

func chosen() -> func(i64, i64) -> bool:
    return ascending
```

A named top-level or `static` namespace function is a value where a function
type is expected: `ascending`, `Scale.twice`, `math.round`.  The place
supplies the signature, just as a numeric place supplies a literal's
width.  With no such place, `let f = ascending` is refused and the
diagnostic asks for an annotation.

**A reading method bound to a receiver is a value in the same places**
(docs/BINDING.md): `doubling.times` where a `func(long) -> long` is
expected is a function value whose environment is `doubling`, with the
receiver's parameter dropped from the written type.  There is no
marker; the landing place is what makes it a bind, exactly as it is for
a bare function name.

```luce
struct Scale:
    factor: i64

    func times(n: i64) -> i64:
        return n * self.factor

func apply(f: func(i64) -> i64, value: i64) -> i64:
    return f(value)

func main():
    let doubling = Scale(factor = 2)
    print(str(apply(doubling.times, 21)))
```

A **value** receiver is copied into the value at the bind, so the bound
value carries its own state and writing the original afterwards does
not reach it.  A receiver that is a **reference** — a list, a map, an
array, or a struct holding one — is shared: the bound value holds its
own two-slot run whose receiver slot references the same object, so
appending to the receiver's list is visible through the bound value,
and the bound value retains that object until the callable itself dies.
It may outlive the original receiver binding.

Since a function type cannot say which of its values carries a
receiver, two consequences follow: a function value has **no equality**
(`string(f)` is how a program asks what it names), and a function value
does **not cross a worker boundary** in either direction. Callable
environments are excluded from the worker graph-copy contract.

Two things also do not bind, each saying so by name: a **writing**
method (its store-back discipline is its own design) and a **fallible**
method (a function type still carries no `!`).

A **union member constructor** is a function value in the same places:
`Msg.query_changed` where a `func(string) -> Msg` is expected builds
that member, with the payload fields as parameters in declaration
order.  A payload-less member such as `Msg.quit` stays a value.

```luce
union Msg:
    quit
    query_changed(query: str)

func describe(m: Msg) -> str:
    match m:
        quit:
            return "quit"
        query_changed(query):
            return "query " + query

func route(make: func(str) -> Msg, text: str) -> str:
    return describe(make(text))

func main():
    print(route(Msg.query_changed, "abc"))
```

A lambda is a parenthesized list of bare parameter names, `->`, and
one expression:

```luce
func apply(f: func(i64) -> i64, value: i64) -> i64:
    return f(value)

func main():
    print(str(apply((n) -> n * 2, 21)))
    let positive: func(i64) -> bool = (n) -> n > 0
    print(str(positive(3)))
```

Its parameter and result types come from the function type at the
landing place; a lambda with no such place is refused.  The body is
exactly one expression, never an indented block.  It may name its own
parameters, visible functions and file-scope constants.  It may not
name a local from the surrounding function, including a surrounding
function-valued local in call position: **a lambda carries no
environment**.  State that travels with behavior is a struct with a
method — and that struct's reading methods bind, which is how the
sentence became something a program can write.

A call through a function value is positional.  Its type carries no
parameter names or defaults, so `f(value = 1)` is refused even when the
declaration that produced `f` happened to use the name `value`.
Argument types are checked exactly as for a direct call.

**A call is a postfix suffix**, beside the index and the field access:
`EXPR(args)` is written wherever `EXPR[i]` is, and calls the value the
expression in front of it answers — `chooser()(5)`, `actions["run"](3)`,
`(f)(x)`.  The forms whose head names a declaration are unchanged and
resolve through the name that was written, so `f(x)`,
`module.func(x)`, `Struct.helper(x)`, `receiver.method(x)`, `Enum(n)`
and every builtin mean exactly what they meant.  A callee that may
hold none is refused, because narrowing proves a local or a parameter
and never a field or an element; the value is bound to a local and
tested there, and the refusal writes those lines out.

```luce
func twice(n: i64) -> i64:
    return n * 2

func chooser() -> func(i64) -> i64:
    return twice

func main():
    var actions = new map[str, func(i64) -> i64]
    actions["double"] = twice
    print(str(chooser()(21)))
    print(str(actions["double"](21)))
```

Function values copy freely.  There is
neither ordering nor **equality**: a function type cannot say which of
its values carries a receiver, so `f == g` would call two binds of one
method equal whatever they carry, and `==`/`!=` are refused saying so
(docs/BINDING.md).  `string(f)` gives a declared function's
qualified name and a lambda's distinct compiler-generated name, and is
how a program asks what a value names.  Visibility gates the reference
site, and a public signature may not hide a private type inside a
nested function type.

The proving standard-library customer is stable comparator sorting:
after `import std.lists`, `xs.sort_by(before)` takes
`func(T, T) -> bool` for a `list(T)` — a named function, a lambda, or a
comparator bound to the state it sorts by.  It is ordinary std Luce routed
through method syntax, not a new runtime builtin.

## Calls: names at the site, defaults at the declaration

Every parameter has a name, and a call site may use it — never must
(docs/ARGS.md).  Positional arguments come first and fill slots left
to right; **the first named argument ends the positional run**, and
everything after it is named.  Named arguments may be written in any
order.  A parameter may declare a default, `= EXPRESSION` after its
type.  A value default is folded once at the declaration by the same
folder that folds file-scope `const`, then inlined at each call site;
the lowered program is byte-identical to one with that value argument
written out.  A flat container default is different: it is one
program-root construction per runtime, and every omitted call shares a
reference to that same object.  Writing a literal at the call instead
creates an ordinary fresh runtime object.  Defaults are trailing: a
parameter
with one may be followed only by parameters with one.  Struct fields
take the same clause for value defaults, and a struct every one of
whose fields has one constructs bare: `Options()`; object-valued field
defaults remain refused.

```luce
func grown(base: i64, step: i64 = 5, twice: bool = false) -> i64:
    var total = base + step
    if twice:
        total = total * 2
    return total

struct Options:
    depth: i64 = 3
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
nameable argument, and takes no default; a default cannot read another
parameter, because it is folded before any call is made; and an object
default on a reference parameter may be a flat literal or a
file-scope constant container, with every omitted call sharing a
reference to the same per-runtime program root.  An object-valued
struct field default remains refused.  Free builtins take
names and defaults from the table that is their signature —
`term_style(fg, bg = -1, bold = false)` — while **builtin value
methods** (`xs.append`, `m.get`) stay positional: their tables hold
types computed from the receiver, and no names.

Two pieces of guidance the compiler cannot check (docs/ARGS.md §7).
A default belongs on a slot whose omission cannot violate an
invariant — two knobs whose defaults are only jointly sensible are
the one real way this feature goes wrong in code that compiles (Zig's
*Faulty Default Field Values* rule, adopted).  And defaults must not
become the way an argument list grows: shipped Luce's arity histogram
tops out at one declaration of arity 5, and if arity ≥ 5 ever reaches
double figures, the right answer is a struct, not another default.

## Methods

Every plain function declared inside a struct — or inside an enum,
which takes the same functions under the same rules — is a **method**.
Its receiver is the implied binding `self`; the declaration lists only
the arguments written between the caller's parentheses.  A member with
no receiver says `static func` and is a namespace function instead.

```luce
struct Point:
    x: f64
    y: f64

    func length() -> f64:                  # reads implied self
        return sqrt(self.x * self.x + self.y * self.y)

    func scale(factor: f64):               # writes implied self
        self.x = self.x * factor
        self.y = self.y * factor

    static func origin() -> Point:            # no self
        return Point(x = 0.0, y = 0.0)
```

`self` is a keyword whose type is the enclosing struct or enum.  It is
available only inside a method and cannot be written as a parameter.
`p.length()` is resolved statically from `p`'s type; there is no
dynamic dispatch or reference type.  `Point.length(p)` is refused:
methods are called through their receiver, while `Point.origin()` is
the namespace call its `static` declaration promises.

That distinction reaches function values and workers too.  `p.length`
is a value — a **bound** one, carrying `p` (docs/BINDING.md) — while
`Point.length` is not: a method is reached through a receiver, and the
type is not one.  A method cannot be spawned in either spelling.
`Point.origin`, like any top-level or other static function, is a value
where `func() -> Point` is expected and may be a worker target.

**Whether a method writes `self` is inferred, not declared.**  A
store to `self` or one of its value fields makes it a writer, as does
calling another writing method on `self`; that fact is found to a
fixed point, so declaration order and a chain of wrappers do not
matter.  Calling a method on a reference field —
`self.items.append(value)` — mutates that object's contents,
not the struct value, and therefore remains a read of `self`.

A reading method accepts any value of its receiver type: a `let`, a
mutable binding, or a temporary.  A writing method requires an exact,
bare mutable binding such as `p`; a `let`, a call result, a field, an
index, or a narrowed optional is refused.  The callee writes the
caller's slot in place, so it may replace one field or the whole struct
value directly.

In-place also decides failure: writes performed before a method raises
an error remain visible to its caller.  A writer's declared results
are otherwise ordinary results — zero, one, or several — and the
receiver is never hidden in the return shape.  There is no `var self`
and no `var` parameter; passing a value to `f(x)` cannot mutate the
caller's value, while `x.advance()` visibly names the only surface
that can.

## Enums, and the match that checks them

Some numbers are secretly a set: a compression method, a block type, a
key.  `enum` gives every value in the set a name, and `match` makes
the compiler check that the code covered them (docs/ENUMS.md).

```luce
enum Method(u8):        # the width is i32 unless one is written
    stored                # 0, the C rule for an unvalued first member
    shrunk                # 1, the one before it plus one
    deflated = 8          # a constant integer expression, folded

    func compressed() -> bool:
        return self != Method.stored

func main():
    print(f"{Method.deflated} is {i32(Method.deflated)}")
```

Members are **namespaced always** — `Method.stored`, never a bare
`stored` — and each is a compile-time constant, so a member stands in
a file-scope `const`, a parameter default and a field default.  An enum
is a value: it copies, and a `list(Method)`
or an array constructed with `new array(Method, n)` holds it at the
backing width.

**No implicit conversion in either direction.**  `int(m)` (and every
other numeric constructor) answers the member's number, trapping
exactly where the same constructor would on the number itself;
`string(m)` answers the member's **name**, and an f-string hole is a
`string(...)` nobody wrote.  The other direction is fallible, because
the number comes from a file or a wire: `Method(n)` answers `Method?`,
with `none` where no member holds `n`.  That is the only way to make
an enum value out of a number, which is what makes *every* value of an
enum one of its members.

Members compare with `==` and `!=`.  Ordering is refused, naming
`int(…)`: an enum is a set of names, not a number line.

```luce
enum Method:
    stored
    deflated

func read_stored(entry: i64) -> i64:
    return entry

func read_deflated(entry: i64) -> i64:
    return entry * 2

func read(method: Method, entry: i64) -> i64:
    match method:
        stored:
            return read_stored(entry)
        deflated:
            return read_deflated(entry)

func main():
    print(str(read(Method.deflated, 3)))
```

Arms are bare member names — the scrutinee's type is known and the arm
namespace is closed — and each opens a block like every other colon in
the language.  **Without an `else`, every member must have an arm**,
so the day somebody adds a member every match that does not name it
stops compiling.  An `else` stands for the members the arms above did
not name, and one that covers nothing is refused for the same reason
`a else b` is when `a` is never absent.

A member carries no payload: a name with a *value* behind it is a
union, next.

## Unions, and the payloads their members carry

Some values are one of a few shapes, and each shape carries its own
facts: a JSON value is one of six things, and two of the six contain
more JSON.  `union` declares the set, and `match` — the same statement
enums built — extends with payload arms rather than forking
(docs/UNION.md).

```luce
union Shape:
    empty
    circle(radius: f64)
    rect(width: f64, height: f64)

func area(s: Shape) -> f64:
    match s:
        empty:
            return 0.0
        circle(radius):
            return 3.0 * radius * radius
        rect(width, height):
            return width * height

func main():
    print(str(area(Shape.rect(width = 3.0, height = 4.0))))
```

Members are namespaced always, like an enum's, and a payload's fields
are **named, always** — construction is a namespaced call with named
arguments and defaults, through the same checker struct construction
uses, and a bare member like `Shape.empty` takes no parentheses.  At
least one member must carry a payload: a union of bare members *is* an
enum, and is refused by a sentence naming `enum`.

**`match` is the only door.**  An arm names its member bare and, if it
wants the payload, lists the member's fields — each binds a local in
the arm's scope **by the field's own name**, all of them or none
(`circle:` is legal and binds nothing; a partial list is refused
naming the missing fields).  There is no field access on a union value
and no tag test, so reading the wrong member's payload is
unrepresentable rather than checked.  Exhaustiveness, `else`, and the
duplicate-arm rules are `match`'s own, unchanged.

**Memory arrives with no new rule.**  A union is a value, like a
struct: it copies field by field.  When a payload field holds a
reference — a `list`, `file`, or another built-in reference — the copy shares that reference, and an
arm's payload binding names the same object the scrutinee holds, so
reference counting keeps it alive for as long as either does.  A union
whose payloads are all values is a plain value throughout.

The zero of a union is its **first declared member** with every
payload field at its own zero: that is what `var s: Shape` starts at,
what `new array(Shape, n)` fills cells with, and what makes
`list(Json)` constructible.  Recursion travels through reference
containers — `array(items: list(Json))` is finite because a list is
one handle — while a member that unconditionally contains its own
union is refused, with `?` named as the fix;
`Shape?` is the recursion terminator that is not a container, and it
works everywhere `T?` works.

`string(u)` answers the member's **name** — never the payload; that
would be a formatting protocol, which this is not.  `==` on unions is
refused by a sentence naming `match`, and a union may not be a map
*key* (keys are `long`, `string` and enums; a union has no key form —
keep it in the value and key by what identifies it).  A union takes the
methods and static namespace functions a struct takes, under the same
implied-`self` rules:

```luce
union Json:
    null
    number(value: f64)
    array(items: list[Json])

    func weight() -> i64:
        match self:
            null:
                return 0
            number:
                return 1
            array(items):
                return len(items)

    static func of(n: f64) -> Json:
        return Json.number(value = n)

func main():
    print(str(Json.of(2.5).weight()))
```

## Collections

```luce fragment
var xs = [1, 2, 3]                 # list[i32], inferred from elements
var ys: list[str] = []          # empty literal needs an annotation
var m = {"one": 1, "two": 2}       # insertion-ordered dictionary
var empty = new map[str, i64]   # {} is deliberately not a literal
var grid = new array[i64](5, 5)    # fixed 5x5, zero-initialized
var b = new builder              # str builder

xs.append(4)                       # [1, 2, 3, 4]
let first = xs[0]                  # index (bounds-checked)
xs[1] = 20                         # index assignment
let mid = xs[1:3]                  # slice -> a NEW list that mid references
let tail = xs[2:]                  # open ends default to 0 / len
m["one"] = 1                       # insert or update
let n = m["one"]                   # missing key traps; guard with has
if m.has("one"):
    m.remove("one")
grid[2, 3] = 7                     # multi-dimensional index
let rows = grid.dim(0)             # dimension size; len(grid) == dim 0
b.append("hello, ")
b.append("world")
let text = b.build()                  # builder -> str
# completed ARC destroys xs, m, grid, and b after their last releases
```

Type-specific operations are **methods** (Python's split: `len`,
`string`, `print` and friends stay free functions; everything that
belongs to one type is called on it — and like Zig, `xs.append(v)` is
sugar for a plain function with the receiver first, not dispatch):

- `list(T)`: `append(v)`, `insert(i, v)`, `remove(i)`, `pop()` (traps
  when empty), `sort()` (in place, **stable**; long/double/string
  elements),
  `reverse()`, `find(v) -> long` (-1 when absent), `contains(v)`,
  `clear()`, plus `len`, index, slice.  A slice produces a fresh list
  holding the selected elements — value elements by copy, reference
  elements as shared references to the same objects.
- rank-1 `array(T, _)` shares `sort()`, `reverse()`, `find(v)`,
  `contains(v)`, `fill(v)` (value elements only); every
  array has `dim(axis)`.
- `map(K, V)`: `K` is `long`, `string`, or an **enum** — an enum is an
  integer at a chosen width whose whole comparison surface is equality,
  which is exactly what a key needs, and a key that goes in a `Key`
  comes back out of `for` and `keys()` as a `Key` (docs/ENUMS.md).
  Index get (traps on a
  missing key), index set (insert or update), `has(k)`, `get(k) -> V?`
  (the value or absence — no trap, and `m.get(k) else d` is the
  fallback form), `remove(k)`
  (no-op when absent), `keys() -> list(K)`, `values() -> list(V)`,
  `clear()`, `len`.  `values()` returns a fresh list of the map's
  values — value values copied, reference values shared.
  Iteration order is insertion order, and the
  lookups (index, `has`, `get`, index-set) are O(1): the entries
  stay a dense array in arrival order with a hash index over it.
  `{key: value, ...}` constructs a fresh mutable map and evaluates
  entries in written order; a later equal key replaces the earlier
  value without changing its position.  An unannotated integer key
  lands on `long`.  `{}` is refused because neither `K` nor `V` can be
  inferred; write `new map(K, V)`.
- `builder`: `append(text)`, `append_ascii(code)`, `clear()`, `len`,
  `b.build()`.  `append_ascii` puts one ASCII byte in without the string
  a `chr()` would allocate; it traps `bad_codepoint` outside 0..127,
  because a builder's bytes become a string and string is valid
  UTF-8.  Wider characters go through `append(chr(code))`.
- `array(T, ...)`: fixed shape, up to 4 dimensions, sizes are runtime
  values at `new`, elements zero-initialized (numbers 0, bool false,
  string "", structs zeroed field by field, reference elements start
  null — using a null element traps until you store
  something).  In type
  annotations the shape is spelled with `_`:
  `func total(grid: array(long, _, _)) -> long`.
- `==` / `!=` on references compare
  *identity* (the same object), never contents.
- Slices produce a new list: `xs[a:b]` allocates a fresh list holding
  the selected elements — value elements by value, reference elements as
  shared references to the same objects.
  `s[a:b]` on a string stays a value.

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
shrink, or replace a collection while iterating it; bounds stay checked
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
s.count(sub)         # non-overlapping occurrences; empty sub counts
                     # len(s) + 1 byte boundaries
s.trim()             # ASCII whitespace off both ends
s.lower()            # ASCII case fold down; multibyte passes whole
s.upper()            # ASCII case fold up
s.replace(old, replacement)  # every occurrence; empty old is a no-op
s.repeat(n)          # n copies (n <= 0 is "")
s.split(sep)         # list(string); empty sep splits on whitespace
s.characters()       # list(string); the code points, one each
s.width()            # display cells (v0.1: the character count)
s.take(cells)        # the longest prefix that fits in `cells` cells
s.pad_left(cells)    # space-padded to `cells` display cells
s.pad_right(cells)
words.join(", ")     # list(string) -> string
strings.format_float(x, 2)   # fixed-point double display: "2.50"
```

The method spelling is the same sugar as everywhere else:
`s.find(x)` is `strings.find(s, x)` — a plain call with the
receiver first — whenever `import std.strings` is in scope, and a compile
error pointing at the missing import otherwise.  Only `byte_at` and
`find_byte` are built in.

**Interpolation.**  An `f"..."` string splices expressions in `{...}`,
each converted with `string(...)`:

```luce
import std.strings

struct User:
    name: str

func show(x: i64, y: i64, a: i64, b: i64, user: User, mean: f64):
    print(f"x = {x}, y = {y}")       # "x = 7, y = 3"
    print(f"sum = {a + b}")          # any scalar expression: i64, f64,
                                     # bool, str — a list is a type error
    print(f"name is {user.name}")    # methods, calls, fields all work
    print(f"{{literal braces}}")     # f64 a brace for a literal { or }
    print(f"mean = {mean:.2f}")      # a f64 to two decimal places
```

The hole is one expression; nested `"..."` strings inside a hole are
fine.  `f"..."` desugars to plain `+` concatenation of `string(...)`
pieces, so it is a string like any other.

**Format specs.**  A hole may end `:.Nf` — N decimal places of a
`f64`, rounded half away from zero (docs/NUMERICS.md §8).  That is
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

Every numeric type is an explicit conversion constructor: `u8`, `u16`,
`u32`, `u64`, `i8`, `i16`, `i32`, `i64`, `f16`, `f32`, and `f64`.
`char(integer)` checks for a Unicode scalar, `u32(character)` reads its
code point, `str(value)` renders text, and `bytes(value)` copies binary
data from text or a byte container. These names are resolved as type
constructors and are therefore reserved.

A floating-point value converted to an integer truncates toward zero and traps
`conversion_range` on NaN, an infinity, or a value outside the target
range. Integer narrowing checks rather than wrapping. Narrowing a float
rounds to nearest, ties to even, and may reach infinity. `str(x)` prints
any numeric width, a `bool`, `char`, or `str`; it gives an enum or union
member's name and a function value's name. Container objects, resources,
and structs are not accepted: a `builder` hands over its text with
`b.build()`.
A float prints as the shortest text that round-trips at its own
width; the infinities print `inf` and `-inf`, and **every NaN prints
`nan`** — IEEE gives a NaN's sign bit no meaning and hardware
disagrees about which sign an invalid operation produces, so the sign
is unobservable: comparisons already answer `false`, `parse_float`
refuses NaN, `i64(NaN)` traps, and the formatter declines to show it.
An f-string hole is a `str(...)` the reader did not write, so the
same rule decides what may stand in one.

```luce fragment
str(42)          # "42"        (numbers, bool, str, enum, function)
parse_int("42")  # 42          i64?   — none when the text is not a number
parse_float("2.5")               # f64?
str(char(955))    # "λ"         checked codepoint -> char -> str
u32('λ')          # 955         char -> codepoint
parse_str(bytes("λ"))             # "λ" as str?
```

`parse_int` and `parse_float` answer a `T?` rather than trapping:
"not a number" is the same reason every time and the name already
implies it, so absence carries all the information there is
(docs/FAILURE.md).  Read the answer with `else`, or test it:

```luce
func main(args: list[str]):
    let count = parse_int(args[0]) else 10
    let text = args[1]
    let n = parse_int(text)
    if n == none:
        print("not a number: " + text)
        return
    print(str(n * 2) + str(count))
```

The free builtins are the generic, cross-type set — Python's own
split of capability: `len print range assert trap error abs
min max clamp sqrt floor ceil trunc chr ord parse_int parse_float`,
`parse_string`, the eight conversion constructors (docs/NUMERICS.md
§7), and the host-gated file, terminal, and key builtins (see
docs/V2.md).  Everything that belongs to one type is a method on it.

## The host

**The command line is not one of them.**  A program that reads its
arguments declares them:

```luce
func main(args: list[str]):     # and `-> !` composes with it
    for name in args:
        print(name)
```

`args` is an ordinary `list(string)`, so `len`, indexing, slicing,
`for … in`, `contains` and `strings.join` all work on it, and
`args[0]` is the first word after the program's own name.  It is
*handed to* the program rather than called *by* it, which is why the
host gate does not cover it and why a host with no arguments to offer
supplies an **empty** list instead of a trap; reading past the end is
the language's own `index_bounds`.  A program that
ignores its arguments writes `func main():` and says nothing false.

Every other effect is a host service, every service is optional, and
one the host does not offer traps `host_unavailable` rather than
touching anything.  The whole set, and what each answers:

```text
print(text)                  a line to standard output
print_error(text)            a line to standard error
read_line(prompt)            # string?  — none at end of input
env(name)                    # string?  — none when unset

shell_run(command)           # string! — host shell transcript and exit status

clock_ms()                   # long, monotonic, unspecified origin
epoch_ms()                   # long, milliseconds since the Unix epoch
sleep_ms(milliseconds)       # waits at least that long

file_read(path)              # string!
file_write(path, content)    # !
file_append(path, content)   # !
file_delete(path)            # !
file_rename(from, to)        # !
path_kind(path)              # long! — 0 nothing, 1 file, 2 directory,
                             #   3 other; links followed.  `!` is the
                             #   world refusing to say, which is not
                             #   the same fact as "nothing is there"
dir_list(path)               # list(string)! — plain names, unsorted
dir_create(path)             # ! — the parents too; already there is ok
file_open(path, mode)         # file! — 0 read, 1 write, 2 append

term_rows()   term_cols()   term_clear()   term_move(row, col)
term_style(fg, bg, bold)   term_write(text)   term_flush()
key_read()   key_text()          # key_read is string?
term_event_data(field)       # long — row/col/button/modifiers/wheel of
                             #   the event key_read just answered; 0 for keys

exit(status)                 # never returns; the run ends `exited`

os_total_memory()            # long — bytes the machine has
os_available_memory()        # long — bytes it could still hand out
os_cpu_count()               # long — logical processors
```

**Two clocks, told apart by their names.**  `clock_ms` counts from an
origin nobody specifies, so only differences mean anything and it is
what a span is measured with; `epoch_ms` counts from
1970-01-01T00:00:00Z, so its reading *is* the answer and it is what a
timestamp is made of.  An operator can set the wall clock backwards, so
a duration measured with `epoch_ms` can come out negative — which is why
the two are two builtins and not one.  Turning `epoch_ms` into a date is
a library nobody has written; this is the number that library will be
built on.  A host with no calendar refuses `epoch_ms` with
`host_unavailable` rather than inventing a number, which is why it takes
the machine facts' fallible shape and not `clock_ms`'s bare one.

**`dir_create` means "there is a directory at this path when I
return."**  That one sentence decides its two rules together: it makes
every directory leading to the one asked for, and a directory already
there is success rather than a failure.  The alternative puts the same
splitting loop in every program and an existence check in front of
every call — and that check is a race, which is exactly what such a
question is documented never to be a guard for.  A *file* holding the name is still
`io_failed`: the caller asked for a directory and there is not one.

**`path_kind` is the one question the boundary was missing.**  Three
things can happen at a path — something is there, nothing is there,
and the world will not say — and a bool has two answers, which is why
`file_exists` retired: it gave `false` to a file that certainly exists
under a directory nobody may open, the same bit it gave a name nothing
holds.  Here the number carries what is there and zero carries
absence, while a refusal travels in the error channel.  A number and
not an enum, for the reason the byte channel's mode is a number: a
builtin speaks what the host slot speaks, and `std.files` is where it
gets a name (`files.kind`, `files.exists`, `files.is_file`,
`files.is_dir`, `files.entries`).

`file_open` is the primitive under `std.files.open`, `create`, and
`append_to`; ordinary code uses those named doors rather than the mode
numbers.  It answers a `file`, a reference.  A file has three fallible
methods: `f.read(buffer) -> long!`, `f.write(buffer, count) -> long!`,
and `f.flush() -> !`, where the buffer is an `array(byte, _)`. There is no
source `close`: ARC closes a `file` at its last release, which is also why
there is no `with`.
`parse_string(bytes) -> string?` is the pure
boundary in the other direction — bytes that are not UTF-8 are absent,
not an I/O error.

Three shapes and one rule behind them (docs/FAILURE.md).  A file
operation is `!` because the world decides and no non-racy check
stands in for the result.  `read_line`, `env` and `key_read` are `?`
because "there is nothing there" is the whole of what they have to
say — end of input, and a variable nobody set, carry no reason worth a
message.  Everything else either cannot fail or is an effect.

The three `os_*` facts are none of the three shapes, and deliberately:
a fact the host knows is a plain number, and a fact it does not know
is a **refusal** — `host_unavailable`, the same trap a withheld
service gives.  There is no `?` because "this host cannot tell you how
much memory the machine has" is not the ordinary case a program plans
around, and no `!` because nothing failed; what happened is that the
program asked the wrong host.  The one thing the boundary will not do
is invent a number, which is why the service answers whether it could
tell rather than answering zero.

**`exit(status)` is the fourth way a run ends**, beside finishing,
trapping, and an uncaught error: the program chose to stop, and chose
the number.  Not a trap — nothing is wrong — and not an error —
nothing failed.  It never returns: a statement after it in the same
block is `luce.sema.unreachable`, the run unwinds the way a trap's
unwind does (no releases run, and the leak census reports what was
standing, on both engines), and the host carries the status — on
POSIX, the low eight bits of the process's exit code.  The status
crosses at the call site through the host's `exited` slot, so a host
that cannot carry one refuses the call (`host_unavailable`) rather
than losing the number.

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
open a terminal or ask for a host service — and the operating system is the
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

**The bit set** (docs/BITWISE.md, ratified): `&`, `|`, `^`, `~`,
`<<`, `>>` on `int` and `long` only — a float has no bits a program
may see, and `byte`/`short` widen to `int` first exactly as
arithmetic widens them.  Two's complement throughout: `~x` is
`-x - 1`, and `>>` is an arithmetic shift because the operands are
signed.  Precedence is Go's, not C's — `&` and the shifts bind at the
multiply level, `|` and `^` at the add level — so `flags & mask != 0`
means what it reads as.  Shifts move bits rather than multiply: `<<`
discards high bits without trapping, and the one thing that traps is
a count below zero or at the operand's width (`shift_out_of_range` —
C leaves that undefined and Go silently masks).  The five compound
forms `&=`, `|=`, `^=`, `<<=`, `>>=` exist, constants fold with
identical semantics (a bad constant count is a compile error), and
the literals came in the same run: `0xFF`, `0b1010`, and `_`
separators between digits — no octal.

**A literal has no type until it lands on one** (docs/TYPES.md §1).
It is read from its text at the width of the place it reaches — an
annotation, an argument, a return, a struct field, a container
element, a subscript, a conversion constructor — so no decimal ever
travels through binary64 on its way to a binary32, and `double(0.1)`
is binary64's 0.1 rather than binary32's widened.  With no place to
land on, `12` is an `int` and `1.5` is a `float`; a literal past the
width it landed on is refused at compile time by a message naming the
width that would hold it.

Number literals are decimal, hexadecimal (`0xFF`) or binary
(`0b1010`), with `_` digit separators between digits (`1_000_000`,
`0xFF_FF`); a fraction or an exponent makes a float (`1.5`, `1e10`,
`1.5e-3`), and a `.` only starts a fraction when a digit follows it
(docs/BITWISE.md R3, D7–D8).  There are no octal literals and no hex
floats — writing one is a `luce.lex.number` error naming the reason,
not a silent misreading.

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
a torus.  `//` and `%` by zero trap; on floating-point values they are IEEE and do
not, and double `%` floors with the integer one so promotion crosses
the line without a seam in it.  Because floating-point values use binary64 and the
floor-mod result is rounded, a boundary case can equal the divisor
(`-1e-100 % 1.0 == 1.0`); do not assume strict `< divisor` for floats.

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
is still a `list(int)`; `let xs: list(double) = [1, 2, 3]` is a
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

Loosest to tightest: `or`, `and`, the comparisons, `else` and `catch`,
`+ - | ^`, `* / // % & << >>`, then the prefix operators `not` `-` `~`
`try`, then postfix `.field` `[index]` `(call)`.  The bit
set sits at Go's precedence, which is why `|` and `^` are additive and
`&` and the shifts are multiplicative (docs/BITWISE.md R1).
Same-precedence binary operators associate to the left — except `else`
and `catch`, which associate to the right so `a else b else c` is a
real chain — and the prefix operators to the right.

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
var counts = new map[str, i64]
counts["k"] += 1    # the key is evaluated once, and defined at 0
```

A **storage-width place combines at its arithmetic type and narrows
back** (docs/TYPES.md): no operator computes at 8 or 16 bits, so
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
var counts = new map[str, i64]
counts["fig"] += 1      # defined at 0, then incremented: 1
var notes = new map[str, str]
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

Use `get(key)` for a read that answers `V?` — absence instead of a
trap, and it never defines; `m.get(k) else d` spells the explicit
fallback with the ordinary absence machinery.

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

One scope per **file** (file-scope constants, structs, and functions),
per **struct** (its implied-self methods and static namespace functions), and per
**function** (parameters and every indented block; `if`/`while`/`for`
bodies open nested scopes).  No shadowing anywhere; `let` is
immutable; `var` is mutable; loop variables are immutable inside the
body.

**`let` freezes the name, not the object it reached.**  `xs.append(v)`,
`xs.sort()`, `xs[0] = v`, `bag.counts[0] = v` and `cells[0].value += 1`
all go through an immutable name, because none of them writes the
name: the store lands in the referenced object, which is shared and
mutable whoever holds it.  That is what lets every function that takes a
container fill it — a parameter is a `let`-bound name.  What `let`
refuses is a store that lands in the binding's own storage: `p = q`,
`p.x = 3`, `p.inner.y = 3`, and a writing `p.advance()` on a struct
**value**, because a value lives in the name.  A reading method and a
method that mutates only an object reached through `self` still work
through a `let` for the same reason the direct object calls above do.

Structs contain implied-self methods and `static` namespace functions
(docs/SELF.md); there is no inheritance and no dispatch.

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
func floor_at_zero(n: i64) -> i64:
    if n < 0:
        return 0
    return n                  # reachable: the guard has no else
```

### File-scope constants

`const` is the file-scope declaration word.  Local `let` and `var`
keep their existing jobs, top-level `let` is retired with a diagnostic
that teaches `const`, and there is no top-level `var`.

```luce
struct Theme:
    keyword: i64
    comment: i64

const width = 80
const tau = 2.0 * pi          # constants may reference each other,
const pi = 3.14159            # in any order — never in a cycle
const version = "2"
const banner = "loom " + version
const theme = Theme(keyword = 176, comment = 244)  # value structs too
const missing: i64? = none   # a typed absence: the annotation says
                              # what is absent (docs/ARGS.md)
```

Initializers fold at compile time.  Foldable forms include literals,
other constants (including `module.constant` through imports), numeric
and bitwise expressions, comparisons and boolean logic, string
concatenation, the eight conversion constructors and `ord()`, enum
members and conversions from enums (`int(m)`, `string(m)`), and
reference-free value-struct construction.
`none` also folds when a `T?` annotation says what it is absent of; a
bare `const x = none` is still refused, because nothing says which `T`
is absent.  Function values and general calls are not constant.

A `const` may also construct one **flat constant container**:

```luce
struct Entry:
    name: str
    fallback: i64?

const NUMBERS: list[i64] = [3, 1, 2]
const AGES = {"ada": 36, "alan": 41}
const ORDER: array[i64, _] = [16, 17, 18, 0]
const ENTRIES = [Entry(name = "first", fallback = none)]
const ALIAS = NUMBERS
```

The element may be a scalar, string, enum, or reference-free value struct;
such a struct may contain an optional field.  A container may not hold
another container, and a top-level optional element or map value is
refused.  A bracket literal is a `list` unless an `array(T, _)`
annotation makes it a rank-1 array.  An empty list or array therefore
needs an annotation, but the annotation supplies only the missing type:
its element type must still be flat and non-optional even when `[]` has
no elements.  A map uses `{key: value}`; duplicate folded keys are a
compile error naming both sites, and `{}` is refused in favour of `new
map(K, V)`.  `builder`, reference-holding structs, and multi-dimensional
arrays cannot be constant containers.

Each written construction has one identity.  Repeated uses, aliases,
imports, lambdas, and a reference-typed parameter default all read that
same program-root object; a separately written equal declaration is a
different object.  The reachable pool is materialized eagerly once per
runtime before a function executes, so every worker gets its own roots
and no object crosses between runtimes.  An unused row is pruned and
costs nothing to ship or start.

The program root holds these objects until runtime teardown.
Reads and iteration work normally.  Slicing a constant list returns a
fresh list, as map `keys()` and `values()` return fresh
lists; arrays have indexing and iteration, but no slice
expression.  Stage 4 refuses every visible mutation (`append`,
`sort_by`, indexed and nested stores, `file.read` into an array).
Sharing a reference to the constant — reading it, passing it, returning
it — is fine; only writing through it is refused.  A reference reached
through a parameter hides the root from static analysis, so every
runtime mutation path also checks and traps `immutable_object` before
writing.  A forbidden write is never silently dropped.

Constants share the file's namespace with structs and functions, are
reachable as `module.name` through imports, and cannot be assigned or
shadowed.  A public constant container cannot expose a private element
type, just as a public function signature cannot expose one.  Folded
values inline at each use; container constructions load their one
program-root handle.

## Workers: `spawn` and `task`

`spawn f(args)` runs `f` on a **worker** — a thread with a runtime of
its own: its own heap, its own scopes, its own fresh call-depth budget
— and answers a `task` the spawning scope holds (docs/THREADS.md).
Nothing a worker touches is reachable from another runtime. Permitted graphs
are rebuilt at the boundary rather than shared, so races over Luce objects are
not detected; they are unrepresentable.

```luce
func crunch(base: f64, count: i64) -> f64:
    var total: f64 = 0.0
    for i in range(0, count):
        let value = base + f64(i)
        total += value * value
    return total

func main(args: list[str]):
    var tasks = new list[task[f64]]
    for part in range(0, 4):
        tasks.append(spawn crunch(f64(part), 3))
    var total: f64 = 0.0
    for t in tasks:
        total += t.wait()
    print(str(total))
```

Three sentences are the whole of it, and each is a rule the language
already had.

**Data crosses; object identity does not.** A value — a number, a `string`, an
enum, or a value field — copies directly. A permitted container graph is
copied recursively into the receiving runtime, so a list argument and the
caller's list are independent after `spawn`. Aliases within the graph and
between arguments remain aliases inside the worker snapshot. A `file`, `task`, or function
value is refused transitively because a host resource or callable environment
cannot be rebuilt as ordinary data. The same boundary copier brings a
worker's permitted result graph back through `wait()`.

**A task is a reference resource**, made by `spawn` and by nothing else—there
is no `new task`. Its last release joins an unfinished worker and discards an
unobserved result. `return t` hands the task reference to the caller.

**`t.wait()` moves the answer here, once.**  The type is written as the
return shape it names — `task`, `task(!)`, `task(double)`,
`task(double!)` — so a worker whose function is `-> T!` gives a task
whose wait is a site that says `try` or `catch`, and the error crosses
whole: code, message, and the place it was raised.  A **trap** is not
data and never was: one in a worker surfaces at the join with the
worker's own frames in front of the joiner's, and stops the program.  A
task nobody waits on is joined all the same and its answer discarded —
only a wait observes.

**Effects from workers are specified to be serialized.**  The shared
recursive guard covers lowered effects and every file callback, including
each read, write and flush made by a whole-file helper, so a `print` from
a worker is line-atomic and host file state is never entered concurrently.
Worker registries use a separate mutex because spawn and join are lifetime
machinery rather than effects: publication is locked, a join detaches its
row under that lock and waits only after releasing it, and teardown refuses
new publications before draining the same way.  A program that never
spawns still pays nothing for either mechanism: its compiled module
contains no effect lock, no install, and no worker entry at all.

Absent from the surface, permanently: locks, atomics, shared mutable
state between workers, condition variables, thread identifiers,
priorities, and `async`/`await` colouring.  Their jobs are done by the
value/reference split, or they do not exist here.  Workers are OS
threads — thousands, not millions — and typed channels are the approved
next design-and-build run; their complete endpoint, capacity, receive,
close and failure surface is not ratified yet.

## Traps

A trap is a **bug**: deterministic, with a stable code, and it aborts
the program without publishing anything.  What a correct program can
meet anyway is an *error* and is not here (see the section above).
The eighteen current codes are `integer_overflow`, `divide_by_zero`,
`conversion_range`, `assertion_failed`, `explicit_trap`,
`missing_return`, `call_depth_exceeded`, `string_bounds`,
`string_boundary`, `host_unavailable`, `index_bounds`, `key_missing`,
`empty_collection`, `null_object`, `bad_codepoint`,
`shift_out_of_range`, `allocation_failed`, and `immutable_object`.

One is a compiler defense rather than a path correct source can reach.
`missing_return` seals a typed MIR block after stage 4 has already
refused a source function that can fall off its end.  The IR verifier
trusts instruction types and a `.lc` is an executable, so the backstop
remains real.  Call depth is a
*policy* limit, not a native-stack accident: compiled code carries
its remaining depth as a hidden argument and refuses the call that
would exhaust it (docs/CODEGEN.md).  Runaway recursion is a trap with
a message and a call stack, never a segfault.

## Modules

A file is a module, like Zig.  `import name` binds the sibling file
`name.luc` as a namespace: `name.func(...)`, `name.Struct(x = ...)`,
`name.Struct.member(...)`, and `p: name.Struct` annotations reach its
top level — all of it, unless a declaration is marked `private`.
Scope stays per file — nothing is visible without an
import, and using a namespace you didn't import is a compile error
(`luce.sema.import`).

**Visibility** (docs/VISIBILITY.md, ratified): a declaration is
public unless it says `private` — written in full, before `func`,
before a file-scope `alias` or `const`, before `struct`, and on a struct field;
`public` is legal anywhere `private` is and inert where it restates
the default.  Inside a struct — and only there — `private:` and
`public:` open an indented region of members.  The unit is the file,
never the struct: within its own module a private declaration is
reachable from anywhere, including from public declarations —
visibility gates the reference site's module, not the call graph.
Touching a marked name from outside is `luce.sema.private`, answered
as *private*, never as *unknown*.  Construction composes with named
fields: an outside site may name unmarked fields only, and every
private field needs a default or the struct is only constructible
through the module's own public functions — the factory pattern,
named in the diagnostic.  A public surface may name only public
types, refused at the declaration; `main` never needs marking and
cannot be `private`, because the runtime is the one caller no marker
can gate.  A name, one more rule beside this: **a name starts with a
letter** — a leading underscore is `luce.lex.name`, because with a
real `private` keyword a sigil has nothing left to encode.  Modules may import each other; the graph loads
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
on the machine that ships it.  Deliberately absent: conditional
imports and re-exports.

**Projects** (docs/PACKAGES.md–D2, built): a `luce.yaml` above the
root source file marks the project root, and under one, dots map to
folders — `import geo.shapes` reads `geo/shapes.luc` under the root,
binds `shapes`, and resolves the same from every file in the tree,
single-segment imports included (one anchor per mode).  The exact-case
and regular-file obligations hold at every segment.  **`import ... as
name`** picks the binding — the remedy `luce.import.collision` names
when two imports' last segments collide — read contextually, so `as`
is not a keyword; the alias moves only the binding, one module holds
one binding per program, and a standard module keeps its own name
(`import std.math as m` is refused).  Rootless programs keep exactly
the sibling behaviour, single segment only, with the dotted form
refused naming `luce.yaml` as what enables it.

**Packages** (docs/PACKAGES.md–D4, built through the store half):
`luce.yaml`'s `packages:` want list names each package at one exact
version, vendored by hand as `.luce/packages/NAME-VERSION/` — a
directory with a `luce.yaml` of its own that must agree with its name
and version or be refused.  `import geo` reads the entry module
`geo.luc` at the package root and `import geo.sub` reaches inside;
a package's own imports anchor to the package — its files, then its
own want list — never the consumer's tree, so two packages' same-named
internals never meet (their serialized names carry the package root).
Resolution probes the project tree, the store, and every `LUCE_LIB`
shelf, and exactly one may answer (`luce.import.ambiguous` otherwise);
the want list gates every store probe, a `path:` annotation replaces
the store probe for development, `sha256:` is verified when present,
and the transitive set resolves at exact versions with diamonds
refused (`luce.import.diamond`) unless the root's `override:` states
the decision.  Shelf and `path:` resolutions print one line to
standard error, every build.  Fetching, a registry, and publishing do
not exist yet.

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

Capturing closures, **tuples** (a return shape is not a type — see "Answering
more than one thing"), exceptions (traps are
final), implicit *narrowing* of a `double` to a `long`, shadowing,
mutable file-scope `var`
(file-scope `const` exists; mutable globals are a separate
decision), `errdefer` and error return traces (docs/FAILURE.md
refuses both, with reasons), typed error sets and error payloads
beyond the message, a tracing garbage collector (memory is automatic
via ARC — docs/MEMORY.md), operator overloading,
and **positional-only and keyword-only parameter
markers** (Python's `/` and `*`, Dart's `{}` section): one kind of
parameter, and the trailing-defaults rule is what keeps a
must-be-named parameter from arriving by accident (docs/ARGS.md).
(string interpolation shipped: see f-strings above; named and default
arguments shipped: see "Calls" above; tagged unions shipped: see
"Unions" above.)
