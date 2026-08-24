# Native, Portable, and Numeric Luce — a research report

**Status:** research, not specification. Nothing here amends
`LUCE_LANGUAGE_DESIGN.md`. Where a goal collides with a ruling in that
document, this report says so and prices the options; the ruling stands until
the owner changes it.

**Question asked:** what would it take for Luce to be a language in which you
*effortlessly* write programs that run on macOS, Linux, and Windows; talk to
SDL3, Metal, and Vulkan without ceremony; read OS input including Mac trackpad
gestures; do numpy-shaped numeric work; and possibly host C or assembly inline
in a `.luc` file.

**Method:** first-hand reading of both repositories, an independent deep-research
pass (14,429 words, 59 verified sources) run through Codex, four topic agents,
and — most usefully — *running the experiment*. Findings marked **[measured]**
were executed on this machine on 2026-08-24.

---

## 0. The short version

1. **The foundation already works.** Stage-0 0.20 opened a real SDL3 window and
   ran a real event loop, today, with no new language features. **[measured]**
   See §2.4. This is much further along than the docs imply.
2. **The language design already sanctions nearly all of this.** §21 is a
   complete native-interop architecture; `graphics`/`audio`/`device` are already
   reserved effect names; GPU allocations are already defined as library
   resources. Most of what follows is *implementation*, not language change.
3. **The hard part is not FFI.** It is acquisition, ABI lowering, linking,
   bundling, and CI across three operating systems. FFI is the middle third of
   one of those five problems.
4. **"We use LLVM, so C calls work" is false.** LLVM never does C ABI lowering.
   Clang does, in per-target classifiers. This is the single most commonly
   underestimated item on the list (§4.1).
5. **Inline C and inline asm should stay excluded** — both research passes
   independently reached your own §25.6 conclusion. Manifest-declared companion
   `.c`/`.m` build-graph nodes give the same power with far better provenance,
   caching, and diagnostics (§4.6).
6. **numpy does not need operator overloading.** Giving `array[T,_]` the
   operators Luce already gives scalars — the Zig `@Vector` / Odin / Go
   `complex128` / Fortran move — keeps the operator-bearing set closed and so
   does *not* reopen §25.1. It also lowers a whole expression to **one loop nest
   with one allocation**, beating numpy, with no MIR change (§5.3).
7. **Recommended order:** narrow C gateway → curated SDL3 recipe → SDL_GPU
   vertical slice → capability-based input → direct ABI → packaging. Numerics
   last, because it depends on all of it. Roughly 6–12 focused months to a
   polished three-platform result *after* the compiler foundation is dependable.
8. **The single cheapest win in the whole report:** emit `reassoc` on float
   reductions. `docs/VECTOR.md` already licenses it; it is a day's work for a
   plausible 4–8× on `sum`/`dot`/`norm` (§5.5).

---

## 1. What "effortless" actually decomposes into

The word hides five separate products. A language can be excellent at one and
useless at the rest:

| # | Product | What it means | Who usually solves it |
|---|---|---|---|
| 1 | **Acquisition** | get the C library's source or binary, pinned and verified | package manager |
| 2 | **Configuration + build** | turn that source into artifacts for *this* target | CMake/Meson/build graph |
| 3 | **ABI-correct calling** | actually call it without corrupting registers | the compiler frontend |
| 4 | **Linking + loading** | import libs, rpaths, install names, DLL search | linker + loader policy |
| 5 | **Bundling + shipping** | `.app`, MSIX, AppImage; signing; notarization | platform tooling |

An FFI is product 3 only. The reason Go's cgo is famously painful cross-platform
is products 1/2/4, not 3. **Luce's differentiation should be a coherent,
inspectable path from locked native source to a verified application bundle** —
not a novel FFI.

---

## 2. Ground truth: where Luce actually stands

### 2.1 Stage-0 0.20 (the shipping compiler)

**Tier-1 FFI landed 2026-08-20 and is real.** `docs/FFI.md`, spec'd on both
engines in `src/luce/specs/ffi_spec.zig`.

What crosses today (`semantics/signatures.zig:695-768`):

- **parameters:** `u32 | i32 | u64 | i64 | foreign` — nothing else
- **results:** the above, plus `f64`, plus void
- **arity cap: 8** (`runtime/ffi.zig:24`)
- `extern blocking func` releases the effect guard for a blocking callee
- **ungated by design** — any file may declare an extern (`SELFHOST.md:42-46`,
  "the safety boundary is *visible*, not *gated*")

What does **not** cross: `str`/`bytes` params, narrow ints (`u8`/`i16`), `f32`,
`f64` *as a parameter*, `bool`, structs by value or pointer, callbacks,
varargs, raw pointers. No `export c`. No header import. No runtime `dlopen` of a
user library — symbols resolve at **link time only** (`runtime/ffi.zig:39-49`
uses `dlsym(RTLD_DEFAULT)` over the current image).

The one memory escape hatch is `std.c` over the std-only
`Builtin.buffer_address`: `with_bytes`, `with_bytes_foreign`, `zstring`. It
accepts `list[u8]` and nothing else — notably **not** `array[f64, _]`, which is
precisely why you cannot hand an array's storage to a BLAS today.

