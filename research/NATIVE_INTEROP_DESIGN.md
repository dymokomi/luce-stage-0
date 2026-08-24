# Native interop: null, beautiful C imports, and merging the ObjC step

**Status:** design research. Companion to `NATIVE_PLATFORM_RESEARCH.md`. Nothing
here amends `LUCE_LANGUAGE_DESIGN.md`; where it proposes language change it says
so and prices it.

Three questions were asked:

1. **Null.** Make it feel native. Luce has optionals — the answer should be in
   there already.
2. **C imports.** Today they are ugly. Make them feel automatic.
3. **Objective-C (and C++).** Using them means *first* a C ABI shim, *then*
   importing that shim. Two steps. Merge them.

Short answers, in order: **`foreign?` with a non-null default, and no `null`
literal ever**; **generate bindings ahead of time in four layers, with a
declarative recipe and a staleness check**; and **yes, merge them — by making
the shim a content-addressed build artifact the user never sees.**

---

## 0. What I measured first

All three questions turned out to reduce to three missing primitives. Measured
on shipped `luce 0.20`, macOS arm64, against Homebrew SDL 3.4.12.

### 0.1 Luce already calls Objective-C

```luce
extern func objc_getClass(name: foreign) -> foreign
extern func class_getInstanceSize(cls: foreign) -> u64
extern func objc_msgSend(receiver: foreign, selector: foreign) -> foreign
```
```
NSObject instance size = 8
sent [NSObject alloc] through objc_msgSend
```

The Objective-C runtime is a plain C API, which is exactly what the FFI speaks.
`--link -lobjc` and nothing else.

### 0.2 …but only at one prototype

Real dispatch needs `objc_msgSend` at *many* prototypes — one per return type and
argument shape. Luce refuses:

```
objc_msgSend is already declared; an extern shares the function namespace
[luce.sema.extern]
```

Because **an extern's Luce name *is* its C symbol**. There is no name/symbol
split. §3.4 of the design doc already licenses one — *"imported native APIs may
receive generated idiomatic names while retaining the foreign spelling in
metadata"* — but nothing exposes it.

### 0.3 The boundary is write-only

`std.c` is three functions and all of them point outward. Luce can hand C a
buffer and let C write into it — that is how `SDL_PollEvent` filled a
`list[u8]`. But **there is no way to read memory at a pointer C returns.**
`SDL_GetError()` hands back a `const char *` and Luce can do nothing with it. No
C-owned string or struct is readable.

This is the single biggest reason the FFI "looks ugly," and it is why every
struct today is decoded byte-by-byte out of a buffer Luce itself owns.

---

## 1. Null

### 1.1 The design

`foreign?` — an ordinary optional — with **non-null as the default**, and **no
`null` literal in the language**.

```luce
extern func SDL_CreateWindow(title: cstr, w: i32, h: i32, flags: u64) -> foreign?
extern func SDL_DestroyWindow(window: foreign)          # must not be null
extern func SDL_SetPersonality(f: foreign, p: foreign?) # null is meaningful here
```

Three rules:

1. **`?` is permitted at the boundary only on `foreign`.** `i64?` has no C
   encoding — there is no sentinel — so it stays refused. This keeps `FFI.md`'s
   closed type vocabulary honest and needs no new machinery.
2. **Bare `foreign` is the author's non-null assertion.** Passing or receiving 0
   through it is undefined behaviour at the boundary — the same class of error,
   with the same documented consequence, as `FFI.md`'s existing *"a wrong shape
   is undefined behaviour at the boundary and the docs say so plainly."*
3. **No `foreign!`-style unchecked optional, and no `null` literal.**

### 1.2 Why non-null by default

Swift imports unannotated pointers as implicitly-unwrapped `T!`, and that is
now treated as technical debt in its own memory-safety vision. But `T!` exists
for exactly one reason: **Apple had to bulk-import a hundred thousand lines of
unaudited headers.** Apple's own *considered* default, once auditing, is
`NS_ASSUME_NONNULL_BEGIN` — non-null, with nullability the annotated exception.

**Luce has no importer.** `FFI.md`: *"No body, no importer, no headers: the
author writes the shape and owns its truth, exactly as in Zig."* Every extern is
hand-written by someone who is, at that moment, reading the C documentation.
There is no unaudited bulk to protect against, so the Swift problem has no work
to do here. Defaulting nullable would force a narrow on the overwhelming
majority of handles C never returns null for.

