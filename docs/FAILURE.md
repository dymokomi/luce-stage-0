# Absence, failure, and the line between them

> **Spellings, since this was decided.**  The builtin type names are
> lowercase (`long`, `double`, `string`, `list`, `map`, `array`,
> `builder` — docs/TYPES.md D8), and the two numeric types became four:
> `int` and `float` are 32 bits and are what a literal takes with
> nothing to tell it otherwise, `long` and `double` are the 64-bit
> types this memo calls `Int` and `Float`.  A fenced block tagged
> `luce historical` is shown as it was written and is not compiled;
> every other one in this file is (`tools/doccheck.zig`).

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

Applied to the **20** codes `06_mir/defs.zig` carried when this was
written (`72fe8be^`), that rule moves almost nothing: **nineteen stay
traps**, and exactly one moves. `file_read_failed` becomes an error —
asking whether a file is there before `file_read` is a TOCTOU race,
which is the canonical proof that a guard function cannot substitute
for a result.
Parse failure moves too, but it was never a trap code to begin with:
`parse_int` answers `Int?`, because "not a number" is the same reason
every time and the function's name already implies it.

> Since then one more code has gone, for a reason unrelated to this
> rule: `step_budget_exhausted` left with the step budget itself
> (`16ed137`). **Luce has 18 trap codes today**, and
> `06_mir/defs.zig`'s `TrapCode` is the list — the site's
> [reference](https://luce.luciaos.com/guide/reference/failure/) carries all of
> them, and a test fails the site build if it stops doing so.
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

```luce historical
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

```luce historical
func read(path: String) -> String!:
    return try host_read(path)

func main(args: List(String)) -> !:
    let text = try files.read(args[0])
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

> **Corrected once built: `catch` has two forms, and it needs both.**
>
> The memo assumed one — the expression `a catch b` — and the corpus
> refused it twice. `editor.luc` handles a failed save by setting two
> fields and a failed open by choosing a greeting; neither is a
> fallback *value*, and writing them as one produced worse code than
> the Bool it replaced. So a statement whose call may raise also takes
> an indented handler:
>
> ```luce
> files.write_lines(path, rolls) catch:
>     print("could not write " + path)
>
> opening = files.read(path) catch:
>     greeting = "new file"
> ```
>
> **This is not the Python block this memo refuses**, and the
> difference is the one the refusal turns on: it guards exactly one
> call, so "which statement failed" has one answer and static cleanup
> emission has one place to put it. Two statement shapes take it — a
> call, and a plain assignment whose value is a call — and no others.
> A `let` is deliberately not among them: the handler would have to
> supply the value the name binds, and only `catch EXPR` can say that.
> A compound assignment is refused for the same reason in reverse —
> `x += f()` reads its place first, so there would be two things in
> front of the word and only one of them can fail.
>
> One token of lookahead separates the two spellings, because nothing
> else can follow the operator form with a colon.

> **Corrected once built: `catch` grew the binding, and it binds the
> message.**
>
> This memo chose `catch` over reusing `else` partly because it
> "grows a binding form later that `else` never could", and then the
> block form shipped without one — so a handler could not see what it
> had caught. `calc.luc` carried the evidence in a comment for two
> releases: its REPL printed `cannot compute:` and the line the user
> had just typed, while the parser's own words — *expected a number at
> position 4* — sat unreachable in the error. The spelling is
> `CALL catch NAME:`.
>
> **`reason` is a `string`, and the code and the origin are not in
> it.** An error carries three things and only one of them is a
> handler's business. The corpus said so with no dissent: every
> `catch` in the tree guards exactly one call — `evaluate` in calc,
> `file_write` in the editor's save, `files.read` in its open — and a
> call raises with one code, so branching on `io_failed` versus
> `user_error` asks a question the call already answered. That is the
> same argument the section above makes for there being two codes at
> all, applied one level down. The origin stays in the host's report,
> where an error nobody caught is announced; a handler that caught one
> is *not* reporting it and has no use for a `file:line`. So the
> feature costs no struct, no closed enum, and nothing in the type
> table — and the memo's own refusal of "error payloads beyond the
> message" still stands, because this is not a payload, it is the
> message.
>
> **The operator form does not take one.** `f() catch(reason) fallback`
> would need a parenthesized binder, which appears nowhere else in the
> grammar, to open a scope inside an expression, which nothing else in
> Luce does. And what such a fallback would be is almost always a
> message being *built* — which is a statement, and the block form.
> Zero corpus sites wanted it.
>
> Two things did need building. One intrinsic, `error_message`, which
> answers a **borrow** of the words rather than a copy — the arena
> holding them outlives the run, so this is exactly the shape
> `key_text` already had, and the binding's own store is what takes the
> copy it owns. It stands in front of the `forget` beside it, and so
> does the copy: the words would in fact survive the clear, because
> `forget` only nulls a pointer, but reading, copying and *then*
> emptying means nothing has to know that. And a scope of its own
> wrapped around the handler's, so the binding is not one of the
> handler's statements and a `return` or `break` out of the handler
> releases it like any other local (S1).
>
> The one thing that cost more than expected was the lookahead. The
> line above says one token separates the two spellings; `catch NAME:`
> needs three, and the third is the newline. A slice takes a whole
> expression either side of its colon, so `xs[first(xs) catch base :
> 10]` is the operator form with a name for a fallback — and the lexer
> emits no newline inside brackets, so a newline behind the colon can
> only be the end of a statement line. The one-line
> `f() catch reason: print(reason)` that falls out of that gets a
> message of its own rather than "expected end of line, found ':'".

> **Corrected once built: `file_write` is fallible too.** The memo
> named only `file_read_failed`, and named `dice.luc:41` — `if
> files.write_lines(...)` with no else — as a live bug "caused directly
> by Bool-as-error". Those two sentences do not fit together: leaving
> `file_write` a Bool leaves the bug writable. So a write that did not
> land is `io_failed` as well, `files.write` and `files.write_lines`
> are `-> !`, and the `if` with no `else` is now a `luce.sema.call`
> because there is nothing to test. The rule at the top of this memo
> was always going to say so — a disk that refuses a write is the world
> deciding, and no non-racy check prevents it.
>
> `file_exists` stays a Bool. It is a question, not a failure.

> **Overturned in the filesystem run (docs/FILESYSTEM.md D13).** The
> memo was right that a question is not a failure and wrong that the
> answer fits in a bool: three things can happen at a path — something
> is there, nothing is there, and *the world would not say* — and a
> file that certainly exists under a `chmod 000` parent answered
> `false`, indistinguishable from a name nothing holds. That is the
> same in-band answer this memo refused for `key_read`, decided the
> other way by default rather than on purpose. `file_exists` is gone;
> `files.kind` answers `Kind?!` — the member for what is there, `none`
> for absence, `!` for refusal — and `files.exists`, `files.is_file`
> and `files.is_dir` are `bool!` over it. `catch false` is the
> deliberate discard, and it is three visible words.

> **Corrected once built: `key_read` is `String?` too.** The memo's
> corpus scan found the absence sites and missed one, because at the
> time it had no answer at all to miss: `key_read` blocks for a key
> and there was no way to say that none would ever come. The rule at
> the top decides it in one line — a keyboard runs dry when the pipe
> driving it ends or the terminal closes, the host cannot tell those
> apart and has no reason to, and "there is nothing there, with no
> reason worth carrying" is `T?`. It is the same fact `read_line`
> already answers `none` for, off the *same file descriptor*.
>
> The other candidate was one more name in the closed set — `"eof"`
> beside `"enter"` and `"up"` — and it is worth saying why it loses,
> because it is the cheaper change and it does not alter a type
> anybody has written. It loses because it does not make the compiler
> say anything. A name is a `String` a loop can fall past, and every
> loop that falls past it goes back to asking for the next key: the
> in-band answer leaves the bug writable, and would have needed the
> same edit to `editor.luc` and `life.luc` with nothing pointing at
> them. `String?` refuses each call site where it stands, which is
> what turned the one-line fix into a compile error at four of them.
>
> Two smaller things fell out. `key_text` empties at end of input, so
> a program reading name and payload separately never sees a key half
> there. And the host had *had* the answer since ABI 3 — `Answer.no`
> — and the lowering read only `exhausted`, so the channel existed
> and carried nothing. An answer nobody reads is not a design; it is a
> loop waiting to be found.

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

> **Corrected once built (2026-08-03).** Half of that paragraph held
> and half of it did not.  The version numbers below are of that day;
> `docs/CODEGEN.md` carries the current ones.
>
> The channel *did* have room, and the numbers are the ones written
> here — but the channel was an `i1`, so making room meant widening
> every internal Luce function's result to `i32`. That is free (a
> register either way, `internal` linkage, no promise to keep) and it
> is the reason the compiled path reads no flag on the success side of
> a `try`: the outcome word the call answered *is* the channel, and
> `errored` is one `icmp` against it. No load, no runtime call.
>
> `luce_main`'s status is a different number and could not take `2`,
> which `exhausted` had held since ABI 3 — a version that arrived
> between this memo and the build. So the published answer is
> `errored = 3`, and `abi.version` went to **7**, not 5: 5 named the
> artifact's machine, 6 put a short String in the value, and the
> memo's arithmetic was two versions out of date by the time anyone
> read it. `.lc` `format_version` is 14.
>
> Three things did need a shape after all. **`raise_error` copies the
> words**: an error unwinds *through* releases, which is the whole
> difference from a trap, so `error("x: " + String(n))` hands over bytes a
> statement temporary is about to give back. The copy is one line in
> `Runtime.raise` and both engines reach it. **A fallible call's value
> crosses a block boundary**, because the branch on its outcome ends
> the block it was made in — so it travels through a hidden slot, and
> that slot is the one that *owns* it: one place, not two, with the
> statement's temporary recorded on the returning side so the failing
> side does not release what it never stored. And **one value must be
> parked once**: `try f()` hands back what `f()` produced, so the walk
> sees the same register twice, and two hidden locals both claiming one
> String's bytes free them twice. That was a real double free, found by
> running the feature.
>
> The crossing is also where errors meet small-string optimisation,
> which landed between the design and the build. A slot that owns its
> storage holds a whole `runtime.Value`; a borrowing one holds the
> register shape, which for a String is `{ptr, i64}` and cannot say
> that the text is *inside* the value it was read out of. Carrying a
> fallible call's result in a borrowing slot therefore marked short
> text as outside text, and the release at the end of the statement
> freed a pointer into the frame. Making the carrying slot the owning
> slot fixes it at the root rather than at the symptom, and it is what
> the value wanted anyway.
>
> One more thing the two features settled between them: a fallible
> function **empties `%out` on its errored edge**. The store that
> carries a result across the branch stands before the branch, so it
> runs on the failing path too, and a callee that returned nothing
> would leave it copying whatever the stack held. Emptying costs the
> failing path one store and the success path nothing, and it makes the
> compiled answer the one the interpreter already gave: a destination
> register nobody wrote is still the `.none` its frame started at.