Linking has three doors — `--link` on the CLI, `app.link()` in a build plan, and
`LUCE_CC` — and **no manifest door**: `luce.yaml` cannot express a native
dependency (`apps/manifest.zig:205`). A *package* therefore cannot declare that
it needs SDL3.

**Targets:** `emit.zig` registers AArch64, X86, and WebAssembly and takes a
triple as a parameter — but every product path hard-codes
`emit.hostTriple()` (`apps/luce/object.zig:70`) and **there is no `--target`
flag**. Link flags are chosen from the OS the *compiler binary* was built for
(`apps/native.zig:500-543`), so even a plumbed triple would link wrong. Windows
support is four small threading shims and `cmd.exe`; there is no COFF, no DLL,
no Windows link path.

**Graphics:** `std.ui` is 29 lines (one `Window` class, no events);
`std.gpu` is 75 lines with exactly five verbs — `width`, `height`, `clear`,
`fill_rect`, `present`. Behind them is a genuine 494-line AppKit + Metal
implementation (`apps/loom/macos_graphics.m`) with a real `MTLRenderPipeline`,
a hand-written MSL shader pair, and a CPU fallback — capped at 2048 rects, and
**pumping no `NSEvent`s at all**. `Backend.vulkan` is an enum member no code
ever returns.

**Input:** terminal only — keys, SGR mouse, bracketed paste. No touch, no
gestures, no gamepad, no IME, no key-release, and no GUI input whatsoever.

**Arrays:** `array[T, _, ...]` is rank 1–4, dense, unboxed, ARC-managed, indexed
`grid[r, c]`. An `array[f64,_]` really is f64s in memory — the property that
makes numerics possible at all. `std.math` has 12 functions over
`array[f64,_]` (`sum`, `dot`, `norm`, `axpy`…). No slicing of arrays, no views,
no SIMD, no `f32` variants, no BLAS path.

### 2.2 Epoch-1 (the self-hosted compiler)

Front end essentially **complete**: tokenizer (592 lines, all 42 keywords),
parser (1,178 lines, every declaration form in §29.6), syntax tree (410).
Middle **is a pinhole**: typed IR 86 lines, lowerer 79, canonical IR **21 lines
with seven instructions** (`I32Constant`, `I64Constant`, `I64Add`, `I64Subtract`,
`I64Multiply`, `WriteText`, `Return`).

Four hand-written byte emitters, no LLVM: a tree-walking interpreter (255), a
WASM encoder (143), an ARM64+Mach-O writer (199), an x86-64+ELF writer (177).
The native ones emit real runnable executables via ~5 instruction encodings and
raw syscalls, capped at one 16 KiB page, **with no register allocator, no
relocations, no symbol table, and no ability to emit a call** — not even
Luce-to-Luce.

The checker accepts `i32 i64 f64 bool str unit` and the `terminal` effect, and
explicitly rejects structs, classes, enums, interfaces, generics, `for`,
`match`, closures, optionals, `try`, method calls, and member access — 43
"not implemented yet" sites, zero TODO comments. That discipline is admirable
and it means the gap is precisely measurable.

`ValueType` is `struct { name: str }` — **a bare string**. Every typed feature
(pointers, C types with widths, array shapes, generic instantiation) needs this
replaced. It is on the critical path for everything in this report.

FFI in epoch-1: `export c` and `uses unsafe_native` **parse**; nothing checks
them; `examples/luce.toml`'s `[native.temperature]` block is read by no code.
`examples/c_import/README.md` says it plainly: *"The C path currently stops
after parsing, before FIIR generation, native binding, or linking."*

### 2.3 What the design doc already decided

This matters more than any external research, because it means most of the work
is licensed already:

- **§21** — a full native-interop architecture: Clang-produced **FIIR**, a
  three-layer binding model (foreign declaration → generated raw unsafe module →
  reviewed safe wrapper), manifest-declared binding targets, ownership
  *recipes*, `export c`, C++ via generated C-ABI thunks, support tiers A/B/C.
- **§18.1** — `graphics`, `audio`, `device`, `unsafe_native` are already in the
  closed effect vocabulary. **No new effect grammar is needed for any of this.**
- **§12.8** — "An arena, pool, memory map, **GPU allocation**, or native buffer
  is a standard-library/native resource, not a language allocation mode."
- **§21.12** — `native_ptr[T]`, `native_mut_ptr[T]`, opaque handles, load/store
  intrinsics, validated ABI casts, all behind `unsafe_native`.
- **§23.3** — the distribution owns object emission and link driving; "a normal
  Luce/C build does not assemble itself through an ambient `cc`."

### 2.4 The experiment: Luce already drives SDL3 **[measured]**

Built and run with shipped `luce 0.20` against Homebrew SDL **3.4.12**:

```luce
import std.c

extern func SDL_Init(flags: u32) -> u32
extern func SDL_CreateWindow(title: foreign, w: i32, h: i32, flags: u64) -> foreign
extern func SDL_PollEvent(event: foreign) -> i32
extern blocking func SDL_Delay(ms: u32)
extern func SDL_DestroyWindow(window: foreign)
extern func SDL_Quit()

# SDL_Event is a 128-byte union; its type tag is a u32 at offset 0.
func event_type(storage: list[u8]) -> u32:
    var value = u32(0)
    var index = 3
    while index >= 0:
        value = (value << 8) | u32(storage[index])
        index -= 1
    return value

func main():
    let started = SDL_Init(u32(32))                     # SDL_INIT_VIDEO
    let title = c.zstring("Luce SDL3 events")
    let window = c.with_bytes_foreign(title, (n) => SDL_CreateWindow(n, 480, 320, u64(0)))

    var storage = list[u8]()
    var slot = 0
    while slot < 128:
        storage.append(0)
        slot += 1
    # ... poll loop calling c.with_bytes(storage, (p) => i64(SDL_PollEvent(p)))
```

Built with `luce build events.luc --link -lSDL3 --link -L/opt/homebrew/lib`.
Output:

```
init 1
  event type 773      # SDL_EVENT_KEYBOARD_ADDED
  event type 1028     # SDL_EVENT_MOUSE_ADDED
  event type 514      # SDL_EVENT_WINDOW_SHOWN
  event type 519      # SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED
pumped 120 frames, saw 4 real SDL events
```

A window appeared. **`SDL_PollEvent` wrote a 128-byte C union back into a
Luce-owned `list[u8]`, and Luce decoded the tag.** The `extern` + `--link` +
`std.c` trio is already sufficient for a genuine SDL3 application loop.

**Friction found, all real and citable:**

| Gap | Consequence | Size |
|---|---|---|
| **No null `foreign` literal** | cannot write `if window == null` — every pointer-returning C API is unfailable | small, sharp |
| No struct layout / field access | every C struct is hand-decoded byte by byte | the Tier-2 gap |
| No `_ =` discard statement | must bind results you don't want | trivial |
| Block closure won't parse as a trailing call argument | must use `(x) => …` lambda form | trivial |
| No hex/format spec in f-strings | `f"0x{k}"` prints a literal `0x` then decimal | cosmetic |

The first row is the highest value-per-byte fix in this entire report.

---

## 3. Five findings that should shape the plan

### 3.1 LLVM does not do C ABI lowering

LLVM turns an *already-lowered* signature into registers and stack slots. It
never sees a C `QualType`, `#pragma pack`, bitfield allocation, HFA semantics, or
Apple-vs-generic `va_list`. The frontend must, per argument and result, choose
ignore/direct/extend/indirect/expand/coerce-and-expand, build the exact coercion
type, insert hidden parameters, set ABI attributes, and lower the call site
identically to the declaration. Clang does this in per-target classifiers
(`clang/lib/CodeGen/Targets/X86.cpp`, `AArch64.cpp`).

**The stable libclang C API does not expose these decisions.** A Clang-based
FIIR importer therefore does *not* automatically solve direct-call lowering —
this should be written into the design now rather than discovered later.

Four routes, cheapest first: generate a C shim and let Clang compile both sides;
drive Clang as an oracle and recover lowered signatures from emitted IR; bridge
to Clang's internal C++ CodeGen APIs; or port each classifier. Full direct
coverage for SysV AMD64 + Apple arm64 + AAPCS64 + Windows x64 is **2–4 focused
engineer-months after the importer and backend are stable**, plus permanent
regression work.

**Implication:** shim-first is not an embarrassing hack. It is the correct
critical path, and it doubles as the differential oracle for the direct
classifiers later.

### 3.2 Apple arm64 varargs is a trap with your name on it

Unnamed arguments go to 8-byte stack slots and `va_list` is pointer-like —
unlike generic AAPCS64's register-save-area scheme. The same trap governs
`objc_msgSend`: Apple's own guidance is that you **must** cast it to the callee's
exact prototype, because calling the variadic declaration puts arguments in the
wrong place. Any Metal-via-runtime plan inherits this on day one.

### 3.3 SDL3 is the right base — but "a curated profile," never "all of SDL"

Measured from the official 3.4.10 tarball: ~52 MiB extracted, 2,181 files,
~656,300 physical lines under `src`+`include`, a **4,356-line** top-level
`CMakeLists.txt`, 11,755 public-header `#define`s, 321 function-like public
macros.

On Linux the *runtime* story is friendly — the default shared library normally
links only glibc and `dlopen`s X11/Wayland/ALSA/PipeWire as needed — but a
full-feature *build* still needs development headers for X11 + Xext/Xcursor/
Xfixes/Xi/Xrandr, Wayland client + `wayland-scanner` + protocol XML + xkbcommon
+ libdecor, ALSA/Pulse/JACK/PipeWire, udev, dbus, DRM/GBM, EGL, Vulkan.

A trustworthy three-platform SDL recipe is **6–10 focused engineer-weeks**.
Do not clone CMake; pin a curated feature profile and use upstream CMake as a CI
oracle. The honest promise is *"Luce makes a curated SDL profile effortless,"*
not *"any CMake project is portable."*

### 3.4 Cross-compilation is partly a licensing problem, not a technical one