This also fits "unsafety is visible, not gated": the assertion is *in the
declaration*, the one place the author is already asserting a shape C will not
check.

**The honest counter-argument**, which the owner should weigh: a mis-annotated
`-> foreign` yields a 0 token that only explodes later, inside C, with no
Luce-side traceback. That is exactly why Zig's *importer* defaults the other way
(`translate-c` emits `?*T` for opaque pointers and never guesses non-null). If
"the FFI must never surprise you" outranks "the common case stays terse," then
nullable-by-default with an explicit non-null spelling is the defensible
alternative. It costs one narrow per handle-returning call, forever.

### 1.3 Representation: do **not** niche-optimize

My first instinct was that `foreign?` should be a niche optional — 0 means
`none`, zero extra storage. **That is wrong, and the repository already contains
the argument.**

`docs/CODEGEN.md` documents `T?` as `{T, i1}` — payload beside a bit, pure
register moves, SROA'd apart in the entry block, no call and no memory. It then
records a *rejected* sentinel proposal for the heap case, and the reason
transfers exactly:

> The null handle is the **zero of an object-typed place** — a value that is
> *present* and traps when used — and a program can put one inside a `T?`
> without a diagnostic. A sentinel lowering would print `true`, and **the two
> engines would part company** on the one program that distinguishes them.
> There is an agree test named for it.

A `foreign` holding 0 is likewise a *present* value: a C function may return 0
as a legitimate non-error token, and a program may want to pass 0 back in. Under
a niche, `optional_wrap` of a present zero would be byte-identical to `none`;
the interpreter (which carries a real `none` tag) would answer `false` and
codegen `true`. You would be rebuilding the precise divergence
`specs/agree.zig` already has a named test for.

**So: `foreign?` is `{i64, i1}`, exactly like every other optional. The niche
lives in the *ABI*, not in the Luce type.** C's encoding of absence is the
integer 0; Luce's is a bit; the extern boundary is the decoder between them:

- returning: `%null = icmp eq i64 %r, 0` → `{i64 %r, i1 %present}`
- passing: `select %present, %payload, i64 0`

One comparison, at a call that just crossed into C. Both engines share the one
decode rule.

### 1.4 It composes with machinery that already exists

```luce
extern func LLVMContextCreate() -> foreign?
extern func LLVMContextDispose(c: foreign)

class Context:
    handle: foreign                      # non-null by construction

    init(handle: foreign):
        self.handle = handle

    deinit:
        LLVMContextDispose(self.handle)

pub func context() -> Context!:
    let raw = LLVMContextCreate()
    if raw == none:
        error("LLVMContextCreate failed")
    return Context(handle = raw)         # narrowed: raw is foreign here
```

This is `FFI.md`'s own stated division of labour made mechanical — *"C's
errno-and-sentinel conventions are the wrapper's business, in Luce, where `T!`
lives"* — with the optional as the bridge. Note that `BINDING.md`'s
locals-and-parameters-only narrowing rule is a *feature* here: a `foreign?`
field would have to be bound to a local first, which is correct pressure toward
keeping fields non-null.

**Pitfalls, checked against Luce's actual rules rather than assumed:**

- `foreign??` — unrepresentable already (`TYPES.md`: one level of absence,
  `T??` cannot be written). No collapse question. Contrast Zig, where `??*u8` is
  16 bytes because the inner optional consumed the niche.
- `map[str, foreign?]` — already refused (`BINDING.md`: `map[K, V?]` is refused
  because `get` would answer `V??`). Pre-existing rule, not a new wart; store
  bare `foreign`, since the map's own absence *is* the absence.
- Comparison and printing — `foreign` is already comparable; `x == none` is the
  existing `is_none` intrinsic. Nothing new.

### 1.5 A second gap this closes

Today you cannot **pass** null to C either. `foreign?` in parameter position
fixes that with the same encode step and no additional design.

### 1.6 Blast radius

Grepping every `.luc` in the tree for `foreign` yields two files: `std/c.luc`
(three functions, which keep compiling unchanged) and the editor's syntax
keyword list. **There are no extern declarations in shipped `.luc` code at
all.** This is the cheapest moment this change will ever be available — the
migration cost Apple paid to annotate its SDKs is, for Luce today, one file.

