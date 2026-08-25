# The C boundary — extern declarations over the C ABI

**Status: 0.20 shipped the narrow core (landed 2026-08-20): `extern func`
over 32/64-bit scalars + `foreign`, ≤8 arguments, `--link`, the scoped
buffer forms, build-plan links.  This revision is the 0.21 completion,
ruled by the owner 2026-08-24.**  The rulings: `foreign?` with the
`null_foreign` trap; named handle types (`extern type`); seamless `str`
in both directions — **which deliberately reverses the 0.20 ruling that
`str` never crosses implicitly**; reading C-owned memory; `out`
parameters; the full C scalar set with no arity cap; `extern struct`
crossing by pointer; capture-free C function values; extern globals.
Deliberately deferred to the binding-generator era: by-value aggregates,
variadics, bitfields, and ARC-carrying callback trampolines.

## The friction rule

The boundary is governed by one principle, sorted by frequency:

1. **The common shape is invisible.** Scalars, strings, structs, null,
   out-parameters, named handles: the declaration states the C shape,
   the compiler does the translation, the call site is ordinary Luce.
2. **The rare shape is one visible verb.** Buffers, views, reading raw
   memory, ownership transfer: never invisible, never more than one
   named scoped call (`c.with_bytes`, `c.bytes_at`).
3. **The exotic shape is generated away.** Variadics, bitfields,
   by-value aggregates: `luce bind` emits a shim; user code never sees
   it.

Two laws over all three: **nothing crosses silently wrong** — a wrong
crossing stops with a Luce trap at the call, not a corrupt pointer
inside C — and **every translation is inspectable**: what the compiler
does at the boundary is stated here, once, and generated bindings are
committed files a person can read.

## The declaration

```text
extern type Window
extern type Renderer
extern type Device = i32          # an integer-shaped handle (CUDA device)

extern func getpid() -> i32
extern func SDL_GetError() -> str
extern func SDL_CreateWindow(title: str, w: i32, h: i32, flags: u64) -> Window?
extern func SDL_CreateRenderer(window: Window, name: str?) -> Renderer?
extern func SDL_GetWindowSize(window: Window, out w: i32, out h: i32) -> bool
extern func SDL_DestroyWindow(window: Window)
extern blocking func SDL_Delay(ms: u32)
extern var SDL_version_number: i32
```

No body, no importer, no headers: the author writes the shape and owns
its truth, exactly as in Zig.  A wrong shape is undefined behavior at
the boundary and the docs say so plainly — except where a check is
cheap, in which case the boundary checks (`null_foreign`, UTF-8
validation below).

## Named handles — `extern type`

`extern type Name` declares a **nominal opaque handle**: a value type
with no ARC, no members, no arithmetic, comparable with `==`/`!=`, and
usable exactly where its name appears in extern signatures.  Passing a
`Window` where a `Renderer` is expected is a compile error — the type
system now carries what C itself carries in its pointer types.

- The default representation is the pointer-sized token (what `foreign`
  is today).  `extern type Name = u32` (or `i32`, `u64`, `i64`)
  declares an **integer-shaped** handle with that exact C width — CUDA
  device ordinals are a C `int`, SDL IDs are `Uint32`, and forcing them
  through a 64-bit token would itself be an ABI bug.
- `foreign` remains the untyped escape hatch and the currency of
  `std.c`.  A named handle converts to `foreign` explicitly
  (`foreign(w)`), never implicitly, and never backwards.
- Each `extern type` is distinct from every other and from all integers.

## Absence — `foreign?` and the `null_foreign` trap

C signals failure by returning null.  Luce's absence is `none`.  The
boundary is the translator:

- A **pointer-shaped** handle type (or `foreign`) marked `?` in an
  extern signature decodes C's 0 into `none` on the way in and encodes
  `none` as 0 on the way out.  One comparison per crossing.
  `Window?` is an ordinary optional — `{token, present}` like every
  other `T?`; there is no sentinel representation, because a present
  zero and `none` must stay distinguishable on both engines.
- A pointer-shaped handle **without** `?` is a contract: zero never
  crosses here.  The boundary enforces it — a bare handle carrying 0
  across, in either direction, **traps `null_foreign`** at the call, in
  every profile.  Same cost as the optional decode; same philosophy as
  checked arithmetic.  The mis-declared extern produces a Luce trap
  with a traceback, never a corrupt pointer inside C.
- **Integer-shaped** handles take no trap and no `?`-decode: 0 is an
  ordinary value (CUDA device 0 is the first GPU).  Their optionals, if
  ever needed, are ordinary Luce optionals with no boundary meaning.
- There is no `null` literal.  Absence is `none`; the check reads as it
  always has: `let w = SDL_CreateWindow(...) else error(last_error())`.