macOS is technically cross-compilable and **operationally and legally
Mac-bound**: the SDK is not redistributable, and signing/notarization need Apple
credentials on Apple hardware. Windows needs COFF import libraries and a DLL
deployment policy. Linux needs a *named* glibc baseline (there is no generic
"desktop Linux ABI"). Plan for **native runners per OS** and remote Mac dispatch
— not a heroic single-host cross-compiler.

### 3.5 A uniform cross-OS gesture API would be a lie

Gestures are recognized at different layers per OS. SDL 3.4.x emits pinch from
Cocoa, Wayland, and X11/XInput2 — and its **Windows backend has no pinch emitter
at all**. AppKit delivers magnify, rotate, and swipe through distinct responder
methods; **SDL normalizes only pinch — never rotate or swipe.** Windows
Precision Touchpad usually arrives at an unenlightened app as mouse-wheel unless
you register for `WM_POINTER` + the PTP APIs. Wayland's pointer-gestures protocol
is explicitly *unstable*.

The honest design is **capability-based**: a common stream (pointer, wheel, touch
contacts, pinch phases) plus *optional, advertised* capabilities (rotate, swipe,
hold, high-resolution scroll, raw touchpad) with per-platform fidelity metadata.
Let the OS recognize gestures; normalize lifecycle and units; do not write a
cross-platform recognizer in the compiler.

---

## 4. Goal by goal

### 4.1 C interop

Target the design doc's §21 architecture, but **invert the implementation
order**: ship the narrow gateway and generated shims first, then build FIIR with
the shim suite as its oracle.

Immediate, high-value, small:

1. **A null `foreign` spelling** and a way to test it. Without this no
   pointer-returning C API can report failure. *(§2.4)*
2. **Widen Tier-1 scalars**: `u8/u16/i8/i16` with explicit sign/zero-extension
   attributes, `f32`, and `f64` **as a parameter**. Cheap, removes constant
   `i64` laundering.
3. **`Builtin.buffer_address` over `array[T,_]`**, not just `list[u8]`. This one
   line is what unblocks BLAS later.
4. **Manifest-declared native dependencies** — a package must be able to say it
   needs SDL3; today only the top-level build script can.
5. **Companion `.c`/`.m` sources as declarative build-graph nodes.** This is the
   real answer to "inline C" (§4.6) and the vehicle for every hard ABI case.

Then: callbacks with a retained context object, a C trampoline, deterministic
unregister, and a documented "no trap unwinds across C" rule. *The dangerous SDL
bugs will be lifetime bugs, not register bugs.*

### 4.2 Cross-platform targets

Ordered: `--target` + a machine-readable **target profile** descriptor (CPU/ABI,
object format, data model, default calling convention, LLVM data layout,
SDK/sysroot, deployment floor, libc/CRT, linker flavor, loader policy, bundle
format, signing modes) → per-target `libluce_rt` → target-aware link flags
(today they are `builtin.os.tag`) → native CI runners per OS → bundling →
signing.

Tier-1 profiles to name now: macOS arm64; Windows x86-64 MSVC; Linux x86-64
glibc with a stated minimum. Everything else explicitly out of contract.

### 4.3 Graphics

**Recommendation: SDL3's GPU API, behind a narrow `luce_gpu_*` C shim you own,
with shaders compiled offline.**

| Option | C ABI? | Backends | First triangle | Maintenance | Risk |
|---|---|---|---|---|---|
| **SDL_GPU** | **native C** | Vulkan, D3D12, Metal | low | **low** | still evolving; shader blob logistics |
| wgpu-native | yes (`webgpu.h`) | +GL | low | medium | **not yet on the standardized header**; Rust supply chain; ~10–40 MB |
| Dawn | yes, stable `webgpu.h` | all | medium | med-high | GN/depot_tools build |
| sokol_gfx | header-only C | **no D3D12**, Vulkan experimental | lowest | low | bus factor 1 |
| bgfx | yes (C99) | most, incl. legacy | medium | medium | bespoke shader dialect |
| raw Vulkan + MoltenVK | — | no D3D12 | **high** | **high** | MoltenVK is explicitly *not fully conformant*; you ship the loader + ICD + signing on macOS |
| raw Metal + D3D12 + Vulkan | — | all | highest | highest | three renderers; `objc_msgSend` ABI traps |

SDL_GPU wins on the criterion that matters most here: **it is already exactly
what Luce's FFI speaks** — pure C, no C++ or Rust in your build — and one
dependency also supplies window, input, events, and audio. Its backend set
(Vulkan/D3D12/Metal, no legacy GL) is precisely your matrix. zlib licensed.

**Metal directly is a trap worth naming.** Apple ships **no C API** for Metal.
Your options are `objc_msgSend` by hand (must cast to exact prototypes;
`_stret`/`_fpret` on x86-64 but not arm64; manual retain/release; hand-built
block literals for completion handlers; ~60–120 selectors for a real renderer),
`metal-cpp` (Apple's header-only **C++17**, Apache-2.0 — still needs an
`extern "C"` shim to reach Luce), or a hand-written `.m` shim with ARC on. If
you take SDL_GPU, the Objective-C lives inside SDL and you write none of it.

