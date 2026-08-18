# Named and default arguments

Every parameter in Luce has a name, and every call site may use it. A
parameter may also declare a default — a value the caller can leave
unwritten. The same clause gives struct fields defaults. This page
describes how names and defaults work at a call site, in a declaration,
and in construction.

Names and defaults are entirely a front-end convenience: stage 4
resolves each argument to the slot it fills and fills every omitted
default from a folded constant, and the MIR `call` instruction that
reaches the back end is positional and fully applied. Nothing about the
serialized module format or the host ABI depends on them.

The memory model is `docs/MEMORY.md`; how a function answers more than
one value is `docs/RETURNS.md`; how a method's implicit `self` is
spelled is `docs/SELF.md`.

## Names at the call site

Positional arguments come first and fill parameters left to right from
zero. A named argument is written `name = value`. **The first named
argument ends the positional run**: every argument after it must also be
named, and a positional argument following a named one is refused.

```luce
func find(s: str, needle: str, start: i64 = 0) -> i64:
    return start

func main():
    let a = find("abc", "b")               # all positional
    let b = find("abc", "b", start = 1)     # trailing name
    let c = find(needle = "b", s = "abc")   # named, reordered
    print(str(a + b + c))
```

Names may be written in **any order** — `find(needle = "b", s = "abc")`
binds each value to the slot it names. Assignment in Luce is a
statement, never an expression, so `f(x = 1)` is unambiguously a named
argument and never "pass the value of assigning 1 to x"; comparison is
the distinct token `==`, so `f(a = 1 == 2)` is one named argument whose
value is a comparison.

A name is always optional. Because Luce has no overloading, one name is
one function, so a label could disambiguate nothing and is never
required — not even on `min(a, b)`.

### Evaluation order

Arguments are evaluated in the order they are **written**, and bound to
the slots they **name**. When a call reorders, evaluation order and
parameter order differ:

```luce
func log(first: i64, second: i64):
    print(str(first))
    print(str(second))

func one() -> i64:
    print("one")
    return 1

func two() -> i64:
    print("two")
    return 2

func main():
    log(second = one(), first = two())   # prints one, two, then 2, 1
```

## Defaults in the signature

A parameter may declare a default after its type: `start: i64 = 0`. A
default is a **folded compile-time constant** — the same folder that
folds a file-scope `const` (`docs/CONSTANTS.md`) evaluates it once, at
the declaration, at the parameter's own type. At each call site that
omits the argument, the compiler materializes the same constant it would
have produced had the value been written there, so the lowered program
is identical to the fully-written call.

**Defaults are trailing.** A parameter with a default may be followed
only by parameters with defaults; otherwise the required parameter after
it could be reached only by name, which the language does not require.

```text
func f(a: i64 = 0, b: i64):   # refused:
# a has a default, so b needs one too — the parameters with defaults come last
```

An **optional** parameter (`T?`) may default to `none` or to a value of
`T`, which widens into the optional:

```luce
func lookup(key: str, fallback: i64? = none) -> i64?:
    return fallback

func step(count: i64? = 1) -> i64?:
    return count

func main():
    let a = lookup("x")
    let b = step()
    print("ok")
```

### What a default may be

A default may be anything the constant folder folds at the parameter's
type: integer and float literals at the declared width, `true`/`false`,
string literals, `none` where a landing type is present, other
file-scope constants and fields of constant structs, arithmetic and
comparison over those, string concatenation, the numeric conversions
(`i64(x)`, `f64(x)`, …), and value-struct construction. A file-scope
`const` container may be named as a default — it is one program-root
reference shared at every call site.

A default may **not** be a freshly built object, a call, or another
parameter:

```text
func f(xs: list[i64] = list[i64]()):   # refused:
# a default must fold at compile time; new, slicing, and indexing belong in a function

func g(a: i64, b: i64 = a):              # refused:
# a default cannot use a: it is folded before any call is made
```

A bracket or brace literal of constants, on the other hand, *is* a
constant container and is accepted as a default, exactly as it is at
file scope.

## Struct fields take the same clause

A struct field may carry a default, written on the same clause, folded
by the same folder, and trailing by the same rule. A field with a
default that a construction omits is filled from it; the remaining
required fields must still be written.

```luce
struct State:
    path: str
    content: str
    cursor: i64 = 0
    scroll: i64 = 0
    dirty: bool = false
    message: str = ""

func main():
    var state = State(path = "notes", content = "hello")
    print(state.path)
```

Two boundaries follow:

- A struct **all** of whose fields have defaults may be written `S()`.
- Construction stays **named-only**: `Point(1, 2)` is refused — a struct
  is built with named fields — and it does not gain positional
  arguments. Field order in a construction is free, as at any call.

