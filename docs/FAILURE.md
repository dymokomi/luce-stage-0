# Absence, failure, and the line between them

Luce has three ways for something to go not-as-hoped, and one rule for
telling them apart.

> - `T?` says a value **may not be there**.
> - `T!` says a call **may not succeed**.
> - A **trap** says the program is **wrong**.

`docs/MEMORY.md` records the memory model; this is the reference for the
three failure mechanisms and how to choose among them.

## The rule

> A failure is an **error** if and only if a correct program, given
> correct input, can still meet it — because the world decided, not the
> program. Everything else is a trap.
>
> **Traps are bugs. Errors are news.**

The operational test: could the caller have prevented it with a check
that is not racy? If yes, it is a trap, and making the check is the
program's job. If the check is inherently racy or impossible, it is an
error. And if the answer is simply "there is nothing there", with no
reason worth carrying, it is neither — it is `T?`.

So reading a file is an error (asking whether a file exists before
opening it is a TOCTOU race), a bad index is a trap (the caller could
have checked `len`), and a failed number parse is absence (`parse_i64`
answers `i64?`, because "not a number" is the same reason every time and
the name already says it).

## Absence is a value; failure is an event

|  | absence (`T?`) | failure (`T!`) |
|---|---|---|
| what it is | a value: a slot that may hold `none` | an event: it propagates and dies |
| can it be stored | yes — in a local, a field, a container | no |
| carries a reason | no reason to carry | the reason is the whole payload |
| effect on cleanup | holding `none` keeps nothing alive | unwinds, releasing what the frame holds |

## Optionals

`T?` means a value may be absent. `none` is the absent value, and it is
an ordinary value that a `T?` place can hold.

```luce
struct User:
    let name: str

func find() -> User?:
    return none

func main():
    let user: User? = find()
    if user != none:            # narrowing: user is User inside the block
        print(user.name)
    else:
        print("anon")
```

**Narrowing is the feature.** Inside a block guarded by `if x != none:`,
`x` has the non-optional type and its fields and methods are reachable
directly. Luce's checker sees through the guard because the language
keeps flow analysis cheap: no shadowing, no aliasing of locals, and only
one subtyping relation (`T <: T?`).

`a else b` is the fallback: it yields `a` when `a` is present and `b`
otherwise. It reads as "otherwise", and because Luce has no truthiness it
is the whole coalescing story — there is no separate `??`.

```luce
func main():
    let count = parse_i64("42") else 0
    print(f"{count}")
```

`x else trap("…")` is the assert-unwrap — present the value or stop the
program — and it is greppable:

```luce
func main():
    let n = parse_i64("42") else trap("not a number")
    print(f"{n}")
```

A list, array, or channel element may be optional (`list[i64?]`); a `map`
value may not, because a lookup already answers `V?` and a `V?` value would
make that `V??`. The following are not part of the language: `T??` (an
optional of an optional), an optional-chaining operator, and a force-unwrap
sigil. Absence is reached through narrowing and `else`.

## Errors

Fallibility is an attribute of a **function**, written `!` after its
return shape. `T!` is **not a type**: it never annotates a binding, a
field, or a parameter, and the value the function answers is an ordinary
`T`.

```text
import std.files

func read(path: str) -> str!:
    return try files.read(path)
```

A function marked `-> !` answers nothing but may fail; `-> T!` answers a
`T` or fails; `-> (A, B)!` answers a shape or fails. Because `T!` is not a
type, `return x` in a `-> T!` function just returns
`x` — Ok-wrapping is free.

`error(message)` raises. It is written as a statement (it diverges), and
the message is any `str`:

```luce
func checked(s: str) -> i64!:
    let n = parse_i64(s)
    if n == none:
        error("not a number: " + s)
    return n

func main() -> !:
    let value = try checked("42")
    print(f"{value}")
```

### try

`try f()` passes a failure on to the current function, which must itself
be fallible. On success the value flows through; on failure the current
function unwinds with the same error.

`try` is an expression prefix and is legal in any expression position —
an operand, a list element, an argument. Three rules make a compound
expression predictable, and the behavior specification pins each:

- **It binds to the tightest following fallible call**, tighter than any
  binary operator: `try f(8) + try f(4)` tries each call, never the sum.
- **Operands still evaluate left to right**, and the first failure
  abandons the whole enclosing statement — later operands never run.
- **A tried call is a handled call.** `try` consumes that call's
  fallibility, so a statement whose fallible calls are all tried has
  nothing left for a statement `catch` to guard, and the compiler says
  so rather than leaving a handler that could never fire. To observe a
  compound expression's first failure, move the expression into its own
  fallible function and `catch` at that call.

### catch

`catch` handles a failure. It comes in two forms.

**`catch EXPR`** supplies a fallback value for the whole expression:

```luce
import std.files

func read(path: str) -> str!:
    return try files.read(path)

func main() -> !:
    let cfg = read("cfg.txt") catch "default"
    print(cfg)
```

**`catch:` block** guards a single statement — a call, a plain
assignment whose value is a call, or a binding — and runs an indented
handler on failure. It supplies no value; it is for the case where the
response is to do something rather than to name a fallback:

```luce
import std.files

func main() -> !:
    files.write("out.txt", "data") catch:
        print("could not write")
```

**`catch NAME:`** binds the error's message for the handler:

```luce
import std.files

func read(path: str) -> str!:
    return try files.read(path)

func main() -> !:
    discard(read("missing.txt")) catch reason:
        print("failed: " + reason)
```

On a binding — `let a = risky() catch:` — the handler must always
leave (`return`, `error`, a trap): it has no value to give the name,
so falling through would reach a read nothing initialized, and the
checker refuses it (`luce.sema.catch`). The name itself is not
visible inside the handler, for the same reason. This is the shape an
early-return guard takes:

```luce
func risky() -> i64!:
    return 7

func read() -> i64:
    let a = risky() catch:
        return -1
    return a + 1
```

The bound name is a `str` — the message, and only the message. An
error's code and origin are not a handler's business: a caught error is
one nobody is reporting, and the call that raised it already answered
which kind it was. `catch` is deliberately distinct from `else`: `else`
means "no value here"; `catch` means "it failed, and I am handling the
failure", which grows the binding form and stays greppable.

### A fallible result cannot be ignored

Calling a fallible function and dropping its result is refused
(`luce.sema.call` / `luce.sema.fallible`). Every fallible call must be
propagated with `try`, given a fallback with `catch`, or handled by a
`catch:` block. Ignoring `files.write(...)` does not compile.

## Traps

A trap stops the program: it is a bug, reported with a code, a message,
a `file:line:column`, and a call trace (function names survive
`--release`). A program cannot catch a trap. `trap(message)` raises one
on purpose; `assert(condition)` raises `assertion_failed` when the
condition is false.

The trap codes are a closed set:

| code | when |
|---|---|
| `integer_overflow` | a checked integer operation overflowed |
| `divide_by_zero` | integer division or remainder by zero |
| `conversion_range` | a numeric conversion was out of the target's range |
| `assertion_failed` | `assert(condition)` saw a false condition |
| `explicit_trap` | `trap(message)` was called |
| `missing_return` | a function ended without returning its value |
| `call_depth_exceeded` | the call stack reached its budget — a million frames, or the bytes of the reservation, whichever ran out first |
| `str_bounds` | a string index or slice was out of bounds |
| `str_boundary` | a string slice split a UTF-8 sequence |
| `host_unavailable` | an effect was used with no host service behind it |
| `index_bounds` | a `list`, `array`, or string index was out of bounds |
| `key_missing` | a `map` was indexed at an absent key |
| `empty_collection` | `pop` from an empty `list` |
| `null_object` | a null object reference was used |
| `bad_codepoint` | `chr` of an invalid character code |
| `shift_out_of_range` | a shift count was negative or at/past the operand's width |
| `allocation_failed` | the machine could not give a container the memory it asked for |
| `immutable_object` | a mutating operation reached a constant container |

Two of these have optional-returning or absent-answering siblings so a
program need not risk them: `key_missing` versus `m.get(k) -> V?`, and
parse failure answered as `i64?` rather than a trap.

## Cleanup on the error path

The error path needs nothing special. Cleanup is ARC's inserted
releases, emitted statically: a `return` hands its value back and
releases the frame's other locals; a `try` on the failing edge releases
everything, including the slot the value would have gone to. There is no
dynamic unwinder to teach about errors and no `errdefer`: the one bit
`errdefer` encodes elsewhere — keep the value on success, release it on
failure — is already a parameter of the release sequence Luce emits.

The one thing an unwinding function cannot undo is a mutation it already
made to a reference it was passed. That object is the caller's, mutation
through a reference is visible to the caller by design, and undoing it is
application logic.

An uncaught error is announced by the host with its origin — the
`line:column` and function recorded at the `error(...)` site. Traps carry
their full call trace; errors carry only the raise origin, so code that
never fails pays nothing for a trace it will not use.

## Representation

Optionals need no runtime machinery: `none` is a value tag every release
path already no-ops on. In compiled code a `T?` is `{T, i1}`, which the
optimizer keeps in registers, and it boxes to the absent value byte for
byte, so absence costs no code on either engine.

Errors need no new type, no new register, and no new value channel. A
compiled function answers its outcome in a result word the caller already
reads — success, trapped, or errored — while the value travels in the
result slot it always used. On the failing edge a fallible function
empties that slot, so a destination nobody wrote is the `none` its frame
started at. `error(...)` copies its message, because an error unwinds
*through* the releases that would otherwise reclaim a statement's
temporaries.

## Deliberately absent

- **`try:`/`except:` blocks** — invisible error paths, and static cleanup
  cannot answer "which statement failed" at the block level. A `catch:`
  block guards exactly one statement, so it can.
- **Exceptions with unwinding** — the outcome word is chosen over
  `longjmp` because it needs no platform machinery.
- **`Result<T, E>` as a user-visible type**, and inferred error sets —
  Luce has no generics for the first and does not want the instability of
  the second.
- **Error payloads beyond the message** — the message is the whole
  payload a handler sees.
- **Value-plus-error returns** (Go's `v, err`) — the error has its own
  channel precisely so it never occupies a return position.