**Shaders — the part people forget.** SDL_GPU never compiles source; you hand it
bytecode, and `SDL_CreateGPUDevice` picks a backend partly from the formats you
declare you can supply. SDL fixes the binding model as part of the shader ABI
(SPIR-V: vertex set 0/1, fragment set 2/3; MSL: vertex buffers at
`[[buffer(14)]]`; HLSL spaces 0–3). The paved road — used by SDL_GPU's own
author's examples — is **compile offline, commit the blobs, select at runtime.**

Author in **Slang** (Apache-2.0 with LLVM exception, now **Khronos-hosted**,
bundled in the Vulkan SDK, prebuilt binaries for all three OSes, targets SPIR-V/
DXIL/DXBC/MSL/metallib/WGSL/HLSL/GLSL) invoked as `slangc` at build time. HLSL +
SDL_shadercross is the equivalent paved road, but shadercross has **no tagged
releases** and drags DXC + SPIRV-Cross behind it — use it as a CLI on CI, never
link it at runtime.

**Phase-1 trick that dodges the worst trap:** ship **SPIR-V + MSL only**. That
gets Metal on macOS and Vulkan on *both* Linux and Windows — no DXC, no
Windows-only `dxil.dll` signing step, no Windows build machine required for v1.
Add DXIL later purely to widen Windows driver coverage.

### 4.4 Input and gestures

Capability-based, per §3.5. Concretely:

- a common stream from SDL: keyboard (with text input/IME), mouse, wheel, touch
  contacts, and **pinch** phases;
- advertised optional capabilities, each with a `supported` query;
- a thin **AppKit `.m` adapter** for rotate/swipe and any phase/pressure detail
  SDL omits, injected into the same event stream (this is exactly the
  "companion source" mechanism from §4.1);
- Windows PTP adapter only if gesture-driven Windows behaviour is a product
  requirement; otherwise documented wheel/touch fallbacks;
- runtime detection for Wayland/X11 protocol availability.

Define **interaction intents** above raw gestures — zoom, pan, rotate-canvas —
so keyboard and mouse remain first-class fallbacks. Real trackpads are required
for testing; CI cannot validate palm rejection, inertia, or compositor
reservation.

Note this replaces nothing that exists: `std.ui.Window` has no event method at
all today, and the macOS host pumps no `NSEvent`s.

### 4.5 Numeric / array computing

The only *toolchain* blocker is small: let `Builtin.buffer_address` accept
`array[T,_]` so an array's storage can reach a C BLAS. Everything else here is a
**language** question, and it gets its own section — see **§5**.

### 4.6 Inline C and inline assembly — the verdict is *don't*

Both external research passes and your own §25.6 agree.

**Inline C** looks convenient and collapses language and build boundaries: the
compiler must define delimiter and indentation behaviour, preprocessing scope,
include resolution, target configuration, macro visibility, source locations and
diagnostics across two parsers, incremental-cache identity, generated symbol
names, and language-server behaviour — and a block can be valid on one target
and meaningless on another. **None of it removes the need for a C compiler or an
ABI bridge.**

The better facility, which gives you the same power: **manifest-declared
companion sources** (`.c`, `.m`, later `.mm`) compiled as explicit build-graph
nodes, with an ordinary Luce foreign declaration naming their stable C gateway.
Slightly more files; vastly better provenance, caching, diagnostics, and
tooling. If inline C is ever wanted, it should be *sugar that materialises such
a node* — not a second C implementation inside the Luce frontend.

**Inline assembly** is worse: it needs target syntax, operand constraints,
register classes, clobbers, memory/volatile semantics, flags, stack and unwind
rules, and optimizer integration; wrong constraints miscompile silently. Expose
reviewed **intrinsics** (atomics, SIMD, traps, special registers) and allow
separately compiled `.S` files in expert packages. This is exactly what
§21.12 already says.

**Verdict: keep both exclusions. Build companion-source nodes instead.** This is
the rare case where the research fully endorses the existing ruling.

---

## 5. Numerics: the answer is *not* operator overloading

This section changed my mind mid-research, so it is worth reading in full.

### 5.1 What numpy actually is

Six fields — `data`, `shape`, `strides`, `dtype`, `ndim`, `base` — and one
formula: `addr = data + Σ index[i] * strides[i]`. Everything downstream is a
*stride edit with no data movement*: slicing scales a stride, transpose permutes
them, broadcasting sets a length-1 axis's stride to **0**. That is why numpy
feels cheap. It is also why it is footgun-heavy (`a += a.T` is wrong; `base`
pins giant arrays alive).

Its BLAS dependency is narrower than folklore suggests: only `matmul`/`dot` and
`numpy.linalg` delegate — roughly `gemm`/`gemv`/`syrk` plus ~10 LAPACK drivers.
Everything else is numpy's own C.

