# Luce native-library end state: Metal, SDL3, CUDA, Vulkan, and the minimal FFI union

**Decision report — 24 August 2026**

## Executive finding

The proposed direction is substantially right, but it is missing the hardest common denominator: **scoped, ABI-typed native storage and views**. `out` parameters solve `cuDeviceGet(&dev)`; they do not solve `cuLaunchKernel(..., void **kernelParams, ...)`, Vulkan arrays and `pNext` chains, NVRTC's caller-allocated result buffer, SQLite's allocator-owned error string, or the pervasive `(pointer, count)` convention. Luce should expose none of this in normal application code. It should give generated `unsafe native` bindings a small typed memory substrate—stable slots, arrays, pointer-to-pointer construction, borrowed views, and copy-in/copy-out—and have `luce bind` generate ARC-safe lists, strings, owners, and builders on top.

The second correction is that an opaque handle has two independent properties: a **nominal identity** and an **ABI representation**. CUDA alone has `CUdevice` (an integer), `CUdeviceptr` (an unsigned integer the width of a target pointer), and `CUcontext`/`CUstream`/`CUevent` (opaque pointer handles). They may all occupy one 64-bit Luce machine word on today's targets, but they cannot all be emitted to LLVM as the same C type. `extern type Window` is worth adding, but FIIR must retain an inferred representation such as `c_ptr`, `c_uintptr`, `c_int`, or `c_u64`; safe owners are separate ARC classes around those non-owning raw values.

The third correction is scheduling. Indirect C calls can be deferred while shipping SDL's direct API and SDL_gpu, but not while claiming direct Vulkan, OpenGL, ONNX Runtime, or complete wgpu-native support. Vulkan obtains instance and device commands through `vkGetInstanceProcAddr`/`vkGetDeviceProcAddr`; ONNX Runtime exports almost its entire API as fields of `OrtApi`. A small, exact-signature `extern fnptr "c"` primitive and generated dispatch tables are therefore a required milestone, not speculative generality.

The recommended first user-facing slice is **SDL3 2D**, followed by **SDL_gpu** for the asset graph. The isolated forcing slice for indirect calls should be a tiny **ONNX Runtime C API** program, not Vulkan: it proves function-pointer-table calls without simultaneously debugging a registry generator, loader lifetime, extension negotiation, and `pNext`. Then a direct Vulkan triangle or compute sample validates the machinery at scale. CUDA Driver + NVRTC vector-add is the forcing slice for native argument packing and caller-allocated return buffers; it must run in Linux/Windows NVIDIA CI because modern CUDA is not a macOS platform.

## Scope and evaluation criteria

The starting FFI admits direct `extern func` calls with at most eight parameters drawn from `{u32, i32, u64, i64, foreign}`, adds `f64` only for results, treats `foreign` as an untyped non-ARC 64-bit token, supplies one scoped byte-list-address helper, and accepts explicit linker inputs. The already-designed work—nullable `foreign?`, `cstr`, `out`, C-layout `extern struct`, callback trampolines, FIIR-backed binding generation and recipes, committed/staleness-checked bindings, and generated Objective-C/C++ thunks—is assumed rather than re-invented.

“Easy inside a Luce project” is taken to mean all of the following:

1. A checked-in project builds from a manifest without hand-written `.h`, `.c`, `.m`, or `.mm` glue.
2. Raw bindings preserve the target C ABI exactly; safe bindings make wrong-handle, nullability, ownership, callback-lifetime, and buffer-length mistakes difficult.
3. Native dependencies, generated bindings, shader/device-code assets, link inputs, runtime libraries, and application-bundle resources are nodes in one reproducible, content-addressed build graph.
4. Unsupported hosts fail early and specifically; a Mac developer can type-check CUDA-dependent code and produce non-CUDA artifacts without pretending that CUDA can execute locally.
5. Generated source may use a deliberately small `unsafe native` substrate that ordinary safe Luce does not need to expose.

## Part 1 — bottom-up requirements

### Requirements matrix

Legend: **Y** means ordinary use requires the shape; **C** means conditional or confined to an integration path; **—** means not a defining requirement. “Indirect” means calling a function address obtained at runtime, not merely passing a callback.

| API | nullable/typed handles | strings and byte views | aggregates / unions | out / pointer-to-pointer | callbacks | float arguments | >8 args | indirect dispatch | asset/tool step | native-language or loader glue |
|---|---|---|---|---|---|---|---|---|---|---|
| SDL3 core/render | Y | Y | Y (`SDL_FRect`, `SDL_Event`) | Y | Y | Y | Y | C | C | C: platform main/DLL discovery |
| SDL_gpu | Y | Y: shader blob + entry point | Y, nested descriptors | C | C | Y | C | — for the SDL_gpu API | Y: backend shader formats | SDL runtime/backend selection |
| Metal | Y, ObjC protocol objects | ObjC strings/data | Y: `MTLClearColor`, `CGSize` | Y: `NSError **` | Y: ObjC blocks | Y: doubles/floats | Y | hidden in ObjC dispatch | Y: `metal` → AIR → `metallib` | Y: generated `.m`, frameworks, ARC/autorelease, `CAMetalLayer` |
| CUDA Driver | Y, with several physical representations | PTX/cubin blobs, names, logs | some descriptors | pervasive | C | C | Y: launch has 11 | C: if dynamically loaded | Y: NVRTC or nvcc | Y: driver/toolkit discovery and GPU runtime |
| cuBLAS/cuDNN | Y | — | descriptors/enums | Y | C | Y, sometimes scalar pointers | Y | often through loaded library | C | CUDA runtime libraries/versioning |
| Vulkan direct | Y | names, shader bytes | pervasive; fixed arrays; `pNext` | pervasive | Y | Y | Y | **Y** | Y: SPIR-V | Y: loader, layers, extensions, registry generation |
| ONNX Runtime C | Y | UTF-8 and Windows path strings | option structs | pervasive | Y | Y | Y | **Y: `OrtApi` table** | model/resource packaging | Y: provider/runtime DLL deployment |
| OpenGL | integer object names + context handles | shader source/logs | small arrays | Y | Y | Y | Y | **Y on normal platforms** | shader source/runtime compile | context creation + proc-address loader |
| Accelerate/CBLAS | mostly scalar enums and pointers | — | complex values/arrays | Y | callbacks in some LAPACK | **Y** | **Y: GEMM has 14** | — | — | frameworks; avoid raw compiler-specific Fortran ABI |
| SQLite | opaque pointers | Y, blobs, nullable text | — | Y | Y | Y | C | — | database files are resources | allocator/destructor sentinels; optional amalgamation build |
| llama.cpp | opaque pointers | paths, tokens, model bytes | Y, some by value | Y | Y | Y | Y | C | model files/runtime assets | C header over C++ build; backend libraries |
| Dear ImGui via cimgui | opaque context + IDs | strings | Y, `ImVec2`/`ImVec4` | Y | Y | Y | Y | C | fonts/shaders backend-specific | generated C++ wrapper; adapters for defaults/varargs |
| wgpu-native | typed opaque pointers | labels/WGSL + pointer-length | Y; chained structs | Y | Y, async/futures | Y | Y | Y via `wgpuGetProcAddress` path | shaders/runtime backend | runtime binaries, callback/thread policy, deployment |

The table understates one cross-cutting issue: small integer and aggregate ABI rules are target-dependent. LLVM's `signext`, `zeroext`, `byval`, `sret`, alignment, and calling-convention attributes are ABI facts that must agree at both declaration and call sites, not decorations Luce can attach uniformly ([LLVM Language Reference](https://llvm.org/docs/LangRef.html)). FIIR should obtain them from Clang's target ABI model or a compiled probe.

### SDL3: the smallest broad forcing function

SDL3 immediately exceeds today's scalar and arity envelope while remaining a conventional C API:

