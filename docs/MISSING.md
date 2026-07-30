# What Luce is still missing — the honest inventory

Written 2026-07-30, after ownership (Phase 1) and file-scope
constants (Phase 2) shipped.  This is the distance-to-travel map:
everything a "real language" reader would look for and not find,
ranked by how much daily programs feel it.  The target stays **Zig's
discipline with Python's ease**; each item notes which parent it
comes from.  Optionals and error handling are listed but their
design is deliberately parked for a joint conversation (Phase 3).

## Scorecard

What already stands: a statically typed language with inference,
structs, modules and imports, collections (List/Map/Array/Builder)
with methods, strings with a real method set, file-scope constants,
recursion to any depth, a ratified and adversarially audited
ownership model with zero-leak guarantee, stable diagnostics with
spans, a verified binary module format, a terminal host, and a
self-hosted editor.  ~170 Zig-side tests, all green.

What that adds up to: **Luce today is a complete small scripting
systems language for single-file-plus-imports programs against
files and a terminal.**  The gaps below are what separates that
from a language you would write a large program in without noticing
the walls.

---

## Tier 1 — walls you hit in an afternoon

Things ordinary programs want weekly; all additive, none blocked on
design philosophy.

1. **Error handling + optionals (`T?`)** — the one *semantic* hole.
   Today: traps (fatal) + Bool returns (`file_write`) + guard
   functions (`file_exists` before `file_read`).  Zig's identity is
   `!T` and `try`; Python's is exceptions.  Luce needs its own
   answer, and `T?` and errors are one design conversation
   (**Phase 3 — parked for joint brainstorm, per plan**).
2. **Map iteration yields keys only.**  `for key, value in m:` needs
   multi-binding in `for` — the single most-felt ergonomic gap
   (every map loop pays a second lookup, O(n) inside O(n) on
   today's linear map).  Related missing: `m.values()`, `m.get(k,
   default)` (blocked on optionals for the no-default form).
3. **Runtime traps carry no source location.**  Compile diagnostics
   have byte spans; a runtime trap says `index out of bounds` with
   no file:line.  Python tracebacks and Zig panic traces both spoil
   users here.  Needs an IR-instruction→span side table (the format
   has room; bump `format_version`).
4. **No `read_line()`** (or any line-mode stdin) — calc.luc cannot
   be a REPL.  One host builtin away.
5. **No character literals.**  `byte_at(...) == 40  # "("` is the
   editor's and calc's whole lexing story.  Options: `'('`, or
   compile-time-folded `ord("(")` now that constant folding exists.
6. **No string interpolation.**  `"x = " + str(x) + ", y = " +
   str(y)` everywhere.  Python f-strings are the gold standard;
   even a minimal `format("x = {}", x)` would relieve most of it.
7. ~~Compound assignment (`+=`, `-=`, ...)~~ — shipped: `+= -= *= /=
   %=` on Int/Float and `+=` on String, value-only, place evaluated
   once.
8. **No `pow`, no `random`, thin math.**  `sqrt/floor/ceil/abs/
   min/max/clamp` exist; `pow`, `log`, `exp`, trig, and any random
   source do not.  Games (life.luc wants random seeding) and stats
   programs feel it immediately.
9. **Assignment targets are a single field or index, not a chain.**
   `p.inner.n = 1` and `cells[0].value = 1` are rejected
   (`luce.parse.assign`); you replace the whole slot instead
   (`p.inner = Inner(...)`, `cells[0] = Cell(...)`).  Reading such
   chains is fine — only the assignment left-hand side is
   constrained.  Nested mutation through a chain is the natural
   thing to want; lifting this is parser + lowering work, worth
   doing once struct/collection programs grow.

## Tier 2 — language shape decisions worth making deliberately

Each changes how programs are *written*, so decide once, on
purpose — same posture as the memory-model process.

9. **Integer division spelling.**  `/` truncates toward zero (Zig);
   Python floors and returns float.  Standing open question from
   audit round 1: make `/` on Ints a compile error and add `//`, or
   keep Zig semantics and document loudly.
10. **Enums and switch/match.**  No enum type, no `match`/`switch`
    statement — today it's Int constants + `if/elif` chains
    (key names from `key_read()` are stringly typed).  Zig's tagged
    unions + `switch` with exhaustiveness is the model worth
    wanting; even C-style enums + exhaustive `match` would
    transform editor/key handling code.
11. **Struct methods with receivers.**  Structs hold static
    namespaces only (`Editing.splice(state, ...)`); there is no
    `state.splice(...)` for user types.  The method *syntax* already
    exists for builtins, so this is sugar + a `self` convention —
    but it touches the "no receivers, no dispatch" line v2 drew, so
    it is a decision, not a chore.
12. **Multiple return values / tuples.**  Functions return one
    value; out-params via mutable containers are the workaround.
    Python tuples vs Zig anonymous structs — either way it
    interacts with ownership (a tuple carrying objects is a
    carrying value) and with `for key, value` (item 2), which is
    really tuple-binding in disguise.