## Order

Optionals ship first and foreclose nothing. Every seam is disjoint:
`Type` versus `Function.fallible`, the value channel versus the outcome
channel, `else` versus `catch`, `?` versus `!`. The single genuine
coupling is the rule at the top, which decides whether `parse_int`
returns `Int?` or `Int!` — and that decision needs no error mechanism
to exist.

1. ~~`T?`, `none`, narrowing and its diagnostics, `else`. Interpreter
   only; `parse_int`/`parse_float` become `Int?`/`Float?` so it has
   real users on day one.~~ **Done.**  *(This list was written while
   the interpreter was still an engine and the LLVM path was reached
   by falling forward to it; it is neither now — docs/ENGINE.md.)*
2. `m.get(k) -> V?`. The narrowing acceptance test in anger.
   ~~Rewrite `wordcount.luc`~~ — **done**, and by a different route:
   a compound store defines its key at the value type's zero, so the
   counter needed no optional at all (docs/LANGUAGE.md, "Zero
   values").
3. `?.` — gated on whether step 2 made anyone want it.
4. ~~LLVM lowering for optionals.~~ **Done**, as `{T, i1}` — see the
   correction above. Steps 2 and 3 were overtaken: leaving `T?` on the
   interpreter made every program calling `parse_int` fall back, so
   this came before them.
5. ~~Errors on the interpreter.~~ **Done.**
6. ~~LLVM, ABI 5, loom reporting.~~ **Done**, at ABI **6** — see the
   correction below.
7. ~~`files.luc` real signatures; `calc.luc` as the worked example.~~
   **Done**, except that the worked example turned out to be
   `dice.luc` and `editor.luc` — see below. Steps 5, 6 and 7 shipped
   together, because leaving errors on the interpreter would have
   repeated exactly the regression step 4 had to undo.

## Refused, with reasons

Python `try:`/`except:` blocks — invisible error paths, and static
cleanup emission cannot answer "which statement failed" at the block
level. Exceptions with unwinding — the `i1` flag was chosen over
`longjmp` because it needs no platform machinery and works on wasm32.
`Result<T, E>` as a user-visible type — no generics, no tagged unions;
special-casing it the way `List(T)` is special-cased is a category
error, because `List(T)` is a monomorphic heap object while `Result`
needs pattern matching and `From`.  (Tagged unions have since shipped
— 2026-08-10 — and this refusal stands on its other legs: the union
run promised errors nothing by design, docs/UNION.md R3, because an
error unwinds through releases and the load-bearing objection was
never the missing type.) Inferred error sets — Zig's cost is
unsupported recursion, unstable type identity, and its own community
calling them a design error in public APIs. Error payloads beyond the
message — Zig's most-upvoted issue, deferred across eight milestones and
closed `not_planned`; the lifetime objection that killed it does not
apply to us, because a String is a value whose bytes belong to whatever
place holds them and are reclaimed with it (docs/STRINGS.md), so we can
afford the one thing Zig could not, and only that one. Go's
value-plus-error — Luce has no multiple returns, and adding them *for*
errors is the tail wagging the dog.

Two lines worth keeping. Griesemer on Go's `try`: *"it is designed to
handle the most common case well… `if` statements are code, too."* And
SE-0413, which is why untyped errors ship first: *"Resist the temptation
to use typed throws because there is only a single kind of error that
the implementation can throw."*
