# Typed errors and fallible function values — design for the freeze

**Status: ratified 2026-08-21 (owner); R3 landed 2026-08-21, R2's
language half landed 2026-08-22 — the std sweep remains.**
Extends docs/FAILURE.md; that file's three-way rule (absence / error /
trap) is untouched. Two rulings land here:

- **R2 — errors are unions.** A fallible function may declare what it
  fails *with*: `-> T ! E`, where `E` is an ordinary union. `catch`
  binds the `E` value; `match` reads it apart. Swift's typed throws,
  spelled with Luce's own sum type — no new value kind enters the
  language. (Zig's error sets were considered: simpler values, but a
  whole new type kind; Luce already froze unions and match.)
- **R3 — function types carry fallibility.** `func(str) -> Ast!` and
  `func(str) -> Ast ! ParseError` are types; fallible functions become
  storable, passable values. A non-fallible function converts *into* a
  fallible slot (Swift's subtype rule); the reverse is refused. A call
  through a fallible value is a fallible call: `try` or `catch`.

## The pieces

1. **Bare `!` is `! str`.** Today's errors are a message; they stay
   exactly that, as the default error type. Every existing program and
   std signature keeps its meaning; typed errors are opt-in per
   function. `error("text")` raises the `str` form, unchanged.

2. **Declaring the type**: `func parse(text: str) -> Ast ! ParseError:`
   where `ParseError` is a union in ordinary scope. Payload fields
   carry the news (`unexpected(found: str, line: i64)`). `-> ! E`
   (no success value) parallels today's `-> !`.

3. **Raising**: `error(ParseError.unexpected(found = "]", line = 3))` —
   the one raising spelling, now typed by the enclosing declaration.
   Raising a value not of the declared `E` is refused where it stands.

4. **Catching**: `parse(text) catch reason:` binds `reason: E` in the
   handler scope, exactly as today binds the `str`. With a union `E`,
   `match reason:` discriminates — exhaustiveness and payload capture
   come along for free, positional captures included (D21).

5. **Propagating**: `try` passes the error up unchanged, so the caller
   must declare the *same* `E` (or bare `!` when `E` is `str`). Two
   different error types do not merge silently — the caller catches
   the inner error and raises its own, which is the Zig-lesson kept
   without error-set inference: the conversion is visible where it
   happens. (Set composition can be revisited post-self-host; the
   spelling above stays valid either way.)

6. **Function types**: fallibility and the error type are part of the
   type — `func(i64) -> i64`, `func(i64) -> i64!`, and
   `func(i64) -> i64 ! ParseError` are three types. Assignability:
   non-fallible → fallible-with-any-E (a function that never fails
   trivially satisfies "may fail with E"); everything else exact.
   Function values still have no equality and do not cross workers;
   the element-zero rule is unchanged (a container of function values
   spells the optional element).

7. **Uncaught**: an error that reaches `main` uncaught dies as today —
   trace plus the rendering: the `str` form prints itself; a union
   form prints the member's name and its `str(...)` rendering, which
   both engines already agree on for union values.

8. **Runtime**: the unwind currently carries a `str`; it grows to
   carry one owned `Value` (the union), released when the handler
   scope ends or the program dies. ARC rules are the ordinary ones —
   an error value is a value.

## What this deliberately does not add

- No exceptions-as-control-flow; `T!` remains an event, not a stored
  value — *the error type* is storable only inside a handler's scope,
  like any binding.
- No inferred error sets, no implicit union-merging across `try`.
- No `throws`-style coloring beyond what `!` already is.

## Blast radius

Syntax (`! E` in signatures and function types), semantics (declared
error types, raise/catch/try typing, function-type identity and the
conversion rule), HIR/MIR (signatures carry the error type; raise and
catch carry a `Value`), both engines through one runtime unwind, specs
for every row above, docs (FAILURE.md, Guide, Library), and then the
std sweep: `files`, `network`, `http`, `zip`, `json`, `os.run`
declare their unions before the freeze locks.