A default belongs on a field whose omission cannot violate an invariant.
Two fields whose defaults make sense only together are the one way this
goes wrong in code that compiles; the language cannot check it, so it is
a rule a reviewer applies.

## `self`, methods, and namespace functions

`self` is the implicit receiver of a method, not a parameter a caller
supplies, so it is never named and never defaulted. A method is called
with the receiver in front and its written parameters after it, which
may be named or defaulted like any others:

```luce
struct Point:
    x: f64
    y: f64
    func scaled(factor: f64 = 2.0) -> f64:
        return self.x * factor
    static func origin() -> Point:
        return Point(x = 0.0, y = 0.0)

func main():
    let p = Point(x = 1.0, y = 2.0)
    let a = p.scaled()               # default factor
    let b = p.scaled(factor = 3.0)   # named
    let o = Point.origin()
    print(str(a + b + o.x))
```

Calling a method through its type — `Point.scaled(p, …)` — is refused:
`scaled is a method with implicit self; call it as p.scaled(…)`. A
`static func` has no receiver and is called as `Point.origin(…)`,
following the ordinary named and default rules.

## The four argument paths

Stage 4 checks arguments in four places, which differ in what each knows
about a slot:

| path | names | defaults |
|---|---|---|
| **user functions** — plain `f()`, `module.f()`, `Type.f()`, and method `x.f()` | yes | yes |
| **struct construction** — `Point(x = 1, y = 2)` | required | yes |
| **free builtins** — `clamp`, `len`, `parse_i64`, … | yes | yes, where the table declares one; none do today |
| **builtin value methods** — `xs.append`, `m.get`, `s.byte_at` | no | no |

A builtin is a declaration the compiler keeps in a table rather than in
Luce, and that table carries a name for every parameter. So a free
builtin's arguments may be named. Host APIs are ordinary declarations in
`std`, so their defaults use the user-function path rather than expanding
the builtin surface:

```luce
import std.term

func fg() -> i64:
    return 3

func main():
    let a = clamp(value = 5, low = 0, high = 10)
    let n = len(value = "abc")
    term.style(fg())               # background and bold defaulted
    term.style(fg(), bold = true)  # background defaulted
    print(str(a + n))
```

**Builtin value methods take neither.** Their parameter types are
computed from the receiver's element type (`list[T]`'s `append` takes
`T`) and their tables hold no names, so `xs.append(value = 1)` is
refused. A method that routes to a std module — `"abc".find("b")` is
`strings.find` — is likewise positional in receiver form: to name its
arguments, write `strings.find(…)` directly.

## Refusals

Every argument mistake is reported with a stable `luce.sema.*` code.
Count mistakes point at the call; type and name mistakes point at the
argument; and every missing required slot is named at once rather than
one per compile.

| written | code | sentence |
|---|---|---|
| `f(widt = 1)` where `f` has `width` | `luce.sema.call` | `f has no parameter widt; did you mean width?` |
| `f(width = 1, width = 2)` | `luce.sema.call` | `width was given twice` |
| `f(1, width = 2)` where `width` is parameter 0 | `luce.sema.call` | `width was given twice, by position and by name` |
| `f(width = 1, 2)` | `luce.sema.call` | `a positional argument cannot follow a named one; write height = …` |
| `f(1)` where `f` takes `(a, b, c = 0)` | `luce.sema.call` | `f is missing b` |
| `func f(a: i64 = 0, b: i64)` | `luce.sema.call` | `a has a default, so b needs one too — the parameters with defaults come last` |
| `func f(a: i64, b: i64 = a)` | `luce.sema.const` | `a default cannot use a: it is folded before any call is made` |
| `func f(xs: list[i64] = list[i64]())` | `luce.sema.const` | `a default must fold at compile time; new, slicing, and indexing belong in a function` |
| `Point.scaled(p, …)` on a method | `luce.sema.self` | `scaled is a method with implicit self; call it as p.scaled(…)` |
| `"abc".find(needle = "b")` | `luce.sema.method` | `find routes to std.strings and its arguments are positional here; write strings.find(…) to name them` |
| `Point(1, 2)` | `luce.sema.construct` | `Point is built with named fields: Point(field = ...)` |

## What does not change

Names and defaults are resolved away in stage 4. A named call, a
defaulted call, and the equivalent fully-written positional call all
lower to the same positional MIR `call`, so the serialized module's
`format_version` and the published host ABI are untouched, and `luce ir`
prints a defaulted call exactly as it prints the call written out.
Positional-only and keyword-only markers do not exist; there is one kind
of parameter, and the trailing rule is what keeps a keyword-only
parameter from arising by accident.
