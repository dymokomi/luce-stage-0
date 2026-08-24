# Collapsing Objective-C/C++ shims into Luce's build

**Technical research report for the Luce language design**  
**Research checked:** 2026-08-24  
**Scope:** Objective-C first; C++ and other native-language libraries as the generalization

## Decision

The owner's intuition is correct at the product boundary: using an Objective-C or C++ library should not require two user-maintained steps. The user should write Luce plus a manifest/binding recipe. The compiler toolchain should parse the native API, generate the native-speaking adapter, compile it, and cache the resulting object. The C ABI remains inside the implementation, but it disappears from the user's maintenance burden.

For Luce, build **option (b), a generated Objective-C/C++ shim compiled as a content-addressed build artifact**, first. Make the canonical pipeline:

```text
header + module map + target SDK + recipe
        -> Clang AST -> FIIR
        -> generated .m/.mm thunk -> target Clang -> cached object
        -> generated raw Luce module -> reviewed/generated safe Luce wrapper
```

This is not a compromise to apologize for. It is the architecture already specified for Luce C++, applied consistently to Objective-C. It lets Clang own the parts that are most dangerous to duplicate: target calling conventions, `objc_msgSend` selection, Objective-C ARC lowering, block ABI details, C++ construction/destruction, and native exception syntax. It also keeps all Luce backends behind one flat ABI.

Do **not** begin with direct `objc_msgSend` emission. Swift proves direct dispatch can be excellent, but Swift also embeds Clang, has a mature Objective-C runtime integration, and has spent many compiler-years on target ABIs and ARC. For a one-person language team, direct dispatch would move a large, target-specific compiler project onto the critical path without improving the first user's source experience.

Option (b) should be a permanent correctness baseline, not merely scaffolding scheduled for deletion. A later direct-dispatch path can optimize a proven, ordinary subset and fall back to the generated thunk whenever the ABI, ownership, callback, or exception case is not proven. The generated bridge is also the natural permanent answer for C++ under Luce's explicit decision not to absorb C++ inheritance, templates, exceptions, or ABI into the language.

## 1. What Clang can recover from an Objective-C header

### 1.1 The declaration graph is substantially richer than a C symbol table

Clang does not see Objective-C as decorated C. Its AST has first-class nodes and queries for interfaces, categories, protocols, methods, properties, selectors, and type parameters. In particular:

| Header construct | Machine-readable information available to an importer | Luce consequence |
|---|---|---|
| `@interface` | class name, superclass, adopted protocols, forward/complete declaration, methods, properties, categories, type parameters, availability/source location | generate a foreign class identity and composition-shaped safe wrapper; do not import inheritance as Luce inheritance |
| `@protocol` | inherited protocols; required and optional instance/class methods and properties | generate a protocol capability surface and runtime `respondsToSelector:` checks for optional requirements |
| `@interface Class (Category)` | owning class, category name, methods/properties/protocol adoption | merge declared members into the imported view while retaining category provenance and link requirements |
| method | instance versus class method, full typed signature, variadic bit, selector, method family, attributes, availability | generate a uniquely keyed thunk and a stable Luce name; reject or wrap variadics |
| selector | every selector piece and colon count, not just a linker symbol | preserve exact dispatch identity even while presenting an idiomatic Luce name |
| property | type; readonly/readwrite; custom getter/setter; assign/copy/retain/strong/weak/unsafe-unretained; atomic/nonatomic; class-property and nullability flags | synthesize getter/setter calls and report storage semantics; do not misrepresent `atomic` as a general concurrency guarantee |
| lightweight generic parameter | parameter name, variance, bound, protocol-qualified bounds, and type arguments at use sites | preserve static element/key/value information in FIIR while remembering that Objective-C generics are erased at runtime |
| designated initializer | explicit Clang attribute and AST queries for designated-initializer status/inheritance | distinguish preferred construction paths and diagnose incomplete subclass/adaptor construction |