The **Array API standard** (data-apis.org) is worth adopting as a *naming and
coverage checklist* — not as a conformance target, since conformance is defined
in Python terms. Its most useful ruling for Luce: **views-vs-copies is
deliberately unspecified — "libraries may do either."** `out=` was excluded on
purpose. **A copy-only v1 is therefore spec-legitimate, not a shortcut** (JAX
ships exactly that way).

### 5.2 The collision, stated precisely

- **§25.1** bans operator overloading *and* user-defined operators.
- **§15.4** allows no general value/const generic parameters.
- **§26.3** lists SIMD intrinsics as a not-promised reconsideration candidate.

The empirical signal is hard to argue with: **every language actually used for
numerical work has infix arithmetic on array types** — Fortran, Matlab, Python,
Julia, R, C++, Rust, Swift, Mojo, Odin, Zig(`@Vector`). The counter-examples are
instructive: Java's `BigDecimal.multiply(...).add(...)` and Go's
`z.Mul(x,y); z.Add(z,c)` both led their ecosystems to *avoid the type* rather
than accept the syntax. So named-method numerics is not a dealbreaker for a
library that exists; it is a dealbreaker for a library that gets **used** for
real formulas.

### 5.3 But overloading is not the only way to get infix

There are four positions, and the design doc only excludes the last one:

- **M1 — compiler-known operators on a compiler-built type.** Extend Luce's
  existing operator semantics from scalars to `array[T,_,…]`. No user-declared
  operators, no traits, no dispatch, no name lookup — the compiler knows one
  more closed family. Precedents: **Zig `@Vector`, Odin's `[4]f32` and
  `matrix[R,C]T`, Go's built-in `complex128` and `string +`, Fortran's whole-array
  expressions.**
- **M2 — a std-only closed protocol**: desugar `a + b` to `a.add(b)` *only* for
  types the standard library declares. Luce already has this exact shape of
  privilege — `handle` is a std-only spelling and `Builtin.*` is unreachable
  from user code.
