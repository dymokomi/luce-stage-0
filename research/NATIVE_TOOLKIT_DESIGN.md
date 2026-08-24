# Making C libraries feel native in Luce

*Plain-language plan. The detailed research lives in
`NATIVE_TOOLKIT_CODEX_REPORT.md`, `NATIVE_INTEROP_DESIGN.md`, and
`NATIVE_PLATFORM_RESEARCH.md` — this file is the version you read first.*

Two questions:

1. What is `foreign?`, and how do you check for null in Luce?
2. What do we need to build so that SDL3, Metal, CUDA, and friends are
   *easy* in a Luce project?

---

## Part 1 — Null, explained simply

### What `foreign` is

When Luce calls a C function that returns a pointer, Luce doesn't try to
understand that pointer. It just holds onto it and gives it back to C
later. `foreign` is that ticket — like a coat-check ticket: you can't open
it, you can't look inside it, but you can hand it back and get your coat.

### The problem

C functions signal failure by returning NULL. Today Luce has no way to
notice that. If `SDL_CreateWindow` fails, you get a dead ticket and the
crash happens later, somewhere inside C, with no useful error message.

### The fix: use `?`, which Luce already has

Luce already has optionals: `i64?` means "a number, or nothing (`none`)".
We use exactly that. If a C function can return NULL, you declare it with
a `?`:

```luce
extern func SDL_CreateWindow(title: cstr, w: i32, h: i32, flags: u64) -> Window?
```

At the border, Luce quietly translates: C's NULL becomes Luce's `none`.
No new keyword. **There will never be a `null` in Luce** — `none` already
means "nothing is here."

### How you check it

Four ways, and three of them work in stage-0 *today* (I ran them):

```luce
# 1. "Give me the window or fail this function" — one line
let window = SDL_CreateWindow(...) else error("no window")

# 2. "Give me the value or use a default"
let count = parse_i64(text) else 0

# 3. Plain check
if window == none:
    return
# past this line, Luce knows window is real

# 4. A polling loop (keep asking until there's nothing)
var event = next_event()
while event != none:
    handle(event)
    event = next_event()
```

That first line is the whole story. "Call C, and if it failed, stop here
with a clear error." One line.

### The safety net

What if you declare a function as *never* returning null — and C returns
null anyway? Instead of letting the broken ticket travel through the
program and explode later, **Luce stops immediately, at that exact call,
with a clear message.** Same thing Luce already does when a number
overflows or an index is out of range. Cost: one comparison. So:

- write `Window?` when null is a real possibility → handle it with `else`
- write `Window` when null should never happen → Luce enforces it for you

Either way, you can't be silently handed a dead ticket.

### One more fix while we're here: name the tickets

Today every C handle has the same type. A window, a renderer, a GPU
device — all just `foreign`. So you can pass a window where a renderer
belongs and Luce won't blink. That's *worse* than C itself, which does
tell them apart.

The fix is to let a binding declare named handle types:

```luce
extern type Window
extern type Renderer

extern func SDL_CreateRenderer(window: Window) -> Renderer?
```

Now mixing them up is a compile error. It costs nothing at runtime — it's
just a name. (One care point from the research: different libraries use
different sizes for their handles — CUDA device IDs are 32-bit, SDL IDs
are 32-bit, most others are pointer-sized — so a named handle records its
real size instead of assuming everything is 64 bits.)

---

## Part 2 — What we build so libraries are easy

### The idea in one sentence

Look at what each library actually needs, build exactly that, and let
each library be the test that proves its feature works.

### What each library needs

**SDL3 (windows, input, sound).** Null handles, C strings, C structs,
decimal-number arguments. Nothing exotic. **This is the first target** —
I already ran a real SDL3 window and event loop from Luce; it works, it's
just ugly. The features below make it pretty.

**Metal (Apple graphics).** Metal is Objective-C, which Luce will never
speak directly. The plan: Luce's tooling *writes the small translation
file for you*, compiles it, and hides it — exactly like the compiler
already hides object files. You write Luce and a few lines of config. You
never see Objective-C.

**CUDA (NVIDIA GPU compute).** Surprisingly friendly — it's almost all
numbers and handles. It needs three things we don't have: functions with
more than 8 arguments (one CUDA call takes 11), decimal numbers as
arguments, and a way to *read* memory that C hands back. Plus a build
step that compiles GPU kernels. One catch: **CUDA doesn't exist on Mac**,
so this work needs a Linux machine to run on.