13. **Bitwise operators.**  No `&`, `|`, `^`, `<<`, `>>`, and no
    hex/binary literals (decimal only, no `_` separators).  A
    systems language without bit twiddling caps what userland can
    reach (color packing, hashing, bitboards).  Cheap to add; needs
    precedence decisions (Zig's are saner than C's).
14. **Visibility.**  Every declaration is public to importers.
    Zig's `pub` is the obvious model; matters before userland
    libraries exist, not after.
15. **`Bytes` is a stub.**  The type exists (ports, zero value)
    but there are no literals, no methods, no file_read_bytes —
    strings do everything today.  Either grow it (binary file work
    needs it) or cut it until it earns its keep.
16. **Constants are value-only.**  Top-level `let` refuses objects
    by design (no hidden startup allocation).  A `const` table of
    Strings/Ints covers most needs; revisit only if a real program
    needs a constant List badly enough to argue.

## Tier 3 — standard library breadth

Nothing here needs language changes; all of it wants a decision on
**where std lives** (builtins vs a shipped `import std` module —
modules exist, so the mechanism is one design choice away).

- **Strings:** `pad`/`center`/`ljust`, `find` from-index /
  `find_last`, `count`, split with limit, `is_digit`/`is_alpha`
  class checks, real Unicode case folding (today's lower/upper is
  ASCII), codepoint iteration (byte_at only).
- **Collections:** `set` type (or Map(K, Bool) blessed), `m.values()`,
  list `min/max/sum`, sort with key/comparator (needs functions as
  values — see Tier 4), `enumerate`-style indexed iteration.
- **Files & OS:** list directory, delete/rename, append mode,
  binary I/O (needs Bytes), `env(name)`, `exit(code)`, current
  time/clock, `sleep(ms)` (life.luc busy-waits today).
- **Math:** pow/log/exp/trig, PRNG with seed, float formatting
  control (`str(2.5)` is take-it-or-leave-it).

## Tier 4 — deliberately out of scope for now (keep it that way)

Recorded so the absence reads as a choice, not an oversight:

- **First-class functions / closures / lambdas** — the biggest
  philosophical fork; unlocks sort-by-key, callbacks, iterators.
  Everything above is designed to not need it.  Decide only with a
  concrete program in hand.
- **Generics for user code** — `List(T)` is compiler-internal;
  user-parametric types are a research project at this scale.
- **Interfaces/traits, inheritance, operator overloading** — no.
- **Async/threads/coroutines** — the Fabric is the eventual answer
  to concurrency; nothing in-language before that.
- **defer** — superseded by scope ownership for memory; may return
  someday for host cleanup only.
- **Reflection/comptime** — constants + folding are as far as
  compile-time execution goes for now.

## Tier 5 — runtime and tooling distance

- **Native codegen.**  Everything runs on the IR interpreter.  The
  IR was shaped for a native backend (block-local registers, locals
  as stack slots) — this is the big performance step and the reason
  the verifier ethos exists.  Sequenced after the language surface
  settles (V2.md).
- **Build modes.**  One mode today: all checks on.  OWNERSHIP.md
  S9 promises a ReleaseFast posture where safety backstops drop;
  needs the mode plumbing and a policy for which traps remain.
- **Map is a linear scan** — honest and insertion-ordered; hash
  index behind the same semantics when a program earns it.
- **Interpreter perf generally** — arena churn per call, no
  instruction fusion; fine for the editor, unmeasured beyond it.
- **Tooling:** no `luce fmt`, no LSP/completions, no debugger or
  stepping, no stack trace on trap (see Tier 1.3), no doc
  generator, no test runner for Luce programs themselves (`assert`
  in main is the current story; a `luce test` discovering
  `func test_*():` would be cheap and very Zig).
- **Module ecosystem:** imports resolve as sibling files only — no
  paths, no packages, no versioning, no std namespace (see Tier 3).

## Tier 6 — the OS beyond the language (V2.md's horizon)

Fabric/Texels/persistence, braids and sync, capabilities, the
agent, multi-user — all deferred by design in V2.md; the language
work above is what they will stand on.

---

## Suggested order (matches felt pain, defers parked designs)

1. Trap source locations (Tier 1.3) — pure quality, no design risk.
2. `for key, value in m:` + `m.values()` (1.2, needs mini-design
   for multi-binding; pairs naturally with tuples decision 2.12).
3. `read_line()`, character-literal folding, `format(...)`,
   pow/random (1.4–1.8) — one small slice. (Compound assignment,
   formerly here, is done.)
4. The three Tier-2 decisions worth a memo each: integer division,
   enums+match, receivers.
5. `import std` mechanism + first std module (Tier 3 umbrella).
6. **Phase 3 brainstorm: optionals + errors** — after which `get`,
   file APIs, and parse functions all get their real signatures.