- **M3 — a lexical broadcast marker** (Julia's dots): `c = a .* b .+ 2 .* d`,
  where the compiler *guarantees* the dotted tree becomes one loop nest with one
  allocation. Costs a lexer row; buys fusion as a language guarantee.
- **M4 — full operator overloading.** Excluded, and rightly.

**M1 is culturally exact for Luce.** All four containers are *already*
compiler-built with built-in syntax (`xs[i]`, `m[k] = v`, literals). Giving
operators to the fifth thing the compiler already owns invents no new kind of
privilege — it does not open the door M4 closes, because the set of types with
operators stays closed and reviewable.

**The payoff nobody mentions:** with M1 or M3 the compiler sees the whole
expression tree at HIR lowering, so `a*b + 2*d` can lower to **one loop nest with
one allocation** — better than numpy, which allocates two temporaries — with no
expression templates, no laziness, and **no new MIR instruction, hence no
`format_version` bump**. Expression templates are C++'s workaround for not owning
its parser. A language that owns its parser never needs them.

### 5.4 Ranked, honestly

| Feature | Verdict | Without it |
|---|---|---|
| **Infix arithmetic on arrays** (M1/M2/M3) | **REQUIRED for adoption** | method chains — fine for pipelines, bad for dense formulas |
| **Slicing / views** | **IMPORTANT**, deferrable | copy-on-slice; spec-legal per Array API; costs bandwidth, not correctness |
| **BLAS FFI** | **IMPORTANT**, blocked today | pure-Luce blocked GEMM at 20–40% of OpenBLAS — fine to ~1000², hopeless for HPC |
| Generics over element type | IMPORTANT, deferrable | duplicate the module per dtype (~2× source) |
| Const-generic rank/shape | **NICE** | rank is *already* static in `array[f64,_,_]` — the 80% that matters |
| SIMD type | **NICE** | LLVM autovectorizes dense f64 loops |
| Lazy/fused expression templates | **do not build** | numpy allocates temporaries and won anyway; M1/M3 give fusion free |

### 5.5 The cheapest real win in this entire report

`docs/VECTOR.md` already commits that **float reduction order is unspecified** —
that is a written licence to emit `reassoc` (and ideally `contract`) fast-math
flags on `math.sum`/`dot`/`norm` **today**. Plausibly a 4–8× win on those
functions for a few lines in codegen, plus a two-engine spec. Checked *integer*
reductions still cannot be reordered (the trap point is observable), and the
Library page should say so plainly: `array[f64,_]` is the fast path,
`array[i32,_]` is correct but scalar.

**Do not ship a user-facing SIMD type for v1.** If it is ever wanted, spell it
`simd[T, N]` — a compiler-built type with a value parameter, *exactly* the
precedent `array[T, N]` already set — so it costs no new generics machinery.

### 5.6 BLAS

**Never put a BLAS in the toolchain or stdlib** — it would poison a build story
that today needs only LLVM and `cc`. Ship `nd.matmul` as a pure-Luce blocked
GEMM (state the measured fraction of OpenBLAS in the docs), and an **optional**
`nd.blas` package that `--link`s a system CBLAS through a small C shim. The shim
is unavoidable regardless of taste, because `tierOneParameter` forbids `f64`
parameters and caps externs at 8 args — `cblas_dgemm` has 14, two of them
`double`, so **it cannot be declared today**. On macOS the shim links Accelerate
and needs no third-party install. This is also why `buffer_address` over
`array[T,_]` (§4.1 item 3) is the unblocking change.

What young languages actually do: Rust's `ndarray` defaults to a pure-Rust
`matrixmultiply` and makes BLAS optional; Julia bundles OpenBLAS behind a
trampoline; Zig ships none. The modal answer is *implement a respectable GEMM,
make BLAS a package.*

### 5.7 Effort, honestly

| Scope | Work |
|---|---|
| **a weekend** | `std.nd` v0: rank-1/2 f64, creation, named-method elementwise, reductions, naive matmul, printing. `std/math.luc:169-266` is already ~15% of it |
| **a day** | the `reassoc` reduction flag + its two-engine spec — highest value per hour here |
| ~1 week | blocked GEMM + LU `solve/det/inv` + a benchmark harness against numpy |
| **2–4 weeks** | **M1/M3: the language grant.** Semantics type rules, HIR fused lowering, codegen loops, one new `shape_mismatch` trap, both-engine specs, suite ownership, Reference + Library pages. No MIR bump if lowering stays scalar. **This is the change that decides the project's fate.** |
| 1–2 months | strided views end-to-end (heap layout, both engines, contiguity fast path, FFI contiguity rule, worker copy, hostile-input tests) — the expensive one; do it only after copies demonstrably hurt |
| 3–6 months | Array-API-shaped coverage for f64 *and* f32, axis reductions, broadcasting, boolean indexing, QR/Cholesky/SVD, RNG, FFT, docs |
| ~1 year | dtype-generic library on real generics, `simd[T,N]`, BLAS package, GPU offload, autodiff, sparse |
| **don't** | beat OpenBLAS; literal Array API conformance; expression templates |

**One-sentence version:** Luce does not need operator overloading, comptime, or
const generics to have a good array library — it needs to admit that arrays are a
*language* type and give them the operators it already gives scalars, exactly as
Zig, Odin, and Fortran did. Views and BLAS are then scheduling questions, not
design blockers.

---

## 6. Where the goals collide with the specification

These need owner rulings. Research cannot settle them.

| Goal | Ruling in the way | Options |
|---|---|---|
| numpy ergonomics | §25.1 no operator overloading | **M1: compiler-known operators on `array` — does *not* reopen §25.1**, since the operator-bearing set stays closed (Zig/Odin/Go/Fortran precedent). Or M3 (dotted fusion), M2 (std-only protocol), or named methods. |
| generic array library | §15.4 no value-generic params | keep `array[T,N]` compiler-built; duplicate the module per dtype until generics land |
| SIMD for numerics | §26.3 item 6, "not promised" | **not needed for v1** — emit `reassoc` on float reductions (already licensed by `docs/VECTOR.md`) and let LLVM autovectorize |
| per-OS graphics/input | §20.8 no conditional compilation | manifest-selected target roots (already designed) — confirm this scales to SDL/Metal/PTP adapters |
| inline C | §25.6 exclusion | **keep exclusion; ship companion-source nodes** |
| inline asm | §25.6 + §21.12 | **keep exclusion; ship intrinsics + `.S` files** |
| "no ambient `cc`" | §23.3 | stage-0 already shells to `cc`/`codesign`; decide whether epoch-1 vendors a toolchain or declares an SDK contract |

Also worth a decision: **§21 assumes Clang produces FIIR.** That makes libclang a
hard build dependency of the Luce toolchain, and §3.1 shows it still does not
give you ABI lowering. Confirm that trade deliberately.

---

## 7. Recommended sequence

Estimates are engineering scope *after* the compiler can reliably compile and
link ordinary programs. They overlap; they are not calendar promises.

| Phase | Work | Scope |
|---|---|---|
| **0** | Target profiles + native CI on all three OSes; a C smoke test called in both directions | 1–3 wk |
| **1** | Narrow C gateway: null `foreign`, wider scalars, `buffer_address` over arrays, callbacks with retained context; companion `.c`/`.m` nodes; generated shims for aggregates/varargs/bitfields | 3–6 wk |
| **2** | Declarative native dependency engine + curated SDL3 recipe + `luce doctor` | 6–10 wk |
| **3** | Safe SDL surface + SDL_GPU vertical slice; offline shader pipeline (Slang → SPIR-V + MSL) | 4–8 wk |
| **4** | Capability-based input; AppKit rotate/swipe adapter | 2–5 wk |
| **5** | FIIR + libclang importer + raw generator; direct ABI classifiers one target at a time, differential-tested against Clang | 8–16 wk |
| **6** | Bundling, loader-path verification, signing/notarization | 4–8 wk |
| **7** | Numerics: views/strides decision, BLAS binding, then kernels | year-scale |

**A polished three-platform result is realistically 6–12 focused months of
native-toolchain work after the compiler foundation is dependable.** A
compelling *demo* is reachable in 2–3 months through shims — calling that demo a
finished native ecosystem would be misleading.

Where to deliberately **not** innovate: windowing/input/audio → SDL3; portable
GPU → SDL_GPU; shader translation → Slang/DXC/SPIRV-Cross; C parsing/layout →
Clang; machine code → LLVM; linking → LLD/platform linkers; containers and
signing → platform tooling; native source builds → curated recipes, **not** a
CMake clone.

Where bespoke work is unavoidable: target-profile/ABI integration with Luce
types and ARC; the recipe model, cache identity, and diagnostics; raw/safe
binding separation and ownership recipes; **ARC bridges for C handles,
callbacks, foreign threads, and asynchronous GPU resources** (ARC does not know
the GPU's lifetime); link/bundle planning; thin platform input adapters; and the
conformance matrix.

---

## 8. Open questions for the owner

1. **M1, M3, M2, or named methods (§5.3)?** This single ruling gates everything
   numeric. The research says M1 is the smallest change that makes Luce a
   language people write formulas in, and that it does *not* reopen §25.1.
2. Is `array` slicing with **strided views** in scope for epoch 1, or is the
   numeric story explicitly "dense, whole-array kernels only"? (Copy-only is
   spec-legal — §5.1.)
3. Does epoch-1 vendor a C toolchain, or declare a platform-SDK contract and
   verify it with `luce doctor`? (§23.3 vs. stage-0's actual `cc` usage.)
4. Tier-1 target list — is Windows in for epoch 1, or does it follow?
5. Is libclang an acceptable hard dependency of the toolchain?
6. Should stage-0 keep gaining small FFI affordances (null `foreign`, wider
   scalars, `buffer_address` over arrays) while epoch-1 matures — given
   `SELFHOST.md`'s freeze is on *capability*, and these are arguably completions
   of the already-landed Tier-1 rather than new capability?

Question 6 is the one with immediate leverage: **§2.4 shows a real SDL3 app is
already possible on stage-0.** A handful of small, freeze-compatible additions
would make that path genuinely pleasant while epoch-1 grows its middle.

---

## 9. Sources

**Graphics/GPU:** [SDL3 GPU](https://wiki.libsdl.org/SDL3/CategoryGPU) ·
[shader formats](https://wiki.libsdl.org/SDL3/SDL_GPUShaderFormat) ·
[SDL_shadercross](https://github.com/libsdl-org/SDL_shadercross) ·
[SDL_gpu_examples](https://github.com/TheSpydog/SDL_gpu_examples) ·
[Slang](https://shader-slang.org/) ·
[wgpu-native](https://github.com/gfx-rs/wgpu-native) ·
[webgpu-headers](https://github.com/webgpu-native/webgpu-headers) ·
[Dawn](https://dawn.googlesource.com/dawn) ·
[bgfx](https://github.com/bkaradzic/bgfx) · [sokol](https://github.com/floooh/sokol) ·
[metal-cpp](https://developer.apple.com/metal/cpp/) ·
[MoltenVK](https://github.com/KhronosGroup/MoltenVK) ·
[Vulkan-Loader](https://github.com/KhronosGroup/Vulkan-Loader)

**ABI/interop:** [LLVM LangRef](https://llvm.org/docs/LangRef.html) ·
[Clang ABIArgInfo](https://clang.llvm.org/doxygen/classclang_1_1CodeGen_1_1ABIArgInfo.html) ·
[Clang X86 ABI](https://github.com/llvm/llvm-project/blob/main/clang/lib/CodeGen/Targets/X86.cpp) ·
[Clang AArch64 ABI](https://github.com/llvm/llvm-project/blob/main/clang/lib/CodeGen/Targets/AArch64.cpp) ·
[LLVM ABI-lowering RFC](https://discourse.llvm.org/t/rfc-an-abi-lowering-library-for-llvm/84495)

**Platform/input:** [SDL Linux README](https://wiki.libsdl.org/SDL3/README-linux) ·
[SDL event types](https://wiki.libsdl.org/SDL3/SDL_EventType) ·
[SDL trackpad hint](https://wiki.libsdl.org/SDL3/SDL_HINT_TRACKPAD_IS_TOUCH_ONLY) ·
[Apple trackpad events](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html) ·
[Windows Precision Touchpad](https://learn.microsoft.com/en-us/windows/win32/input-precisiontouchpad/precision-touchpad-portal) ·
[Wayland pointer gestures](https://wayland.app/protocols/pointer-gestures-unstable-v1)

**Numerics:** [Array API standard](https://data-apis.org/array-api/latest/) ·
[Rust ndarray](https://docs.rs/ndarray/) ·
[Julia dot-fusion](https://julialang.org/blog/2017/01/moredots/) ·
[Mojo parameters](https://docs.modular.com/mojo/manual/parameters/) ·
[Rust std::simd](https://doc.rust-lang.org/std/simd/) ·
[Google Highway](https://github.com/google/highway) ·
[Futhark](https://futhark-lang.org/) ·
[OpenBLAS](https://github.com/OpenMathLib/OpenBLAS) ·
[Apple Accelerate](https://developer.apple.com/documentation/accelerate)

The full 14,429-word Codex report (59 verified URLs) covering native dependency
distribution, C ABI lowering, binding generation, and cross-compilation is the
companion to this document.