The relevant Clang APIs are visible in its public AST documentation: [`ObjCInterfaceDecl`](https://clang.llvm.org/doxygen/classclang_1_1ObjCInterfaceDecl.html), [`ObjCMethodDecl`](https://clang.llvm.org/doxygen/classclang_1_1ObjCMethodDecl.html), [`ObjCPropertyDecl`](https://clang.llvm.org/doxygen/classclang_1_1ObjCPropertyDecl.html), [`ObjCCategoryDecl`](https://clang.llvm.org/doxygen/classclang_1_1ObjCCategoryDecl.html), and [`ObjCTypeParamDecl`](https://clang.llvm.org/doxygen/classclang_1_1ObjCTypeParamDecl.html). Apple separately documents that protocols contain class methods, instance methods, and properties, and divide requirements into required and optional members ([Working with Protocols](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ProgrammingWithObjectiveC/WorkingwithProtocols/WorkingwithProtocols.html)).

For implementation, Luce should use a version-pinned Clang AST/LibTooling service, not treat the stable-but-narrow libclang cursor API as the definition of FIIR. FIIR should serialize normalized facts plus source provenance so the rest of Luce never depends directly on Clang C++ classes.

### 1.2 Nullability is type information, including nested pointer levels

Clang's `_Nullable`, `_Nonnull`, and `_Null_unspecified` are type qualifiers rather than comments. They can distinguish, for example, a nullable pointer to non-null pointers. Objective-C also has the contextual spellings `nullable` and `nonnull` for methods and properties. Clang documents both the nesting behavior and the Objective-C spellings in its [nullability attribute reference](https://clang.llvm.org/docs/AttributeReference.html#nullability-attributes).

`NS_ASSUME_NONNULL_BEGIN`/ `NS_ASSUME_NONNULL_END` establish an audited region in which ordinary pointer declarations default to non-null, with explicit nullable exceptions; Apple describes their role in [Designating Nullability in Objective-C APIs](https://developer.apple.com/documentation/swift/designating-nullability-in-objective-c-apis). The importer must consume the *post-preprocessing Clang type*, not search the source text for the macro.

Recommended Luce mapping:

- explicit/audited non-null object pointer -> non-optional wrapper;
- nullable -> `T?`;
- null-unspecified or completely unannotated -> unsafe raw unknown plus `T?` in a conservative generated wrapper, or a recipe requirement before calling the wrapper Tier A;
- nested pointer nullability -> preserve every level in FIIR, even if the first safe wrapper copies the data and hides those pointers.

Do not copy Swift's historical implicitly-unwrapped-optional compromise. Luce has a cleaner choice: be conservative and make missing facts visible.

### 1.3 ARC ownership conventions are executable compiler metadata

Modern Objective-C headers communicate far more ownership than “returns a pointer”:

- Methods in the `alloc`, `copy`, `mutableCopy`, and `new` families return at +1. Other ordinary object-returning methods return at +0.
- `init`-family methods consume `self` and return at +1. They may return a different object or `nil`, so a wrapper must not publish the pre-init receiver.
- Family membership follows a precise selector rule: the first selector component begins with the family name and the next character is not lowercase; explicit method-family attributes can override inference.
- `NS_RETURNS_RETAINED`, `NS_RETURNS_NOT_RETAINED`, and related macros lower to attributes such as `ns_returns_retained` and override conventions.
- `ns_consumed` on a parameter transfers a +1 to the callee; `ns_consumes_self` does the analogous job for the receiver.
- Property `strong`, `retain`, `copy`, `weak`, and `unsafe_unretained` attributes describe setter/backing-storage behavior. They are useful, but they must not be confused with a getter's return convention.

These are normative ARC rules, not Swift heuristics. The [Clang ARC specification](https://clang.llvm.org/docs/AutomaticReferenceCounting.html) defines the method families, +0/+1 semantics, consumed parameters, bridging casts, runtime entry points, autorelease handoff, blocks, and exception behavior. Clang's [ownership attribute reference](https://clang.llvm.org/docs/AttributeReference.html#cf-consumed-cf-returns-not-retained-cf-returns-retained-ns-consumed-ns-consumes-self-ns-returns-autoreleased-ns-returns-not-retained-ns-returns-retained-os-consumed-os-consumes-this-os-returns-not-retained-os-returns-retained-os-returns-retained-on-non-zero-os-returns-retained-on-zero) says these attributes affect ARC code generation as well as static analysis.

That is enough for an importer to classify most framework object results as **adopt +1** or **retain borrowed +0** without a per-method handwritten recipe. Ambiguous third-party declarations still require a recipe; an importer must never “repair” an incorrect native header by guessing.

### 1.4 Blocks are typed foreign closures, not opaque pointers

Clang sees a block's argument types, result type, qualifiers, and nested nullability. Its [Blocks language specification](https://clang.llvm.org/docs/BlockLanguageSpec.html) defines capture and copy behavior. The [Apple block ABI specification](https://clang.llvm.org/docs/Block-ABI-Apple.html) describes the literal's invoke pointer, descriptor, flags, and generated copy/dispose helpers. Under Objective-C, blocks are Objective-C objects and escaping a stack block requires copy/retain behavior.

This metadata makes API-shape import straightforward:

- a nonescaping synchronous block can map to a scoped Luce callback;
- an escaping block needs a generated heap context, copy/dispose hooks, and a lifetime token;
- a block accepted on an arbitrary foreign thread needs a runtime-entry policy, not merely a function-pointer cast;
- a completion-handler convention may support a higher-level async wrapper later, but only when its exactly-once/thread/error contract is known.

The typed header answers “what is called.” It does not answer “how long retained, how often, on which thread” unless the API's attributes or an external recipe say so.

### 1.5 `NSError **` is recognizable, but failure is a convention, not a type theorem

The common Cocoa pattern is a final, non-block `NSError **` parameter plus a result that signals success. Swift removes that parameter and imports the method as throwing. Clang's `swift_error` attribute makes the dynamic convention explicit: null result, zero result, nonzero result, or non-null error; the [Clang attribute documentation](https://clang.llvm.org/docs/AttributeReference.html#swift-error) spells out each case. Apple's [About Imported Cocoa Error Parameters](https://developer.apple.com/documentation/swift/about-imported-cocoa-error-parameters) explains the default Objective-C pattern.

Important qualification: writing a non-null error object is not by itself a universal failure predicate, and not every `NSError **` API follows the canonical form. The importer should:

1. honor an explicit `swift_error`/API note;
2. recognize Swift-compatible Cocoa defaults for eligible methods;
3. require a recipe for noncanonical APIs;
4. keep Objective-C exceptions completely separate from recoverable errors.

The generated thunk should pass an `__autoreleasing NSError *` out slot, check the documented result condition, promote the error object to a +1 Luce-owned handle before any pool pop, and return a flat status/result record. The safe wrapper maps that record to Luce `T!`.

### 1.6 Designated initializers and lightweight generics improve API shape, not runtime certainty

Clang recognizes `objc_designated_initializer` ([attribute entry](https://clang.llvm.org/docs/AttributeReference.html#objc-designated-initializer)), and its Objective-C AST can query whether a method is a designated initializer and whether designated initializers are inherited. Luce can use this to prefer safe constructor surfaces and to warn when an adapter exposes an incomplete initialization path. It should still preserve convenience initializers as named factories where useful.

Apple's [lightweight generics import documentation](https://developer.apple.com/documentation/swift/using-imported-lightweight-generics-in-swift) shows that collection element types survive import. This is valuable metadata, but the runtime object remains an erased Objective-C object and hostile/dynamic producers can violate the static promise. FIIR should therefore record both the parameterized source type and its erased ABI representation.

### 1.7 Verdict on the hypothesis: confirmed, with a boundary

**For a modern, audited Cocoa-style header, the hypothesis is correct.** Relative to a typical plain C header, an Objective-C header normally carries more machine-readable information relevant to a safe wrapper: object identity, class/protocol graph, exact selectors, method versus class dispatch, property storage semantics, nullability, standardized +0/+1 naming rules, consumed parameters, designated initializers, typed blocks, lightweight generics, and a widely recognized error convention.

This can make *safe API-shape and ownership inference* easier than for C. A typical C declaration such as `void *make(void *)` says almost nothing about allocation, aliasing, validity, nullability, error signaling, mutation, or lifetime. Luce's existing design is right to require recipes for those facts.

Two qualifications prevent overclaiming:

1. C can use Clang nullability, ownership attributes, typed structs, API Notes, and project conventions too. The difference is ecosystem density and standardization, not a metaphysical limit of C syntax. Clang's [API Notes](https://clang.llvm.org/docs/APINotes.html) are specifically designed to add importer metadata without editing a header and are an excellent model for Luce recipes.
2. Objective-C's *runtime boundary* is harder than C: dynamic dispatch, autorelease, blocks, arbitrary callback threads, exceptions, categories, method swizzling, and KVO remain. Rich declarations make the wrapper's intended contract clearer; they do not make the runtime static.

So the precise conclusion is: **Objective-C is often easier than C to infer, but harder than C to execute correctly.** That combination strongly favors a Clang-generated native bridge.

## 2. How Swift makes Objective-C look shimless

Swift is the existence proof for the desired user experience, but its mechanism matters. It does not secretly write a normal C wrapper around every Objective-C method.

### 2.1 End-to-end path

1. A Clang module map names an umbrella/header set, exports, framework linkage, and submodules. Clang's [Modules documentation](https://clang.llvm.org/docs/Modules.html) describes module maps and the precompiled-module cache.
2. Swift's embedded Clang parses the target SDK and configured headers as C/Objective-C. Swift's compiler source organization identifies `lib/ClangImporter` as the component that imports Clang modules and maps C-family APIs ([Swift compiler documentation](https://www.swift.org/documentation/swift-compiler/)); Swift's [Modules design document](https://github.com/swiftlang/swift/blob/main/docs/Modules.md) describes imported Clang modules.
3. The Clang Importer maps declarations into Swift types and names: nullability to optionality, methods/properties, Objective-C generics, Foundation bridges, `NSError **` conventions, blocks, and availability. API Notes and importer-specific attributes can refine the mapping.
4. Swift type-checks the call as an ordinary Swift expression, but retains the Clang declaration and foreign ABI information.
5. Swift IR generation emits the appropriate Objective-C message-send operation and exact target ABI signature. Swift's own [Objective-C interop implementation notes](https://github.com/swiftlang/swift/blob/main/docs/ObjCInterop.md) state that it emits `objc_msgSend` variants in the same manner as an Objective-C compiler.
6. Swift ARC inserts the Objective-C retains/releases and autorelease-return-value handshakes required by the imported +0/+1 convention. The linker supplies the framework and Objective-C runtime.

This is direct ABI-aware compiler integration. “No handwritten shim” is true; “there is only a C ABI underneath” is not. The Objective-C runtime message ABI is underneath.

### 2.2 Why the exact `objc_msgSend` type matters

`objc_msgSend` is a family of runtime entry points whose effective function type is the selected method's type. A caller must cast it to the exact prototype before calling. Apple's [function-pointer guidance](https://developer.apple.com/documentation/uikit/managing-functions-and-function-pointers?language=objc) warns that mismatched calling conventions produce incorrect behavior.

Apple arm64 makes the danger especially concrete: a call made through a variadic declaration uses the variadic argument convention, which places affected arguments differently from a fixed-parameter method. Apple's [Apple-silicon ABI guidance](https://developer.apple.com/documentation/Apple-Silicon/addressing-architectural-differences-in-your-macos-code) calls out this fixed-versus-variadic distinction. “Declare `objc_msgSend` variadic and pass values” is therefore not a portable shortcut. Struct returns, floating-point returns on older targets, super sends, stret/fpret variants where applicable, and target-specific aggregate classification all belong to the target ABI.

Swift can emit this correctly because Clang and Swift IRGen agree on the complete method type and target ABI. A generated `.m` bridge gets the same correctness from Clang for free.

### 2.3 ARC: +0/+1 enters Swift's ownership model

An imported Objective-C reference is a managed Swift reference. The imported method family/attributes tell Swift whether a result arrives at +0 or +1 and whether an argument is consumed. Swift ARC then emits Objective-C runtime ownership operations or optimized equivalents. The two essential return cases are:

- **+1 result:** the caller already owns it; adopt that ownership and release when the Swift reference dies.
- **+0 result:** it is only borrowed/autoreleased; retain it if the Swift value must survive.

The `__bridge` family belongs to Objective-C ARC's boundary between retainable Objective-C pointers and unmanaged representations such as `void *`/Core Foundation:

- `__bridge`: reinterpret with no transfer;
- `__bridge_retained`: produce an unmanaged pointer carrying a new +1 that its recipient must release;
- `__bridge_transfer`: consume an unmanaged +1 into ARC ownership.

Those semantics are defined by the [Clang ARC specification](https://clang.llvm.org/docs/AutomaticReferenceCounting.html#conversion-of-retainable-object-pointers). A normal Swift-to-Objective-C method call does not ask the programmer to spell these casts; the importer and ARC lowering already know both sides. They become directly relevant to Luce option (b), because a generated C thunk must turn an ARC-managed `id` into an opaque C handle with an explicit +1 contract.

### 2.4 Errors and blocks

For an eligible final `NSError **` parameter, Swift removes the parameter and imports the operation as `throws`; the Boolean/null result used solely for failure indication is correspondingly removed or strengthened. Apple's [Cocoa error import documentation](https://developer.apple.com/documentation/swift/handling-cocoa-errors-in-swift) demonstrates this mapping, and Swift Evolution's [NSError bridging proposal](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0112-nserror-bridging.md) records the model.

Objective-C exceptions are not this mechanism. Apple explicitly says there is no safe Swift recovery path and that Objective-C code must catch an exception before it reaches Swift ([Handling Cocoa Errors in Swift](https://developer.apple.com/documentation/swift/handling-cocoa-errors-in-swift)).

Objective-C block types import as closures. Swift has an explicit `@convention(block)` representation for an Objective-C-compatible block ([Swift attributes reference](https://developer.apple.com/library/content/documentation/Swift/Conceptual/Swift_Programming_Language/Attributes.html)), and its compiler/runtime emits the native block object plus capture copy/dispose behavior. Higher-level import rules can additionally turn completion-handler methods into async Swift functions ([Calling Objective-C APIs Asynchronously](https://developer.apple.com/documentation/Swift/calling-objective-c-apis-asynchronously)), but that transformation depends on conventions and annotations beyond the raw block signature.

### 2.5 What Swift does not import or promise

Swift's importer is deliberately selective. Its [C API import design notes](https://github.com/swiftlang/swift/blob/main/docs/HowSwiftImportsCAPIs.md) document representative boundaries:

- arbitrary function-like macros do not become Swift functions;
- C ellipsis variadics are not normally imported as safe ordinary calls;
- incomplete/opaque types remain opaque;
- declarations that cannot be represented are unavailable or require an adapter;
- absent nullability historically imports as an unsafe/implicitly-unwrapped form rather than becoming magically known;
- Objective-C exceptions never become Swift `Error`.

Dynamic dispatch also remains dynamic. Imported type information says what a conforming implementation should accept and return; it does not prove that runtime swizzling, a category collision, KVO subclassing, or an optional protocol member will behave statically.

### 2.6 Swift C++ interop: an instructive but different line

Modern Swift C++ interop again uses embedded Clang and module maps, but forward calls are generally **direct C++ ABI calls**, not generated flat-C shims. Swift's [C++ interoperability overview](https://www.swift.org/documentation/cxx-interop/) says Swift directly calls C++ functions/constructors and stores imported C++ objects without an extra wrapper or indirection. Reverse interop generates a C++ header whose inline C++ surface calls Swift ABI entry points.

That choice commits Swift to understanding the selected C++ ABI, object layout, calling conventions, value semantics, and standard library compatibility. Its official [supported-features and constraints page](https://www.swift.org/documentation/cxx-interop/status/) is a useful boundary map:

- much ordinary non-template API, constructors, members, selected standard-library types, and some template specializations work;
- class-template use is limited to concrete specializations that Clang exposes; several dependent, universal/rvalue-reference, non-type, and variadic-template cases remain limited;
- C++ inheritance relationships are not modeled as Swift inheritance; imported members can be flattened;
- Swift cannot catch a C++ exception; an uncaught exception reaching Swift causes fatal termination;
- enabling C++ mode and standard-library choices can affect the dependency graph;
- apparently simple iteration/copying can have non-obvious performance behavior.

Swift is therefore an existence proof for *both* good importer UX and the high ongoing cost of direct C++ ABI ownership. Luce's stated semantic line—no C++ inheritance, templates, exceptions, RTTI, or overload machinery leaking into Luce—fits flat generated thunks much better.

## 3. The three architectures, priced honestly

The estimates below are order-of-magnitude engineering costs for one experienced compiler/runtime engineer, after a minimally capable target-correct C ABI caller, linker driver, and serializable FIIR exist. If those prerequisites do not yet exist, add roughly two to four months of foundation and ABI-probe work. “Production” means diagnostics, deterministic caching, SDK/version tests, sanitizer coverage, callbacks, ownership checks, and a supported failure policy—not just one Foundation demo.

| Option | Credible prototype | Production-quality first Apple target | Per-library work | Debuggability | Cross-compilation |
|---|---:|---:|---:|---|---|
| **(a) Direct Objective-C dispatch** | 2–4 months | 12–24+ person-months; more for every independent backend/target family | low for ordinary declarations; recipes/wrappers remain | initially poor: ABI errors are crashes in generated code; later excellent only with custom IR/debug tooling | no native compiler at final build, but Luce must implement every target ABI; target SDK/runtime still required |
| **(b) Generated `.m`/`.mm` cache artifact** | 6–12 weeks | 6–12 person-months including hard edges; C++ adds another substantial tranche | usually manifest + ambiguity recipes + Luce wrapper; regenerated on header changes | good if glue can be emitted and diagnostics remapped; Clang/sanitizers remain available | requires a target-capable Clang, SDK/sysroot, standard library, and target libraries; object/cache is target-specific |
| **(c) Handwritten native shim** | days to expose one API | almost no central solution ever becomes “production” | 2 days to many weeks per library, repeated after header/ABI changes | locally understandable, globally inconsistent; ownership bugs live in bespoke code | same target toolchain requirement as (b), but every project must reproduce flags and build logic |

These ranges are deliberately wider than a feature estimate. Blocks, arbitrary-thread callbacks, exception containment, SDK availability, fat binaries, ObjC++ mixtures, and library quirks dominate hardening.

### 3.1 Option (a): direct dispatch

The Luce compiler would lower an imported method to a call through the correct Objective-C runtime entry point. At minimum it must own:

- class/selector references and runtime lookup;
- instance, class, and super dispatch;
- exact per-call prototype formation and target aggregate classification;
- all required `objc_msgSend` variants;
- +0/+1 ownership and consumed-argument lowering;
- autorelease-return-value handshake correctness and optimization;
- weak-reference operations if exposed;
- autorelease-pool entry/exit on Luce and callback threads;
- native block literal layout, capture descriptors, copy/dispose functions, and ARC interaction;
- Objective-C exception personalities/unwind containment;
- debug locations and diagnostics that point back to the imported declaration;
- equivalent behavior in every Luce backend, or a shared native-call lowering layer.

The catastrophic failure mode is not a friendly linker error. It is a successful build whose arguments are in the wrong registers, whose aggregate result is read with the wrong convention, or whose +0 object dies after a pool pop. Such failures are target-, optimization-, and signature-dependent.

Direct dispatch's real advantages are no native source compilation during an incremental build, better whole-program optimization potential, and a single debugger step from Luce into the framework. Those become valuable after the semantics are mature. They are weak reasons to put a new ABI implementation before a usable foreign interface.

### 3.2 Option (b): generated native thunk as an object-file-like artifact

For Objective-C, the importer emits `.m`; for C++ or mixed Objective-C++, it emits `.mm`. The platform compiler receives the same target triple, sysroot, module map, defines, language mode, ARC mode, deployment target, and framework/library search paths used for parsing. It produces a target object exposing deterministic flat C symbols. Luce calls those symbols through the ordinary C ABI.

A representative generated ownership bridge is only conceptually this:

```objective-c
void *luce_NSURL_fileURLWithPath(void *path) {
    @autoreleasepool {
        return (__bridge_retained void *)[NSURL fileURLWithPath:(__bridge NSString *)path];
    }
}
```

The important property is not the spelling. Clang selects the correct message ABI and ARC operations, while the bridge promises Luce that the returned opaque handle is exactly +1. Real generated code must also carry null/error/exception status, target availability, and source mapping.

The source and object belong under a content-addressed cache keyed by:

- complete header and transitive include content;
- module map/API Notes;
- all defines and compiler flags;
- target triple, CPU/features, deployment target, language and ARC modes;
- SDK/sysroot identity and framework/library identity;
- Clang version/resource directory and C++ standard library/ABI;
- FIIR schema, generator, recipe, and safe-wrapper versions.

This is already almost exactly the cache key required by Luce §21.15. The generator should never silently reuse a host-parsed AST for a different target.

“Hidden” must mean **not source-controlled or hand-maintained**, not impossible to inspect. Required tools:

- `luce bind --explain`: declaration, inferred ownership/nullability/error rule, support tier, native symbol, source provenance;
- `luce bind --emit-glue DIR` or `--keep-glue`: deterministic native source, compile command, module cache path, and ABI report;
- remapped Clang diagnostics referring first to the original header/recipe and secondarily to generated lines;
- a reproducible command to rebuild one thunk with sanitizers and without optimization;
- generated debug info and a symbol map from Luce wrapper to thunk to selector.

The main failure modes are stale or incomplete cache keys, parse/compile flag drift, dead stripping, missing framework/category linkage, incorrect recipe facts, and poor generated diagnostics. These are serious but testable build-system failures rather than a new handwritten target ABI.

### 3.3 Option (c): handwritten shims

Handwritten C/Objective-C/C++ adapters remain useful as Tier C escape hatches for undocumented ownership, exotic macros/templates, runtime-generated APIs, or a library whose source contract is wrong. They are not a reasonable default workflow.

The central cost is multiplication: every application team independently chooses naming, error encoding, pool policy, exception policy, ownership transfer, callback lifetime, visibility, linker flags, and regeneration strategy. Header changes do not automatically invalidate or audit the shim. The apparent low compiler cost merely transfers integration and memory-safety work to every library forever.

### 3.4 Recommendation among the three

Build (b). Preserve (c) as an explicitly audited escape hatch. Treat (a) as a future profile-guided or supported-subset optimization whose observable contract is identical to (b).

Option (b) is simultaneously:

- the shortest path to the owner's desired “write Luce + manifest” UX;
- the best fit for Luce's backend-independent FIIR;
- the least risky way to obey Apple arm64 and other target ABIs;
- the permanent C++ architecture implied by Luce's flat-ABI design;
- a differential oracle and fallback if direct Objective-C dispatch is later implemented.

No requirement says a language implementation must eliminate native source internally to count as seamless interop. A build system already generates IR, object files, link maps, metadata, and headers. Generated `.m` is another reproducible intermediate.

## 4. Precedent: generated native glue hidden in, or owned by, the build

There is abundant precedent for collapsing “write adapter, then bind adapter” into one command. The systems differ in whether the intermediate is a direct ABI call, generated native source, generated language declarations, or all three. The durable pattern is: **the user owns a declarative interface/manifest; the tool owns generated code and compilation.**

### 4.1 Rust `cxx`

`cxx` asks the user to declare a deliberately constrained bridge in a Rust `#[cxx::bridge]` module. The macro/code generator checks both sides, emits Rust and C++ pieces, and uses static assertions to keep layouts/signatures synchronized. In Cargo, [`cxx-build`](https://cxx.rs/build/cargo.html) runs the bridge generator and returns a `cc::Build` that compiles the C++ as part of the package build. Generated headers/sources are normally under Cargo's output tree; [the tutorial](https://cxx.rs/tutorial.html) explains how to inspect the `target/cxxbridge` paths, but users do not maintain those files.

What users pay for:

- signatures often appear in the bridge declaration even though they also exist in C++, because the restriction is part of the safety model;
- unsupported C++ shapes need a handwritten C++ facade;
- non-Cargo build integration has to coordinate the generator executable, include paths, output layout, and exact crate/tool versions—pain captured in [cxx issue #462](https://github.com/dtolnay/cxx/issues/462);
- a safe narrow vocabulary is intentionally less “automatic” than a whole-header translator.

Lesson for Luce: a generated native bridge can be safe, normal, and invisible in source control, but its supported subset and version coupling must be explicit.

### 4.2 Rust `autocxx`

`autocxx` layers whole-header discovery over `bindgen`, `cxx`, and native C++ generation. Its [build documentation](https://google.github.io/autocxx/building.html) shows that it generates Rust, C++, and header artifacts and compiles the C++ through `cc`; critically, parser flags and compiler flags must agree. The [workflow documentation](https://google.github.io/autocxx/workflow.html) is candid that C++ is too complex to ingest completely: unsupported declarations become placeholders or require an extra C++ wrapper/manual `cxx` bridge. Its [reference/lifetime notes](https://google.github.io/autocxx/references_etc.html) show why ambiguous C++ references cannot simply be made safe.

Generated code is normally build output but can be emitted for IDEs and debugging. Documented/user-visible friction includes:

- opaque failures inherited from several layers (preprocessing, bindgen, autocxx, cxx, `cc`, linker);
- duplicate configuration between parsing and compilation;
- pinning and lifetime ergonomics for C++ references;
- manual wrappers when templates, special members, or parser bugs defeat automation;
- project maintenance risk—the [repository](https://github.com/google/autocxx) has explicitly sought maintainers and points users toward alternatives for some cases.

Lesson for Luce: one FIIR diagnostic surface must own errors from all pipeline stages; “we generated it” is not a sufficient debugging story.

### 4.3 Swift C++ interop

Swift C++ interop is primarily a counterexample to the premise that all seamless interop uses a C shim. The forward direction uses Clang types plus direct C++ ABI-aware code generation; the user sees no generated forward wrapper. The reverse direction emits a generated C++ header/facade. Swift's [overview](https://www.swift.org/documentation/cxx-interop/) and [status page](https://www.swift.org/documentation/cxx-interop/status/) make both the capability and the boundary visible.

The official constraints correspond closely to user complaints:

- enabling C++ interop can affect dependencies and standard-library/toolchain compatibility;
- unsupported templates, reference categories, and standard-library types require adapters;
- C++ inheritance does not map naturally;
- an uncaught C++ exception is fatal rather than a Swift `throw`;
- value semantics can trigger surprising copies.

Lesson for Luce: direct ABI integration buys elegant calls by accepting a permanent, evolving compiler commitment. It is evidence that the UX is possible, not evidence that a small compiler should choose the same internals.

### 4.4 Kotlin/Native `cinterop` and Objective-C

Kotlin/Native uses a `.def` file to name headers/modules and specify compiler/linker options. The `cinterop` tool parses the target native API and packages generated declarations/metadata into a target-specific `.klib`; application source imports that library. The [definition-file documentation](https://kotlinlang.org/docs/native-definition-file.html) describes headers, modules, `language = Objective-C`, compiler/linker flags, static libraries, and even an escape hatch for custom inline C after `---`. Users normally own the `.def`, not the generated stubs.

Its [Objective-C interop documentation](https://kotlinlang.org/docs/native-objc-interop.html) covers classes, protocols, methods, properties, and blocks. Pure Swift API is not generally importable unless it is exposed to Objective-C. Its [interop stability page](https://kotlinlang.org/docs/native-lib-import-stability.html) labels C/Objective-C library import Beta and describes compiler/Xcode/library compatibility constraints.

The most valuable warning for Luce is ownership. Kotlin/Native connects a tracing garbage collector to Objective-C ARC, whereas Luce will connect ARC to ARC. Kotlin's [ARC integration documentation](https://kotlinlang.org/docs/native-arc-integration.html) documents delayed deinitialization, special GC-thread autorelease-pool behavior, and retain cycles spanning the two runtimes. Different collection technology changes timing, but the cross-runtime cycle and thread-entry problems are the same.

Documented friction includes target-specific regeneration, opt-in foreign APIs, Xcode/SDK compatibility, generic/type-mapping limitations, pure-Swift invisibility, default fatal behavior for foreign exceptions unless specially configured, and lifetime surprises at the GC/ARC boundary.

Lesson for Luce: a small manifest can own a large importer pipeline, but generated bindings remain target artifacts and runtime ownership needs an explicit model.

### 4.5 Dart FFI, `ffigen`, and `objective_c`

Dart's base FFI is a C ABI. `ffigen` uses libclang to generate Dart bindings from C and Objective-C headers, while the `objective_c` support package supplies runtime machinery. Dart's official [Objective-C interop guide](https://dart.dev/interop/objective-c-interop) describes object wrappers, retain/release behavior, blocks, protocols, and Swift's need for an Objective-C-visible facade. The [ffigen package documentation](https://pub.dev/packages/ffigen) exposes separate Dart output and Objective-C binding output.

This is one of the closest precedents to Luce option (b). Ordinary message paths use generated Dart/runtime bindings; APIs involving blocks or implementable protocols can cause `ffigen` to emit Objective-C `.m` support that must be compiled and linked. The user generally sees the generated Dart file and may see the `.m`; they regenerate rather than hand-maintain it. Luce can make the native file a stricter cache artifact while retaining an “emit for inspection” command.

The issue history is an unusually useful map of hard edges:

- [native issue #835](https://github.com/dart-lang/native/issues/835) concerns a block argument's object lifetime around a callback;
- [issue #1475](https://github.com/dart-lang/native/issues/1475) shows generated native helper symbols being dead-stripped and failing at runtime;
- [issue #1421](https://github.com/dart-lang/native/issues/1421) records generated trampoline/ARC compatibility trouble;
- [issue #2964](https://github.com/dart-lang/native/issues/2964) reports block-helper code-size growth;
- the [ffigen changelog](https://pub.dev/packages/ffigen/versions/17.0.0/changelog) records fixes involving Objective-C method-family ownership, blocks, struct returns, and arm64 message dispatch.

Lesson for Luce: generated glue is proven, but blocks, ownership families, arm64 ABI selection, linker retention, and cache/versioning need first-class tests—not post-MVP cleanup.

### 4.6 .NET/Xamarin binding projects and `ObjectiveCMarshal`

.NET's Apple bindings are generated from a maintained C# binding description such as `ApiDefinition.cs` plus native references. The [.NET iOS binding migration guide](https://learn.microsoft.com/en-us/dotnet/maui/migration/ios-binding-projects?view=net-maui-10.0) describes that project shape. Objective Sharpie can parse Objective-C and generate an initial API definition, but Microsoft's [API-definition guidance](https://learn.microsoft.com/en-us/dotnet/maui/ios/objective-sharpie/platform/api-definition-structs-enums?view=net-maui-10.0) explicitly expects developers to inspect and repair `[Verify]` annotations and inferred method/property shapes.

The binding DSL is rich because the problem is rich: selectors, base/protocol information, nullability, ownership semantics, delegates/events, and marshaling attributes. The [macios binding-types reference](https://github.com/dotnet/macios/blob/main/docs/website/binding_types_reference_guide.md) shows that generated registrars/trampolines still need precise ownership and signature metadata. `System.Runtime.InteropServices.ObjectiveC.ObjectiveCMarshal` is low-level runtime infrastructure for Objective-C tracking, initialization callbacks, and exception propagation—not a header importer ([API reference](https://learn.microsoft.com/en-us/dotnet/api/system.runtime.interopservices.objectivec.objectivecmarshal)).

What users pay for:

- parser-generated definitions are a starting point, not a finished safe binding;
- selector/name conflicts and ownership semantics need curation;
- registrar/trampoline/native-link failures can surface far from the declaration;
- SDK evolution creates binding lag;
- pure Swift libraries without Objective-C exposure still require an author-provided facade, as illustrated by [macios issue #21549](https://github.com/dotnet/macios/issues/21549).

Lesson for Luce: the coherent user-authored object is a declarative binding description plus safe Luce wrapper—not generated imperative C# or native glue. Automatic inference needs a visible confidence/support tier.

### 4.7 Go `cgo`

`cgo` is the literal precedent for generated C hidden in a normal language build. The Go command scans special imports/preambles, generates Go declarations plus several C files and headers, invokes the host/target C compiler, and links the objects. The official [cgo implementation documentation](https://go.dev/src/cmd/cgo/doc.go) names artifacts such as `x.cgo2.c`, `_cgo_export.c`, and `_cgo_export.h`; the [Go cgo article](https://go.dev/blog/cgo) explains the source-to-generated-Go/C pipeline. These files normally live in temporary work directories, and Go build tooling can preserve its work directory for inspection.

The familiar friction is also relevant:

- a C compiler and correct target sysroot are part of the build;
- cross-compilation requires an appropriate target compiler and configuration; the [cgo command documentation](https://go.dev/cmd/cgo/) describes `CC_FOR_TARGET`/target compiler requirements;
- strict pointer-passing rules constrain callbacks and retained pointers;
- C layouts that Go cannot express may require generated accessors;
- errors can emerge from preprocessing, compilation, external linking, or runtime ABI mismatch;
- target configuration can still produce builds that fail only on-device, as reports such as [Go issue #73406](https://github.com/golang/go/issues/73406) illustrate.

Lesson for Luce: users accept a native compiler inside a one-command build when the toolchain owns it, reports it, and makes cross-target requirements explicit.

### 4.8 Synthesis of the precedents

No successful system makes the native language disappear by wishing away its semantics. They choose among:

- **direct ABI ownership** (Swift C++ and much of Swift Objective-C);
- **generated compiled native glue** (`cxx`, `autocxx`, cgo, Dart block/protocol support);
- **generated metadata/stubs plus runtime integration** (Kotlin/Native, .NET, Dart);
- **a declarative/manual adapter escape hatch** (all of them).

The user need not maintain a shim. The *toolchain* must still maintain a language-specific bridge backend, precise target configuration, cache invalidation, diagnostics, and runtime ownership rules.

## 5. Can the shim itself be written in Luce?

### 5.1 `export c` solves the opposite direction

Luce's `export c` gives C a stable entry point implemented by Luce. It answers:

> “How can foreign code call a Luce function/value through a C-compatible surface?”

The desired forward bridge asks:

> “How can Luce perform an Objective-C message send or C++ operation that is not a C operation?”

An exported Luce function can wrap a call only if Luce already has some primitive capable of making that call. Today it does not speak Objective-C selectors, block literals, `@try/@catch`, C++ constructors/destructors, overload resolution, templates, or C++ exceptions. Rewriting:

```text
Luce -> exported-C Luce function -> ??? -> Objective-C/C++
```

does not fill in `???`. If `???` becomes a set of Luce compiler intrinsics implementing native dispatch, block ABI, ARC, and exception handling, that is option (a) under a different spelling. It is not a shortcut.

Thus “write the imperative native shim itself in ordinary Luce” is a category error **at the current language boundary**. It also conflicts with the good existing rule that `export c` accepts a closed representation subset and never leaks Luce ARC/classes/collections through C.

### 5.2 The coherent version is a Luce-authored binding description

There is, however, a strong version of the idea: let the user write a small **declarative native binding description**, embedded in the manifest or in a Luce-adjacent declaration file. It describes intent; the toolchain generates whichever native language is required.

A deliberately small illustration:

```toml
[native.foundation]
language = "objective-c"
module = "Foundation"
frameworks = ["Foundation"]
expose = ["NSURL", "NSFileManager"]
```

Additional recipe entries can say:

- expose/rename/omit this declaration;
- treat this ownership/nullability fact as audited;
- map this eligible `NSError **` result to `T!`;
- copy or retain this borrowed value;
- callback is synchronous, escaping, reentrant, main-thread-only, or arbitrary-thread;
- exception policy is fatal or one explicitly approved translation;
- instantiate this exact C++ template and expose it behind this Luce name;
- use this handwritten Tier C native adapter.

That description must be declarative rather than an alternate imperative foreign language:

- it is target-independent until Clang resolves the declaration;
- the compiler can validate it against the AST and report stale selector/type matches;
- changes participate in the content cache key and API diff;
- documentation can show which facts came from the header, Clang convention, API Notes, recipe, or generator default;
- the same intent can generate `.m`, `.mm`, C declarations, Luce raw declarations, safe wrappers, tests, and ABI reports.

The user's ordinary safe wrapper can also be written in Luce. That is a valuable reviewed layer and does not require exposing native syntax in the language.

### 5.3 Proper role of `export c`

`export c` remains essential in the reverse path:

- a generated Objective-C block/context can call a C-ABI Luce runtime trampoline;
- a C++ callback adapter can invoke an exported capture-free function or runtime entry;
- native code can hold an opaque Luce context handle governed by retain/release/attach functions;
- tests can call generated Luce exports from Clang ABI probes.

The generator may synthesize internal C-export stubs from callback declarations. The user still writes only Luce, but “export C” and “import Objective-C/C++” remain different compiler operations joined by tooling.

### 5.4 Generalization beyond Objective-C and C++

The real abstraction is not “everything first becomes handwritten C.” It is:

```text
foreign language frontend + ABI backend -> FIIR -> stable Luce boundary
```

Objective-C can use Clang plus `.m`; C++ can use Clang plus `.cc`/`.mm`; a pure Swift library would need Swift compiler metadata and a Swift-generated adapter or an Objective-C/C export supplied by its author; Rust would need C exports or a Rust-aware generator. A manifest can unify the user workflow, but every foreign language still requires a parser, semantic policy, compiler/runtime, and target ABI strategy.

## 6. Hard edges and the policies Luce must specify

### 6.1 ARC-to-ARC is ownership composition, not one shared ARC

Luce ARC counts a Luce wrapper object. Objective-C ARC counts the Objective-C pointee. They do not share an object header, weak table, compiler dataflow, or cycle detector.

Adopt this invariant:

> Every live owning Luce foreign-object wrapper contains exactly one Objective-C +1 reference. Copying a Luce reference retains the Luce wrapper, not the Objective-C object again. Destroying the wrapper releases the Objective-C object exactly once.

Boundary rules follow mechanically:

| Foreign event | Bridge action |
|---|---|
| method returns +1 | adopt the native reference into a new wrapper without another retain |
| method returns +0 | retain/promote before it can outlive the call or autorelease pool |
| nullable result is `nil` | produce `none`; never construct a wrapper around null |
| pass non-consumed object | borrow the stored native pointer and keep the Luce wrapper live across the call |
| pass `ns_consumed` object | retain an extra +1 for the callee so the ordinary Luce wrapper remains valid; expose a separately audited invalidating/take operation only if performance requires it |
| weak property getter | return an optional strong snapshot; do not expose the weak slot as a stable borrowed pointer |
| owned wrapper deinit | call `objc_release` once, on a documented allowable thread |

This model deliberately does not intern wrappers by Objective-C pointer. Two independently imported +1 handles for the same native object may produce two Luce wrappers, each owning one legitimate +1. Identity-preserving interning introduces global weak maps, synchronization, resurrection races, and callback-thread complexity; defer it. If native identity matters, expose an explicit Objective-C identity operation through the wrapper.

Protocol views and class-shaped wrappers should share the same underlying owning handle rather than create ambiguous borrowed aliases. Since Luce classes are final, use composition—exactly as the language design already requires—rather than importing the native superclass hierarchy.

The model also cannot collect a cross-runtime strong cycle such as:

```text
ObjC object -> copied block -> Luce closure/context -> Luce wrapper -> ObjC object
```

Neither ARC sees a count reach zero. Safe APIs must provide weak captures, cancellation/unregistration tokens, or an explicit close/break-cycle operation. “Both sides use ARC” makes this problem more predictable than GC/ARC timing, not nonexistent.

### 6.2 Autorelease pools are a runtime-entry contract

An autoreleased +0 result may die when the current pool drains. Apple explains that application event loops normally create pools, command-line programs and secondary threads need their own, and long loops benefit from nested pools in [Using Autorelease Pool Blocks](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MemoryMgmt/Articles/mmAutoreleasePools.html).

Required Luce policy:

- every Luce-created thread that may call Objective-C has a root autorelease pool around its native run-loop/entry interval;
- every foreign callback thread entering Luce pushes a pool before any Objective-C conversion and pops it after return;
- a correctness-first MVP may wrap each generated thunk in `@autoreleasepool`, provided every returned/callback-escaped object is promoted to +1 before pop;
- expose a scoped pool operation for allocation-heavy loops so users/libraries can control peak temporary memory;
- never promise deinitialization at a source statement merely because Luce ARC is deterministic—Objective-C autorelease intentionally delays one native release until pool drain.

Per-call pools are simple but can change weak/deinit timing and add overhead. They are an acceptable first boundary rule if documented; a later runtime-entry pool plus explicit nested scopes is a better steady-state design.

### 6.3 Blocks and callbacks arriving on foreign threads

A generated escaping block needs a heap context with two independent lifetimes:

1. Objective-C copies/releases the block using native block copy/dispose hooks.
2. The context retains/releases the Luce closure or callback token through C-ABI runtime functions.

On invocation, the adapter must:

- establish an autorelease pool;
- attach the current foreign thread to the Luce runtime;
- validate that the token has not been unregistered;
- convert/copy arguments while their foreign borrows are valid;
- obey the callback recipe's synchronous/reentrant/thread policy;
- detach and drain after all escaping results have been promoted.

Luce's existing §21.11 rule is exactly right: an arbitrary-thread callback should normally copy validated sendable arguments into the owning worker's ingress queue. It must not touch ordinary Luce identity directly. If the foreign caller requires an immediate return, accept only a capture-free/thread-safe generated function or require a Tier C audited adapter. A callback lifetime token needs a state machine that makes unregister-versus-inflight invocation safe; simply freeing the context in an unregister call races.

Protocols/delegates add another direction: the generator may need a small Objective-C class implementing selected selectors and forwarding them to Luce. That is a natural `.m` artifact and one of the strongest reasons to keep native generation even if ordinary method sends are optimized directly later.

### 6.4 Exceptions must terminate or translate *inside native glue*

Objective-C exceptions are conventionally programmer/runtime failures, not Cocoa recoverable errors. Apple's [Exception Programming Topics](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Exceptions/Exceptions.html) recommends catching expected native exceptions at subsystem boundaries and translating them; Swift's guidance says Objective-C must catch before Swift.

Set a hard ABI invariant:

> No Objective-C or C++ exception may unwind through a Luce frame, and no Luce error/trap may unwind through a native frame.

Generated Objective-C thunks should contain `@try/@catch` at the outer native boundary. The default catch policy should call a Luce fatal foreign-exception handler with class/name/reason/backtrace context, because converting every `NSException` to an ordinary `T!` would hide programmer errors. A recipe may explicitly allow translation for a documented library that uses exceptions as recoverable control flow.

If a thunk catches and continues after an Objective-C exception, compile with the exception-safe ARC mode and test cleanup. The [Clang ARC specification's exceptions section](https://clang.llvm.org/docs/AutomaticReferenceCounting.html#exceptions) notes that ordinary Objective-C ARC does not emit all strong-local cleanup for exceptions by default; Objective-C++ differs. This is another reason that “catch everything and continue” cannot be a casual policy.

Generated C++/`ObjC++` thunks should:

- omit catch overhead only for declarations proven `noexcept`;
- map explicitly listed exception types to stable Luce error codes;
- catch `std::exception` for context;
- catch `...` as an opaque bridge failure;
- ensure every owned output is either committed or destroyed before returning a C status.

Swift's official C++ interop instead terminates when an uncaught C++ exception reaches Swift. Luce's generated thunk is an opportunity to provide a better, explicit package policy without allowing cross-language unwinding.

### 6.5 Dynamic Objective-C behavior limits static promises

Objective-C categories add methods to an existing class, and at runtime those methods are not distinguishable from original methods. Apple's [Cocoa Objects documentation](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CocoaFundamentals/CocoaObjects/CocoaObjects.html) also warns about category method collisions. Consequences:

- importing a declared category method is valid, but the linker must actually load its object code; static libraries may require `-ObjC` or an equivalent force-load strategy;
- two categories can collide, and load order/runtime composition can change which implementation answers a selector;
- optional protocol requirements need `respondsToSelector:` checks;
- a selector existing in a header does not prove it exists on an older runtime; availability and weak-link policy belong in FIIR.

KVO is explicitly dynamic: Apple's [KVO implementation details](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/KeyValueObserving/Articles/KVOImplementation.html) describe automatic subclass creation and `isa`-swizzling. General method swizzling can replace implementations after load.

Therefore safe wrappers may promise type conversion, ownership normalization, null/error handling, and thread gating. They may **not** infer purity, non-reentrancy, stable concrete class, or immutable behavior merely from a header. Treat an Objective-C message as a dynamic foreign effect unless a reviewed wrapper provides a stronger library-specific contract.

### 6.6 Cross-compilation is a toolchain contract, not a cache trick

Parsing and compiling must use the destination target:

- destination SDK headers/module maps and deployment availability;
- target triple and ABI;
- target framework/library binaries;
- matching Clang resource headers;
- Objective-C runtime and, for C++, selected standard library/ABI.

Option (b) requires a target-capable Clang during a clean build or access to a trusted prebuilt binding artifact. This is not worse in principle than cgo, Rust C++, or native extension builds, but Apple SDK availability/licensing makes “build macOS/iOS anywhere” a separate product question. Option (a) removes the native-source compiler from the final lowering step, yet still needs the target SDK for import and the target runtime/libraries for linking—and makes Luce responsible for the ABI.

The manifest and `luce doctor` should name/verify a toolchain identity. Binding packages may distribute signed prebuilt thunk objects per target only when their FIIR, public C ABI report, SDK compatibility range, and full cache key match; otherwise rebuild.

## 7. Recommended architecture in Luce terms

### 7.1 Extend the existing FIIR; do not create an Objective-C side channel

Luce §21 already states the right three-layer invariant:

1. exact foreign declaration;
2. mechanically generated raw unsafe module;
3. reviewed/generated ordinary Luce wrapper.

Add Objective-C records to FIIR rather than lowering Objective-C prematurely to fake C functions. The foreign layer should retain at least:

- Clang USR and full source/module/category provenance;
- class, superclass, adopted protocols, category, and lightweight generic parameters;
- selector and class/instance dispatch kind;
- canonical Clang parameter/result types, target ABI classification, variadic flag, and availability;
- nullability at every pointer/block level and how it was established;
- method family, explicit ownership attributes, consumed parameters, and property semantics;
- initializer/designated-initializer status;
- block signature and known escape/thread/call-count facts;
- eligible `NSError **` error convention;
- exception policy;
- confidence/source of every inferred fact: header type, Clang language rule, API Note, Luce recipe, or conservative default;
- support tier and the exact reason a declaration cannot be safely wrapped.

The bridge generator consumes Objective-C-rich FIIR and produces the internal flat ABI. The safe-wrapper generator consumes the same rich FIIR, not a lossy reparse of the generated C header. This preserves the metadata advantage demonstrated in §1.

### 7.2 Define one internal native-bridge ABI

The bridge ABI should be versioned and boring:

- deterministic, collision-resistant C symbol names derived from binding identity plus declaration identity—not user-facing selector spelling alone;
- opaque handles for Objective-C/C++ owners;
- fixed-width status/error discriminants and out parameters;
- target-correct C scalar and POD records;
- no native exception, autoreleased reference, C++ reference, block object, Luce class, Luce collection, or Luce ARC pointer crossing unnormalized;
- explicit create/adopt/retain/release/copy/destroy entry points where needed;
- callback function + opaque context + context retain/release + registration token;
- an ABI report containing size, alignment, offsets, calling convention, symbol, ownership, and deployment constraints.

The current Luce C FFI's integer/opaque-handle subset is enough for a proof of concept but not a sound long-term Objective-C bridge. Framework APIs routinely use `BOOL`, `CGFloat`, `NSInteger`, enums/options, `NSRange`, CoreGraphics structs, SIMD types, function pointers, and block signatures. **Expand and verify target-correct C scalars, floating point, pointers, POD structs, and out parameters before marketing Objective-C import.** Do not flatten floats or aggregate bits into integers and call that an ABI.

The thunk's C surface is an internal implementation contract. It need not be pleasant to author or expose Objective-C naming. Its job is determinism and backend portability.

### 7.3 Treat parsing and compilation as one hermetic action

One binding action should:

1. resolve the declared SDK, module map/header, target, compiler, and link inputs;
2. ask the same pinned Clang configuration for the AST/FIIR;
3. validate recipes and report unsupported declarations;
4. generate native glue, raw Luce declarations, safe wrappers, ABI probes, and provenance maps;
5. compile native glue with the exact parse configuration plus deliberate codegen flags;
6. compare compiler-reported layouts/type encodings against FIIR assertions;
7. publish all outputs atomically into a content-addressed cache;
8. link only by an explicit returned artifact manifest.

Do not let a project separately configure “Clang used by importer” and “Clang used to compile glue.” `autocxx` and cgo show how easily that becomes an ABI fault line. A hermetic action can still call an installed platform Clang; hermetic means its resolved identity and all inputs are recorded.

### 7.4 Generated source must remain inspectable

The default package tree contains only manifest/recipe and Luce source. Generated `.m`/`.mm`, headers, raw modules, object files, and module cache live under the build cache and are never committed. However:

- diagnostic builds preserve/reproduce the exact generated source;
- debug paths are stable or prefix-mapped;
- every wrapper method can report its selector/native symbol;
- a user can run the generated native compile line;
- cache entries carry a human-readable manifest;
- release archives may optionally include generated-source provenance for crash symbolication and license compliance.

This is the right interpretation of “the user never sees the shim”: no user authors or maintains it. Deliberately forbidding inspection would turn every generator defect into a black box.

## 8. Staged implementation plan

The sequence below is intentionally narrower than “import Foundation.” Each stage has a shippable contract and an exit gate. Calendar ranges assume one full-time experienced implementer and exclude unrelated Luce compiler work.

### Stage 0 — Freeze boundary semantics and build an ABI fixture corpus (2–4 weeks)

Before generating public APIs:

- write the one-wrapper/one-native-+1 invariant into the language design;
- specify unknown nullability, `ns_consumed`, autorelease pools, exceptions, callback thread entry, and cross-runtime cycles;
- define the Objective-C FIIR schema and provenance/confidence fields;
- pin the first supported Apple Clang/Xcode/SDK range;
- create native fixtures covering class/instance methods, selectors with multiple arguments, every scalar class, small/large/odd aggregates, object +0/+1 returns, all method families, ownership overrides, nullable nesting, properties, designated initializers, `NSError **`, blocks, protocols, categories, availability, and exceptions;
- have Clang emit independent layout/type-encoding probes as the oracle.

**Exit gate:** FIIR round-trips deterministically and the fixture oracle detects deliberately wrong signatures/ownership annotations.

### Stage 1 — Finish the C ABI substrate and native-artifact cache (6–10 weeks)

Build the infrastructure option (b) depends on:

- target-correct integer, float, pointer, POD struct/enum, function/out-parameter calls;
- header generation and ABI report/diff for `export c`;
- compile/link actions with target/sysroot/module-map/framework identity;
- transitive input hashing and atomic content-cache publication;
- `luce doctor`, `luce bind --explain`, and `--emit-glue`;
- Clang diagnostic remapping and a “rebuild this one bridge with sanitizers” path.

Use a trivial generated C and Objective-C object in tests even before public Objective-C import. The goal is to prove the action graph, not API aesthetics.

**Exit gate:** changing any header, module map, define, recipe, SDK identity, generator, compiler, deployment target, or target triple invalidates exactly the correct artifact; a clean target build requires no ambient search path.

### Stage 2 — Ship a deliberately small Objective-C vertical slice (8–12 weeks)

**Build this first user-visible slice:** macOS arm64, the Foundation Clang module, and a curated set around `NSString`, `NSURL`, and one `NSFileManager` operation that uses `NSError **`.

Support:

- module-map import;
- classes/protocol identity in FIIR but composition-only Luce wrappers;
- class and instance methods;
- exact selectors, ordinary nonvariadic scalar/POD/object parameters and results;
- readonly/readwrite properties as methods;
- explicit and audited-region nullability;
- ARC method families and explicit retained/not-retained/consumed attributes;
- `init`/designated initializer facts;
- an owned foreign handle with exactly-one-+1 deinit;
- eligible canonical `NSError **` -> `T!`;
- per-thunk autorelease pool for initial correctness;
- boundary `@catch` that reports and terminates by default;
- raw unsafe module and small idiomatic safe wrappers;
- emitted glue/source maps and a target ABI report.

Do **not** support escaping blocks, delegate implementation, arbitrary-thread callbacks, variadic methods, broad collection bridging, KVO conveniences, or direct dispatch in this slice. Copy `NSString` to/from Luce `str` first; zero-copy views are a separate lifetime feature.

**Exit gate:** Foundation fixtures show balanced retains across +0/+1/nullable/error paths, no object escapes a drained pool unowned, exception frames never cross Luce, and source-level debugging can identify the selector and thunk.

### Stage 3 — Harden declaration coverage and safe-wrapper evidence (8–16 weeks)

Add:

- categories with correct link-retention metadata;
- required/optional protocol surfaces and `respondsToSelector:`;
- lightweight generics with erased-ABI markers;
- availability/weak-link checks;
- class properties, custom accessors, weak/copy properties;
- API Notes and Luce recipe overlays;
- API diff reports when an SDK/library changes;
- support-tier reports and declaration-level reasons for rejection;
- more Foundation/CoreFoundation bridges, with explicit copy versus ownership semantics;
- release-mode LTO as an optional optimization across the C thunk when the toolchains agree.

**Exit gate:** an SDK update produces a reviewable semantic binding diff; no unannotated ambiguous lifetime is silently promoted into Tier A.

### Stage 4 — Blocks, callbacks, delegate/protocol adapters, and threads (12–20 weeks)

This is a separate runtime project, not “one more type”:

- generated Objective-C block literals/copy-dispose support through Clang;
- context retain/release functions using `export c` infrastructure;
- callback lifetime tokens with unregister/inflight race handling;
- runtime attach/detach and autorelease pool for foreign threads;
- synchronous/reentrant/escaping/thread recipes;
- sendable argument copying and owning-worker queueing;
- generated Objective-C delegate classes for explicitly selected protocols;
- main-thread assertions/marshaling where the API contract requires it;
- stress tests under ThreadSanitizer and randomized unregister/callback races.

**Exit gate:** no callback can observe freed context; an arbitrary-thread callback cannot access ordinary Luce identity; pool and runtime attachment are balanced even on native errors.

### Stage 5 — C++/`ObjC++` on the same bridge engine (6–12 additional months for useful breadth)

Only after the flat ABI, ownership handles, callbacks, cache, and diagnostics are mature:

- free functions/enums/POD first;
- owner-wrapped constructors/destructors/methods;
- exact manifest-listed template instantiations;
- blessed adapters for strings, spans, optionals, expected-like values, and selected smart pointers;
- exception translation in `.cc`/`.mm`;
- composition-shaped wrappers for selected virtual/inheritance-heavy interfaces;
- no C++ inheritance/templates/exceptions/references as Luce language features.

This implements the C++ plan already in Luce §21.6–§21.10. Expect library-specific recipes to remain more common than in audited Objective-C.

### Stage 6 — Consider direct Objective-C dispatch only with measured justification

Do not schedule option (a) as inevitable cleanup. Consider it only when:

- profiling shows the extra thunk call materially affects real applications and LTO cannot remove it;
- the generated-thunk path has become a trusted differential oracle;
- one target/backend has comprehensive signature and ownership fixtures;
- the team can maintain target ABI changes;
- fallback remains available per declaration.

Start with a tiny whitelist: nonvariadic ordinary instance/class methods whose arguments/results are objects or already-proven scalar/POD ABI types, with no blocks, consumed parameters, exceptions-as-errors, super send, or unusual availability. Compare the emitted call against Clang-generated assembly/IR for every signature and target. Preserve the same FIIR, wrapper, ownership, error, and debugging contract.

Option (b) is therefore a **stepping stone in knowledge and testing**, but a **permanent destination in architecture**. Direct dispatch may bypass a thunk; it should never bypass the bridge contract.

## 9. Verification matrix and non-negotiable release gates

### ABI and code generation

- Differentially compile every signature fixture as native Objective-C and through the generated thunk on each supported target.
- Cover integer extension, Boolean, `NSInteger`/pointer width, `CGFloat`, vectors if supported, small/large structs, nested structs, unions if exposed, and all applicable message-send variants.
- Disassemble a small golden set so an accidental variadic `objc_msgSend` call on arm64 fails CI.
- Compare size/alignment/offset/type encodings against a Clang-compiled probe.

### Ownership and pools

- Instrument retain/release/deinit counts for +0, +1, explicit attributes, init replacement, nullable results, consumed arguments, weak properties, and errors.
- Drain a pool immediately after every return path to prove all escaping values carry +1.
- Test nested pools and foreign threads with and without an ambient Cocoa loop.
- Detect cross-runtime cycles in documentation/examples and provide explicit weak/unregister patterns; do not claim automatic collection.

### Errors and exceptions

- Test each `swift_error` dynamic convention and canonical inferred `NSError **` form.
- Verify error objects are owned before pool drain.
- Throw Objective-C and C++ exceptions at every bridge phase and assert no Luce frame is unwound.
- Ensure default exception handling preserves useful name/reason/native backtrace context before fatal termination.

### Blocks, callbacks, and concurrency

- Test stack-to-heap block copy, multiple copies/releases, cancellation, reentrancy, nested callbacks, callback-after-unregister attempts, and concurrent unregister.
- Invoke from unregistered POSIX/native threads and verify attach/pool/detach on success and failure.
- Test queueing of sendable arguments and rejection of non-sendable captures/immediate-return contracts.

### Link and dynamic-runtime behavior

- Test categories from dynamic frameworks and static archives, including dead-strip modes.
- Test optional protocol methods both present and absent.
- Test old deployment runtimes/weak-linked selectors and unavailable declarations.
- Test a controlled swizzle and KVO-observed object to ensure wrappers make no false static dispatch or class-identity assumption.

### Build determinism and diagnostics

- Mutate every cache-key input independently.
- Reproduce one artifact from its recorded manifest in a clean directory.
- Ensure generated output is byte-stable where toolchain outputs permit, or record/normalize nondeterministic fields.
- Make every Clang/generator/linker error actionable from the original header/recipe/Luce wrapper.
- Verify `--emit-glue` exactly reproduces the cached native source and compile command.

## 10. Concrete final recommendation

The product sentence should be:

> “Luce imports Objective-C and supported C++ APIs from a manifest. Clang parses the target headers; Luce generates and caches the required native bridge and exposes a raw module plus a safe Luce wrapper. Users never maintain native shim source.”

The engineering decision should be:

1. keep rich Objective-C facts in FIIR;
2. lower them initially through generated target-Clang `.m` thunks;
3. normalize every escaping object to an explicit +1 opaque handle;
4. put pool, callback-thread, and exception containment in the bridge contract;
5. use a declarative recipe for facts the header cannot prove;
6. keep generated glue invisible by default but exactly reproducible;
7. retain handwritten native adapters only as Tier C;
8. keep generated thunks as the permanent C++ path and Objective-C fallback;
9. revisit direct Objective-C dispatch only after profiling and differential ABI evidence.

The first thing to build is **not a general Objective-C surface and not `objc_msgSend` lowering**. Build one end-to-end Foundation vertical slice—`NSString`/Luce string copying, `NSURL` ownership/nullability, and one `NSFileManager` `NSError **` call—through a generated `.m` cache artifact on macOS arm64. That slice forces the design to prove parsing, module maps, target configuration, selectors, ARC +0/+1, pool timing, error conversion, C ABI normalization, caching, linking, safe wrappers, and diagnostics while blocks and foreign threads remain intentionally out of scope.

If that slice is pleasant to use and unpleasant to debug only until `--emit-glue` is invoked, the architecture is working. If it requires the user to edit generated Objective-C, duplicate selectors, or understand `__bridge_retained`, the two steps have not actually been merged.

## Selected primary-source index

- Clang: [Objective-C ARC specification](https://clang.llvm.org/docs/AutomaticReferenceCounting.html); [attribute reference](https://clang.llvm.org/docs/AttributeReference.html); [modules/module maps](https://clang.llvm.org/docs/Modules.html); [API Notes](https://clang.llvm.org/docs/APINotes.html); [Blocks language specification](https://clang.llvm.org/docs/BlockLanguageSpec.html); [Apple block ABI](https://clang.llvm.org/docs/Block-ABI-Apple.html).
- Swift: [compiler architecture](https://www.swift.org/documentation/swift-compiler/); [Objective-C interop implementation notes](https://github.com/swiftlang/swift/blob/main/docs/ObjCInterop.md); [C API importer notes](https://github.com/swiftlang/swift/blob/main/docs/HowSwiftImportsCAPIs.md); [C++ interop overview](https://www.swift.org/documentation/cxx-interop/); [C++ status/constraints](https://www.swift.org/documentation/cxx-interop/status/); [safe C++ interop](https://www.swift.org/documentation/cxx-interop/safe-interop/).
- Apple: [Cocoa error import and Objective-C exception boundary](https://developer.apple.com/documentation/swift/handling-cocoa-errors-in-swift); [autorelease pools](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MemoryMgmt/Articles/mmAutoreleasePools.html); [categories/runtime behavior](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CocoaFundamentals/CocoaObjects/CocoaObjects.html); [KVO implementation](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/KeyValueObserving/Articles/KVOImplementation.html).
- Generated-interop systems: [Rust cxx](https://cxx.rs/); [autocxx](https://google.github.io/autocxx/); [Kotlin/Native cinterop](https://kotlinlang.org/docs/native-c-interop.html); [Dart Objective-C interop](https://dart.dev/interop/objective-c-interop); [.NET Apple binding projects](https://learn.microsoft.com/en-us/dotnet/maui/migration/ios-binding-projects?view=net-maui-10.0); [Go cgo implementation](https://go.dev/src/cmd/cgo/doc.go).
