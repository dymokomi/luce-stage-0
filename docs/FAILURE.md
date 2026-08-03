# Absence, failure, and the line between them

> Three mechanisms, one rule for choosing. `T?` says a value may not be
> there. `T!` says a call may not succeed. A trap says the program is
> wrong. This memo records why there are three and not one, and what
> each costs.

`docs/MEMORY.md` records why scope ownership won. This is the same kind
of memo for the one remaining semantic hole.

## The rule

> A failure is an **error** if and only if a correct program, given
> correct input, can still meet it — because the world decided, not the
> program. Everything else is a trap.
>
> **Traps are bugs. Errors are news.**
>
> Operational test: could the caller have prevented it with a check
> that is not racy? If yes, it is a trap and the check is the program's
> job. If the check is inherently racy or impossible, it is an error.
> And if the answer is simply "there is nothing there", with no reason
> worth carrying, it is neither — it is `T?`.

Applied to the 21 codes in `06_mir/defs.zig`, that rule moves almost
nothing. Eighteen stay traps. `file_read_failed` becomes an error —
`file_exists` before `file_read` is a TOCTOU race, which is the
canonical proof that a guard function cannot substitute for a result.
`parse_failed` becomes an optional, because "not a number" is the same
reason every time and the function's name already implies it.
`key_missing` and `empty_collection` keep their traps and gain
optional-returning siblings.

That the existing trap set was already drawn almost exactly right is
the best evidence the rule is the one this codebase was following by
instinct. It also **bounds the feature**: errors in Luce are the host
boundary plus `error(...)`, which is why two error codes suffice.

## Absence is a value; failure is an event

|  | absence | failure |
|---|---|---|
| exists today as | `Value.Tag.none` — a slot the heap already carries | `Runtime.pending` — an out-of-band channel with a message |
| can be stored | yes: local, struct field, container | no: it propagates and dies |
| carries a reason | meaningless | the reason is the whole payload |
| ownership | holding `none` owns nothing (S43) | *causes* the release of what you own |

The corpus agrees with no overlap. Absence sites — `counts.has(word)`
then index, and five `parse_int`/`parse_float` calls — want no reason.
Failure sites — three `trap(...)` in `calc.luc` on bad user input, and
`file_read` — all want a reason and want to propagate. **No site wants
both.**

## Optionals

```luce
var user: User? = none
if user != none:              # narrowing: user is User inside
    print(user.name)
let label = user?.name else "anon"
```

`?` means nullable and only nullable. It is never spent on errors —
which is why Rust's `?` and Swift's `try?` are both refused below.

**Narrowing is the feature; the operator is the convenience.** A `?.`
bolted onto a weak checker is a workaround, and reaching for it
everywhere because the checker cannot see through `if x != none:` is
precisely what PEP 505's critics predicted. Luce deletes most of what
makes flow analysis expensive elsewhere: no closures to capture and
invalidate, no subtyping beyond `T <: T?`, no shadowing, no aliasing of
locals, no concurrency. Dart's promotion chain collapses to one bool.

`a else b` is the fallback, and it costs zero new tokens. Python needs
`??` only because `or` is broken there by truthiness; Luce has no
truthiness, so `else` — which already reads as "otherwise" — is enough.
The one recorded objection to `else`-as-coalesce is that
`a if b else c else d` is ambiguous, and Luce has no ternary.

`?.` short-circuits **the whole chain**, not per link. Dart shipped
per-link, abandoned it for whole-chain under sound null safety, and now
warns on the redundant `?`. Under whole-chain, each `?` marks exactly
one genuinely-nullable link and nothing else.

Refused in v1: `T??`; `T?` as a container element or Map value (which
makes `[1, none, none, 2]` unrepresentable — the one PEP 505 objection
that partly transfers); `a?.b = c`; and force-unwrap as a sigil, since
`x! == y` mis-lexes against `!=` and it is the most-complained-about
feature in both Swift and Kotlin. `x else trap("…")` is the
assert-unwrap, and it is greppable.

## Errors

```luce
func read(path: String) -> String!:
    return try host_read(path)

func main() -> !:
    let text = try files.read(arg(0))
    let cfg  = files.read("cfg") catch ""
```

`T!` is **not a type** — fallibility is a function attribute. That
keeps `types.Type` completely untouched: no change to the `.lc` type
table, no change to `Value`, no change to the twenty exhaustive `Type`
switches. It also gives Luce Ok-wrapping for free, which Rust never
shipped: `return x` in a `-> T!` function just returns `x`.

`catch` rather than reusing `else`, because the two are different acts.
`else` means "no value here, use this instead". `catch` means "it
failed, and I am deliberately discarding a reason" — which should be
greppable, and which grows a binding form later that `else` never could
without acquiring a second meaning.

An error carries a stable code from a closed set plus a message — the
same payload a trap carries. Two codes: `io_failed` and `user_error`.
Not `not_found`/`permission_denied`, because `abi.Answer` is
`yes/no/exhausted` and the host physically cannot tell them apart;
inventing those codes would be a lie.

## Ownership on the error path needs nothing new

This is where the answer is Zig's, wholesale, and the reason is in our
own source. `lowerReturn` ends every no-value return with three lines:
release temporaries, release scopes innermost-first, terminate. `break`
and `continue` do the same against a loop frame. **The unwinder is
entirely static and compile-time emitted; there is no dynamic unwinder
to teach about errors.** So `try` is the same three lines with one
terminator changed.