**Vulkan (cross-platform graphics, the hard way).** Needs one genuinely
new feature: calling C *through a function pointer* instead of by name.
That's real work, and nothing else on this list needs it — so we defer
it. (When we do build it, Vulkan's API comes as a machine-readable file,
so its bindings can be fully generated.)

**Everything GPU** needs a shader pipeline: compile the shader at build
time, embed the result bytes in the program. That's a build-system
feature, not a language feature — a build step produces a tiny generated
module with the bytes in it.

### The language changes (all small)

In build order. Each one lands together with the library that needs it —
nothing gets built speculatively.

1. **`?` on C functions** — null becomes `none`, plus the safety-net trap.
2. **Named handle types** (`extern type Window`) — no more mixed-up handles.
3. **Reading C memory** — two functions that copy bytes/strings *out* of
   C-owned memory. (Today Luce can hand memory to C but never read what C
   returns — the border is one-directional.)
4. **`cstr`** — pass a Luce string where C wants a string, directly.
   Deletes the clumsy convert-then-wrap dance from every call.
5. **Out-parameters** — C loves "give me a pointer and I'll fill it in."
   These become ordinary extra return values.
6. **Full number support** — decimals as arguments, small integers, and no
   argument-count limit. (The limit shouldn't move from 8 to 16; it
   should just not exist — the C rules of the target machine decide.)
7. **C structs** — declare a struct with C's layout, read its fields. Ends
   the current practice of decoding structs byte-by-byte.
8. **Callbacks** — let C call back into Luce safely.
9. **Function-pointer calls** — the Vulkan feature. Designed now, built
   last.

Plus one substrate piece the research flagged as missing: a small set of
*generated-code-only* memory operations (stable slots, typed load/store,
scoped views) so that the binding generator can express things like
CUDA's argument arrays and Vulkan's linked structs. Ordinary programs
never touch these — only generated binding files do.

### The tools

1. **`luce bind`** — reads a C library's headers, generates the Luce
   bindings. You review a small "recipe" file (which functions can fail,
   who owns what); the generator does the rest. Bindings are committed,
   and the build *refuses* to run if they're stale.
2. **The Objective-C bridge** — same generator, but it also writes and
   compiles the hidden translation file. This is how Metal gets easy.
3. **Dependencies in the manifest** — a package says "I need SDL3" and the
   build fetches, builds, and links it. No `--link` flags by hand.
4. **The asset pipeline** — build steps that compile shaders/kernels and
   embed the bytes.
5. **`luce doctor`** — before anything fails mysteriously, check the
   machine: is Xcode there? the CUDA toolkit? the Vulkan SDK? Say what's
   missing in plain words.
6. **A conformance check for the C border** — a test suite that calls C
   and gets called back, on every supported platform, so we *know* the
   argument-passing rules are right instead of hoping.

### The order, with the demo that proves each step

| Step | Demo that proves it |
|---|---|
| 1. Null + handles + strings + reading | The SDL3 window demo, rewritten — no ugly code left |
| 2. Out-params + full numbers | SQLite: open a database, insert, query (teaches error handling and ownership) |
| 3. Structs + the binding generator | `luce bind sdl3` regenerates what we hand-wrote, and the demo still runs |
| 4. Asset pipeline | A triangle on the GPU via SDL_gpu — one Luce source, runs on Mac (Metal) and Linux (Vulkan) |
| 5. Objective-C bridge | A small Metal demo with zero visible Objective-C |
| 6. CUDA slice | `saxpy` on a Linux runner: allocate, upload, launch kernel, read back |
| 7. Function-pointer calls | ONNX Runtime answering an inference; then Vulkan as the stress test |

### Decisions needed from you

1. **The safety net** (trap when a "never null" function returns null) —
   yes or no? *My recommendation: yes. It's what makes the terse default
   safe.*
2. **Luce Next dropped `else`.** The new language spec removed the
   `x else fallback` / `else error(...)` forms — but that one-liner is
   exactly what makes C code pleasant, and stage-0 has it today. Without
   it, epoch-1 boundary code gets *worse* than stage-0's. Bring `else`
   into Luce Next? *My recommendation: yes, unchanged.*
3. **Named handles in stage-0 now, or epoch-1 only?** *Recommendation:
   now — it's additive, and the freeze allows completions.*
4. **Accept the number-widening work** (decimals as args, no arity cap)?
   FFI.md avoided it on purpose to stay simple; CUDA and BLAS force it
   eventually. The question is only when.