## Text — `str` crosses, both directions

The 0.20 ruling ("`str` never crosses implicitly") is reversed: text is
the single most common boundary shape and belongs in tier 1 of the
friction rule.

- **Parameter `str`**: the compiler materializes a NUL-terminated
  temporary (the bytes plus one zero), passes its address as C's
  `const char *`, and releases it when the call returns.  **Borrowed
  for the call only** — a callee that keeps the pointer is undefined
  behavior; an API that stores its argument needs a wrapper that keeps
  the buffer alive (binding-recipe territory).
- **Parameter `str?`**: as above, with `none` crossing as C's NULL.
- **Result `str`**: the callee's `const char *` is copied immediately —
  NUL-scanned, bytes copied, UTF-8 **validated**.  Invalid UTF-8 traps
  (`invalid_utf8`): a `str` is valid UTF-8 by contract and the boundary
  does not launder that contract.  A C API that returns arbitrary bytes
  is not a `str` API — read it with `c.bytes_at`.
- **Result `str?`**: NULL decodes to `none`; otherwise as above.
- The pointer+length pair form (`bytes` parameters splitting into two C
  arguments) from the original draft stays **out**: two conventions for
  text is one too many, and length-carrying buffers are `c.bytes_at` /
  `c.with_bytes` business.

## Reading C-owned memory

The 0.20 boundary was write-only.  Two std additions make it readable —
copies, not borrows, per the tier-2 rule:

```text
c.bytes_at(pointer: foreign, count: u64) -> bytes   # copy count bytes out
c.cstring_at(pointer: foreign) -> str               # NUL-scan, copy, validate
```

`cstring_at` exists for the raw layer and generated code; hand-written
externs should prefer declaring `-> str` and letting the boundary do it.
Both trap `null_foreign` on a zero pointer.  `with_bytes` /
`with_bytes_foreign` / `zstring` remain for outbound buffer scopes, and
`Builtin.buffer_address` additionally accepts `array[T, _]` so a dense
array's storage can reach C (the BLAS door).

## Out parameters

C's "pass a pointer, I fill it" convention becomes extra results:

```text
extern func SDL_GetWindowSize(window: Window, out w: i32, out h: i32) -> bool
extern func cuDeviceGet(out device: Device, ordinal: i32) -> i32

let ok, w, h = SDL_GetWindowSize(window)
let status, device = cuDeviceGet(0)
```

- An `out` parameter takes no argument at the call; the compiler
  allocates the slot, passes its address, and appends the value to the
  results **in declaration order after the declared return**.
- Legal `out` types: the scalars, named handles, and `extern struct`s.
- The received values are ordinary Luce values; multiple results are
  received by the existing destructuring, not tuples.

## Scalars and arity

The type vocabulary completes to the full fixed-width set in **both**
positions: `u8 u16 u32 u64 i8 i16 i32 i64 f32 f64 bool`.  Narrow
integers carry the target's sign/zero-extension attributes; the
compiler derives them from the ABI, never hardcodes them.

**There is no argument-count cap.**  The 0.20 nine-by-three thunk table
is retired; the target C ABI decides register and stack assignment,
exactly as it does for C.  The oracle's shim generalizes (libffi,
linked explicitly into the oracle-carrying test binaries and into
nothing that ships — macOS carries it in the SDK, Linux uses the
system library).  Specs deliberately cover 0, 1, 8, 9, 11, and 14
arguments — `cuLaunchKernel` is 11 and `cblas_dgemm` is 14, and both
must be declarable verbatim.

## Structs — `extern struct`, crossing by pointer

```text
extern struct Rect:
    x: i32
    y: i32
    w: i32
    h: i32

extern func SDL_GetRectUnion(a: Rect, b: Rect, out result: Rect) -> bool
```

- An `extern struct` is an **ordinary value struct** whose fields
  additionally have **C's layout**: declaration order, the target's
  alignment and padding, no reordering.  Memberwise construction,
  field access, copies, equality, printing and zero values are the
  ordinary struct machinery; the C byte form exists only at a
  boundary crossing, where the call site materializes the fields at
  their C offsets and reads them back the same way.  Fields are the
  boundary scalars and the handles — `foreign` or named — and nested
  extern structs, inline.  **Fixed-size array fields are deferred to
  the binding generator**: stage-0 arrays carry runtime shape and
  have no C-layout form, so a declaration naming one is refused
  saying so.