**Luce needs no `errdefer`.** That construct exists because Zig's
cleanup is manual, so the programmer must distinguish "success
transfers ownership, do not free" from "failure, do free". Luce already
makes that distinction structurally — `return` passes the returned
binding as `moved` and skips it; `try` passes nothing and releases
everything. The one bit `errdefer` encodes is already a parameter of
the existing unwinder.

The feature has also aged badly: Zig removed capturing `errdefer` in
April 2026 after concluding all three possible typings break `switch`,
with two uses in its own repository at removal.

The one case Luce cannot roll back is a function that partially mutated
a *borrowed* container and then failed. That is the caller's object,
mutation through a borrow is legal (S38), and undoing it is application
logic. Go says the same.

## No error return traces

They look nearly free — `luce_rt_unwound` already fires on every
unwinding edge — and they are not. Measured: +272 bytes of stack in the
first fallible frame, an extra hidden parameter on every fallible call,
and a save/restore protocol **on the success path**, because the trace
must be popped when an error is handled. That is a cost on code that
never fails, which `docs/MODES.md` forbids. Zig ships them Debug-only
and Luce has no such mode split.

Instead: record the raise origin only — one `line:column` plus function
index, stored once at `error(...)`. Traps keep their full trace.

## What this costs

Optionals need **no runtime change at all**: `Value.Tag.none` exists and
every ownership path already no-ops on it. No new MIR instructions —
four intrinsics. In the compiled representation a `T?` is `{T, i1}`,
which SROA keeps in registers.

> **Corrected once built.** This memo originally said that a heap `T?`
> could be "the existing `i32` with the null index, which is literally
> free", and that one sentence was wrong twice. The width went first:
> generational handles made a handle `{index, generation}` in an
> `i64`. The idea went with it. The null index is not spare — it is
> the zero of an object-typed place (S40), a value that is **present**
> and traps on use — and a program can hand one to a `T?` without a
> diagnostic (`look(raw)` against `func look(xs: List(Int)?)`). The
> interpreter answers "present", because absence there is
> `Value.Tag.none`, a tag *beside* the payload rather than a value
> inside it. A sentinel would answer "absent" and the engines would
> disagree. So `{T, i1}` serves all seven payloads, and the six that
> have no spare value were always going to need it anyway.
>
> The deeper error was assuming one representation serves both
> engines. It does not, and it did not need to: on the interpreter a
> `Value` already carries its tag, so absence *is* `tag == .none` for
> every payload and wrap and unwrap are the identity. Two engines, two
> shapes, one set of answers — which is what the agree tests check.
> The seam between them is the box: absence becomes `Value.none` byte
> for byte, so the runtime's ownership walk finds nothing to own and
> S43 costs no code on either side. docs/CODEGEN.md is the detail.

Errors need no new type, no new register, and no new ABI shape. The
outcome channel already has room: `1` is trapped, `2` becomes errored,
and the value still travels in `%out`. Compare Zig, which sret-returns
every payload-carrying `!T` — even an 8-byte one — through memory.

## Order

Optionals ship first and foreclose nothing. Every seam is disjoint:
`Type` versus `Function.fallible`, the value channel versus the outcome
channel, `else` versus `catch`, `?` versus `!`. The single genuine
coupling is the rule at the top, which decides whether `parse_int`
returns `Int?` or `Int!` — and that decision needs no error mechanism
to exist.

1. ~~`T?`, `none`, narrowing and its diagnostics, `else`. Interpreter
   only; `parse_int`/`parse_float` become `Int?`/`Float?` so it has
   real users on day one.~~ **Done.**
2. `m.get(k) -> V?`, and rewrite `wordcount.luc`. The narrowing
   acceptance test in anger.
3. `?.` — gated on whether step 2 made anyone want it.
4. ~~LLVM lowering for optionals.~~ **Done**, as `{T, i1}` — see the
   correction above. Steps 2 and 3 were overtaken: leaving `T?` on the
   interpreter made every program calling `parse_int` fall back, so
   this came before them.
5. Errors on the interpreter.
6. LLVM, ABI 5, loom reporting.
7. `files.luc` real signatures; `calc.luc` as the worked example.

## Refused, with reasons

Python `try:`/`except:` blocks — invisible error paths, and static
cleanup emission cannot answer "which statement failed" at the block
level. Exceptions with unwinding — the `i1` flag was chosen over
`longjmp` because it needs no platform machinery and works on wasm32.
`Result<T, E>` as a user-visible type — no generics, no tagged unions;
special-casing it the way `List(T)` is special-cased is a category
error, because `List(T)` is a monomorphic heap object while `Result`
needs pattern matching and `From`. Inferred error sets — Zig's cost is
unsupported recursion, unstable type identity, and its own community
calling them a design error in public APIs. Error payloads beyond the
message — Zig's most-upvoted issue, deferred across eight milestones and
closed `not_planned`; the lifetime objection that killed it does not
apply to us, because a String is a value from the run arena, so we can
afford the one thing Zig could not, and only that one. Go's
value-plus-error — Luce has no multiple returns, and adding them *for*
errors is the tail wagging the dog.

Two lines worth keeping. Griesemer on Go's `try`: *"it is designed to
handle the most common case well… `if` statements are code, too."* And
SE-0413, which is why untyped errors ship first: *"Resist the temptation
to use typed throws because there is only a single kind of error that
the implementation can throw."*
