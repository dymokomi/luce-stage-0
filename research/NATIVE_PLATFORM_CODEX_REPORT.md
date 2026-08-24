# Making Native Programs Effortless in Luce

## Native dependency distribution, C ABI lowering, binding generation, cross-compilation, and a realistic implementation order

**Research date:** 2026-08-23  
**Audience:** the Luce language and compiler owner  
**Scope:** desktop macOS, Linux, and Windows; ARC-managed Luce; LLVM code generation; C/Objective-C interoperation; SDL3 and SDL_GPU as the first serious native dependency.

This report uses “effortless” in a deliberately strict sense: a developer should be able to declare a dependency and target, run one Luce command, and either receive a runnable/bundleable artifact or a precise diagnosis of the missing external prerequisite. It does **not** mean that one binary runs on all systems, that a Linux machine can legally manufacture every Apple artifact, or that the toolchain can erase signing identities, SDK licenses, GPU-driver behavior, and operating-system distribution policy.

## Executive findings

1. Native dependency support is three products—acquisition/configuration, ABI-correct compilation/linking, and runtime bundling—and an FFI implements only part of the middle product.
2. What works in practice is a three-mode policy: pinned source builds by curated Luce recipes, verified target-specific binary artifacts where justified, and an explicit system-library escape hatch.
3. Zig succeeds at source vendoring because its build graph can compile C for the selected target; Rust succeeds when a `-sys` maintainer hides probing and vendoring inside a crate; neither makes arbitrary upstream build systems free.
4. Go demonstrates the opposite boundary: cgo is usable on the host, but cross-compilation immediately requires a target C compiler, headers, libraries, and configuration that Go modules do not supply.
5. Odin’s SDL3 package is useful binding inventory, not a complete distribution solution: it ships Windows artifacts but expects a system SDL3 on macOS and Linux.
6. SwiftPM binary targets work best inside a curated platform ecosystem; its cautious non-Apple static-library support excludes libraries with dependencies beyond libc, which is exactly the hard case SDL represents.
7. SDL 3.4.10 is practical to vendor but not small: the official source expands to roughly 52 MiB, 2,181 files, and about 656,000 C/header/Objective-C lines under `src` and `include`.
8. SDL’s Linux runtime is friendlier than its build: the default shared library normally links only glibc and dynamically loads X11, Wayland, ALSA, PipeWire, and related backends, but a full source build still needs their development headers and generators.
9. Luce should not reproduce SDL’s 4,356-line top-level CMake configuration generically; it should own a versioned, tested SDL recipe whose selected features are intentionally narrower.
10. LLVM does not infer the C source-language ABI for Luce: the frontend must determine C layout, classify each argument and result, split/coerce/indirect it, add hidden parameters and ABI attributes, and lower variadic calls correctly.
11. SysV AMD64, generic AArch64, Apple arm64, and Windows x64 disagree materially about aggregate registers, hidden returns, stack layout, and varargs; “extern C” cannot be one target-neutral lowering rule.
12. Apple arm64 varargs are a particularly dangerous trap: unnamed arguments go to 8-byte stack slots and `va_list` is pointer-like, unlike generic AAPCS64’s register-save-area scheme.
13. Packed records, bitfields, non-default calling conventions, and variadics should initially cross generated C shims; pretending they are ordinary Luce records or calls creates silent corruption.
14. Libclang can parse declarations and compute target layouts, but its stable C API does not hand Luce Clang’s complete `ABIArgInfo` lowering; direct calls still require a classifier, an internal-Clang bridge, IR introspection, or a C shim.
15. Generated raw bindings and human-designed safe bindings are different artifacts: generation solves spelling and layout, while recipes must express ownership, nullability, callback lifetime, thread rules, and error conventions.
16. A legal, supportable macOS release pipeline needs an Apple-SDK-enabled Mac build/test worker plus signing and notarization credentials; LLVM’s ability to emit Mach-O does not remove those constraints.
17. Windows needs COFF import-library and DLL deployment policy; Linux needs an explicit glibc baseline or a separately tested musl target; every platform needs deliberate loader paths rather than ambient search behavior.
18. SDL_GPU is the correct first graphics layer over Metal, Vulkan, and D3D12, but shaders remain multi-format build assets and SDL_shadercross is better treated as a prebuilt host tool than a runtime dependency.
19. SDL 3.4.10 exposes pinch on Cocoa, Wayland, and X11 but not its Windows backend, and it omits AppKit rotate/swipe; a small platform gesture layer is unavoidable and must advertise capabilities rather than promise false parity.
20. The fastest credible route is a narrow C-shim vertical slice, curated SDL source builds, native CI on all three systems, SDL_GPU, then direct full-ABI FIIR and broad binding generation—not full C/C++ compatibility or inline C/assembly first.

## 1. The real native-dependency problem

A C library dependency has at least seven independent dimensions:

| Dimension | Questions the Luce toolchain must answer |
|---|---|
| Identity | Which exact upstream version, patch set, license, and content hash? |
| Configuration | Which preprocessor definitions, feature flags, headers, generated configuration headers, and source files apply to this target? |
| Toolchain | Which C/C++/Objective-C compiler, assembler, archiver, linker, sysroot, SDK, and deployment target? |
| Discovery | Is this a Luce-built artifact, a downloaded binary, a package-manager installation, an OS framework, or a user-specified prefix? |
| Link | Static or shared, in what order, with which transitive libraries/frameworks, symbol visibility, import library, and calling convention? |
| Runtime | Which DLLs/dylibs/SOs and data files accompany the executable, and what loader paths or install names point to them? |
| Release | How is the result bundled, signed, notarized, sandboxed, and tested on the minimum supported OS? |

An `extern` declaration answers none of the acquisition questions and only a fraction of the ABI/link questions. This distinction is the central design constraint. If Luce exposes a beautiful FFI but tells users to install `libsdl3-dev`, find the right `SDL3.lib`, edit linker flags, and repair `rpath`, native programming will not feel effortless.

### 1.1 What current language ecosystems actually do

#### Zig: one target-aware build graph, with upstream complexity still visible