- **Crossing is by pointer, both directions.**  A parameter of extern
  struct type passes the struct's C bytes' address (C's `const T *`),
  **borrowed for the call** — a callee that keeps the pointer is
  undefined behavior; an `out` parameter passes a writable address
  (C's `T *`) and each field is read back after the call.  This
  covers SDL and Vulkan-shaped APIs completely.  **By-value aggregate
  passing and returning is deliberately not in 0.21**: it requires
  per-target ABI classification (the SysV eightbyte algorithm and
  kin), and the binding generator's C shims are the planned road.  A
  declaration that would require it is refused with a message saying
  exactly that.
- **A field read carries no boundary decode.**  A pointer-shaped
  handle field read back out of an `out` struct is a field read, not
  a boundary slot: C's null arrives as an ordinary zero value and
  takes no automatic `null_foreign` trap — the trap belongs to bare
  handle *slots*, where the phase-1 rules apply whole.
- Unions and bitfields are not declarable; the generator's shims and
  accessors are the road (SDL_Event decodes through generated
  accessors, not a union type).

## C function values — `cfunc`

```text
extern func SDL_AddTimer(interval: u32, callback: cfunc(u32, foreign) -> u32,
                         userdata: foreign) -> u32
```

- `cfunc(params) -> R` is a boundary-only function type: C's function
  pointer.  A **capture-free** Luce function or lambda converts to it
  at an extern call site; anything that captures is refused with the
  reason (C has no environment slot — the trampoline machinery that
  carries a closure through `userdata` arrives with `luce bind`).
- A `cfunc` value may also appear as an extern **result**, an extern
  struct **field**, and be **called** with ordinary call syntax — this
  is the function-pointer-call primitive (`vkGetInstanceProcAddr`,
  `OrtApi`), and its calls carry the same boundary semantics as any
  extern call.  A null `cfunc` is expressed as `cfunc(...)?` with the
  same decode as handles.
- The callback runs on whatever thread C calls it from; a capture-free
  function touches no Luce heap and needs no runtime attach.  The
  ARC-carrying form is the generator's problem, later, by design.

## Globals — `extern var`

`extern var name: T` binds a C global of boundary-scalar or handle
type — `foreign` or named; no `str`, no optionals, no aggregates,
because a C global loads and stores one word.  It shares the value
namespace like a file-scope constant, takes `pub` like any
declaration, and writing follows `var` mutability.  Reads and writes
are direct loads and stores of the symbol with **bare semantics**: no
traps and no `?` decode in either direction — a pointer-shaped
handle's zero is a value here.  No initializer: the C side owns the
value.  Rare, but real (`stdout`-shaped APIs); anything fancier is a
shim.

## Semantics at the boundary (unchanged from 0.20)

- **Extern calls are effects**; `extern blocking func` opts out of the
  effect lock and takes the thread-safety contract.
- **Guarantees end at the boundary, loudly.**  The leak census does not
  count foreign memory; a foreign crash is a process crash; checked
  arithmetic, traps, and the census resume the instant the call
  returns.
- **Fallibility is not assumed.**  `T!` is the wrapper's business —
  now one line away: `let w = create() else error(last_error())`.
- **Externs do not cross workers as values**; a handle crosses as the
  value it is, and whether that means anything is the library's
  contract.

## Both engines, one dispatch

Generated code emits direct calls (and address-of for `out`/struct
slots); the oracle's `runtime/ffi.zig` shim generalizes from the fixed
thunk table to libffi-backed dispatch so every declarable signature
runs on both engines.  The differential suite holds them together, as
everywhere.

## Linking (unchanged)

`--link` on the CLI, `links` in a build plan, `LUCE_CC` for the driver.
A manifest `native:` block is the binding generator's arrival, not
0.21's.

## Blast radius (change-map rows)

Lexer (`out` contextual, `cfunc`), parser/AST (`extern type`,
`extern struct`, `extern var`, `?` in extern signatures, `out`
parameters, `cfunc` types), semantics (handle nominality, boundary type
rules, capture-free check), HIR, MIR (foreign-call signature gains
per-slot shape/nullable/out facts; struct layout table; **format
bump**), verifier (hostile signatures for every new shape), runtime
shim (libffi dispatch, `null_foreign`/`invalid_utf8` traps, string
materialization), codegen (decode/encode pairs, slot allocation,
extension attributes, struct layout via the target's data layout),
both-engine specs per feature, docs (LANGUAGE.md, MEMORY.md, STD.md,
site), grammar/highlighting/TextMate.  Host ABI table untouched —
externs remain direct calls.

## Deliberately deferred (the generator's arrival, not 0.21)

By-value aggregates; variadics; bitfields and unions as declarable
types; ARC-carrying callback trampolines; the header importer
(`luce bind`) and binding recipes; manifest-declared native
dependencies.  Each is designed in `../../luce`-side documents and
lands with the library that forces it.