Lexer/parser: none (`?` on a type already parses). Semantics: allow `?` on
`foreign` in extern signatures, refuse elsewhere at the boundary. MIR: a
per-slot nullable bit on the foreign-call instruction → **format bump**, no host
ABI bump (externs are direct calls, not host slots). Codegen: the icmp/select
pair. Oracle: the same decode after its thunk returns. Specs: null returned,
null passed, and **present-zero-is-not-none**.

---

## 2. Beautiful C imports

### 2.1 Ruling 0 — generate ahead of time; never import in the compiler

**Zig spent two years walking out of the room Luce is being tempted into.**
`@cImport` is being removed (issue #20630, PR "Remove cImport"), moved to a
standalone `translate-c` tool built on Aro. The stated motive: remove the
libclang dependency from the compiler binary, and fix caching. Andrew Kelley
acknowledged in-thread that `zig run` with `@cImport` *"will regress"* — they
paid a real convenience cost knowingly.

D's ImportC is the maximal opposite (`import foo;` on a `.c` file works because
the compiler *contains* a C compiler) and shows the permanent price: an external
preprocessor dependency, `const` semantics that silently differ from C, partial
macro translation.

`docs/FFI.md` already rules the same way. This design makes that a feature.

**The novel part — take Zig's discarded consolation prize and make it
mandatory.** From the same issue: *"the TranslateC build step can be enhanced
with advanced settings, such as namespace stripping and **validation of existing
bindings**."* So:

> The generated module embeds the hash of its header set, flags, target, and
> recipe. `luce build` re-hashes and **refuses to compile against a stale
> binding**: `sdl3 bindings are stale: run 'luce bind sdl3'`.

That is what makes committed, vendored bindings trustworthy (Odin's model)
without taking on Odin's maintenance burden. It is the single most valuable
mechanism in this section.

### 2.2 Ruling 1 — the boundary carries *shapes*, not addresses

Do not add a general raw pointer to Luce. Add the five shapes C APIs actually
use at their edges. This is the difference between Zig's `[*c]T` (honest, ugly,
permanently unsafe) and Swift's `Span`-from-`__counted_by` (annotated, safe,
native). Luce should land on the Swift side, because it has no `unsafe` culture
to fall back on.

| C shape | Luce spelling | Fact comes from |
|---|---|---|
| pointer to an opaque type | `foreign` / `foreign?` (§1) | header |
| `const char *` | **`cstr`** — parameter-only; `str` coerces, NUL temporary lives for the call | header |
| `T *out` | **`out w: i32`** → an extra returned value | recipe |
| `T *ptr, size_t n` | pass `array[T,_]` / `list[T]` whole | recipe: `counted by` |
| `struct S` by value | **`extern struct`** with target C layout | header |
| `R (*)(A, void *userdata)` | **`cfunc(A) -> R`**; generator emits the `userdata` trampoline | recipe |

`cstr` alone deletes the ugliest thing in the measured SDL example. `out` alone
deletes the second-ugliest, and lifts today's "an extern answers at most one
value" restriction in the one way that introduces no tuples — Luce already
receives multiple results by destructuring.

**Reading C-owned memory (§0.3) is the missing primitive underneath all of
this.** The Luce-shaped form is a **copy**, not a borrow:

```luce
c.bytes_at(ptr: foreign, count: u64) -> bytes
c.cstring_at(ptr: foreign) -> str!        # strlen, copy, UTF-8 validate
```

Copies need no borrow rules, no lifetimes, and no escape analysis, and they
match §21.4's own ruling: *"copied values when a foreign borrow cannot safely
escape."* `SDL_GetError()` becomes readable for two functions' worth of work.

### 2.3 Ruling 2 — four layers, of which two are generated

The design doc says raw / safe. Refine it: **the safe layer should be generated
too**, because Swift demonstrates that ~90% of "feels native" is mechanical.
Keep a fourth, hand-written file for the 10% that is genuine API design.

```
sdl3/
  raw.luc       generated, committed, never edited  — verbatim C names
  sdl3.luc      generated from raw.luc + the recipe — Luce-native names
  extra.luc     hand-written, re-exported           — iterators, conveniences
  sdl3.bind     hand-reviewed recipe                — the API-notes analogue
  raw.skipped   generated report: what was not bound, and why
```

