# Tier-1 FFI — extern declarations over the C ABI (design draft)

**Status: plan, awaiting owner ratification of the details**
(docs/SELFHOST.md Phase 2; the direction — ungated Zig-style
declarations with Swift-style safety visibility — is owner-ratified
2026-08-19). Nothing here is current behavior.

## The declaration

An `extern` declaration names a foreign function and its C shape, in
ordinary Luce source, anywhere:

```text
extern func getpid() -> i32
extern func memcmp(a: bytes, b: bytes, count: u64) -> i32
extern func LLVMContextCreate() -> foreign
extern func LLVMModuleCreateWithName(name: str) -> foreign
```

- No body, no importer, no headers: the author writes the shape and
  owns its truth, exactly as in Zig. A wrong shape is undefined
  behavior at the boundary and the docs say so plainly.
- The **type vocabulary is closed** in Tier 1: the fixed-width
  integers and floats (which already map to C exactly), `bool`,
  `str`/`bytes` (passed as pointer+length pairs by the compiler — the
  callee sees C's two-argument convention, spelled once in the docs),
  buffer views via the scoped form below, and `foreign`.
- **`foreign` is the opaque handle type**: a token a program may hold,
  store, pass back, and compare for identity — never dereference,
  never do arithmetic on. It is the `LLVMValueRef` shape and covers
  the great majority of real C APIs. It is a value type (copies), and
  it deliberately has no ARC: what it points at is the foreign
  library's to manage, and a wrapper class with a `deinit` calling the
  library's destroy function is the ownership idiom (`files.File`'s
  pattern, written in user code).

## Scoped buffer access

No raw pointer exists as an ordinary value. A C function that reads or
fills memory receives it through a scope:

```text
var buffer = array[u8](4096)
let landed = os.with_bytes(buffer, func(p: foreign, count: u64) -> i64:
    return read_fd(0, p, count)
)
```

`with_bytes` pins the buffer for exactly the closure's extent and
hands the callee an address-carrying `foreign`; the token must not
outlive the scope, and the docs state that escaping it is undefined
behavior (Tier 1 does not police it — Tier 2's borrow rules are a
separate future design). This is Swift's `withUnsafeBytes` shape on
Luce's existing closure machinery.

## Semantics at the boundary

- **Extern calls are effects.** They run under the effect lock by
  default; an `extern blocking func …` form opts a call out of the
  lock and takes on the socket slots' contract: the callee must be
  thread-safe, because workers will reach it concurrently.
- **Guarantees end at the boundary, loudly.** The leak census does not
  count foreign memory; a foreign crash is a process crash; checked
  arithmetic, traps, and the census resume the instant the call
  returns. One paragraph in MEMORY.md and one on the site say exactly
  this.
- **Fallibility is not assumed.** An extern function returns what its
  shape says; C's errno-and-sentinel conventions are the wrapper's
  business, in Luce, where `T!` lives.
- **Externs do not cross workers as values** (function values already
  do not), and a `foreign` token crosses only as the value it is —
  whether that is meaningful is the library's contract, not the
  language's.

## Both engines, one dispatch

The interpreter reaches externs through a runtime shim —
`runtime/ffi.zig`, dlopen + libffi in the oracle-carrying test binary
(which already links libLLVM; the shim ships in nothing) — while
generated code emits a direct call and the linker resolves the symbol.
One dispatch semantics, two emission strategies, held together by the
differential exactly as every other feature is. The spec world gets a
harness-built test library the way it has a scripted filesystem.

## Linking

The symbol has to come from somewhere, and the answer is the build
system that already exists: `build.luc` compiles C sources and `.s`
shims as command steps, and the dropped `--link OBJ` option revives so
foreign objects and `-l` requests join the native link. `luce build
FILE.luc --link foo.o` is the file-form spelling; a plan's `luce` step
gains a `links` list. Inline assembly stays out (a shim is the
answer); a C header importer stays out (a `translate` *tool* may emit
extern `.luc` files later).

## Blast radius (change-map rows)

Lexer/parser (`extern`, `foreign`, `blocking`), semantics (closed type
vocabulary at the boundary, effect classification), HIR/MIR (a
foreign-call instruction carrying symbol + signature; format bump),
verifier (hostile signatures), runtime shim + oracle dispatch, codegen
(declare + call + str/bytes splitting), `--link` in the CLI and plan
executor, both-engine specs against a harness library, docs
(LANGUAGE.md boundary section, MEMORY.md, site pages), grammar and
highlighting tables, TextMate regeneration. The host ABI table is
untouched — externs are direct calls, not host slots.

## Open details for ratification

1. The spellings: `extern func` / `foreign` / `blocking` as above, or
   other words.
2. `str` at the boundary: pointer+length pair (proposed) vs. requiring
   the caller to NUL-terminate through `bytes` explicitly.
3. Whether `extern` declarations may carry default arguments (proposed:
   no — the C shape is the whole truth).
4. Library naming: symbols resolve at link time only (proposed), or an
   optional `extern("sqlite3") func …` load-time annotation from day
   one.