- `SDL_RenderLine(SDL_Renderer *, float, float, float, float)` requires `f32` parameters, not just `f64` results ([SDL_RenderLine](https://wiki.libsdl.org/SDL3/SDL_RenderLine)). `SDL_RenderTextureRotated` combines pointer handles, nullable rectangle and center pointers, and a `double` angle ([SDL_RenderTextureRotated](https://wiki.libsdl.org/SDL3/SDL_RenderTextureRotated)).
- `SDL_ConvertPixelsAndColorspace` has twelve parameters, including enums, integer dimensions, `void *`, pitches, color spaces, properties, and a boolean result; lifting eight arguments is necessary even before CUDA ([SDL_ConvertPixelsAndColorspace](https://wiki.libsdl.org/SDL3/SDL_ConvertPixelsAndColorspace)).
- `SDL_PollEvent(SDL_Event *event)` is a nullable out pointer; the event itself is a 128-byte C union containing many event structs and a shared `type` discriminator ([SDL_PollEvent](https://wiki.libsdl.org/SDL3/SDL_PollEvent), [SDL_Event](https://wiki.libsdl.org/SDL3/SDL_Event)). Luce needs either an imported `extern union` with disciplined field access or, initially, a correctly aligned opaque event blob plus generated discriminator-specific copy accessors. Treating the value as an ordinary 64-bit `foreign` is impossible.
- Audio and enumeration are real callback tests. `SDL_SetAudioStreamGetCallback` accepts a nullable callback and userdata and documents calls from the audio stream's operating context; the wrapper must keep the closure/context alive, respect reentrancy, and unregister before release ([SDL_SetAudioStreamGetCallback](https://wiki.libsdl.org/SDL3/SDL_SetAudioStreamGetCallback)). `SDL_EnumerateDirectory` invokes a callback with userdata and two C strings and uses the callback return value for control flow ([SDL_EnumerateDirectory](https://wiki.libsdl.org/SDL3/SDL_EnumerateDirectory), [SDL_EnumerateDirectoryCallback](https://wiki.libsdl.org/SDL3/SDL_EnumerateDirectoryCallback)). Callback recipes therefore need more than a C signature: synchronous versus retained, permitted thread, reentrancy, and unregister/destructor rules.
- Routine queries use optional out pointers, for example `SDL_GetWindowSizeInPixels(window, &w, &h)` ([SDL_GetWindowSizeInPixels](https://wiki.libsdl.org/SDL3/SDL_GetWindowSizeInPixels)). A safe wrapper should return a Luce record or tuple, not expose pointer formation.

SDL_gpu adds a useful asset boundary. `SDL_GPUShaderCreateInfo` contains `size_t code_size`, a byte pointer, a C-string entry point, a shader-format discriminator, a stage, and resource counts ([SDL_GPUShaderCreateInfo](https://wiki.libsdl.org/SDL3/SDL_GPUShaderCreateInfo)). The accepted formats include SPIR-V, DXBC, DXIL, MSL source, and Metal libraries ([SDL_GPUShaderFormat](https://wiki.libsdl.org/SDL3/SDL_GPUShaderFormat)). Pipeline creation uses nested descriptors and pointers ([SDL_GPUGraphicsPipelineCreateInfo](https://wiki.libsdl.org/SDL3/SDL_GPUGraphicsPipelineCreateInfo)); sampler and color-target descriptors contain floats, booleans/small integers, and nested color structs whose layout must be exact ([SDL_GPUSamplerCreateInfo](https://wiki.libsdl.org/SDL3/SDL_GPUSamplerCreateInfo), [SDL_GPUColorTargetInfo](https://wiki.libsdl.org/SDL3/SDL_GPUColorTargetInfo)). SDL_shadercross can translate SPIR-V or HLSL among the backend formats, but it is a separate tool/library whose version and options must enter the cache key ([SDL_shadercross](https://github.com/libsdl-org/SDL_shadercross)).

**Implication.** SDL3 2D forces nominal pointer handles, C strings, floats, unlimited practical arity, C structs, event-union handling, out values, and callbacks. SDL_gpu then forces target-specific blob generation and immutable byte embedding. Calls into SDL itself are direct, so SDL_gpu-first can postpone indirect foreign calls. That postponement ends as soon as an application asks SDL for Vulkan proc addresses or uses Vulkan directly.

### Metal: Objective-C semantics cannot be modeled as merely unusual C names

Metal is an Objective-C protocol API with C aggregates embedded in method signatures. A generated `.m` bridge is the correct boundary; teaching Luce source Objective-C message syntax would be much larger and would duplicate Clang's ABI knowledge.

- Metal objects such as `id<MTLDevice>`, `id<MTLCommandQueue>`, and `id<MTLRenderPipelineState>` are nullable protocol object references with Objective-C retain/release and autorelease behavior. Raw bindings should use distinct non-owning handle types; safe wrappers should retain or consume according to API Notes/Clang annotations.
- `MTLClearColor` is a C struct passed by value and initialized from four `double` values ([MTLClearColor initializer](https://developer.apple.com/documentation/metal/mtlclearcolor/init%28red%3Agreen%3Ablue%3Aalpha%3A%29)). `CAMetalLayer.drawableSize` uses `CGSize`, another by-value aggregate ([CAMetalLayer.drawableSize](https://developer.apple.com/documentation/quartzcore/cametallayer/drawablesize)). The thunk's C ABI must use Clang-determined aggregate classification; lowering all aggregates to a pointer would silently change the ABI unless the thunk explicitly accepts a pointer and performs the by-value method call itself.
- Runtime library compilation accepts an Objective-C `NSString *`, options, and an Objective-C completion block ([`newLibraryWithSource:options:completionHandler:`](https://developer.apple.com/documentation/metal/mtldevice/makelibrary%28source%3Aoptions%3Acompletionhandler%3A%29?language=objc)). Command buffers similarly retain completion blocks until GPU completion ([`addCompletedHandler:`](https://developer.apple.com/documentation/metal/mtlcommandbuffer/addcompletedhandler%28_%3A%29?language=objc)). A C function pointer is not ABI-equivalent to a block. Generated `.m` glue must construct/copy a block capturing a trampoline context, then release the context on completion or cancellation according to a recipe.
- `CAMetalLayer` is a QuartzCore layer configured with a device and pixel format; `nextDrawable` can return nil and drawables come from a limited reusable pool ([CAMetalLayer](https://developer.apple.com/documentation/quartzcore/cametallayer), [`nextDrawable`](https://developer.apple.com/documentation/quartzcore/cametallayer/nextdrawable%28%29?language=objc)). An easy package must wire the QuartzCore/Metal frameworks, app lifecycle and main-thread constraints, native window/view attachment, and temporary autorelease pools—not merely emit selectors.
- Error-returning creation methods commonly pair a nullable result with `NSError **`. The safe wrapper should turn that convention into `T!` using a generated error payload; it should not expose `NSError **`.

Metal assets have two legitimate paths. Xcode's normal source build compiles `.metal` to AIR and links a default `.metallib`; Apple also documents command-line precompilation and runtime source compilation ([Metal libraries](https://developer.apple.com/documentation/metal/metal-libraries), [precompiling a shader library](https://developer.apple.com/documentation/metal/building-a-shader-library-by-precompiling-source-files)). Offline `metal` → `.air` → `metallib` reduces runtime compilation work and makes errors build-time failures ([Metal Programming Guide](https://developer.apple.com/library/archive/documentation/Miscellaneous/Conceptual/MetalProgrammingGuide/Dev-Technique/Dev-Technique.html)). Luce's build graph should offer offline `metallib` as the production default and a runtime-source node only when hot reload is explicitly desired.

**Implication.** The existing generated `.m` thunk plan is necessary and sufficient if it also covers ownership annotations, autorelease pools, nullable ObjC objects, `NSError **`, block construction/lifetime, C aggregate ABI, framework/app-bundle linking, and exception containment. A generic callback trampoline alone does not cover blocks.

### CUDA Driver API: the native-memory forcing function

The Driver API is a better Luce boundary than the CUDA Runtime API because it exposes explicit contexts, modules, functions, streams, and device addresses. It also demonstrates why one untyped `foreign` representation is insufficient.

#### Type taxonomy

- `CUdevice` is an integer device ordinal/type, and APIs such as `cuDeviceGet(CUdevice *device, int ordinal)` fill it through an out pointer ([CUDA device management](https://docs.nvidia.com/cuda/cuda-driver-api/group__CUDA__DEVICE.html)). It should be a nominal `c_int`, not a pointer-like optional handle.
- NVIDIA defines `CUdeviceptr` as an unsigned integer whose size matches the target pointer size, while context/module/function/stream/event types are opaque handles ([CUDA Driver API PDF](https://docs.nvidia.com/cuda/pdf/CUDA_Driver_API.pdf)). `CUdeviceptr` is indeed an excellent non-ARC Luce value, but it needs `c_uintptr` ABI metadata and device-address arithmetic helpers. Conflating it with a host pointer would invite invalid dereferences; conflating it with a C pointer could generate the wrong IR on some ABIs.
- `CUcontext`, `CUmodule`, `CUfunction`, `CUstream`, and `CUevent` deserve distinct raw types. Some APIs admit null/default-stream sentinels and some do not. Optionality belongs on individual declarations; “zero means nullable” must not be inferred for every nominal handle.
- Safe ownership differs by type and creation path. A module returned from `cuModuleLoadData` is destroyed by `cuModuleUnload`; a stream by `cuStreamDestroy`; a borrowed current context is not automatically owned. The safe layer needs owner/borrow distinctions generated from recipes.

#### Out values, buffers, and `cuLaunchKernel`

The Driver API uses out parameters pervasively: device enumeration, context creation, module loading, function lookup, allocation, event creation, and query APIs. Designed `out` support covers the one-slot case. It does not cover kernel launch.

`cuLaunchKernel` has **eleven** formal arguments: function, three grid dimensions, three block dimensions, shared-memory bytes, stream, `void **kernelParams`, and `void **extra` ([CUDA execution control](https://docs.nvidia.com/cuda/cuda-driver-api/group__CUDA__EXEC.html)). For `kernelParams`, element *i* is a host pointer to stable storage containing the actual value of kernel parameter *i*. A device pointer argument is therefore represented by a host slot containing the `CUdeviceptr` integer, and the array contains the address of that slot. The alternative `extra` form accepts one packed parameter buffer plus size, but the caller must reproduce device-code alignment and padding rules ([CUDA Driver API kernel execution](https://docs.nvidia.com/cuda/cuda-programming-guide/03-advanced/driver-api.html#kernel-execution)).

The minimal safe solution is not `foreign[]`. It is a generated launch adapter or runtime `KernelArgs` builder backed by a scoped native arena:

1. each ABI-typed argument is copied into aligned stable storage;
2. an array of pointers to those slots is built;
3. storage and pointer array live through the synchronous host call;
4. only the device work is asynchronous—the launch no longer reads the host argument slots after return;
5. a generated per-kernel signature, when available from a manifest/reflection file, statically checks argument count and representations.

An untyped fallback may accept explicit `KernelArg.i32`, `.f32`, `.device_ptr`, `.bytes(repr, alignment)` values, but should be visibly unsafe. This same arena and view mechanism solves pointer arrays elsewhere without making native pointers general safe-language values.

#### NVRTC versus offline device code

NVRTC is a runtime C API: create a program from source C strings, compile with option strings, query PTX or cubin/log size through `size_t *`, allocate a caller buffer, and copy the result out with `nvrtcGetPTX`/related functions ([NVRTC documentation](https://docs.nvidia.com/cuda/nvrtc/)). `cuModuleLoadData` then consumes that memory. This requires all of: C-string input and C-string arrays, two-call size/query wrappers, mutable native buffers, reading C-written memory back into Luce bytes/string, explicit lifetime through module load, and allocator/error cleanup.

Offline nvcc can emit PTX, cubin, or fatbin artifacts ([nvcc documentation](https://docs.nvidia.com/cuda/cuda-compiler-driver-nvcc/index.html)). Production builds should normally use an asset node whose key contains nvcc version, GPU architecture/code-generation flags, includes, defines, and source closure, then embed or deploy the artifact. NVRTC remains valuable for specialization and developer hot reload. Luce should support both through the same `Bytes`/native-view boundary rather than choose one.

#### cuBLAS, cuDNN, loading, and CI

cuBLAS reinforces arity and scalar ABI. `cublasCreate_v2` returns an opaque handle through an out pointer; GEMM-style calls have well over eight arguments, and BLAS scalars are often pointers so host/device pointer mode can be selected ([cuBLAS API](https://docs.nvidia.com/cuda/cublas/index.html)). cuDNN likewise interprets `alpha`/`beta` pointers by tensor data type—commonly pointer-to-`float` for half/float data and pointer-to-`double` for double data ([cuDNN scaling-parameter conventions](https://docs.nvidia.com/deeplearning/cudnn/backend/v9.17.1/developer/misc.html)). Safe wrappers should materialize correctly typed stable scalar slots and keep pointer-mode semantics explicit.

The NVIDIA driver library and CUDA toolkit are separate deployment facts. The driver supplies the actual driver API library; toolkit components supply headers, nvcc, NVRTC, and math libraries. Dynamic loading is attractive for optional CUDA support but turns every loaded symbol into an indirect call; initial Luce support can link/import driver symbols directly, then reuse the function-pointer primitive when an optional loader is added.

CUDA 10.2 was the last toolkit release to support macOS ([CUDA 10.2 release notes](https://docs.nvidia.com/cuda/archive/10.2/cuda-toolkit-release-notes/)); current installation guidance targets supported Linux and Windows environments ([CUDA Linux Installation Guide](https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html)). A Mac-based project therefore needs four CI levels: committed-binding/staleness checks that need no toolkit; cross-project type/check tests using fixture FIIR; Linux/Windows build-and-link jobs with a toolkit; and an NVIDIA GPU runner for execution. `luce doctor cuda` on macOS should report “execution unsupported on this host” while identifying remote/container CI recipes, rather than mark the entire Luce installation broken.

**Implication.** CUDA forces pointer-width integer typedefs, pervasive output conversion, stable native slots/arrays, pointer-to-pointer marshalling, caller-filled buffers and reads, arbitrary arity, target-aware assets, and SDK/runtime diagnostics. It does not require general host pointer arithmetic in safe Luce.

### Vulkan direct: semantic registry generation plus mandatory dispatch

Vulkan's difficulty is scale plus explicit runtime dispatch, not exotic syntax.

The Khronos registry is the correct generator source. Khronos states that headers, specification material, and reference pages are generated from the registry, and `vk.xml` carries types, commands, enumerants, features, extensions, aliases, guards, dependencies, and semantic attributes ([Vulkan-Docs repository](https://github.com/KhronosGroup/Vulkan-Docs), [registry schema documentation](https://registry.khronos.org/vulkan/specs/latest/registry.html)). Parsing only `vulkan.h` loses or makes difficult to recover metadata such as `len`, `optional`, `structextends`, extension dependencies, success codes, aliases, and platform protection. Conversely, XML alone should not be trusted as a target ABI compiler. The recommended hybrid is:

1. pin `vk.xml` and generate the semantic model and safe recipes from it;
2. compile the official target headers with Clang to obtain/verify exact typedefs, macros, sizes, alignments, offsets, calling convention, and platform guards;
3. store registry/header versions and target triple in FIIR and the generated-file stamp.

The generated `vulkan_core.h` is tens of thousands of lines and contains enormous enum/flag/extension surfaces ([Vulkan-Headers](https://github.com/KhronosGroup/Vulkan-Headers/blob/main/include/vulkan/vulkan_core.h)). That volume is a code-generation and namespacing problem, not a reason to add first-class language syntax for every C enum or flag convention. Generate nominal bitmask wrappers with constants and operations; omit extensions not selected by the package feature set while retaining reproducible regeneration.

Most extensible create/query structs begin with `sType` and `pNext`. `sType` identifies the concrete struct, while `pNext` links a chain of extension structures ([Khronos pNext and sType guide](https://docs.vulkan.org/guide/latest/pnext_and_stype.html)). Raw bindings need nullable typed native pointers and exact structs. Safe bindings should generate builders that set `sType`, verify `structextends`, hold each node in stable arena storage, reject duplicate/illegal nodes where the registry says so, and preserve the entire chain through the call. No new general Luce “chain” feature is warranted.

Vulkan handle representations differ: dispatchable handles are pointer-to-opaque types; non-dispatchable handles are 64-bit integer types under the modern header model. Null handles are only meaningful where the command permits them ([Vulkan object model](https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html)). This is the same nominal-plus-representation requirement exposed by CUDA.

The loader makes indirect calls unavoidable. A program normally obtains commands using `vkGetInstanceProcAddr` and `vkGetDeviceProcAddr`; availability depends on core version, enabled extensions, instance/device, and platform ([Vulkan style guide](https://registry.khronos.org/vulkan/specs/latest/styleguide.html), [`vkGetInstanceProcAddr`](https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html#vkGetInstanceProcAddr)). Luce must:

- represent a nullable C function address with an exact calling convention and signature;
- convert the untyped loader result only in generated unsafe code;
- call through the typed value;
- generate separate entry/global, instance, and device dispatch tables whose lifetime cannot exceed the owning instance/device;
- report a missing required proc at table construction and retain optional extension procs as optionals.

Calling through a mismatched function-pointer type is undefined behavior; Clang's indirect-call sanitizer explicitly diagnoses incompatible indirect calls ([Clang UndefinedBehaviorSanitizer](https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html)). A generic `foreign.call(args...)` with runtime arity is not acceptable. FIIR must hold the exact prototype and target calling convention, and the LLVM backend and interpreter must both implement it.

Vulkan shader modules consume SPIR-V bytecode, so shader compilation is another build-graph node rather than a binding concern ([Khronos shader-module tutorial](https://docs.vulkan.org/tutorial/latest/03_Drawing_a_triangle/02_Graphics_pipeline_basics/01_Shader_modules.html)). On macOS, MoltenVK additionally requires runtime/framework deployment and a `CAMetalLayer`, making Metal window integration relevant even when the application uses Vulkan ([MoltenVK Runtime User Guide](https://github.com/KhronosGroup/MoltenVK/blob/main/Docs/MoltenVK_Runtime_UserGuide.md)).

**Implication.** Direct Vulkan cannot ship before typed indirect calls. `vk.xml` should be a first-class binding-generator frontend/plugin with Clang ABI verification, not fed through a C-header-only recipe. `pNext` safety, dispatch-table lifetimes, flags, and extension selection are generated-library mechanisms.

### Function-pointer-table APIs: ONNX Runtime and OpenGL

ONNX Runtime is the cleanest isolated test of indirect calls. The one ordinary exported function, `OrtGetApiBase`, yields `OrtApiBase`; its `GetApi` field yields a versioned `OrtApi` whose hundreds of members are C function pointers. Allocators and custom-op structures contain further callbacks/function tables ([ONNX Runtime C header](https://github.com/microsoft/onnxruntime/blob/main/include/onnxruntime/core/session/onnxruntime_c_api.h), [`OrtApi` documentation](https://onnxruntime.ai/docs/api/c/struct_ort_api.html)). The project's C API guidelines explicitly make the table the stable ABI surface ([C API Guidelines](https://github.com/microsoft/onnxruntime/blob/main/docs/C_API_Guidelines.md)). A direct-call-only FFI can retrieve the table and then do nothing useful with it.

An ONNX wrapper also tests opaque owners, status-pointer-as-error, caller-allocated output arrays, tensor data views, UTF-8 names, Windows wide/path types, provider-specific option structs, and deployment of the selected execution-provider shared libraries. But a minimal `GetApi` → create environment → release environment program is much smaller than a Vulkan triangle and cleanly validates table field loading and typed indirect invocation.

OpenGL has a platform-specific version of the same problem. Modern commands are commonly obtained through `wglGetProcAddress`, `glXGetProcAddress`, or an analogous context loader; on Windows, core-library lookup and `wglGetProcAddress` fallback have to be combined, and returned addresses are context-dependent ([Khronos loading guide](https://wikis.khronos.org/opengl/Load_OpenGL_Functions), [Microsoft `wglGetProcAddress`](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-wglgetprocaddress)). A generated GL loader therefore needs typed function slots plus context-current ordering. SDL can create the context and return proc addresses, but does not remove the need to call them.

**Implication.** Indirect calls are one small language/IR primitive with disproportionate reach. Implement them once, keep address-to-signature casts confined to generated unsafe code, and test them with ONNX before scaling to Vulkan or OpenGL.

### Quick pass over adjacent high-value APIs

#### Accelerate and CBLAS

Apple's Accelerate framework exposes CBLAS and LAPACK surfaces in LP64 and ILP64 variants ([Accelerate BLAS library](https://developer.apple.com/documentation/accelerate/blas-library)). `cblas_sgemm`-class operations pass `float` scalars by value and have roughly fourteen parameters; double variants require `f64`. This is an excellent ABI test for arbitrary arity and scalar floats. The underlying Fortran ecosystem is not one portable ABI: compiler conventions can differ for symbol names, logicals, complex returns, and hidden string lengths. Apple provides documented Fortran 90 wrappers and integer-width modes ([Accelerate Fortran wrappers](https://developer.apple.com/documentation/accelerate/usingthefortran90wrappers)). Luce should bind the documented CBLAS/C LAPACK headers or generate a tiny C thunk, not add “Fortran FFI” on the strength of one vendor library.

#### SQLite

SQLite's core handle model is straightforward, but it is a concentrated ownership test. `sqlite3_exec` accepts a callback plus userdata and can return an allocator-owned `char **errmsg` that must be freed with SQLite's allocator; row cells can be null ([sqlite3_exec](https://www.sqlite.org/c3ref/exec.html)). Blob/text binding pairs a pointer and byte length with a destructor policy; the special `SQLITE_STATIC` and `SQLITE_TRANSIENT` values are function-pointer-typed sentinels, including a cast of `-1`, not ordinary callbacks ([binding values](https://www.sqlite.org/c3ref/bind_blob.html), [destructor behavior](https://www.sqlite.org/c3ref/c_static.html)). Recipes should hide these behind copy/borrow APIs and pin a Luce buffer only when its lifetime is provably sufficient. General function-pointer integer casts should not leak into application Luce.

SQLite also contains variadic convenience APIs. The correct policy is to bind fixed or `va_list`/adapter alternatives and emit generated typed thunks, not add a general C variadic call facility.

#### llama.cpp

llama.cpp provides an `extern "C"` header over a C++ implementation. It uses opaque model/context types, structs by value such as batch/configuration records, booleans, floats, arrays, callbacks, and many pointer-count pairs ([llama.h](https://github.com/ggml-org/llama.cpp/blob/master/include/llama.h)). The build has selectable CPU/GPU backends and a substantial C++ dependency graph. The model itself is normally a multi-gigabyte runtime file and should be a deployed/resource path, not an embedded object blob. Luce's C++ thunk generator is useful for exception containment and any unstable C++-only pieces, but the published C header should remain the primary ABI.

#### Dear ImGui through cimgui

cimgui demonstrates that generated adapters beat language expansion. It generates a C header/implementation and machine-readable metadata from Dear ImGui's C++ API ([cimgui](https://github.com/cimgui/cimgui)). The wrapper normalizes overloads, default parameters, methods, and C++ vector types into C-callable functions, while still requiring a C++ compilation step. Luce should consume cimgui's generated C ABI and JSON metadata, build the matching C++ source content-addressably, and generate safe `Vec2`/`Vec4`, string, slice, and owner wrappers. printf-style varargs should route through fixed adapters. There is no need for Luce C++ method or default-argument syntax.

#### wgpu-native

wgpu-native combines many Vulkan-like shapes with a more regular C API. Its WebGPU headers define chained input/output structs with `sType`/`next`, pointer-length string views, callback-info structs, futures and callback modes, and nested descriptors ([struct chaining](https://webgpu-native.github.io/webgpu-headers/StructChaining.html), [asynchronous operations](https://webgpu-native.github.io/webgpu-headers/Asynchronous-Operations.html), [WGPUDeviceDescriptor](https://webgpu-native.github.io/webgpu-headers/structWGPUDeviceDescriptor.html)). Global functions include `wgpuGetProcAddress`, returning a generic procedure address for optional/dynamic dispatch ([global functions](https://webgpu-native.github.io/webgpu-headers/group__GlobalFunctions.html)). The project publishes C headers and native artifacts for major desktop platforms ([wgpu-native](https://github.com/gfx-rs/wgpu-native)).

Bindings must encode callback timing modes (“spontaneous” versus process-events/polling), keep userdata alive, prevent use-after-free across asynchronous completion, and deploy the right backend shared library. This is where a `while let` loop would be pleasant, but it is not what makes the FFI possible.

## The minimal ABI and wrapper union derived from Part 1

The union below is smaller than “support C” and larger than A–I as written. The key is choosing which layer owns each capability.

| Required mechanism | Public language surface | FIIR/backend obligation | Generated safe-layer treatment | First forcing slice |
|---|---|---|---|---|
| Nominal C values | `extern type Window`; distinct underlying scalar hidden/inferred | preserve C pointer/integer/width representation | owner/borrow wrappers, no implicit cross-handle conversion | SDL `Window` vs `Renderer`; CUDA taxonomy validates representations |
| Nullable boundary values | `T?` on declarations | zero/null representation as declared, not globally inferred | required/optional conversion with diagnostics | SDL nullable geometry pointers |
| C scalar family | `f32/f64`, signed/unsigned 8/16/32/64 and C aliases in generated code | target ABI classification, extension attrs, enum/bool/size types, unrestricted practical arity | normal Luce numeric types or checked newtypes | CBLAS `sgemm`; SDL render/conversion |
| C strings | designed `cstr` coercion | NUL-terminated pointer ABI | input scratch C string; nullable/borrowed/owned return copying; arrays; pointer-length strings | SQLite and SDL enumeration |
| Out/inout | designed `out` plus generator metadata | addressable typed slot | return tuple/record/result; initialize/read/drop correctly | `cuDeviceGet`; SDL window-size query |
| Aggregates | designed `extern struct`; add fixed arrays and a union strategy | Clang layout and by-value/by-reference return classification | value records/builders; generated union accessors; bitfield thunks | `SDL_Event`; Metal `MTLClearColor` |
| Scoped native storage/views | mostly generated-only `unsafe native` operations | typed load/store/copy, alignment, address stability, pointer-to-pointer | slices/bytes/strings/two-call enumeration and arena builders | CUDA kernel args + NVRTC output |
| Callbacks | designed trampoline syntax | exact C calling convention, retained context hooks | recipe encodes lifetime/thread/reentrancy/unregister | SDL audio/enumeration; Metal block bridge |
| Indirect C calls | nullable `extern fnptr "c"(...) -> R` callable only with exact signature; unsafe cast/load | load/call through function address in LLVM and interpreter; signature/callconv identity | generated versioned dispatch tables and lifetime ties | ONNX Runtime `OrtApi` |
| Build/link/deploy graph | manifest, not expression syntax | reproducible target-aware artifact graph | package recipes choose providers and runtime assets | SDL_gpu shader matrix; Metal and CUDA assets |

### The native-memory substrate, precisely

The epoch-1 design already anticipates generated unsafe native pointer operations. Make that substrate explicit enough for generators but deliberately unattractive for hand-written application code:

```text
native_ptr[T]             // immutable C address; no ARC and no implicit dereference
native_mut_ptr[T]         // mutable C address
native_slot[T](value?)    // aligned, stable, scoped storage
native_array[T](count)    // aligned, stable, scoped contiguous storage
address(slot/array[i])
load/store/copy           // unsafe and bounds-aware where a count is known
borrowed_bytes(ptr, len)  // scoped view; explicit copy before scope escape
```

FIIR must also describe pointer depth, pointee constness, array length relationships, and address space where relevant. Generated code can then express `T **`, arrays of C strings, CUDA's array of argument-slot addresses, and Vulkan `pNext` nodes. Safe wrappers should normally expose:

- `Bytes`/`List[T]` inputs converted to scoped pointer-count pairs;
- copied `Bytes`/`String` results from borrowed native memory;
- a two-call “query count/size, allocate, retry if changed” combinator;
- owners with a recipe-selected release function and borrowed children tied to the owner;
- explicit pin/retention only for APIs that keep a buffer after return.

This need not create a general-purpose unsafe pointer language. The compiler can initially reserve the operations for generated modules stamped with FIIR identity. Hand-written use can remain behind the existing `unsafe native` policy.

## Part 2 — how other languages make the same APIs tractable

### Comparison matrix

| Ecosystem | What it actually ships | Mechanism that makes it tractable | Lesson for Luce |
|---|---|---|---|
| Rust | crates: `sdl3-sys`/safe SDL crates, `ash`, `cudarc`, `objc2-metal`; many community wrappers | C-layout/raw `-sys` layer, `repr(transparent)` newtypes, typed `unsafe extern "C" fn`, build scripts, generated loaders, RAII wrappers | Separate exact raw ABI from curated safe owners/builders; generation and packages matter more than syntax |
| Zig | compiler C interop/translation facilities, typed C-callable function pointers, `opaque {}`, `@embedFile`, programmable build graph; third-party packages | direct header reuse or translated declarations plus compile-time reflection/build logic | A compact language can cover the ABI with few primitives, but package quality and semantic recipes remain work |
| Odin | a large checked-in `vendor:` collection including SDL3, Vulkan, OpenGL, Metal and wgpu, plus `foreign` imports, `distinct`, C procedure types | compiler-supported C ABI plus centrally maintained, generated/vendor bindings | “Easy” requires a maintained distribution and tested versions, not merely a generator command |
| Nim | `importc`, `cdecl`, `header`, `dynlib`, `compile`/`passL`, incomplete structs, distinct types; community wrappers and generators | pragmas attach native ABI/build facts to ordinary declarations; typed proc values can be cast from symbols | Flexible escape hatches work, but fragmented recipes shift maintenance and safety to each package |

### Rust: generated raw layers plus ownership libraries

Rust's most successful native bindings are layered. A raw crate mirrors the ABI with `#[repr(C)]` records and `unsafe extern "C" fn` signatures; a safe crate adds RAII, slices, errors, thread restrictions, and builders.

- `ash` is generated from Vulkan registry data and provides entry/instance/device function tables and extension loaders; its default entry loading uses a dynamic library rather than assuming all Vulkan commands are directly linked ([ash](https://github.com/ash-rs/ash), [`EntryFnV1_0`](https://docs.rs/ash/latest/ash/struct.EntryFnV1_0.html)). The lesson is not Rust syntax; it is semantic registry generation plus generated dispatch scopes.
- `cudarc` offers versioned CUDA bindings and a safe driver layer, normally with dynamic loading. Its launch builder holds argument references and constructs the required `Vec<*mut c_void>`; for a device slice it pushes the address of the stored `CUdeviceptr` field ([cudarc](https://docs.rs/cudarc/latest/cudarc/), [launch source](https://docs.rs/cudarc/latest/src/cudarc/driver/safe/launch.rs.html)). This is direct evidence for Luce's stable-storage/argument-builder requirement.
- The older `metal-rs` crate now directs new users toward the `objc2` family ([metal-rs migration recommendation](https://github.com/gfx-rs/metal-rs/issues/339)). `objc2-metal` supplies framework bindings using retained/protocol-object types, and `block2` models Objective-C blocks ([objc2](https://github.com/madsmtm/objc2), [objc2-metal](https://docs.rs/objc2-metal/latest/objc2_metal/), [block2](https://docs.rs/block2/latest/block2/)). Clang/header translation and ownership-annotated wrappers make it tractable, not manually flattened selectors.
- `sdl3-sys` is the low-level SDL3 surface and supports platform/native dependency discovery/build choices; safe SDL crates build higher-level types over it ([sdl3-sys](https://docs.rs/sdl3-sys/latest/sdl3_sys/)). The crate ecosystem, Cargo build scripts, pkg-config/vcpkg logic, and linked native binary are part of the feature.

Rust's `#[repr(transparent)]` guarantees a one-field wrapper has the field's ABI/layout, allowing zero-cost nominal handles ([Rust type layout](https://doc.rust-lang.org/stable/reference/type-layout.html)). Opaque C struct tags are also commonly declared as uninhabited/incomplete Rust types and used only behind pointers ([Rust FFI Nomicon](https://doc.rust-lang.org/nightly/nomicon/ffi.html)). Luce can obtain the same protection much more cheaply than Rust's full trait/type system: prohibit implicit conversions between two `extern type`s, retain underlying ABI metadata in FIIR, allow equality/zero checks only when a recipe opts in, and generate explicit `raw` access solely in unsafe code.

### Zig: a small primitive set, with build logic carrying much of the load

Zig's `opaque {}` creates a distinct incomplete type, so pointers to different C handle tags are not interchangeable. Typed procedure pointers include a calling convention and can be called indirectly; the compiler's C interop/translation workflow makes headers directly usable rather than demanding hand transcription ([Zig language reference](https://ziglang.org/documentation/master/)). Zig does not centrally ship polished bindings for every named library in the way Odin's `vendor:` tree does; projects either import/translate headers or consume third-party generated packages, and `build.zig` supplies include paths, C/C++ sources, frameworks, libraries, and tool steps.

Zig's `@embedFile` returns a compile-time fixed byte array containing a file ([Zig 0.15.2 language reference](https://ziglang.org/documentation/0.15.2/)). It is excellent for a final artifact but does not itself specify how MSL, SPIR-V, PTX, or a fatbin is produced. The programmable build graph does that. Luce should copy this division of responsibility, but need not copy the source-expression builtin immediately.

### Odin: compiler ABI support plus a maintained vendor surface

Odin has first-class C strings, `foreign` library/import blocks, typed C-calling-convention procedure values, and `distinct` defined types ([Odin overview](https://odin-lang.org/docs/overview/)). More importantly, its distribution ships a broad `vendor:` package collection: SDL3, generated Vulkan, an OpenGL loader, Metal, and wgpu are present as maintained source packages ([Odin vendor packages](https://pkg.odin-lang.org/vendor/), [vendor Vulkan](https://pkg.odin-lang.org/vendor/vulkan/), [vendor Metal](https://pkg.odin-lang.org/vendor/darwin/Metal/)).

This demonstrates the non-language half of “easy.” A user can import a known package because somebody has pinned headers, normalized names, handled dynamic symbols/platform split, and tested the result. `luce bind` plus recipes is not an end state unless Luce also owns a small versioned catalog of maintained high-value bindings and dependency recipes.

### Nim: expressive interop pragmas, decentralized polish

Nim attaches native facts through pragmas such as `importc`, `header`, `dynlib`, `cdecl`, incomplete-struct declarations, and compile/link options; it also supports distinct types over pointer representations ([Nim manual](https://nim-lang.org/1.0.0/manual.html)). Its dynamic-library support resolves an address and casts it to a typed `proc` value before invocation ([Nim dynlib](https://nim-lang.org/docs/dynlib.html)). Community packages and generators such as c2nim/Futhark fill ecosystem gaps; for example, SDL3 bindings exist as a community package rather than a language-distribution guarantee ([nim-sdl3](https://github.com/transmutrix/nim-sdl3)).

Nim shows that a compact compiler can express everything here. It also shows the cost of leaving dependency acquisition, annotation quality, lifetime policy, and generated-version maintenance to unrelated packages. Luce's committed bindings and API-Notes-style recipes are a stronger reproducibility baseline if paired with a maintained catalog and ABI verification.

### Typed opaque handles: mechanism and cost

C already distinguishes `struct SDL_Window *` from `struct SDL_Renderer *` through different struct tags. Rust preserves that distinction with opaque marker structs or transparent newtypes; Zig uses pointers to distinct `opaque {}` declarations; Odin uses distinct/defined types; Nim can use `distinct pointer`. All are compile-time distinctions with no per-value runtime overhead.

For Luce the minimal rule set is:

```luce
// Surface shown for illustration; the generator normally emits it.
extern type Window             // FIIR: pointer-to-incomplete SDL_Window
extern type Renderer           // FIIR: pointer-to-incomplete SDL_Renderer
extern type DeviceId           // FIIR: c_int
extern type DeviceAddress      // FIIR: c_uintptr
extern type VkBuffer            // FIIR: c_u64
```

- values are plain, copyable, non-ARC raw values;
- distinct types do not implicitly convert, even if their machine representation matches;
- nullability is `Window?`, only where a parameter/result is annotated nullable;
- arithmetic is unavailable by default; a device-address wrapper may explicitly expose checked offset operations;
- no constructor from integers exists in safe code; generated unsafe code may use an FIIR-checked representation conversion;
- safe owning wrappers are ordinary ARC-managed types containing the raw value and a release policy.

Compiler cost is modest: nominal type identity in the checker, representation metadata in FIIR, equality/optional lowering, and transparent argument/return lowering. The real cost is generator correctness and diagnostics. Do **not** implement this as “every extern type is a 64-bit token”; doing so loses 32-bit portability, distinguishes neither pointers from integers in LLVM, and mishandles `CUdevice`.

### Asset embedding: language expression or build-system product?

Rust's `include_bytes!` returns a reference to a compile-time byte array ([Rust `include_bytes!`](https://doc.rust-lang.org/std/macro.include_bytes.html)); Zig's `@embedFile` similarly includes bytes at compilation; Go's `//go:embed` initializes a string, byte slice, or embedded filesystem from matched files ([Go embed](https://go.dev/pkg/embed/)). These are ergonomic *consumers* of artifacts. Shader/device-code production still needs a build tool: Cargo build scripts can run generators and report exact rerun/link dependencies ([Cargo build scripts](https://doc.rust-lang.org/cargo/reference/build-scripts.html)), while crates such as shaderc compile source to SPIR-V ([shaderc-rs](https://docs.rs/shaderc/latest/shaderc/)).

For epoch-1, make embedding a build-graph feature with a generated module rather than a general source builtin:

```text
asset "triangle_spv" {
    tool = "glslc"
    input = "shaders/triangle.vert"
    output = "spirv"
    embed = true
}
```

The node should produce (a) a readonly object-file section or equivalent linker blob and (b) a tiny generated Luce module exporting `BytesView { data, count }` plus optional metadata. This avoids megabytes of generated numeric literals, supports alignment and zero-copy views, allows per-target variants, participates in remote/content caches, and can choose `embed`, `copy_resource`, or `app_bundle` without source changes. Its key includes tool identity/version, target, flags, includes/import closure, environment allowlist, and input hashes.

Presets should cover Metal (`metal`/`metallib`), Vulkan (`glslc`, DXC, or Slang to SPIR-V), CUDA (nvcc PTX/cubin/fatbin), and SDL_shadercross target matrices. A later `embed_bytes("file")` expression is harmless for ad hoc static data, but it does not reduce the work needed for these libraries and should not block them.

### Indirect calls: what can be deferred and what cannot

SDL core and SDL_gpu call exported C functions directly, so a deliberate SDL-first roadmap can defer function-pointer invocation. Metal message sends and blocks are also hidden behind generated direct C thunks. CUDA Driver can begin with directly linked/imported symbols. That is the complete deferral window.

The following break without indirect calls:

- Vulkan instance/device/extension commands obtained from proc-address functions;
- virtually all ONNX Runtime operations behind `OrtApi`;
- modern OpenGL commands returned by the platform/context loader;
- optional wgpu-native procedures returned by `wgpuGetProcAddress`;
- optional-runtime loaders for CUDA or any other library;
- C plugin/vtable interfaces common outside this list.

The needed primitive is narrow:

```luce
extern fnptr "c" CreateEnv(LoggingLevel, cstr, out Env?) -> Status?
```

The name denotes an exact function-pointer type, not a declaration of a global symbol. Values may be optional, may be loaded from an `extern struct` field, and may be invoked like functions. Conversion from an untyped address is restricted to generated unsafe code and checks size/address kind; the prototype, calling convention, target ABI attributes, and unwind policy are in FIIR. No closure capture, JIT, variadic dispatch, or arbitrary dynamic signature is required.

## Part 3 — critique of the strawman

### Language/ABI proposals A–I

| Item | Verdict | Required correction |
|---|---|---|
| **A. `foreign?`** | **Keep, high priority** | Nullability must be per declaration/recipe. Generalize the spelling to nominal extern types (`Window?`), nullable C strings and function pointers. Do not assume zero is invalid for every raw handle or ID. |
| **B. nominal opaque handles** | **Keep, expand slightly** | Add nominal extern *value* types whose FIIR representation can be pointer, pointer-width integer, fixed integer, or C enum—not only a renamed 64-bit `foreign`. Separate raw non-owning values from ARC owner wrappers. |
| **C. `cstr` coercion** | **Keep, high priority** | Input coercion is only half: add generated handling for nullable C strings, borrowed/owned returns, C-string arrays, pointer-length string views, and platform encodings/path types. |
| **D. `out` params** | **Keep, high priority** | Recipes must express `in`, `out`, `inout`, optional out, multiple results, pointer-to-pointer, allocator-owned results, caller-buffer/two-call queries, and pointer/count relationships. Back them with native slots/views. |
| **E. scalars and arity** | **Keep, reframe as ABI completeness** | Add `f32/f64`, 8/16-bit signed/unsigned, C bool/char/short/int/long/size/ptrdiff/intptr/enum representations and arbitrary practical arity. Derive extension/aggregate attributes from target Clang ABI; never hardcode “u8 means `zeroext` everywhere.” |
| **F. `extern struct`** | **Keep, expand importer** | Require nested structs, fixed arrays, alignment, target conditionals and aggregate returns. SDL forces a union strategy; initially generated blob/accessors are acceptable, but FIIR must model unions. Use thunks for bitfields and layout-sensitive macros. |
| **G. indirect foreign calls** | **Keep; defer only through SDL/Metal** | Make an exact typed, nullable C function-pointer value callable. Implement before ONNX/Vulkan/OpenGL/wgpu or optional CUDA loading. It is small compared with the loaders it enables. |
| **H. callback trampolines** | **Keep** | Add declarative lifetime/thread/reentrancy/unregister/error-return policy. Objective-C blocks are generated `.m` adapters around the callback trampoline, not the same ABI. |
| **I. diverging `else`; `while let`** | **Useful but not an FFI prerequisite** | Treat as ordinary language ergonomics. Do not place on the critical native-library path; generated wrappers can use existing control flow until the general language design justifies them. |

The potentially misleading phrase in E is “lift the 8-arg cap.” Codegen should have no semantic fixed cap at all; the target ABI determines register/stack assignment. Tests should deliberately cover 0, 1, 8, 9, 11, 14, and mixed scalar/aggregate calls rather than replace eight with another arbitrary number.

### What is missing from the language/runtime union

#### 1. Scoped native storage and readback — must add

This is the principal omission. It should include aligned stable slots/arrays, pointer-depth representation, typed load/store/copy, borrowed views, pointer-count and pointer-array construction, and an explicit scope/escape rule. Keep it generated/unsafe. It enables CUDA kernel arguments, NVRTC, Vulkan enumeration and chains, C string arrays, result tensors, and C-written buffers.

#### 2. ABI-represented distinct scalar typedefs — add as part of B/E

Opaque pointer tags are not enough. Preserve `CUdevice`, `CUdeviceptr`, Vulkan non-dispatchable handles, SDL IDs, C enums, `size_t`, and platform-dependent typedefs as nominal values with their actual underlying ABI types. This catches mixing two integer handles without losing calling correctness.

#### 3. Function-pointer types inside aggregates — add as part of F/G

FIIR and `extern struct` field access must represent typed function-pointer fields, including nullability and calling convention. Otherwise `OrtApi` remains inaccessible even after adding standalone indirect-call syntax.

#### 4. External union and fixed-array representation — add to FIIR; public syntax may wait

`SDL_Event`, Vulkan names/memory types, platform records, and many headers contain unions or inline arrays. FIIR must model their size/alignment/member layouts. Public safe Luce can initially use generated tagged decoding/accessors, avoiding unrestricted union reads. A full C importer will eventually benefit from `extern union` syntax.

#### 5. Ownership, thread, and lifetime metadata — recipes/tooling, not core types

Nullability is not ownership. Recipes need owned/borrowed/consumed, parent-tied borrows, release function, allocator family, buffer retention, callback retention, thread affinity, and reentrancy. ObjC annotations and API Notes can seed this; C APIs such as SDL/CUDA/Vulkan need curated notes.

#### 6. Error-convention adapters — generator feature

Libraries report failure as `bool + SDL_GetError`, `CUresult`, `VkResult` with multiple success codes, nullable `OrtStatus *`, `NSError **`, or SQLite integer codes. The recipe must map these to Luce `T!` while preserving warning/nonfatal statuses and fetching thread-local error strings at the correct moment.

#### 7. Vararg and bitfield policy — explicitly *do not* generalize now

Use generated fixed-signature C/C++ thunks, `va_list` alternatives, or library-specific adapters. Use generated getters/setters/thunks for C bitfields and macro expressions. This is a conscious boundary, not an accidental unsupported corner.

### What is overbuilt for this objective

- **The two I ergonomics changes on the critical path.** Diverging `else` and `while let` improve wrappers and polling code but unlock none of the named ABIs. Design them for Luce as a whole after the FFI milestones.
- **A general user-facing unsafe pointer language.** Stable slots, pointer depth and copies are necessary; arbitrary pointer arithmetic, integer casts and escaping borrows are not. Reserve the substrate for generated `unsafe native` modules until independent use cases justify more.
- **General C variadic calls.** They multiply ABI cases and undermine static signatures. Fixed generated adapters cover SQLite, ImGui and logging; bind typed non-variadic alternatives where available.
- **Objective-C or C++ syntax in Luce.** Content-addressed Clang thunks already provide the stable flat ABI. Exposing selectors, templates, overload resolution or C++ exceptions would be a different language project.
- **A source-level asset builtin before the asset graph.** `embedFile` is convenient but cannot choose/produce SPIR-V, metallib, DXIL or fatbin. The graph plus generated byte-view module is the forcing feature.
- **First-class safe union mutation and C bitfield syntax.** FIIR must know layouts, but generated discriminated accessors and thunks cover the named libraries. Broaden public syntax only when ordinary Luce code needs to define such types.
- **A universal native build-script escape hatch as the default.** Reproducible declarative recipes should cover high-value packages. Provide an explicit quarantined escape hatch later, with declared inputs/outputs and lost-cache/reproducibility diagnostics.

### Tool proposals T1–T6

| Tool | Verdict | Concrete end state |
|---|---|---|
| **T1 `luce bind` + recipes** | **Keep; central** | Clang-to-FIIR raw import plus safe wrapper pass. Add semantic frontends for registries/metadata (`vk.xml`, cimgui JSON), target conditionals, ownership/lifetime/error notes, and reproducible header/registry provenance. |
| **T2 ObjC/C++ thunk generator** | **Keep; central for Metal/cimgui** | Generate `.c/.m/.mm` only as content-addressed nodes. Cover selectors/protocols, ObjC ownership/autorelease, blocks, `NSError **`, C++ overload/default normalization, exception firewall, bitfields/macros and typed vararg adapters. |
| **T3 native dependency recipes + link autowiring** | **Keep; broaden to deployment** | Resolve system SDK/framework, pkg-config, vcpkg-like package, checked source archive/git, or supplied path. Carry include/defines/compile language/link order/frameworks/runtime DLLs/rpaths/licenses and target predicates. |
| **T4 build-graph asset nodes + embedding** | **Keep; prefer generated module/object** | Tool/version/target/input-aware shader/PTX graph. Emit readonly object blob + tiny Luce `BytesView` module, or copy/app-bundle resource. Presets for Metal, SPIR-V, nvcc and SDL_shadercross. |
| **T5 `luce doctor`** | **Keep** | Capability-scoped checks: compiler SDK, headers, link library, runtime loader, validation layers, GPU/driver, asset tools. Distinguish build-time, run-time and optional capabilities; print actionable commands/paths without mutating machines. |
| **T6 staleness-checked committed bindings** | **Keep** | Stamp FIIR/schema, generator, recipe, source header/registry hashes, target family and feature set. CI regeneration must be deterministic and show a semantic diff. |

### Additional tools required for a credible end state

#### T7. Dispatch/loader generator

Generate typed tables for Vulkan entry/instance/device scopes, ONNX Runtime versions, OpenGL contexts, wgpu procedures, and eventually optional CUDA symbols. It should:

- load the bootstrap symbol through a manifest-selected direct import or `dlopen`/`LoadLibrary` adapter;
- resolve each function to an exact `extern fnptr` type;
- negotiate version/extensions and distinguish required from optional commands;
- tie dispatch table lifetime to the library/instance/device/context owner;
- produce a single diagnostic listing absent required procedures and the negotiated environment.

This is distinct from T1: `luce bind` knows signatures; T7 knows runtime resolution and scope.

#### T8. `luce bind verify`: ABI probes and smoke tests

Generate and compile a tiny C/C++/Objective-C probe for each target/toolchain. Compare `sizeof`, `_Alignof`, `offsetof`, enum/typedef widths, function-pointer size, selected macro values, and symbol availability against FIIR. For aggregate calls and small integers, generate cross-language call/return probes or compare Clang LLVM IR. Run indirect-call tests under Clang's function sanitizer where available. Record the compiler target triple and SDK/header identity.

Committed generated source without this check can be consistently stale or consistently wrong. Verification is especially important for platform-conditioned Vulkan types, ObjC aggregates, Windows calling conventions, C `long`, and 32/64-bit CUDA typedefs.

#### T9. Runtime deployment/bundle nodes

Linking is not deployment. Add graph nodes/rules to copy required DLLs/dylibs/shared objects and data assets, set rpath/install names, place frameworks and metallibs in app bundles, carry Vulkan layers/ICDs only when appropriate, and integrate signing/notarization hooks. Emit a machine-readable runtime dependency manifest and a human-readable `luce native explain` view.

This is required for wgpu-native, ONNX execution providers, SDL dynamic builds, CUDA companion libraries, MoltenVK, and Metal application bundles.

#### T10. Maintained binding/package catalog

Ship curated packages such as `vendor:sdl3`, `vendor:metal`, `vendor:cuda_driver`, `vendor:vulkan`, `vendor:sqlite`, and `vendor:wgpu`, each with supported upstream versions, recipes, tests, examples and CI targets. Allow project-local generation, but make common imports boring. Odin's vendor tree and Rust's mature crates show that a generator alone does not deliver ease.

#### T11. Native build explanation and lock/provenance

`luce native explain PACKAGE` should show chosen provider, exact headers/registry, generated-binding stamp, defines, tool versions, compile/link flags, runtime artifacts, asset variants, cache keys, and why a node rebuilt. Lock remote source archives and tools by checksum and surface licenses. This turns “works on my machine” native state into a debuggable graph.

### Native dependency recipe model

A recipe should be declarative and target-selectable, not an unrestricted project shell script by default. It needs at least:

```text
native "sdl3" {
    version = "3.x pinned range"
    providers = [system_pkg_config("sdl3"), source_archive(url, sha256)]
    headers = ["SDL3/SDL.h"]
    compile_definitions = { target-dependent ... }
    link = { libraries, frameworks, search_paths, order }
    runtime = { copied_libraries, rpaths, resources }
    bind = { recipe, committed_output, feature_set }
}

asset "gpu_shader" {
    variants = {
        macos: metal(source) -> metallib,
        windows: hlsl(source) -> dxil,
        linux: glsl(source) -> spirv
    }
    expose = embed_bytes_view
}
```

Source builds must declare their C/C++/ObjC language mode, include closure, definitions, compiler identity and generated outputs. If an upstream CMake/Meson build is used, isolate it as a hashed external node and capture its declared outputs; do not let it inject invisible global flags. Link order, weak frameworks, whole-archive behavior, and runtime search paths are first-class because native libraries depend on them.

## Prioritized implementation plan and forcing-function vertical slices

The ordering below minimizes simultaneous unknowns. Each milestone ends with a runnable, documented package rather than an isolated compiler feature.

### Phase 0 — ABI truth and generated-native substrate

**Deliver:** FIIR representations for C scalar/enum/pointer/incomplete/struct/union/fixed-array/function-pointer types; target ABI attributes from Clang; no fixed arity; generated-only native slots, arrays, loads/copies, pointer-depth and borrowed views; ABI probe harness.

**Forcing tests:** Accelerate/CBLAS `cblas_sgemm` for 14 mixed integer/`f32`/pointer arguments, plus a synthetic Clang probe suite for small integer sign/zero extension and by-value aggregate returns.

This phase should precede public packages. Otherwise every later failure can be incorrectly blamed on a wrapper or loader.

### Phase 1 — SDL3 2D as the first complete package

**Deliver:** nominal pointer handles, nullable handles, `cstr`, `out`, floats, C records, arbitrary arity, native dependency recipe, errors, synchronous/retained callbacks, and a union-accessor strategy. Ship window creation, renderer, textures, input/event polling, directory enumeration and one audio callback example.

**Primitive forcing map:**

- `SDL_Window` versus `SDL_Renderer`: nominal opaque pointer handles;
- `SDL_RenderLine`: `f32` arguments;
- `SDL_ConvertPixelsAndColorspace`: >8 arguments and pointer/count-ish raw memory;
- `SDL_Event`: union layout and safe discriminator access;
- `SDL_GetWindowSizeInPixels`: multiple out values;
- directory/audio callback: closure trampoline, userdata, lifetime/thread recipe.

This is the best first public signal because it is cross-platform, visual, and covers most ordinary C shapes without a dynamic dispatch loader.

### Phase 2 — SQLite as the ownership/error adapter slice

**Deliver:** generated ARC owner wrappers, borrowed child views, nullable returned strings, allocator-family cleanup, pointer-length blob policy, callback lifetime, and fixed adapters for sentinel/variadic corners. Ship open/prepare/bind/step/column/finalize and `exec` examples.

**Forcing function:** `sqlite3_exec` and bind APIs. They prove that recipes can turn messy C ownership and callback conventions into an idiomatic safe API rather than merely transliterate headers.

### Phase 3 — SDL_gpu as the asset-graph slice

**Deliver:** target-aware shader nodes, readonly object embedding/generated byte-view modules, dependency scanner, tool-version cache keys, and `luce doctor` checks for the selected shader path. Ship one graphics and one compute sample across the available backends.

**Forcing function:** one source shader pipeline compiled through a declared cross-platform policy (for example SPIR-V/HLSL plus SDL_shadercross) into the exact `SDL_GPUShaderCreateInfo` blob and entry point. This proves the graph without yet requiring Vulkan dispatch or ObjC methods.

### Phase 4 — Metal as the ObjC/C-aggregate/block slice

**Deliver:** `.m` generation, ObjC framework discovery/linking, protocol-object nominal handles, ownership/autorelease policies, `NSError **` result conversion, by-value C aggregates, completion block adapters, `CAMetalLayer`, metallib bundle nodes and signing-aware app packaging.

**Forcing function:** a CAMetalLayer triangle that loads an offline metallib and also has an opt-in runtime compilation path with a completion handler. It exercises `MTLClearColor`, drawable nil handling, block lifetime, and layer integration in one coherent sample.

### Phase 5 — CUDA Driver + NVRTC as the pointer-depth/buffer slice

**Deliver:** correct CUDA type taxonomy, driver errors, owners for context/module/stream/event/allocation, scoped kernel argument builder, `void **` construction, size-query/caller-buffer readback, PTX/cubin/fatbin asset nodes, and Linux/Windows toolkit/GPU doctor and CI lanes.

**Forcing function:** Driver-API vector add loaded both from embedded offline PTX and from NVRTC. Kernel parameters should include at least two `CUdeviceptr`s, an integer, and a float to prove stable typed slots and alignment. A no-GPU CI test validates packing bytes/pointers against a C oracle; a GPU runner validates execution.

### Phase 6 — ONNX Runtime as the indirect-call slice

**Deliver:** exact typed nullable `extern fnptr`, function-pointer fields in `extern struct`, safe generated dispatch table, dynamic-library bootstrap, version negotiation, lifetime coupling, and runtime DLL deployment.

**Forcing function:** `OrtGetApiBase` → `GetApi` → create/release environment, followed by a tiny CPU inference. This isolates the core indirect mechanism before registry-scale Vulkan. Use the same primitive for an optional CUDA driver loader afterward.

### Phase 7 — Vulkan direct as the registry/dispatch/chain scale test

**Deliver:** pinned `vk.xml` frontend, Clang header ABI verification, feature/extension selection, bitmask/enum generation, entry/instance/device dispatch tables, `pNext` builders, enumeration retry helpers, callbacks, SPIR-V assets, validation-layer doctor checks and MoltenVK deployment.

**Forcing function:** a direct compute sample first (fewer window-system variables), then an SDL-windowed triangle. Require one optional extension in a `pNext` chain so the sample cannot pass while chain support is fake.

### Phase 8 — C++ wrapper and async ecosystem hardening

**Deliver:** cimgui content-addressed C++ generation/build, llama.cpp backend/package recipes and model-resource deployment, wgpu-native chained structs/futures/callback modes, and generalized runtime deployment reports.

**Forcing functions:** cimgui demo for generated C++ adapter correctness; wgpu-native async device request for retained callback/future policy; llama.cpp token generation for large runtime resource paths and optional accelerators.

### Primitive-to-library decision table

Where one library must own acceptance for a new primitive, use this mapping:

| Primitive/tool | Acceptance owner | Why this owner is diagnostically clean |
|---|---|---|
| nominal opaque pointer handles | SDL3 | Window/renderer confusion is obvious; no loader noise |
| non-pointer nominal extern values | CUDA Driver | `CUdevice`, `CUdeviceptr`, and `CUstream` expose all representations |
| scalar floats and unlimited arity | Accelerate CBLAS | a stable documented C call with 14 args and known numeric oracle |
| extern structs and union access | SDL3 | `SDL_FRect` plus `SDL_Event` cover both with visible behavior |
| out/error/ownership recipes | SQLite | small deployment, dense ownership and allocator conventions |
| callback trampolines | SDL3 | both synchronous enumeration and retained/threaded audio paths |
| ObjC aggregate/block thunking | Metal | these are native API fundamentals, not wrapper accidents |
| scoped native slots and `void **` | CUDA Driver | `cuLaunchKernel` precisely specifies the required host storage |
| caller-filled memory readback | NVRTC | canonical size-query then caller buffer API |
| build-graph assets/embed | SDL_gpu | one cross-platform API consumes several target shader formats |
| indirect function calls/tables | ONNX Runtime | one bootstrap function exposes an otherwise ordinary versioned C table |
| registry generation and `pNext` | Vulkan | `vk.xml` is authoritative and chains are central |
| C++ thunk build | cimgui | upstream already defines a generated C-boundary model |
| async callback modes/deployment | wgpu-native | explicit callback modes/futures and multi-backend binaries |

## Support and CI contract

“Supported” should be a matrix, not a boolean:

| Level | Meaning | Example checks |
|---|---|---|
| Generate | pinned source/registry can regenerate deterministic bindings | FIIR/schema hash, semantic diff, ABI fixture |
| Check | Luce source using committed binding type-checks without native SDK | all host CI, including macOS for CUDA packages |
| Build | headers/tools/link libraries exist for target | SDL all desktop; Metal macOS; CUDA Linux/Windows |
| Package | runtime libraries/assets/frameworks are deployed correctly | rpath/DLL copy/app bundle/metallib/SPIR-V |
| Run | smoke test works on representative hardware/driver | NVIDIA GPU runner, Vulkan validation runner, Metal Mac |
| Conformance | ABI probes and representative semantics pass across supported versions | size/align/offset/call probes; loader/extension cases |

For CUDA, a Mac developer gets Generate/Check and can drive remote CI, but not local Build/Run. For Metal, non-Mac hosts can Check committed bindings but cannot generate from the SDK or execute. For Vulkan, CI should cover at least Linux loader/validation plus Windows and MoltenVK packaging where claimed. `luce doctor` reports the highest locally available level per package and the missing prerequisite for the next level.

## Concrete end state for a Luce project

A user should be able to write a manifest-level dependency and a small safe program:

```text
[dependencies]
sdl3 = { vendor = true, version = "locked" }
sdl_gpu = { features = ["shadercross"] }

[assets.triangle]
kind = "gpu_shader"
source = "shaders/triangle.slang"
targets = ["spirv", "dxil", "metallib"]
embed = true
```

and then import safe, nominal types such as `Window`, `Renderer`, `GpuDevice`, and `ShaderBytes` without seeing link flags, C pointer formation, backend shader filenames, or generated thunks. `luce build` resolves the native recipe and asset variant; `luce native explain` shows exactly what it chose; `luce doctor sdl3` diagnoses missing system/tool components; CI checks generated binding staleness.

Raw packages remain available under an explicit unsafe namespace for novel APIs:

```text
from vendor.sdl3.raw import SDL_Window, SDL_Renderer, SDL_Event
from vendor.cuda_driver.raw import CUdevice, CUdeviceptr, CUstream
```

Those declarations retain nominal ABI representations. Generated safe packages wrap owners, lists, results, callbacks, dispatch scopes and chain builders. No user maintains glue source; every `.c`, `.m`, `.mm`, registry expansion, dispatch table, shader blob and embedding object is a reproducible graph artifact.

## Final recommendations

1. **Approve A–H with the corrections above; remove I from the native-library critical path.** I is good syntax work, not a prerequisite.
2. **Add scoped native storage/views as the one missing primitive family.** Keep it reserved for generated unsafe bindings initially.
3. **Define `extern type` as nominal identity plus FIIR ABI representation.** Do not standardize all handles as 64-bit tokens even if the first 64-bit backend can store them in one word.
4. **Make scalar/arity work target-ABI-driven.** Clang/FIIR determines attributes and aggregate classification; an ABI probe suite gates releases.
5. **Commit to indirect calls, but schedule them after SDL/Metal and before ONNX/Vulkan.** ONNX Runtime is the isolated acceptance test; Vulkan is the scale test.
6. **Choose generated object + tiny module for asset embedding.** A language `embedFile` builtin can wait; reproducible shader/device-code transformation cannot.
7. **Add T7–T11: dispatch generation, ABI verification, deployment, maintained packages, and explain/lock provenance.** These are what convert FFI capability into project ease.
8. **Use one vertical slice per risk.** SDL3 2D first, then SQLite, SDL_gpu, Metal, CUDA/NVRTC, ONNX, Vulkan, and the C++/wgpu hardening set.

The resulting language delta remains minor: nominal ABI-represented extern values; complete ordinary C scalars/aggregates and unrestricted arity; exact typed function pointers; and a generated-only native memory substrate. Most complexity—ownership, loaders, chains, callbacks, assets, native builds, and deployment—belongs in FIIR-informed tools and maintained packages, where it can evolve without permanently enlarging Luce's safe language.