**The recipe is the key idea, and it is Clang's API Notes lesson exactly.**
Swift cannot annotate headers it does not own, so it puts the annotations in a
versioned YAML sidecar (`Nullability`, `SwiftName`, `SwiftImportAs`,
`EnumKind`, …) applied with `-fapinotes-modules`. The annotations are **data,
not code, live outside the headers, and version separately.** That is the
difference between "we annotated SDL" (impossible) and "we annotate *our view
of* SDL" (a Tuesday).

```
library sdl3:
    strip SDL_                      # one declarative rule, like Odin's link_prefix
    style snake                     # applies to the SAFE surface only
    error from SDL_GetError()

    own SDL_Window:
        class Window
        release SDL_DestroyWindow

    func SDL_CreateWindow:
        makes Window
        fails when result == null

    func SDL_GetWindowSize:
        method Window.size          # import-as-member, cf. Swift SE-0044
        fails when result == false

    func SDL_PollEvent:
        rename next_event
        returns event?              # false means "no event", not "failure"

    flags SDL_WindowFlags:
        strip SDL_WINDOW_
```

Which yields a call site that is simply Luce:

```luce
import sdl3

func main() -> !:
    try sdl3.init(sdl3.InitFlags.video)
    let window = try sdl3.Window("Luce SDL3", 480, 320)
    let w, h = try window.size()

    var running = true
    while running:
        while let event = sdl3.next_event():
            if event.kind == sdl3.EventType.quit:
                running = false
        sdl3.delay(u32(16))
    # window closed by ARC in deinit
```

No `zstring`. No `with_bytes` closure. No `i64(...)` cast to satisfy a
hard-wired closure result. No 128-byte `list[u8]` filled by a `while` loop. No
manual little-endian tag decode. No `--link` on the command line — the manifest
`native:` block carries it, exactly as a Clang module map's `link` declaration
does.

### 2.4 Ruling 3 — naming

Swift's SE-0005 renamed essentially all of Cocoa and it remains the language's
most-cited painful migration: docs lagged, Stack Overflow answers stopped
compiling, and searching for a C symbol no longer found the Swift call. Odin
went the other way on purpose: *"Case notation should remain the same as the
original authors intended, to make porting code easier."*

Take the middle, which the two-module split makes available and which is
strictly better than either:

- **Namespacing does ~80% of the work for free.** `sdl3.CreateWindow` is already
  most of the readability win, costs nothing, and breaks nothing.
- **Strip exactly one declared prefix**, from the recipe. Not a heuristic — a
  string you wrote down. Same for enum-case prefixes.
- **Case-convert only on the safe surface.** Raw is a transcription and stays
  verbatim; safe is a designed API and reads like Luce.
- **Per-declaration `rename` from day one**, not after the first controversy.
- **Do not** synthesize prepositional argument labels or "omit needless words."
  That is the half of SE-0005 that caused the pain, it needs a curated English
  lexicon, and Luce's named arguments are not selector-shaped enough to benefit.
- **Every generated declaration carries `# C: SDL_CreateWindow` above it.** That
  answers Swift's grep problem for the price of one comment: the rename is
  visible in checked-in source, one hop from the call site. Swift's renames live
  inside a closed compiler; Luce's live in a file you can read.

### 2.5 What is automatic vs. recipe vs. hand-written