Zig’s build system can add C and C++ sources to a compile step, pass target and optimization choices through the graph, link system libraries, and fetch content-addressed packages. Package metadata in `build.zig.zon` identifies dependency locations and hashes; `zig fetch --save` records a dependency, and the consumer’s `build.zig` resolves it through the build graph while forwarding the selected target/optimization to a dependency artifact. The official guidance explicitly prefers building a dependency from source through the Zig build system because that improves reproducibility and cross-compilation; it also recognizes `linkSystemLibrary` as necessary for system packaging and search-prefix use cases ([Zig Build System](https://ziglang.org/learn/build-system/)). This is the strongest model for Luce’s stated hermetic, declarative direction.

What Zig buys is **control of the compilation graph**. A Zig package author can describe upstream C files, defines, include directories, platform libraries, and generated steps once; every consumer receives that knowledge. Zig does not magically understand a CMake project. Someone still has to port the relevant configuration logic, decide which probes become target facts, and maintain that recipe as upstream changes. Packages that invoke CMake, Make, Python, or shell scripts give back much of the hermeticity and cross-target predictability.

The useful lesson is not “embed another general-purpose language in `luce.toml`.” It is “make native compilation a first-class target-aware graph node, and let package maintainers publish declarative recipes that the compiler can cache and diagnose.”

#### Rust: `-sys` crates make maintainers the integration layer

Cargo permits a package `build.rs` to probe the machine, compile vendored code, and emit link-search and link-library directives. The `links` manifest key prevents two packages from claiming the same native library and lets a low-level crate publish metadata to dependent crates ([Cargo build scripts](https://doc.rust-lang.org/cargo/reference/build-scripts.html)). The ecosystem convention is a low-level `foo-sys` crate containing raw declarations and native-link logic, with a separate crate providing an idiomatic safe API. Cargo’s own examples show `pkg-config` discovery on Unix ([Cargo build-script examples](https://doc.rust-lang.org/cargo/reference/build-script-examples.html)).

This works when the `-sys` maintainer absorbs the mess: common crates try a system `pkg-config` installation, accept environment overrides, support a `vendored` feature, use the `cc` crate to compile source, or use vcpkg on Windows. The application author sees a feature flag; the sys-crate author sees every target-specific failure. Cargo’s build scripts are arbitrary host executables, so they are flexible but not intrinsically hermetic, remotely cacheable, or safe to execute. Cross compilation also exposes the distinction between the **host** running `build.rs` and the **target** whose `pkg-config` metadata, compiler, and library are required.

The lesson for Luce is the package split—raw native package versus safe wrapper—and the value of a single package owning a native link identity. The arbitrary-code build-script mechanism conflicts with Luce’s existing design goal of no package build scripts, plugins, ambient environment reads, or compilation-time network access. Luce should preserve that goal and accept a smaller but inspectable recipe language.

#### Go: language-level cross-compilation stops at the C boundary

The official cgo documentation makes the boundary explicit. cgo invokes a C compiler, accepts C compiler/linker flags and `pkg-config` directives, and compiles C files in the package. During cross compilation cgo is disabled by default; enabling it requires a working target C compiler selected with `CC_FOR_TARGET` or `CC` ([cgo command documentation](https://pkg.go.dev/cmd/cgo)). The target compiler is only the first prerequisite: target headers, target libraries, sysroot, and compatible `pkg-config` results must also exist.

Pure-Go packages cross-compile smoothly because the Go distribution owns their complete code-generation path. A cgo package reintroduces the native toolchain and dependency-distribution problem. Go modules version source packages, but do not by themselves deliver arbitrary system C libraries. cgo is therefore a warning against marketing “cross compilation” as a compiler flag: Luce must test the claim specifically with native dependencies enabled.

#### Odin: rich vendored bindings are not the same as portable dependency delivery

Odin deliberately has no official package manager ([Odin FAQ](https://odin-lang.org/docs/faq/)), but its source tree includes an extensive `vendor` collection, including SDL3, Metal, Vulkan, D3D12, and WGPU ([Odin vendor packages](https://pkg.odin-lang.org/vendor/)). This is convenient for declarations and examples.

The SDL3 package demonstrates the distribution limit. Its generated documentation reports 378 types and 1,381 procedures ([Odin SDL3 package](https://pkg.odin-lang.org/vendor/sdl3/)). The actual foreign-import selection uses shipped SDL3 library artifacts for Windows and `system:SDL3` on other desktop systems ([Odin SDL3 foreign import](https://github.com/odin-lang/Odin/blob/master/vendor/sdl3/sdl3__foreign.odin)). The repository’s Git LFS pointers identify a roughly 2.79 MB Windows DLL and 284 KB import library, while macOS and Linux consumers still need a discoverable installation. Odin has solved a large binding-maintenance problem and one binary target, not the whole three-OS application-delivery problem.

#### SwiftPM: binary targets work when the publisher owns a bounded matrix

Swift Package Manager added checksum-verified binary targets initially around Apple XCFrameworks. An XCFramework can collect variants for Apple platforms and architectures, and a package may mix source and binary targets ([SE-0272](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0272-swiftpm-binary-dependencies.md)). Artifact bundles later generalized target-triple variant selection for executable tools ([SE-0305](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0305-swiftpm-binary-target-improvements.md)).

Swift 6.2’s static-library binary target work is especially instructive. It adds non-Apple `.a`/`.lib` artifacts with headers/module maps, but deliberately limits the first version to C libraries whose dependencies do not extend beyond the platform C runtime, because expressing and resolving arbitrary transitive native dependencies is the difficult part ([SE-0482](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0482-swiftpm-static-library-binary-target-non-apple-platforms.md)). SDL is outside that deliberately easy subset once window-system, audio, graphics, and SDK link requirements enter the picture.

Binary targets provide excellent installation ergonomics when a trusted publisher builds and tests every supported tuple. Their costs are matrix multiplication, download size, signing/provenance, security updates, deployment-baseline choices, and the inability to let downstream users freely change compile-time features. XCFramework success should not be generalized into “binaries solve native dependencies”; it means Apple supplied a good container for a controlled family of Apple ABIs.

### 1.2 The model Luce should adopt

Luce should offer three explicit resolution modes, in this preference order for application developers:

| Mode | Intended user | Mechanism | Strength | Cost/failure mode |
|---|---|---|---|---|
| **Pinned source** | Normal application build | Fetch by immutable content hash outside compilation, apply declared patches, compile with Luce’s selected target C toolchain, cache by complete input identity | Reproducible features; best cross-target control; no ABI skew | Recipe author owns upstream configuration and build fixes |
| **Verified artifact** | Fast CI, very large dependencies, proprietary SDKs | Download a signed/checksummed artifact variant selected by an exact target profile | Fast and predictable when a variant exists | Publisher owns a large matrix and emergency rebuild channel |
| **System** | Distribution packagers and advanced integrators | Search only declared prefixes/toolchain roots, then optionally `pkg-config`/platform framework metadata; record the resolved file and version | Respects OS security updates and distro policy | Ambient state, version skew, weak cross compilation, poor novice experience |

“Auto” may choose a cached source result or a matching verified artifact, but it should **not silently fall through to whatever library happens to be installed**. A system dependency should be requested explicitly or surfaced in the lockfile/build record. Otherwise identical project sources can link different ABIs on two machines.

The native recipe needs to remain declarative while being richer than a list of link flags. At minimum it needs:

- upstream URL/mirror, immutable digest, license files, patch digests, and source subdirectory;
- supported target predicates and a stable recipe-format version;
- C language mode, target triple, CPU features, sysroot/SDK identity, minimum OS or libc baseline, and debug/release CRT choice;
- source lists and target-conditioned exclusions, include roots, forced includes, preprocessor definitions, generated configuration headers, and permitted code-generation tools;
- C, Objective-C, Objective-C++, and assembly inputs as distinct language kinds;
- static/shared selection, position-independent code, symbol visibility, library ordering, OS frameworks, import libraries, and weak/optional system libraries;
- public headers and the exact preprocessing environment used by the binding generator;
- runtime payload files, install names/SONAMEs/DLL names, destination subdirectories, and loader-path policy;
- declared build outputs and a deterministic probe/verification suite.

Every artifact cache key must include the recipe and patch content, dependency graph, target profile, toolchain and sysroot identities, all compiler/linker flags, feature set, and relevant generated inputs. Caching only by `SDL-3.4.10 + x86_64-linux` is incorrect: Wayland on/off, glibc baseline, LTO, static/shared, and compiler version can change both symbols and code.

A `luce doctor --target …` operation is as important as the happy path. It should report the selected recipe mode; C compiler and linker; SDK/sysroot; every discovered system package and version; missing headers/tools; chosen runtime loader paths; deployment baseline; and why an available artifact was rejected. The right error is “Wayland support requested; `wayland-scanner` and protocol XML version X are unavailable in target sysroot Y,” not a hundred-line C compilation failure.

### 1.3 “Vendor the C source” versus “find a system library”

The choice moves cost; it does not eliminate it.

| Concern | Vendored source | System library |
|---|---|---|
| First user experience | Usually one command after source acquisition | Often a platform-specific install tutorial |
| Reproducibility | Strong if recipes and toolchains are pinned | Weak unless an image/sysroot is pinned |
| Security fixes | Luce/package owner must update and republish | Distro may patch without app rebuild |
| Cross compilation | Good if target SDK and all generated tools exist | Often fails because discovery returns host metadata |
| Feature consistency | Recipe controls it | Distro configuration varies |
| ABI/header match | Same build produces both | Easy to mix header and binary versions |
| Build time/cache | Higher cold cost; excellent content-cache opportunity | Near zero |
| Licensing/notices | Package must retain and surface them | Still required for distribution, but distro helps |
| Platform integration | Recipe must track frameworks and SDK changes | Packager has already integrated them |
| Maintenance owner | Luce package maintainer | User plus OS/distro packager |

For a language whose promise is application development, pinned source should be the default for a small curated foundation set. For general C ecosystem compatibility, system discovery is still necessary. Trying to source-vendor every possible C dependency would turn the one-person compiler team into a cross-platform distribution.

### 1.4 SDL3 as the concrete cost case

The current stable release at research time is [SDL 3.4.10](https://github.com/libsdl-org/SDL/releases/tag/release-3.4.10). Measurements of the official 15,606,216-byte source tarball after extraction give:

| Measurement | SDL 3.4.10 |
|---|---:|
| Extracted tree | about 52 MiB |
| Files in tree | 2,181 |
| Files under `src` + `include` | 1,443 |
| Physical lines in `.c`, `.h`, `.m`, `.mm` under those roots | about 656,300 |
| Top-level `CMakeLists.txt` | 4,356 lines |
| Public-header `#define` directives under `include/SDL3` | 11,755 |
| Lexically function-like public macros | 321 |

These are workload indicators, not a claim that Luce must understand every line: SDL contains generated tables, bundled protocol material, platform implementations, tests, shaders, and headers for APIs an application may not use. They do show why “just compile all the `.c` files” is not a recipe. SDL’s [top-level CMake configuration](https://github.com/libsdl-org/SDL/blob/release-3.4.10/CMakeLists.txt) selects mutually exclusive drivers, generates configuration, probes headers and functions, and coordinates Objective-C, assembly, Windows resources, and platform link dependencies.

On Linux, SDL’s runtime strategy is unusually distribution-friendly. Its Linux documentation says the default SDL shared library normally links only to glibc and dynamically loads most optional backends; a missing subsystem generally disables that feature instead of preventing process startup ([SDL Linux README](https://wiki.libsdl.org/SDL3/README-linux)). A full-feature **build**, however, still needs development inputs for several families:

- X11 plus Xext/Xcursor/Xfixes/Xi/Xrandr/Xss and related headers;
- Wayland client libraries, `wayland-scanner`, Wayland protocol XML, xkbcommon, and often libdecor;
- ALSA, PulseAudio, JACK, sndio, and PipeWire headers, depending on requested audio backends;
- udev, dbus, ibus, usb, DRM/GBM, OpenGL/EGL, and Vulkan development components for the selected input/video/GPU features;
- on newer distributions, optional liburing and other feature-specific inputs.

Dynamic loading moves those libraries out of SDL’s ELF `DT_NEEDED` set; it does not make their declarations, protocol generation, configuration tests, or runtime semantics disappear. A static SDL archive also does not statically absorb the X server, compositor, PipeWire daemon, or GPU driver. “Hermetic native dependency” must mean hermetic **build inputs that are legally redistributable**, not isolation from operating-system services.

The sensible first Luce SDL recipe is therefore a curated profile, not “all SDL options”:

- macOS: Cocoa, Metal/SDL_GPU, standard input/audio, arm64 and x86_64 as separate builds, linked against declared Apple frameworks from the selected SDK;
- Windows x64: Win32, WASAPI, D3D12/SDL_GPU and/or Vulkan, with the chosen Windows SDK or MinGW target explicitly identified;
- Linux x86_64 glibc: X11 **and** Wayland, xkbcommon, udev, ALSA and PipeWire/PulseAudio as chosen, Vulkan, and runtime dynamic loading where upstream supports it;
- headless/offscreen and exotic audio/video backends only when a real Luce use case requests them.

For the first self-contained applications, building SDL statically into the executable reduces DLL/dylib/SO placement and version-skew problems. Luce must still offer a shared/system mode for Linux distribution packaging and users that require independent SDL upgrades. The SDL zlib license permits either, but Luce must propagate notices and a software bill of materials.

The initial engineering cost of a trustworthy three-platform SDL source recipe is plausibly **six to ten focused engineer-weeks**, not an afternoon: source selection and configuration, three toolchain integrations, dependency diagnostics, static/shared details, cache identity, minimal-version CI, and runtime bundle tests. A new SDL point release should then cost hours to several days when it is routine and longer when drivers/build logic change. A generic CMake-compatible executor would be a much larger project and would reintroduce arbitrary configure-time execution; Luce should use upstream CMake as an oracle and validation path, not try to clone CMake semantics.

The dividing line should be explicit: Luce can make a **curated SDL profile** effortless. It cannot make every possible SDL backend and every Linux distribution combination effortless without becoming an SDL distribution maintainer.

## 2. The C ABI problem in depth

“C ABI” is not one specification. It is the combination of a target data model, compiler record-layout rules, processor ABI, operating-system additions, function calling convention, object-file format, linker naming, and sometimes compiler-version compatibility. A declaration that is correct on x86-64 Linux can be wrong on x86-64 Windows even though both use 64-bit registers. An arm64 call that works on Linux can corrupt a variadic call on Apple silicon.

For each imported function, the frontend must solve five distinct problems:

1. Reproduce the C type and record layout for the exact target and preprocessing configuration.
2. Apply that target’s C ABI classification to every parameter and result.
3. transform the source-level signature into an ABI-level LLVM signature, including scalar extension, coercion, splitting, indirect copies, and hidden parameters.
4. Generate the caller-side packing/copying and callee-side reconstruction required by that signature.
5. Select the right symbol, object format, calling convention, import/export attributes, and library.

LLVM is extremely useful for the last machine-level step, but it does not replace the first four.

### 2.1 C layout precedes calling-convention classification

The classifier cannot run on a Luce record that merely “looks equivalent.” It needs the exact C size, alignment, field offsets, and field types. Important target differences include:

| Property | 64-bit Linux/macOS | Windows x64 | Why it matters |
|---|---|---|---|
| Data model | LP64: `long` and pointer are 64-bit | LLP64: `long` is 32-bit, pointer is 64-bit | A translated `long` cannot map to one target-neutral Luce integer |
| `wchar_t` | Commonly 32-bit on Unix | 16-bit | Text APIs and structures differ |
| `long double` | Commonly 80-bit extended value in a 16-byte slot on x86-64 SysV | Same representation as `double` in MSVC | Layout and return class differ |
| Apple arm64 `long double` | Same as `double` | N/A | Generic AArch64 assumptions are wrong |
| Enum representation | Usually target/compiler-selected compatible integer, affected by flags | MSVC rules and flags differ | Size must come from the configured C frontend |
| Default packing | Target/compiler default | MS headers frequently alter packing around declarations | Offsets and even pass mode can change |

For a record, Luce must preserve base and nested-record layout, arrays, unions, anonymous members, internal and tail padding, effective alignment, flexible-array members, and zero-sized/compiler-extension cases. It must honor `#pragma pack`, `__attribute__((packed))`, `aligned`, and MSVC `__declspec(align)` under the exact compiler compatibility mode. A packed field may be unaligned even when its scalar type normally is aligned; on SysV AMD64 that alone can force the whole argument to the MEMORY class.

Bitfields are worse. The C standard leaves major allocation details to the implementation: storage-unit selection, ordering within the unit, whether a bitfield can straddle units, the effect of a zero-width bitfield, and the signedness of plain `int` bitfields. Packing flags and MS-compatibility switches alter these rules. A bitfield does not have an address or an independently callable ABI type. The safe policy is to store its containing record as opaque bytes in raw bindings and emit C-compiled getter/setter shims, unless Luce has reproduced and verified the precise Clang layout for that target. Rust bindgen takes the same essential approach by generating a storage unit and accessors rather than pretending each bitfield is an ordinary language field ([bindgen bitfield documentation](https://rust-lang.github.io/rust-bindgen/using-bitfields.html)).

Clang is the right parser and record-layout authority for imported headers. The FIIR should record, per target and header configuration, the C spelling, canonical type, size, ABI alignment, preferred alignment where relevant, field bit offsets and widths, packing/alignment attributes, and whether a record is safe to expose structurally. It should not infer those facts later from a target-neutral Luce type.

### 2.2 System V AMD64: recursive eightbyte classification

The authoritative specification is the [x86-64 psABI](https://gitlab.com/x86-psABIs/x86-64-ABI). Its aggregate rule is often summarized as “small structs go in registers,” which hides the part a compiler must implement.

The classifier conceptually rounds an aggregate to eight-byte chunks (“eightbytes”) and assigns each chunk one of these classes:

| Class | Meaning at the call boundary |
|---|---|
| `NO_CLASS` | Empty/unclassified portion; neutral during merging |
| `INTEGER` | Integer or general-purpose register |
| `SSE` | Vector/SSE register head |
| `SSEUP` | Upper portion of the preceding vector register value |
| `X87`, `X87UP`, `COMPLEX_X87` | x87-specific values and continuations |
| `MEMORY` | Pass/return through memory rather than ordinary argument/result registers |

The mechanism, simplified only where the psABI has vector-extension details, is:

1. Compute the exact size and alignment. A nontrivial C++ object, an aggregate that violates the ABI size rules, or a record containing an unaligned field becomes `MEMORY` immediately. C++ nontriviality is one reason Luce should restrict the first importer to C.
2. Classify scalar leaves: integer types and pointers as `INTEGER`; `float`, `double`, and vector components as `SSE`/`SSEUP`; x87 values into their special classes.
3. Recursively classify nested aggregate fields into the eightbytes they overlap, then merge classes. Equal classes remain unchanged; `NO_CLASS` yields to the other class; `MEMORY` wins; then `INTEGER` wins over floating/vector classes; incompatible x87 combinations force `MEMORY`; remaining compatible floating/vector combinations resolve to `SSE`.
4. Perform post-merge cleanup. An `X87UP` must directly follow `X87`; invalid wide aggregate patterns become `MEMORY`; a stray `SSEUP` is normalized. Ordinary C records larger than two eightbytes generally end up in memory, while ABI-supported wide vector-shaped values are the notable exception.

After classification, allocation is all-or-nothing for one aggregate. Integer-class chunks consume, in order, `RDI`, `RSI`, `RDX`, `RCX`, `R8`, and `R9`; SSE chunks consume `XMM0` through `XMM7`. If all chunks of the aggregate do not fit in the remaining registers, the allocator rolls back the tentative assignments and passes the whole aggregate on the stack. It must not pass the first half in a register and the second half on the stack. Independent integer and SSE register pools mean a two-chunk `{ double, int }` can consume one XMM register and one GPR.

Examples show why size alone is insufficient:

| C-shaped value | Typical SysV AMD64 result |
|---|---|
| two `double`s | two `SSE` eightbytes, normally XMM registers |
| `double` followed by a 32-bit integer | `SSE` plus `INTEGER`, using both register banks if available |
| three 32-bit integers in a 12-byte record | two `INTEGER` chunks |
| packed record containing an unaligned `double` | `MEMORY`, despite being small |
| ordinary record larger than 16 bytes | normally `MEMORY` |

Stack arguments are laid out with the alignment required at the call boundary; the stack is 16-byte aligned at the required point, and the ABI defines a 128-byte red zone below the stack pointer for leaf-function use. Return classification uses the same classes but fixed result registers: integer chunks use `RAX` then `RDX`; SSE chunks use `XMM0` then `XMM1`. A `MEMORY` result uses caller-provided storage: a hidden result pointer is passed in `RDI`, normal arguments shift, and the callee also returns that address in `RAX`. This is commonly called `sret`, but the exact hidden-register rule is ABI-specific.

Variadic SysV calls require more than default C promotions. The caller sets the low byte of `RAX` (`AL`) to the number or upper bound of vector registers used for arguments, and the callee’s `va_start` logic works with a prescribed register-save area and overflow stack area. A Luce caller that passes the visible values correctly but omits `AL` can still break `va_arg` for floating-point values.

Apple’s Intel ABI is close enough to share most machinery but is not a reason to label one implementation “all x86-64.” Apple documents differences including treatment of narrow integer arguments and certain vector/aggregate cases in [Writing 64-bit Intel code for Apple platforms](https://developer.apple.com/documentation/xcode/writing-64-bit-intel-code-for-apple-platforms). Every supported OS/architecture pair deserves its own named ABI profile and differential tests.

### 2.3 Generic AArch64 AAPCS64

The [AAPCS64 specification](https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst) uses a different staged allocation algorithm:

- `x0`–`x7` are the eight general-purpose argument/result registers; `v0`–`v7` are the eight floating-point/SIMD argument/result registers.
- A homogeneous floating-point aggregate (HFA) or homogeneous short-vector aggregate (HVA) containing one to four identical eligible elements uses one vector register per element if enough remain. Thus a record of four `float`s is not treated like an arbitrary 16-byte integer blob.
- A non-HFA composite no larger than 16 bytes is copied into one or two general-purpose registers when enough consecutive argument registers remain. Conceptually it is loaded as though into one or two 64-bit words, with byte ordering determined by endianness.
- A composite larger than 16 bytes is copied by the caller to suitably aligned memory and the argument becomes a pointer to that copy.
- If an aggregate that needs registers cannot be allocated as a unit, it goes to the stack; it is not partially split between registers and stack.
- Overalignment and 16-byte scalar/composite rules affect register-number rounding and stack padding, so a “next register” counter is part of the actual algorithm.

Results broadly follow the corresponding argument classification. Small integer/composite results use `x0`/`x1`; HFA/HVA results use `v0`–`v3`; large or otherwise indirect results use caller-owned memory whose address is passed in `x8`, the dedicated indirect-result register. This differs from SysV AMD64, where the hidden result pointer occupies the first normal integer argument register.

The generic variadic ABI specifies a `va_list` state that can address stack arguments, the saved general-register area, and the saved vector-register area with offsets. A variadic callee therefore has prescribed register-spill behavior. That mechanism must not be copied to Apple arm64.

### 2.4 Apple arm64 is an ABI variant, not merely an object-file variant

Apple documents its departures in [Writing ARM64 code for Apple platforms](https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms). Important compiler-facing differences include:

- `x18` is reserved by the platform and must not be treated as an allocatable general-purpose register.
- Stack arguments use compact natural-size slots rather than always consuming 8-byte multiples. The caller and callee must agree on those exact offsets.
- The generic AAPCS64 rule that can skip an odd register before a 16-byte-aligned argument is relaxed; Apple can begin such an argument in the next available register.
- The caller extends integer arguments narrower than 32 bits to 32 bits.
- `long double` has the same representation as `double`.
- Apple defines a 128-byte red zone and platform-specific frame/unwind conventions.

The largest trap is variadics. After all named parameters, Apple arm64 places unnamed variadic arguments on the stack in slots aligned to at least 8 bytes instead of continuing to use the ordinary argument registers, and its `va_list` is effectively a stack pointer (`char *`) rather than generic AAPCS64’s multi-area structure. Default C promotions still apply: `float` becomes `double`, and narrow integer types become `int`/`unsigned int` as required. A frontend that selects generic AAPCS64 because the target CPU says `aarch64` will silently miscompile variadic Apple calls.

This is a strong argument for target profiles such as `aarch64-apple-macos` and `aarch64-unknown-linux-gnu` carrying an explicit ABI implementation identifier, not branching ad hoc on pointer width or CPU architecture.

### 2.5 Windows x64 and 32-bit Windows conventions

The Microsoft [x64 calling-convention documentation](https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention?view=msvc-170) describes a deliberately compact but very different convention:

- There are four **positional** register slots. Integer/pointer arguments in positions one through four use `RCX`, `RDX`, `R8`, and `R9`; floating-point arguments in those positions use `XMM0`–`XMM3`. Unlike SysV, these are not two independently packed register streams.
- The caller always reserves 32 bytes of “shadow space” (home space) for the callee’s four register parameters, whether or not the callee spills them.
- The stack is maintained at 16-byte alignment outside restricted prolog/epilog regions, and unwindable non-leaf functions require prescribed unwind metadata.
- Scalar aggregates of exactly 1, 2, 4, or 8 bytes can be passed as integer values. Other aggregate sizes—including a typical 12- or 16-byte record—are generally passed by reference to a caller-created, 16-byte-aligned temporary. An aggregate is never spread over multiple argument registers.
- Floating/vector types and compiler-specific vector conventions have additional rules; a 128-bit vector is not an excuse to pass an arbitrary 16-byte struct the same way.

Small scalar and qualifying POD-like record results use `RAX`; floating results use `XMM0`. Other records use a hidden caller-storage pointer in `RCX`, shifting the first visible parameter to the next slot, and return the storage address in `RAX`. The exact MSVC eligibility rules for returning a user-defined type in `RAX` include size and triviality constraints; an importer should use Clang’s MS ABI decision, not a home-grown “size <= 8” approximation.

For unprototyped or variadic functions, each floating argument in one of the first four positions must be duplicated into both its XMM register and corresponding general-purpose register so the callee can consume it through varargs. Arguments after the fourth position are on the stack. This is completely different from SysV’s `AL` vector-count protocol and Apple arm64’s stack-only unnamed tail.

On 64-bit Windows, source annotations such as `__stdcall` and `__fastcall` generally collapse into the unified x64 convention. They matter on 32-bit x86 and must be represented in FIIR:

| Win32 convention | Core rule | Symbol decoration (typical MS toolchain) |
|---|---|---|
| `__cdecl` | right-to-left stack arguments; caller pops; supports varargs | leading underscore |
| `__stdcall` | right-to-left stack arguments; callee pops; common Win32 API convention | `_name@bytes` |
| `__fastcall` | first eligible arguments in `ECX`/`EDX`, remainder on stack; callee pops | `@name@bytes` |

Microsoft documents the switches and defaults in its [calling-convention reference](https://learn.microsoft.com/en-us/cpp/build/reference/gd-gr-gv-gz-calling-convention?view=msvc-170) and the [`__stdcall` reference](https://learn.microsoft.com/en-us/cpp/cpp/stdcall?view=msvc-170). A future Windows arm64 target is another distinct profile; it must not inherit either Windows x64 or generic ELF AAPCS64 merely from the CPU family.

### 2.6 Aggregate calls and returns: the differences at a glance

| Case | SysV AMD64 | AAPCS64 | Apple arm64 | Windows x64 |
|---|---|---|---|---|
| Ordinary small record | Recursively classified into up to two eightbytes and possibly mixed GPR/XMM registers | Up to 16 bytes in one/two GPRs unless HFA/HVA | Similar base rule with Apple alignment/packing changes | Only 1/2/4/8-byte aggregates directly; most others by pointer |
| Homogeneous float record | SSE classes, subject to eightbyte merge | 1–4 members in `v0`–`v3` etc. | HFA rules with Apple platform variant | Ordinary struct generally not treated as four FP register arguments |
| Large argument | Stack value (`MEMORY`) | caller copy plus pointer when >16 bytes | caller copy plus pointer, Apple allocation details | caller copy plus pointer |
| Indirect result pointer | consumes first normal GPR (`RDI`) | dedicated `x8` | dedicated `x8` | hidden first slot in `RCX` |
| Variadic FP protocol | XMM args plus `AL` count; register save area | generic GPR/vector save areas | unnamed tail on 8-byte-aligned stack slots | duplicate first-four FP values in XMM and GPR |

Even “by reference” is not one operation. Some ABIs require the caller to create a private copy with a specific alignment; `const T *` in the source signature does not mean the same thing. Similarly, an `sret` pointer can be noalias/write-only in practice, may need an LLVM `sret(T)` attribute and alignment, and shifts or does not shift visible parameters according to the target.

### 2.7 Varargs should be contained, not celebrated

Calling a variadic C function requires:

- knowing the fixed prototype exactly;
- applying the C default argument promotions at the call site;
- using target-specific placement, duplication, counts, and stack alignment;
- preserving ABI-specific `va_list` only if Luce implements a variadic callee or forwards the list;
- respecting format-string type contracts that the ABI cannot verify.

There is no useful fully safe Luce type for arbitrary `...`. The first implementation should expose only generated, typed adapters: logging functions by fixed overloads, `printf`-like calls behind checked formatting, and C shims for libraries whose variadic API cannot be avoided. Imported `va_list` should be opaque and target-specific. Defining a generic Luce `VaList` record is incorrect.

The same containment principle applies to callbacks. A C function pointer needs the target calling convention; a captured Luce closure additionally needs a stable trampoline and context pointer, ARC retention/release rules, cancellation/lifetime handling, thread-entry registration, and a policy that prevents Luce panic/unwind from crossing C frames. These are not machine ABI classification, but they determine whether the FFI is usable rather than merely able to call a leaf function.

### 2.8 Exactly what LLVM does—and does not—do

LLVM’s backend knows how to turn an **already ABI-lowered LLVM function signature** into machine registers, stack slots, call instructions, unwind information, and object-file relocations for a selected LLVM calling convention. Its [Language Reference](https://llvm.org/docs/LangRef.html) defines the pieces a frontend uses to describe the contract, including `signext`, `zeroext`, `inreg`, `byval`, `sret`, `align`, `inalloca`, and `preallocated`. ABI-impacting attributes generally must agree at the declaration and each call site.

LLVM does not receive a Clang `QualType`, active `#pragma pack`, C bitfield allocation, MSVC triviality decision, HFA semantic element type, or Apple-versus-generic `va_list`. An LLVM `DataLayout` can lay out an LLVM struct, but it cannot decide that this source-level C record should be coerced to `{ double, i64 }`, expanded into two parameters, copied to an aligned temporary and passed as a pointer, or returned through a hidden pointer. Nor can it reconstruct information erased when the Luce importer mapped C `long`, enum, vector, or packed fields to an imprecise Luce type.

The frontend therefore must, for each argument/result:

- choose ignore, direct, extended, indirect, expanded, coerced-and-expanded, or target-special handling;
- construct the exact LLVM coercion type and any padding pieces;
- add hidden result/context parameters in the correct position;
- set ABI attributes and their alignments/types;
- generate temporary copies and marshal between the Luce value and lowered pieces;
- lower the call site identically to the declaration;
- apply variadic promotions and target-specific call metadata.

Clang implements this above the generic LLVM backend. Its target CodeGen files contain ABI-specific classifiers—for example [Clang’s x86 ABI implementation](https://github.com/llvm/llvm-project/blob/main/clang/lib/CodeGen/Targets/X86.cpp) and [AArch64 ABI implementation](https://github.com/llvm/llvm-project/blob/main/clang/lib/CodeGen/Targets/AArch64.cpp). The central `ABIArgInfo` representation has modes such as Direct, Extend, Indirect, Expand, CoerceAndExpand, InAlloca, and Ignore ([Clang `ABIArgInfo` documentation](https://clang.llvm.org/doxygen/classclang_1_1CodeGen_1_1ABIArgInfo.html)). Clang classifies the C semantic type, builds a lowered `CGFunctionInfo`, emits the LLVM declaration with attributes, and generates prolog/call/epilog coercions.

This is why “we use LLVM, so C calls are handled” is false. LLVM has ongoing experimental work toward a reusable ABI-lowering library ([LLVM ABI-lowering RFC](https://discourse.llvm.org/t/rfc-an-abi-lowering-library-for-llvm/84495)), but it is not yet a stable, public, target-complete replacement for Clang CodeGen. Luce cannot responsibly base near-term portability on an experimental subset.

There are four implementation choices:

| Approach | Near-term cost | Long-term characteristics |
|---|---:|---|
| Generate a C wrapper and let Clang compile both sides of the hard boundary | Lowest | Robust and testable; adds generated symbols/copies; still needs a narrow scalar/pointer C ABI between Luce and shim |
| Ask a custom Clang-based helper to expose CodeGen ABI decisions | Medium/high | Reuses truth, but depends on unstable Clang internal C++ APIs and ships a large/version-locked tool |
| Generate tiny C stubs, have Clang emit LLVM IR, and recover lowered signatures | Medium | Treats Clang as an executable oracle; IR parsing/mapping and optimization-independent metadata need careful design |
| Implement/port each ABI classifier in Luce | Highest initial and verification cost | Removes runtime Clang CodeGen dependency and gives control; creates permanent ABI maintenance responsibility |

The stable libclang C API is excellent for parsing, canonical types, source locations, constants, and many layout queries; it does **not** expose the complete target CodeGen `ABIArgInfo` decision for every parameter and return. A Clang-based FIIR importer therefore does not automatically solve direct-call lowering. This gap should be called out in the design now rather than discovered after binding generation works.

### 2.9 Recommended ABI strategy for Luce

The fastest correct bootstrap is a deliberately narrow, stable Luce-to-C gateway:

- permit fixed-prototype scalar integers/floats, pointers, opaque handles, and explicitly tested callbacks;
- represent public SDL records behind C accessors or pointers where practical;
- compile generated C/Objective-C shims with Clang for by-value records, unions, bitfields, macros, varargs, and target-special APIs;
- use that gateway to ship the first window/event/GPU vertical slice.

In parallel, design FIIR to be capable of direct lowering. Each imported function should record the target profile, source calling convention, whether it is variadic, result mode, each argument mode, exact coercion/expansion type, hidden-parameter positions, required LLVM attributes/alignment, and the evidence/toolchain version that produced the decision. Target-neutral API identity and target-specific ABI realizations should be separate records; the same header declaration can lower differently for four targets.

Direct classifiers should arrive one target at a time and be differential-tested against Clang:

1. Generate a corpus combining scalar widths, enums, pointers, vectors, nested records, arrays, unions, HFAs, mixed float/integer chunks, packed/overaligned fields, empty records where supported, and every boundary size/alignment.
2. Ask the same pinned Clang to emit record layouts, LLVM IR, and assembly for caller and callee specimens.
3. Compare Luce’s lowered signature, attributes, register/stack outcome, and runtime round trips against a C echo library.
4. Run both directions—Luce calls C and C calls exported Luce—and callbacks, because one-sided tests miss reconstruction errors.
5. Repeat under release optimization, LTO-off/on where supported, each minimum SDK/sysroot, and sanitizer builds; ABI bugs often disappear in debug memory layouts.

A narrow scalar/pointer FFI on one target is a weeks-scale feature. Full, production-quality direct ABI coverage for SysV AMD64, Apple x86-64, AAPCS64 ELF, Apple arm64, Windows x64, and Win32 conventions is plausibly **two to four focused engineer-months after the importer and LLVM backend are stable**, plus permanent regression work. Generated shims reduce the critical path and provide a correctness fallback; they are not an embarrassing temporary hack.

## 3. Binding generation: declarations are the easy half

A binding generator performs two very different translations:

1. **Mechanical/raw translation:** names, constants, type graphs, layouts, functions, global variables, calling conventions, and availability conditions.
2. **Semantic/safe translation:** ownership, lifetime, nullability, error handling, buffer lengths, string encoding, callback threading/cancellation, and API shape.

The first is substantially automatable. The second generally is not present in C headers, and incorrect guesses are more dangerous than an explicitly unsafe raw API.

### 3.1 Hand-written versus generated bindings

| Strategy | Where it excels | Failure mode | Appropriate Luce use |
|---|---|---|---|
| Hand-written narrow bindings | Small stable API; excellent names/docs; fastest vertical slice | Omissions and layout drift; tedious platform/version maintenance | Initial SDL adapter and curated safe layer |
| Header-generated raw bindings | Broad coverage; repeatable updates; preserves obscure declarations | Macro/extensions gaps; noisy API; no ownership model | Canonical `sdl3.raw` and general C packages |
| Generated C shim plus raw bindings | Handles macros, inline functions, bitfields, varargs, C/ObjC compiler extensions | Extra compilation/symbol layer; generator complexity | Required escape hatch, especially during ABI bootstrap |
| Fully generated “safe” wrapper | Attractive demos for simple APIs | Invented ownership/lifetime rules cause leaks, use-after-free, or deadlock | Do not make this the default |

For SDL specifically, a hand-written subset is reasonable for the first milestone: initialization, window creation/destruction, event polling through accessor functions, GPU device/resource ownership, and a small set of error/string helpers. Hand-writing all 1,381 procedures represented by Odin’s current SDL binding is not a sustainable maintenance plan. The raw surface should become generated early, while the safe wrapper stays curated.

### 3.2 Why a real C frontend is required

Regex and a bespoke header parser fail because a header is a preprocessor program whose resulting token stream depends on target, compiler mode, language mode, include paths, SDK version, and definitions. Rust bindgen requires libclang because Clang performs preprocessing, parsing, and type checking ([bindgen requirements](https://github.com/rust-lang/rust-bindgen/blob/main/book/src/requirements.md)). Zig’s translation documentation similarly warns that the same target and C flags used to build the library must be used when translating its headers or subtle ABI incompatibilities result ([Zig C translation](https://ziglang.org/documentation/master/#C-Translation)).

The import identity must therefore include at least:

- all header bytes and transitive includes;
- include search order and framework paths;
- target triple, CPU/ABI flags, language standard, and C versus Objective-C mode;
- sysroot/SDK and Clang resource-directory identity;
- every `-D`/`-U`, packing, short-enum, MS-compatibility, visibility, and feature macro;
- Clang major/versioned behavior and Luce generator version.

If the SDL library was built with Wayland disabled but the importer sees headers/config macros saying it is enabled, the binding may contain symbols that do not exist. If the importer sees default packing while the library was compiled under a pack pragma or ABI flag, calls can link and then corrupt memory. The generated module and native artifact must be two outputs of the **same recipe execution**, not independently cached conveniences.

### 3.3 What libclang can translate well

After preprocessing and semantic analysis, a Clang-based generator can reliably inventory:

- functions, fixed prototypes, typedef chains, canonical scalar/pointer types, and declared calling conventions;
- records/unions, fields, arrays, source comments, sizes, alignments, and many offsets;
- enumerators and object-like constants whose value Clang can evaluate;
- function-pointer typedefs and callback signatures;
- target availability/deprecation attributes and source locations;
- declarations selected by the current preprocessor configuration.

That is enough for a high-quality raw module when combined with target-aware FIIR and ABI lowering. It is not enough to produce one universal generated file if record layout or declarations vary by target. Luce can either generate a portable conditional source module from multiple FIIR variants or generate/cache a target-specific raw module. The latter is simpler initially and avoids embedding C preprocessor logic into Luce source.

### 3.4 Macro-heavy headers and the genuinely hard cases

Macros are token substitution, not declarations. The Clang AST normally represents the declarations that remain after preprocessing; a function-like macro may not have a type, address, or single-evaluation behavior that maps to a Luce function. Hard cases include:

- token pasting and stringification that manufacture identifiers or syntax;
- macros whose meaning depends on `sizeof`, target features, compiler builtins, or active configuration;
- statement expressions, `typeof`, `_Generic`, compound literals, and control-flow macros;
- macros that evaluate arguments more than once or require an lvalue;
- variadic macros and wrappers around variadic functions;
- object-like constants too large or type-sensitive for a simplistic integer evaluator;
- macro aliases that choose platform-specific symbols or calling conventions;
- static inline functions containing goto, atomics, SIMD builtins, inline assembly, or other compiler extensions.

Zig’s documented translation limitations include `goto`, some bitfields, token-pasting macros, and constructs that become `@compileError` or opaque declarations ([Zig C translation](https://ziglang.org/documentation/master/#C-Translation)). These are not signs of a weak implementation; they are places where translating C syntax into another language changes semantics or requires implementing much of C.

SDL 3.4.10’s public headers contain 11,755 `#define` directives by lexical count and 321 function-like definitions. Many are benign include guards, version tests, numeric constants, aliases, calling-convention markers, or platform gates. The count still means a generator needs an explicit macro policy:

1. Import evaluated object constants when Clang can prove a target-specific value and type.
2. Convert simple, side-effect-safe function-like expressions only after semantic validation.
3. Preserve aliases as aliases where that matters for diagnostics/versioning.
4. Generate a named C wrapper for an addressless macro or static inline function when users need it.
5. Report every skipped public construct in a machine-readable coverage file; silent omission is unacceptable.

Compiling a wrapper with the same C frontend is superior to reimplementing a complex macro in Luce. It preserves promotions, single/multiple evaluation behavior as chosen by the wrapper, target builtins, and future header changes. The wrapper generator can deliberately normalize a hostile API—for example, expose a bitfield get/set pair or replace a macro taking a record by value with pointer/scalar parameters.

Other hard header features include flexible array members, transparent unions, `_Atomic`, complex numbers, target vectors, 80-bit long double, incomplete arrays, anonymous nested records, over-alignment, address-space qualifiers, nullability annotations, and MS/GNU extensions. The correct behavior is a spectrum—native representation, opaque representation, shim, or explicit unsupported diagnostic—not a promise that every AST node maps to a pretty Luce declaration.

### 3.5 Header declarations do not encode safe ARC semantics

Consider a C function returning `Thing *`. The header usually does not say whether the pointer is:

- newly owned and must be destroyed;
- borrowed until the next call;
- borrowed from a parent object;
- nullable on error;
- reference counted through separate retain/release functions;
- thread-confined;
- an interior pointer invalidated by mutation.

Likewise, a callback parameter rarely states whether invocation is synchronous, stored until cancellation, called from arbitrary threads, or called after the owner’s destructor begins. A `const void *data, size_t len` pair does not state whether the callee copies or retains the memory. ARC cannot infer this from `const`.

Luce’s safe layer needs reviewed binding recipes or annotations that express:

- constructor/destructor and retain/release pairs;
- owned, borrowed, nullable, out, in-out, and transferred parameters/results;
- parent/child lifetime ties and whether a borrow survives a call;
- buffer-pointer/length relationships, string termination and encoding;
- error source (`NULL`, negative result, status enum, thread-local error string);
- callback storage duration, cancellation function, context ownership, allowed threads, and reentrancy;
- functions requiring a main thread, event-loop lock, autorelease pool, or external synchronization.

For SDL, these rules are manageable because the API documentation is consistent but still nontrivial: many create/destroy pairs, borrowed strings, temporary event payload pointers, callbacks, properties, and thread-affinity constraints need manual recipes. The safe API should be a normal reviewed Luce package generated partly from those recipes, not magic behavior hidden in the compiler.

### 3.6 A maintainable three-layer output

The existing Luce design direction—FIIR to raw binding to safe wrapper—is sound. It should be made operational as three independently inspectable layers:

**FIIR (target-specific facts).** Header provenance, all preprocessing inputs, declarations, canonical C types, exact layouts, symbol/calling-convention metadata, ABI-lowering decisions, macro inventory, ownership annotations with provenance, and unsupported reasons.

**Raw Luce module.** C-shaped names and types; unsafe pointers; explicit target C integer types; opaque representations where needed; no invented ownership; functions grouped closely enough to compare with upstream headers. Generated files should contain upstream version and configuration fingerprints.

**Safe package.** Idiomatic names, ARC-managed owners, scoped borrows, result/error types, slices/strings, typed callbacks, thread checks, and higher-level event/GPU objects. It depends on one validated raw-module configuration and declares that compatibility.

A generated C/Objective-C adapter is a peer artifact of FIIR, not a fourth public API. It owns anything that cannot safely or economically cross directly.

### 3.7 Tracking upstream changes without binding roulette

Regeneration must be treated like a source update, not performed implicitly on every user build. A package maintainer should:

1. Pin a new upstream source digest and Clang/toolchain profile.
2. Regenerate FIIR/raw bindings for every supported target profile in CI.
3. Produce a semantic diff: declarations added/removed, canonical signature changes, record size/alignment/offset changes, enum/constant changes, symbol availability, macro coverage, and ABI-lowering changes.
4. Reconcile safe-wrapper recipes and explicitly accept breaking changes.
5. Build the native artifact and wrappers from the same source/configuration.
6. Compile target C probes that compare `sizeof`, `_Alignof`, `offsetof`, enumerator/constant values, and symbol availability with FIIR.
7. Run bidirectional call/return/callback tests on real native runners.
8. Publish a new package version and lockfile identity; do not silently replace old generated bindings.

Headers and binaries can drift even within a nominal version when distributions backport patches or change feature flags. In system mode, Luce should verify whatever upstream exposes—version macros, `pkg-config` version, runtime version function, and required symbols—and reject a demonstrable mismatch. It cannot prove binary compatibility from a filename alone.

Binding generation based on libclang is plausibly a **one-to-two engineer-month** subsystem once FIIR and the native build recipe exist; complete extension/macro handling is open-ended. A high-quality SDL raw binding plus reviewed safe vertical slice is another **four to eight weeks**. Those estimates assume shims are an accepted escape hatch. Requiring every macro, inline function, bitfield, and ABI corner to translate into pure Luce would expand the project substantially without improving application ergonomics.

## 4. What effortless cross-platform native development requires beyond FFI

Cross-compilation has four escalating meanings:

1. Emit an object file for another target.
2. Link a command-line executable against that target’s runtime and system ABI.
3. Build all native dependencies and resources for that target.
4. Produce, sign, install, and test a distributable application accepted by the target OS.

LLVM makes step 1 broad. A sysroot/SDK, headers, libraries, C compiler behavior, linker, and object tools are needed for steps 2–3. Platform identities, packaging tools, online services, secrets, and native validation are needed for step 4. Luce’s documentation and command names should say which level is supported.

### 4.1 The host/target/tool distinction

A native build graph runs two classes of programs:

- **host tools**, such as a binding generator, shader compiler, `wayland-scanner`, resource compiler, or code generator;
- **target outputs**, such as SDL object files, the Luce executable, target DLLs, and target shaders.

The graph must compile host tools for the build machine and target sources for the selected target, then prevent host discovery from leaking into target flags. `pkg-config` without a target sysroot is the classic leak: it returns `/usr/include` and `/usr/lib` from the Linux host while building a different root or architecture. A recipe should classify each dependency and executable edge as host or target and reject an absolute host path in target metadata unless explicitly allowed.

An honest initial support matrix is more valuable than nominally accepting every LLVM triple. For example:

| Target profile | Initial supported build host | System baseline |
|---|---|---|
| `aarch64-apple-macos` | macOS native CI | pinned macOS SDK + minimum deployment target |
| `x86_64-apple-macos` | macOS native CI | same, optionally merged into a universal app |
| `x86_64-pc-windows-msvc` | Windows native CI | pinned Windows SDK/UCRT + MS-compatible linker/import libs |
| `x86_64-unknown-linux-gnu` | Linux container/native CI | pinned oldest-supported glibc sysroot |
| `x86_64-unknown-linux-musl` | later, separate | pinned musl sysroot; independently tested |

Cross-host compilation can be added profile by profile after native builds are reproducible. It should not be the prerequisite for the first application release.

### 4.2 macOS: technically cross-compilable, operationally and legally Mac-bound

LLVM can emit Mach-O for Apple targets from a non-Mac host. Open-source linkers and Mach-O tools can technically create an executable if supplied the right inputs. That is not the same as possessing a supportable Apple development environment.

A normal macOS build needs:

- Apple SDK headers, framework stubs (`.tbd`), libraries, availability metadata, and Clang resource behavior;
- a selected SDK version and minimum deployment target, which control weak availability and load commands;
- Mach-O linking, install names, run paths, Objective-C metadata, and platform load commands;
- an actual Mac for runtime, UI, input, GPU, minimum-OS, and Gatekeeper testing.

The Apple SDK is proprietary. Apple’s [Xcode and Apple SDKs Agreement](https://www.apple.com/legal/sla/docs/xcode.pdf) defines the macOS SDK as Apple-proprietary material and grants its installation/use under Apple-platform and Apple-branded-computer conditions. A Luce project should not redistribute extracted SDKs or promise an officially supported Linux-to-macOS build by telling users to copy one into a container. This is a licensing constraint, not a missing LLVM feature. Exact use cases should be reviewed against the current agreement; this report is not legal advice.

The defensible Luce experience is:

- allow target-independent Luce compilation or cached intermediate/object production elsewhere when useful;
- perform SDK-dependent compilation/linking and release validation on a user-controlled or hosted Mac worker;
- provide a remote-build protocol/cache so “build for Mac” from another workstation can transparently dispatch the Apple phase without redistributing the SDK;
- never include an Apple SDK in the Luce distribution.

Release distribution adds code signing and notarization. Outside the Mac App Store, a polished app normally uses a Developer ID certificate, hardened runtime, secure timestamp, and Apple notarization; Apple’s process validates the signature, scans the submission, and returns a ticket that can be stapled ([Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)). The [Notary API](https://developer.apple.com/documentation/NotaryAPI) permits service interaction without `notarytool`, so notarization upload is not intrinsically Mac-only. It still requires Apple credentials and a correctly built/signed artifact, and it does not solve SDK licensing or native testing.

The `.app` is a semantic bundle, not a renamed directory. Apple specifies `Contents/Info.plist`, the executable under `Contents/MacOS`, resources under `Contents/Resources`, and embedded frameworks/dylibs under `Contents/Frameworks` ([Apple bundle placement](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle)). Embedded code needs correct identifiers/install names and must be signed before the containing app is signed. Entitlements and hardened-runtime exceptions affect dynamic code, plug-ins, and JIT behavior. Luce should generate the structure and manifests, then invoke Apple’s signing/notarization tools or service with explicit user-provided identity; it should not invent a replacement signature format.

### 4.3 Windows: cross builds are feasible, but imports and deployment are part of the ABI

PE/COFF executables normally do not link directly to a DLL file. They link against an **import library** (`.lib` in the MSVC ecosystem, also archive forms in MinGW), which supplies symbol/import-table metadata; the corresponding DLL must be present at runtime. Microsoft’s DLL-linking documentation identifies the header, import library, and DLL as separate inputs for implicit linking ([Linking an executable to a DLL](https://learn.microsoft.com/en-us/cpp/build/linking-an-executable-to-a-dll?view=msvc-170)).

Luce therefore needs to:

- consume and eventually produce COFF import libraries;
- understand `.def` exports, symbol spelling/decoration, ordinals where encountered, and architecture/machine type;
- select debug/release CRT consistently and avoid mixing incompatible runtimes or allocators across DLL boundaries;
- package the actual DLL, not merely the `.lib` that made the link succeed;
- report which imported DLL and symbol caused a load failure.

For a DLL without a matching import library, a tool can generate one from a trustworthy `.def`/export list, or the application can use explicit runtime loading (`LoadLibraryEx`/`GetProcAddress`) behind a typed adapter. The latter is useful for optional GPU/system features but gives up link-time symbol checking.

Windows cross-compilation from Linux/macOS is technically practical with LLVM/LLD plus MinGW-w64 headers/import libraries, producing a GNU-flavored Windows target. Claiming MSVC ecosystem compatibility is a separate target profile requiring MS ABI decisions, the UCRT/Windows SDK inputs, compatible import libraries, and testing. The Windows SDK is also licensed material, but the ecosystem offers open MinGW-w64 inputs; there is no exact equivalent of the unavoidable Apple-hardware development path. For the first high-confidence release, a Windows runner should build and test the MSVC profile natively.

DLL discovery is a security property. The effective search order varies with packaged-app state, Safe DLL Search Mode, APIs used, and process configuration. Microsoft warns that an attacker-controlled directory in the search path can cause DLL preloading ([Dynamic-link library security](https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-security)). Luce should place private DLLs beside the executable or in a controlled package location, use qualified paths or safe `LoadLibraryEx` flags for explicit loading, and never solve a missing DLL by adding the current working directory or a broad user path.

For early distribution, a signed or unsigned development directory/ZIP containing the executable and private DLLs is the simplest observable artifact. MSIX can later supply identity, clean install/update/uninstall, manifest capabilities, and containerized package semantics ([MSIX overview](https://learn.microsoft.com/en-us/windows/msix/overview)). Production MSIX packages must be signed with a certificate trusted for the package identity; Store distribution performs its own signing path, while sideloading requires trust provisioning ([MSIX package signing](https://learn.microsoft.com/en-us/windows/msix/package/signing-package-overview)). Luce should generate a manifest and invoke the platform packager/signer, not implement the entire MSIX format and trust workflow in the compiler.

### 4.4 Linux: choose a baseline; there is no generic desktop-linux ABI

The primary glibc compatibility rule is to build against the oldest glibc baseline the artifact promises to support. Linking on a new distribution can record references to versioned symbols such as `GLIBC_2.xx`; copying that binary to an older distribution fails before `main`. Glibc maintainers recommend using an old build environment/sysroot rather than attempting to falsify symbol versions ([glibc compatibility discussion](https://sourceware.org/pipermail/libc-alpha/2023-July/150165.html)). A pinned container is useful only if it truly supplies the baseline headers, startup objects, libc, linker, and target development packages—not merely an old base image with new host paths mounted into it.

musl should be a separate Luce target, not a link flag for a glibc build. Its documented behavioral differences include resolver, dynamic linking, locale, thread, and extension choices ([musl functional differences](https://wiki.musl-libc.org/functional-differences-from-glibc.html)). Static musl can eliminate a glibc symbol-version floor for suitable command-line programs, but a graphical SDL application still interacts dynamically with the compositor/X server, GPU loader and vendor driver, audio services, dbus/udev, input, fonts, and possibly plug-ins. Fully static linking is not a universal desktop compatibility solution and can collide with components that assume glibc behavior.

For ELF dynamic dependencies, the loader’s rules matter. The Linux [`ld.so` manual](https://man7.org/linux/man-pages/man8/ld.so.8.html) documents the interaction of `DT_RPATH`, `LD_LIBRARY_PATH`, `DT_RUNPATH`, the loader cache, default paths, secure-execution restrictions, and `$ORIGIN`. In particular, `DT_RUNPATH` applies to direct dependencies rather than recursively solving every child’s lookup. A Luce bundle that puts private libraries under an adjacent `lib` directory must set and audit run paths for the executable **and any bundled library with private transitive children**.

The initial Linux release policy should be explicit:

- one x86-64 glibc baseline built in a pinned old-enough sysroot/container;
- SDL statically linked or a private SDL shared library with `$ORIGIN`-relative paths;
- do not bundle glibc, the dynamic loader, Vulkan/OpenGL vendor drivers, Wayland/X server components, or desktop service daemons;
- inspect every ELF `NEEDED`, SONAME, symbol-version requirement, and RUNPATH in CI;
- run on representative minimum and current X11 and Wayland systems with actual GPU/audio/input hardware;
- add a separate musl artifact only when its behavior is tested and its value is clear.

AppImage packages an AppDir into a single runnable image and advises building on an old base and bundling non-base dependencies ([AppImage concepts](https://docs.appimage.org/introduction/concepts.html)). It offers low-friction downloads but does not create a stable Linux base ABI or sandbox. Flatpak instead builds against a named runtime/SDK and declares a sandboxed application manifest; extra dependencies are built into the app, and host interaction goes through permissions and portals ([Flatpak first build](https://docs.flatpak.org/en/latest/first-build.html), [dependency bundling](https://docs.flatpak.org/en/latest/dependencies.html), [portal APIs](https://docs.flatpak.org/en/latest/portal-api-reference.html)). Flatpak is often the more reproducible desktop contract but adds runtime distribution and sandbox integration. Luce should emit AppDir/Flatpak project scaffolding and call their maintained tools after the basic tar/ZIP bundle works.

### 4.5 Dynamic-loader policy must be generated with the bundle

The three systems encode runtime dependency location differently:

| Platform | Link-time reference | Relocatable private dependency mechanism | Common failure |
|---|---|---|---|
| ELF/Linux | `DT_NEEDED` name/SONAME | `$ORIGIN` in `DT_RUNPATH`/`DT_RPATH` | direct library found, its private child missing; accidental new-glibc symbol |
| Mach-O/macOS | load command containing install name | `@rpath`, `@loader_path`, `@executable_path` plus `LC_RPATH` | absolute build path embedded; install name rewritten after signing |
| PE/Windows | import descriptor populated through import library | app/package directory or explicit safe load path | `.lib` shipped instead of DLL; wrong architecture/CRT; unsafe search pickup |

Apple’s run-path documentation explains that a dylib can carry an `@rpath/...` install name and the loading image supplies ordered run paths ([Run-path dependent libraries](https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/DynamicLibraries/100-Articles/RunpathDependentLibraries.html)). `@loader_path` is relative to the image performing a load; `@executable_path` is relative to the main executable. They are not interchangeable for nested libraries and plug-ins. Luce should set final install names and load paths at link/bundle time and verify them **before** code signing, because changing Mach-O load commands invalidates signatures.

For each release artifact, a Luce bundle verifier should recursively inspect object headers rather than trusting manifest intent. It should identify architecture slices; deployment metadata; ELF `NEEDED`/RUNPATH/symbol versions; Mach-O load commands/install names/rpaths; PE imports and machine types; missing runtime payloads; absolute build paths; duplicate/conflicting library basenames; and forbidden components such as a bundled system GPU driver. This verifier is small compared with a linker and has very high leverage because loader failures otherwise occur only on clean user machines.

### 4.6 Packaging and publishing are separate compiler commands

A useful product model separates:

- `luce build`: deterministic target objects/executable/native libraries;
- `luce bundle`: deterministic-ish directory structure, private libraries, resources, metadata, loader paths, notices, and SBOM;
- `luce package`: platform container such as ZIP, DMG/PKG, MSIX, AppImage, or Flatpak build;
- `luce publish`: signing identities, timestamps, notarization/store upload, and network credentials.

The later stages are intentionally less hermetic. Secure timestamps and notarization are online; signatures may incorporate time or service output; private keys must never enter a normal compilation cache. Keeping these stages separate preserves reproducible unsigned builds and lets CI apply policy and secrets only to reviewed outputs.

The blockers should be named accurately:

| Constraint | Technical, legal/policy, or both? | Luce response |
|---|---|---|
| Apple SDK on non-Apple build infrastructure | Legal/license plus tooling | Do not redistribute; use a Mac worker/user SDK; document the boundary |
| Developer ID/notarization | Account/policy plus technical signing | User/CI supplies identity and credentials; Luce orchestrates and verifies |
| Mac hardware/GPU/input validation | Physical/technical | Native test runner; emulation is insufficient |
| Windows import library and DLL | Technical | Generate/consume import metadata; bundle and inspect DLL |
| Windows/MSIX trust identity | Policy/PKI plus technical | Separate publish step; support ZIP first |
| glibc baseline | Technical compatibility | Old sysroot/container and symbol-version audit |
| musl behavior | Technical/ecosystem | Separate target and artifact, never silent fallback |
| AppImage/Flatpak ecosystem policy | Packaging/sandbox policy | Generate metadata; delegate to maintained tools; test portals |

### 4.7 GPU portability: SDL_GPU solves the API, not the asset pipeline

Luce should not build first-party Metal, Vulkan, and D3D12 abstractions. SDL_GPU already presents modern graphics and compute over those backends, including device selection, command buffers, resources, pipelines, and swapchain integration ([SDL GPU API](https://wiki.libsdl.org/SDL3/CategoryGPU)). It intentionally targets a portable feature floor rather than every cutting-edge GPU feature. That trade is ideal for a tiny language team seeking a credible first application.

Shader portability remains an application-build concern. SDL identifies SPIR-V for Vulkan, DXBC or DXIL for D3D12, and MSL or metallib for Metal ([SDL shader formats](https://wiki.libsdl.org/SDL3/SDL_GPUShaderFormat)); device creation selects among Metal, Vulkan, and D3D12 based partly on formats the application can supply ([SDL_CreateGPUDevice](https://wiki.libsdl.org/SDL3/SDL_CreateGPUDevice)). One HLSL source file is not a runtime-portable payload by itself.

SDL_shadercross can translate HLSL or SPIR-V into several required forms and offers both a library and CLI ([SDL_shadercross](https://github.com/libsdl-org/SDL_shadercross)). Its dependencies include SPIRV-Cross and, for relevant outputs, DirectX Shader Compiler components. SDL itself recommends precompilation and warns that building shadercross is complex with large dependencies ([SDL development FAQ](https://wiki.libsdl.org/SDL3/FAQDevelopment)).

The high-leverage Luce policy is:

- choose one documented authoring subset, initially HLSL suitable for shadercross;
- treat a pinned, verified shadercross/DXC/SPIRV-Cross tool bundle as a **host build tool**, not a library linked into every application;
- compile and reflect shaders during the asset-build phase in native CI, emitting SPIR-V, DXIL (and DXBC only if the supported hardware floor needs it), and metallib/MSL as required;
- store shader source hash, compiler versions/flags, entry point, stage, resource layout/reflection, and output formats in the build graph;
- package only the required precompiled shader variants and select by the actual SDL GPU backend;
- retain runtime shader compilation only as an opt-in development feature.

This confines a large dependency tree to build machines and makes release startup and failure modes predictable. The first acceptance test should be one triangle/compute operation with validation layers enabled on all three native runners, followed by loss/recreate, resize, high-DPI, and minimized-window cases—not a new rendering framework.

### 4.8 Trackpad gestures expose the limits of a single portability layer

SDL 3.4.10 has public pinch begin/update/end events ([SDL event types](https://wiki.libsdl.org/SDL3/SDL_EventType)). Inspection of that release’s source shows emitters in Cocoa, Wayland, and X11 XInput2 paths: the [Cocoa implementation](https://github.com/libsdl-org/SDL/blob/release-3.4.10/src/video/cocoa/SDL_cocoawindow.m) maps AppKit magnification into SDL pinch events, while [Wayland](https://github.com/libsdl-org/SDL/blob/release-3.4.10/src/video/wayland/SDL_waylandevents.c) and [X11](https://github.com/libsdl-org/SDL/blob/release-3.4.10/src/video/x11/SDL_x11xinput2.c) do likewise when the relevant protocol/version exists. The release’s [Windows event implementation](https://github.com/libsdl-org/SDL/blob/release-3.4.10/src/video/windows/SDL_windowsevents.c) contains no corresponding pinch emitter.

SDL also lets macOS applications opt into treating the trackpad as a raw multitouch device rather than ordinary mouse input through `SDL_HINT_TRACKPAD_IS_TOUCH_ONLY` ([SDL trackpad hint](https://wiki.libsdl.org/SDL3/SDL_HINT_TRACKPAD_IS_TOUCH_ONLY)). That is useful but not equivalent to all native recognized gestures. AppKit delivers magnify, rotate, and swipe through distinct responder methods and supplies gesture-specific deltas ([Apple trackpad event handling](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html)); SDL 3.4.10 publicly normalizes pinch, but not rotate or swipe.

Windows is not merely “the same events under another name.” Precision Touchpad input is normally interpreted by Windows and often reaches an unenlightened desktop application as mouse-wheel behavior. Higher-fidelity handling requires registering a window/thread as touchpad-capable and consuming `WM_POINTER` plus the precision-touchpad information/gesture APIs ([Precision Touchpad input](https://learn.microsoft.com/en-us/windows/win32/input-precisiontouchpad/precision-touchpad-portal)). Wayland’s pointer-gestures protocol currently describes swipe, pinch, and hold, but is explicitly an unstable protocol and compositor availability matters ([Wayland pointer gestures](https://wayland.app/protocols/pointer-gestures-unstable-v1)). X11 support depends on XInput 2.4 and driver/server behavior.

The correct Luce abstraction is capability-based:

- a small common stream for pointer, wheel, touch contacts, and pinch phases where SDL supplies them;
- optional `rotate`, `swipe`, `hold`, high-resolution scroll/inertia, and raw-touchpad capabilities with platform-specific fidelity metadata;
- a macOS Objective-C companion adapter for AppKit rotate/swipe (and any pressure/phase detail SDL omits), injected into the Luce/SDL event stream;
- a Windows C/C++ adapter for Precision Touchpad only if gesture-driven Windows behavior is a product requirement, otherwise documented mouse/touch fallbacks;
- Wayland/X11 capability detection rather than assuming the compositor/server exposes a protocol.

The Objective-C and Windows adapters are good examples of bespoke work that should stay thin. Let the OS recognize gestures; normalize lifecycle and units; do not implement a cross-platform gesture recognizer in the compiler. Identical semantics cannot be guaranteed because users and compositors reserve gestures and hardware reports different data. “Gesture-driven on all three systems” should mean a tested common interaction has fallbacks, not that every trackpad yields the same raw stream.

## 5. Recommendation for a one-person-plus-AI compiler team

### 5.1 The strategic decision

Luce should aim to be an **excellent orchestrator of a deliberately supported native stack**, not a universal replacement for CMake, vcpkg, Homebrew, every platform SDK, three graphics APIs, and every C ABI on day one.

The first product promise should be narrow and testable:

> A pinned Luce project can build and bundle the same SDL3/SDL_GPU application from source on supported native macOS, Windows, and Linux runners, with no manual link flags; it reports a capability-aware input stream and produces platform-appropriate unsigned development bundles. Release signing/publishing is a separate guided step.

That promise is meaningful. It covers the unglamorous acquisition, build, ABI, link, asset, loader, and bundle work. It avoids the false promise that any host can legally produce every release or that any CMake project is automatically portable.

The current Luce language design already points in the right direction: exact package locks; declarative native recipes; compilation without arbitrary package scripts, network, or ambient environment; Clang-derived FIIR; raw and safe binding layers; explicit target roots; and deferred inline assembly. Preserve those constraints. The implementation order, however, should use generated shims to get application evidence before completing every direct ABI classifier.

### 5.2 Fix the supported profiles before writing the importer

Choose Tier 1 profiles, not just triples:

- macOS arm64, with one minimum deployment target and a named Xcode/SDK range;
- macOS x86-64 only if Intel support is commercially important; otherwise defer it and avoid doubling Apple testing/universal packaging;
- Windows x86-64 MSVC ABI, Windows 10/11 floor, pinned Windows SDK/UCRT policy;
- Linux x86-64 glibc, a named minimum glibc baseline, X11 and Wayland runtime paths;
- Vulkan/Metal/D3D12 hardware floors inherited from the selected SDL release and documented.

Every profile needs a machine-readable target descriptor: CPU/ABI, object format, C data model, default C calling convention, LLVM data layout, SDK/sysroot, deployment floor, libc/CRT, linker flavor, binary suffixes, loader policy, system frameworks/libraries, package/bundle format, and allowed signing modes. This descriptor should be an input to FIIR, native recipes, linker invocation, and bundle verification. Duplicated target-condition logic across those subsystems will drift.

Support only native-host builds at first. Add cross-host claims after the identical target profile can consume a relocatable sysroot/toolchain and pass on a native runner. For macOS, provide remote Mac dispatch rather than distributing an SDK.

### 5.3 Highest-leverage implementation order

The estimates below are engineering scope estimates after Luce can reliably compile/link basic programs; they are not calendar promises and overlap. AI helps with inventory, generated tests, and repetitive bindings, but does not remove native hardware validation or design review.

#### Phase 0 — Target contract and native CI (about 1–3 weeks)

Deliver:

- the initial target profiles and explicit non-goals;
- one clean native runner per OS, plus minimum-version test environments where practical;
- a build record that captures LLVM/Clang/linker/SDK/sysroot identity;
- object/executable inspection in CI;
- a trivial C library compiled and called in both directions using scalars and pointers.

Exit criterion: each runner builds the same fixed-prototype C smoke test without hand-edited flags, and CI can explain every tool/sysroot/library selected.

#### Phase 1 — Narrow C gateway and generated shim path (about 3–6 weeks)

Implement fixed-prototype scalar, pointer, opaque-handle, C-string, and basic callback interop for the Tier 1 ABIs. Make Clang-compiled C/Objective-C companion files first-class declarative package inputs. Generate shims for all aggregates, unions, bitfields, variadics, and macros rather than waiting for full ABI lowering.

Add ARC callback infrastructure deliberately: retained context object, C trampoline, deterministic unregister/release, thread-entry handling, and “no panic/unwind across C” behavior. The most dangerous SDL bugs will otherwise be lifetime bugs rather than register bugs.

Exit criterion: a thin SDL adapter opens and closes a window, polls normalized events, and reports errors on all three native runners. No direct public SDL record needs to cross by value.

#### Phase 2 — Declarative native dependency engine and curated SDL recipe (about 6–10 weeks)

Implement source acquisition outside compilation, immutable hashes, patch/license handling, source/configuration nodes, host-versus-target tools, complete cache keys, and explicit source/artifact/system modes. Add the curated SDL 3.4.x recipe and a diagnostic `doctor` path. Start with static SDL for development bundles and retain a shared/system option.

Do not implement a general CMake interpreter. Compare the recipe’s output with upstream CMake in CI: feature summary, exported symbols, configuration macros, and smoke tests. Treat upstream changes as recipe-review events.

Exit criterion: a clean machine with platform SDK prerequisites but no preinstalled SDL builds from the locked source, reuses a correct cache, and produces a windowed development bundle whose runtime dependency audit passes.

#### Phase 3 — Safe SDL surface and SDL_GPU vertical slice (about 4–8 weeks)

Create a small reviewed Luce package around SDL ownership/error/event rules. Do not expose all raw SDL declarations as the application API. Add a verified prebuilt host shader-tool artifact and an offline HLSL-to-SPIR-V/DXIL/metallib pipeline with reflection metadata.

Exercise resource lifetime under ARC: GPU device before child destruction, command-buffer submission/fences, mapped transfer buffers, window/device teardown, callback shutdown, and error paths. ARC does not know the GPU’s asynchronous lifetime; wrappers need explicit submission/fence/resource policies.

Exit criterion: the same Luce source displays a validated GPU-rendered scene on Metal, D3D12, and Vulkan; resize/high-DPI/minimize/recreate and device-error paths are covered; the release bundle contains only precompiled shaders.

#### Phase 4 — Capability-based gesture layer (about 2–5 weeks for the first useful slice)

Use SDL pinch and raw touch where available. Add a tiny Objective-C Cocoa adapter for rotate/swipe and any required phase/pressure detail. On Windows, first provide wheel/touch fallbacks; add the Precision Touchpad registration/`WM_POINTER` adapter only if the product truly needs high-fidelity two-finger input. Surface Wayland/XInput protocol availability at runtime.

Define common interaction actions above raw gestures—zoom, pan, rotate canvas—so keyboard/mouse controls remain fallbacks. Test with real trackpads; virtual CI cannot validate palm rejection, inertia, compositor reservation, or user settings.

Exit criterion: the demo supports zoom/pan on every Tier 1 platform with documented input fallbacks, plus native-quality pinch and the promised platform extensions where hardware supports them.

#### Phase 5 — FIIR, raw generator, and direct C ABI expansion (about 8–16 weeks)

Now use the working shim suite as an oracle and compatibility fallback. Build the libclang importer, target-specific FIIR, raw binding generator, ABI diff, and Clang differential corpus. Add direct by-value aggregate and result lowering one profile at a time. Keep bitfields and arbitrary varargs shimmed until evidence justifies more.

The target order should follow usage and risk: the primary development host first; Windows x64 next because its record rule is relatively constrained but different; SysV AMD64; Apple arm64/AAPCS64 with HFA and varargs tests; secondary architectures last. This ordering may change based on Luce’s owner machine, but each classifier needs a completion gate rather than being developed simultaneously.

Exit criterion: generated SDL raw bindings pass target layout/symbol probes; a broad ABI corpus matches Clang in both call directions; the safe SDL package can progressively remove shims without public API changes.

#### Phase 6 — Release packaging and publishing (about 4–8 weeks initially, then ongoing)

Generate `.app`, Windows directory/ZIP, and Linux AppDir/tar artifacts first. Add loader-path verification and nested-code inventory before signing. Then integrate Developer ID/hardened-runtime/notarization on Mac, optional MSIX on Windows, and AppImage/Flatpak recipes on Linux as separate platform-tool-driven stages.

Exit criterion: CI can produce installable signed release candidates using injected credentials, and each is tested on a clean minimum-supported system. Unsigned local development remains possible and clearly distinguished.

The phases are not simply additive, but a polished three-platform result is realistically **six to twelve focused months of native-toolchain and platform work after the compiler/runtime foundation is dependable**. Full arbitrary-C-package compatibility is a multi-year ecosystem activity. The fastest demo could appear in two or three months through shims; calling that demo a finished native ecosystem would be misleading.

### 5.4 Where Luce should deliberately not innovate

| Problem | Stand on | Luce-specific work |
|---|---|---|
| Windowing, controllers, common input/audio | SDL3 | recipe, bindings, ARC-safe wrapper, diagnostics |
| Modern portable GPU API | SDL_GPU | wrapper, resource-lifetime policy, examples/tests |
| Shader translation | SDL_shadercross, DXC, SPIRV-Cross, Apple Metal tools | pinned host-tool artifacts, graph integration, reflection/packaging |
| C preprocessing/parsing/layout | Clang | FIIR extraction, stable representation, coverage reports |
| Machine code/object emission | LLVM | correct frontend ABI lowering and target profiles |
| Native linking | LLD and/or platform linkers | deterministic invocation, import/install-name/runpath policy |
| Application container formats | Apple/Microsoft/AppImage/Flatpak tooling | manifest generation, staging, verification, orchestration |
| Signing/notarization | OS trust systems and official services | secret boundaries, command UX, verification |
| Native dependency source builds | upstream source plus curated Luce recipes | target graph, cache, diagnostics; not a CMake clone |

SDL should remain visible in the abstraction. A thin Luce API can be pleasant without pretending every backend capability is identical. Applications needing ray tracing, platform-exclusive APIs, or exact native UI can opt into raw/platform packages later; the common layer should not grow into a least-common-denominator mega-framework maintained by Luce.

### 5.5 Where bespoke work is unavoidable

The following cannot be delegated away:

1. Target profile and C ABI integration between Luce types, ARC, FIIR, and LLVM.
2. A declarative native recipe model, content-addressed cache identity, lockfile representation, and actionable diagnostics consistent with Luce’s hermeticity goals.
3. Raw/safe binding separation and reviewed ownership/callback recipes.
4. ARC bridges for C handles, parent-owned borrows, callbacks, foreign threads, and asynchronous GPU resources.
5. Link and runtime-bundle planning: import libraries, install names, RUNPATH, DLL payloads, resource locations, and verification.
6. Thin platform adapters for input semantics SDL does not expose—most clearly AppKit rotate/swipe and potentially Windows Precision Touchpad.
7. Native conformance infrastructure and the release matrix. A compiler cannot reason itself into proof that a notarized `.app` launches or a Wayland gesture reaches the process.

These are the places where language quality will be felt. Investing here is higher leverage than adding syntax for inline C.

### 5.6 A concrete SDL package shape

The SDL package should contain four versioned products with one public safe dependency surface:

- **native artifact recipe:** pinned SDL source/configuration, target outputs, licenses, and runtime payload metadata;
- **FIIR/raw module:** comprehensive generated C-shaped API for experts and wrapper implementation;
- **adapter module:** generated/hand-reviewed C and Objective-C shims for difficult ABI/header/platform constructs;
- **safe Luce module:** owners such as window/device/resource types, error results, event sum types, typed callbacks, and capability queries.

The safe module should hide `SDL_Event`’s large C union behind an adapter that copies only the active variant into stable Luce values. This avoids union layout exposure early, prevents borrowed payload pointers from outliving the event, and gives Luce an evolvable event type. GPU handles should be opaque owners with an explicit destruction dependency graph rather than generic ARC pointers; destroying a device while child resources remain live should be prevented or deterministically drained.

The package version must include both upstream SDL compatibility and Luce wrapper compatibility. System mode should perform runtime/header/version checks and can expose fewer compile-time guarantees. Pinned-source mode is the reference configuration used by tests.

### 5.7 Inline C and inline assembly: defer both

Inline C inside a `.luc` file looks convenient but collapses language and build boundaries in costly ways. The compiler would need to define delimiter/indentation behavior, preprocessing scope, include resolution, target configuration, macro visibility, source locations and diagnostics across two parsers, incremental-cache identity, generated symbols, language-server behavior, and whether package code can execute compiler extensions. A block can also be valid on one target and lexically meaningless on another. None of this reduces the need for a C compiler or ABI bridge.

The better facility is manifest-declared companion sources (`.c`, `.m`, later `.mm`) compiled as explicit graph nodes, with a Luce foreign declaration referencing their stable C gateway. Generated adapters can live in the build cache; hand-written adapters can live beside the package. This is slightly more files and vastly clearer provenance, tooling, security, and diagnostics. If a future “inline C” feature is desired, it should initially be syntax sugar that materializes such a source node with explicit target guards—not a second C implementation in the Luce frontend.

Inline assembly is even less portable. A correct facility needs target instruction syntax, operand constraints, register classes, clobbers, memory/volatile semantics, flags, stack/unwind rules, and optimizer integration. LLVM inline assembly is target-specific and can inhibit optimization or miscompile when constraints are wrong. For the foreseeable roadmap, expose reviewed compiler/runtime intrinsics for atomics, SIMD, traps, and special registers, plus separately compiled `.S` files for expert packages. Add an explicit unsafe inline-assembly feature only after backend/ABI maturity and only with per-target tests. This matches the existing Luce design’s decision to omit inline assembly from epoch 1.

### 5.8 Numeric/array computing comes after the native substrate

“Like NumPy” is not mainly a C binding. A credible array system needs a buffer ownership model; dtype representation and promotion; rank/shape/strides; views and slicing; broadcasting; contiguous-versus-strided kernels; overflow/bounds policy; aliasing and copy-on-write decisions; reduction accuracy; vectorization; parallel scheduling; BLAS/LAPACK integration; and eventually CPU/GPU transfer semantics. ARC makes shared backing buffers natural, but views require explicit owner retention and mutation/alias rules.

The native work in this report is still prerequisite. Once C ABI, source recipes, and artifact packaging are stable, Luce can bind a narrow BLAS provider and platform accelerators (for example, Apple Accelerate versus a packaged OpenBLAS elsewhere) behind one tested numeric layer. That exercise will stress Fortran/C ABI, threading runtimes, allocator alignment, and large binary distribution—another reason to solve dependency modes first. It should not block the SDL application milestone.

Do not make SDL_GPU the first array-compute backend. Start with correct CPU arrays and explicit kernels/BLAS; later add GPU arrays with asynchronous ownership and transfer semantics designed intentionally. A windowing demo and a NumPy semantics project share infrastructure but are different products.

### 5.9 Definition of “done” for effortless native support

The feature is not done when a developer machine links. It is done for a target profile when all of the following are automated:

- clean acquisition from the lockfile with digest/license verification and offline rebuild from a populated cache;
- deterministic selection of C compiler, sysroot/SDK, recipe features, and link inputs;
- Clang-verified C layouts and ABI calls in both directions, including callbacks;
- no undeclared target files discovered from host paths;
- runnable clean-machine bundle with audited loader metadata and transitive payloads;
- debug and optimized builds, failure diagnostics, and teardown/lifetime tests;
- minimum/current OS tests, real GPU path, high-DPI/resize, X11/Wayland where promised, and real input hardware;
- unsigned development flow plus documented signing/publishing flow;
- SBOM/license notices and a procedure for urgent native-library updates;
- a target-support statement precise enough that a failed configuration is outside or inside the contract without debate.

The hard conclusion is favorable but sober: one person plus AI can build a compelling curated native experience by standing on SDL3, SDL_GPU, Clang, LLVM, and platform packaging tools. The same team cannot make arbitrary native ecosystems effortless by compiler cleverness alone. Luce’s differentiation should be a coherent, inspectable path from locked native source to a verified application bundle—with excellent ARC-safe APIs and diagnostics—rather than new implementations of mature platform layers.

## Appendix A: Native recipe review checklist

Before accepting or updating a native package recipe, review:

- immutable source/archive identity, mirror policy, license and notice obligations;
- target and host tool inputs, with no undeclared network or environment reads;
- exact feature set and comparison to upstream supported configuration;
- generated headers/files and whether generation is target-sensitive;
- C dialect, extensions, packing/enum/visibility flags, CRT and exception/runtime assumptions;
- public header preprocessing configuration shared with binding generation;
- static/shared outputs, exported symbol allowlist, transitive link requirements;
- deployment baseline, sysroot/SDK, libc/CRT and architecture slices;
- runtime payload paths, SONAME/install name/DLL basename and loader policy;
- cross-boundary allocator ownership and callback/thread behavior;
- ABI/layout probes and runtime smoke tests on every supported profile;
- cache-key completeness and reproducibility evidence;
- security-update owner, upstream watch channel, and rollback procedure.

## Appendix B: Minimum C ABI conformance corpus

The direct-ABI test generator should cover at least:

- every signed/unsigned integer width, `_Bool`, enums under relevant flags, pointers, function pointers, float/double/long double;
- scalar extension on declaration, call, return, and varargs;
- records at every size around 1/2/4/8/16/32-byte boundaries and every natural/over/under-alignment;
- mixed integer/floating records, nested records, arrays, unions, empty/zero-width cases where supported;
- SysV eightbyte merges and register-exhaustion rollback;
- AArch64 HFA/HVA sizes one through four, near-HFA counterexamples, and indirect `x8` returns;
- Apple arm64 compact stack arguments, odd-register alignment variance, and named-versus-unnamed variadic transition;
- Windows positional register holes, shadow space, by-reference temporaries, hidden-return shifting, and FP duplication in varargs;
- packed/misaligned records and zero-width/packed bitfields through verified shims;
- normal, `cdecl`, `stdcall`, `fastcall`, and any imported convention actually present in supported headers;
- callbacks and exported Luce functions, not only outbound calls;
- stack alignment, callee-saved preservation, unwind containment, optimized tail calls, and sanitizer instrumentation;
- little test values chosen to reveal byte order, padding misuse, truncation, sign extension, and partial copies.

## Appendix C: Principal risks and containment

| Risk | Earliest detection | Containment |
|---|---|---|
| Header/native artifact configuration skew | recipe-time config fingerprint and symbol probe | generate both from one graph; refuse unverified system version |
| Silent aggregate ABI corruption | Clang differential IR/assembly plus bidirectional runtime corpus | shim until target classifier passes gate |
| Callback use-after-free or foreign-thread ARC failure | stress cancellation/late callback/thread tests | retained context token, explicit unregister, thread attach, no cross-FFI unwind |
| “Works on developer machine” loader dependency | clean bundle audit and minimum-OS VM | relative loader paths, recursive dependency inspection |
| New glibc requirement | ELF symbol-version audit | oldest baseline sysroot; reject newer symbol |
| macOS signature broken during bundling | final Mach-O inspection before sign and Gatekeeper test after | finalize paths, sign nested code inside-out, never mutate afterward |
| Shader format/resource mismatch | offline reflection and validation-layer CI | pin tools/flags; package all required backend variants |
| Gesture behavior absent on target | runtime capability telemetry and hardware test | interaction fallbacks; thin platform adapter; no false parity promise |
| Recipe scope becomes a CMake clone | review any new imperative escape | curate packages; explicit system mode; decline unsupported upstream builds |
| Team swamped by matrix | support-tier dashboard and release gates | fewer profiles/features, native CI, automate inspection before adding targets |