**Automatic** (header alone, must be right every time): C scalars → same-width
Luce scalars; `_Bool` → `bool`; `const char*` → `cstr`; `struct` by value →
`extern struct`; `enum` → Luce enum with algorithmic common-prefix stripping
(Swift's CP/EP algorithm is ~30 lines and is right); opaque pointer → `foreign?`
on returns; literal `#define`s → constants; module namespacing and the one
declared prefix strip; **staleness checking**. Variadics are never bound —
Swift does not import them either.

**Recipe-driven** (facts the header cannot express): ownership and release
function; nullability where unannotated; failure convention (`fails when result
== false | == null | < 0`) plus where the error text comes from; which `T*`
parameters are outputs; counted buffers; flag enums and open-vs-closed enums;
import-as-member; per-declaration rename and skip; callback `userdata` slot.

**Hand-written** (genuine API design): iterators and control-flow shapes;
anything lifetime-coupled beyond one owner; variadic and macro APIs re-expressed
at fixed arity; the recipe itself — reviewing it *is* the security boundary.

**Partial import must always succeed.** Zig's best idea is *demotion*: an
untranslatable construct is skipped, not fatal, and the pointer to it stays
usable as an opaque handle. `raw.skipped` makes that auditable:

```
SDL_Log                 variadic; hand-write a fixed-arity wrapper in extra.luc
SDL_MUSTLOCK(S)         function-like macro; not bound
SDL_PixelFormatDetails  contains a bitfield; struct not bound (pointer usable as foreign)
```

---

## 3. Merging the Objective-C step

### 3.1 The hypothesis was right

**Objective-C headers carry materially more machine-readable safety metadata
than C headers.** Clang recovers a full declaration graph — classes, protocols,
categories, properties, class-vs-instance methods, selectors, designated
initializers, lightweight generics — plus three things plain C simply does not
have:

- **Nullability is type information**, including at nested pointer levels
  (`_Nullable` / `_Nonnull`, `NS_ASSUME_NONNULL_BEGIN` regions).
- **ARC ownership conventions are executable compiler metadata** — the
  `init`/`copy`/`new`/`mutableCopy` naming family, `NS_RETURNS_RETAINED`,
  `ns_consumed`. The +0/+1 contract is machine-readable.
- **Blocks are typed foreign closures**, not opaque pointers, with a documented
  ABI.

`NSError **` is recognizable, though failure remains a convention rather than a
theorem. So: importing Objective-C *safely* is in real ways **easier** than
importing C — the header tells you things a C header never will.

### 3.2 The decision: generated thunk as a build artifact

> Build **option (b): a generated Objective-C/C++ shim, compiled as a
> content-addressed build artifact**. The C ABI stays inside the implementation;
> it disappears from the user's maintenance burden.

```text
header + module map + target SDK + recipe
  -> Clang AST -> FIIR
  -> generated .m/.mm thunk -> target Clang -> cached object
  -> generated raw Luce module -> generated/reviewed safe Luce wrapper
```

**This is the merge.** The two steps become one because the second one becomes
invisible — the shim is cached and keyed like an object file, not maintained
like source. The user writes Luce plus a recipe entry, and never sees a `.m`.

**Do not begin with direct `objc_msgSend` emission.** Swift proves direct
dispatch can be excellent — but Swift embeds Clang, has mature runtime
integration, and has spent compiler-*years* on target ABIs and ARC. For a
one-person team it would move a large target-specific project onto the critical
path *without improving the first user's source experience*. And the Apple arm64
variadic trap (§3.2 of the platform report) applies to every `msgSend` call:
Apple's own guidance is that you must cast to the callee's exact prototype.

Letting Clang own the dangerous parts — calling conventions, `objc_msgSend`
selection, ARC lowering, block ABI, C++ construction/destruction, native
exception syntax — also keeps **all Luce backends behind one flat ABI**, which
matters because the design doc explicitly refuses to *"depend on LLVM for the
meaning of native interop."*

**Option (b) is a permanent correctness baseline, not scaffolding.** A later
direct-dispatch path can optimize a proven ordinary subset and fall back to the
thunk whenever ABI, ownership, callback, or exception cases are not proven. It
is also the permanent answer for C++, given the decision not to absorb C++
inheritance, templates, or exceptions into the language.

This revises something I said earlier in this session: I had suggested the
name/symbol split would enable direct ObjC dispatch without shims. It would —
but that is the wrong road. **The symbol split is still worth having** (raw-layer
naming, C symbols that are not valid Luce identifiers, one symbol at several
prototypes) and §3.4 already licenses it; it is simply not the ObjC answer.

### 3.3 "Make it automatic by writing Luce" — the coherent version

The instinct is right, with one correction: the shim cannot be *written* in
Luce, because its job is to speak a language Luce cannot speak. `export c` is
the **reverse** direction — it is how a generated ObjC block or C++ callback
adapter calls *back* into Luce, and the generator can synthesize those export
stubs itself.

But the strong version of the idea is exactly right: **the user writes a
declarative binding description, and the toolchain generates whatever native
glue is required.**

```toml
[native.foundation]
language = "objective-c"
module    = "Foundation"
frameworks = ["Foundation"]
expose = ["NSURL", "NSFileManager"]
```

Declarative rather than imperative matters, for reasons that are all
operational:

- it is target-independent until Clang resolves the declaration;
- the compiler can **validate it against the AST** and report stale selectors or
  types;
- changes participate in the content cache key and the API diff;
- documentation can show which fact came from the header, from Clang
  conventions, from API Notes, from the recipe, or from a generator default;
- **one intent generates `.m`, `.mm`, C declarations, the raw Luce module, the
  safe wrapper, tests, and the ABI report.**

That last line is the whole answer to "merge these steps." It is the same recipe
file as §2.3, with `language = "objective-c"` instead of `"c"`.

### 3.4 The hard edges, which any option must answer

- **ARC-to-ARC is ownership *composition*, not one shared ARC.** Two retain/
  release systems meet at the boundary. Normalize every escaping object to an
  explicit **+1 opaque handle**; the Luce wrapper class's `deinit` performs the
  release. Never let a +0 borrow escape the call.
- **Autorelease pools are a runtime-entry contract**, not a per-call detail —
  drawables and temporaries leak without a pool around the frame.
- **Callbacks from foreign threads** attach only long enough to copy validated
  sendable arguments into the owning worker's queue.
- **Exceptions must terminate or translate *inside* the native glue.** No ObjC
  or C++ exception may unwind a Luce frame.
- **Objective-C is dynamic** — categories, swizzling, KVO cannot be statically
  verified. The binding describes the static surface and says so.

### 3.5 Build this first

Not a general ObjC surface, and not `objc_msgSend` lowering. **One Foundation
vertical slice** on macOS arm64, through a generated `.m` cache artifact:

- `NSString` ↔ Luce `str` copying,
- `NSURL` ownership and nullability,
- one `NSFileManager` call with `NSError **` → `T!`.

Blocks and foreign threads stay deliberately out of scope. That slice forces the
design to prove parsing, module maps, target configuration, selectors, ARC
+0/+1, pool timing, error conversion, C ABI normalization, caching, linking,
safe wrappers, and diagnostics — all at once, on the smallest possible surface.

**The test of success**, stated well: *the slice should be pleasant to use, and
unpleasant to debug only until `--emit-glue` is invoked.* If it requires the user
to edit generated Objective-C, duplicate selectors, or understand
`__bridge_retained`, the two steps have not actually been merged.

---

## 4. None of this needs a new language concept

Every primitive proposed here is already licensed by `LUCE_LANGUAGE_DESIGN.md`:

| Primitive | Already stated |
|---|---|
| `foreign?` at the boundary | §21.4 — *"`T?` for nullable pointers"* (line 1891) |
| name/symbol split | §3.4 — *"generated idiomatic names while retaining the foreign spelling in metadata"* |
| copying reads | §21.4 — *"copied values when a foreign borrow cannot safely escape"* |
| recipe-driven bindings | §21.4 (ownership recipes), §21.15 (`luce bind` UX) |
| generated thunks as artifacts | §21.6 — C++ via *"generated C ABI thunks"*, now applied to ObjC too |
| `cstr` / `out` / `extern struct` | §21.3 — importer supports *"pointers, arrays, function pointers, opaque types"* |

Two caveats worth naming. **`docs/FFI.md` (stage-0) has no nullability ruling at
all** — its four ruled details are spellings, `str` never crossing implicitly,
no extern defaults, and link-time-only symbols. And Tier-1 was narrowed to
32/64-bit widths deliberately, *"which keeps the boundary correct with no
per-parameter attribute machinery"* — so widening scalars later buys
`signext`/`zeroext` attributes. Not free, but small.

---

## 5. Sequencing

Highest value per byte first. Steps 1–4 are language changes; step 5 is a tool
and **must stay one.**

| # | Change | Why here |
|---|---|---|
| 1 | **`foreign?` + boundary decode** | every pointer-returning C API is unfailable without it; nothing in the tree breaks; pure language work |
| 2 | **`c.bytes_at` / `c.cstring_at`** | the boundary is write-only today; two functions make C-owned memory readable |
| 3 | **`cstr` with `str` coercion** | deletes `zstring` + `with_bytes` from every call site that passes text — the change that most alters how the FFI *feels* |
| 4 | **`out` params, then `extern struct`** | ends byte-by-byte decoding; `extern struct` is the Tier-2 gap and the thing that makes generated bindings worth generating |
| 5 | **`luce bind` + recipe + manifest `native:`** | only worth building once 1–4 exist, or the generator can only emit the ugly form |
| 6 | **ObjC vertical slice** (§3.5) | proves the thunk-as-artifact architecture on the smallest real surface |
| 7 | **`cfunc` + `userdata` trampolines** | needed for real event/audio APIs, not for a first native-feeling app |

Steps 1–4 are arguably *completions of the already-landed Tier-1* rather than
new capability — which matters, because `SELFHOST.md` freezes capability and
permits purely additive change. That is the owner's call, and it is the same
question raised as #6 in the platform report.

---

## 6. Open decisions

1. **Non-null default, or nullable default, for `foreign`?** (§1.2) — terse
   common case vs. never-surprising boundary.
2. **Does the safe layer get generated, or hand-written?** This design says
   generated-from-recipe with a hand-written `extra.luc`; the design doc
   currently says *"reviewed ordinary Luce API."*
3. **Case conversion on the safe surface — yes or no?** Swift says yes and
   bled; Odin says no on purpose.
4. **Is libclang an acceptable hard dependency of `luce bind`?** (It is *not* a
   dependency of `luce` itself under Ruling 0.)
5. **`str?` / `bytes?` at the boundary** — deliberately out of scope here.
   `str` crosses as pointer+length, so a null `str?` encodes as `(0,0)`, which
   some C APIs distinguish from an empty string and others do not. That
   ambiguity deserves its own ruling rather than being smuggled in with
   `foreign?`.

---

## 7. Sources

**Nullability:** [Apple — designating nullability in ObjC APIs](https://developer.apple.com/documentation/swift/designating-nullability-in-objective-c-apis) ·
[Rust `std::option` representation](https://doc.rust-lang.org/std/option/#representation) ·
[Rustonomicon — FFI](https://doc.rust-lang.org/nomicon/ffi.html) ·
[Clang nullability attributes](https://clang.llvm.org/docs/AttributeReference.html)

**Import UX:** [Zig langref — C](https://ziglang.org/documentation/master/#C) ·
[ziglang/zig#20630 — move `@cImport` to the build system](https://github.com/ziglang/zig/issues/20630) ·
[ziglang/translate-c](https://github.com/ziglang/translate-c) ·
[Clang Modules](https://clang.llvm.org/docs/Modules.html) ·
[Clang API Notes](https://clang.llvm.org/docs/APINotes.html) ·
[CToSwiftNameTranslation](https://github.com/swiftlang/swift/blob/main/docs/CToSwiftNameTranslation.md) ·
[HowSwiftImportsCAPIs](https://github.com/swiftlang/swift/blob/main/docs/HowSwiftImportsCAPIs.md) ·
[SE-0005](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0005-objective-c-name-translation.md) ·
[SE-0044](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0044-import-as-member.md) ·
[Swift memory-safety vision](https://github.com/swiftlang/swift-evolution/blob/main/visions/memory-safety.md) ·
[D ImportC](https://dlang.org/spec/importc.html) ·
[Nim FFI](https://nim-lang.org/docs/manual.html#foreign-function-interface) ·
[Odin vendor/sdl3](https://github.com/odin-lang/Odin/tree/master/vendor/sdl3) ·
[rust-bindgen](https://rust-lang.github.io/rust-bindgen/introduction.html)

**Objective-C / generated glue:** [Clang ARC spec](https://clang.llvm.org/docs/AutomaticReferenceCounting.html) ·
[Blocks ABI](https://clang.llvm.org/docs/Block-ABI-Apple.html) ·
[Swift ObjC interop notes](https://github.com/swiftlang/swift/blob/main/docs/ObjCInterop.md) ·
[Swift C++ interop](https://www.swift.org/documentation/cxx-interop/) ·
[Rust cxx](https://cxx.rs/) · [autocxx](https://google.github.io/autocxx/) ·
[Kotlin/Native cinterop](https://kotlinlang.org/docs/native-c-interop.html) ·
[Dart ObjC interop](https://dart.dev/interop/objective-c-interop) ·
[Go cgo](https://go.dev/src/cmd/cgo/doc.go)

The full Codex report on the Objective-C question is beside this file as
`NATIVE_INTEROP_CODEX_REPORT.md`.
