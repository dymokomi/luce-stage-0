# Luce

## Compiler and runtime plan for LuciaOS

**Status:** proposed implementation plan  
**Implementation language:** Zig  
**Initial compiler backend:** LLVM 22  
**Initial hosts:** Apple Silicon macOS and x86-64 Linux  

---

## 1. The decision

Luce is the small, native language used to write a Texel's evaluator.

A Texel owns Luce source as content. There are no source files, imports, packages, or file extensions inside LuciaOS. Loom compiles the source on the local machine, caches the resulting native evaluation blob as derived state, and invokes it when the Texel's outputs are demanded.

Luce should look and read somewhat like Python, but it is not Python and will not inherit Python's runtime model. It is:

- statically typed;
- compiled to native machine code;
- safe by default;
- procedural rather than object-oriented;
- built around functions, local variables, value structures, and explicit Input and Output Ports;
- pure by default, with effects crossing trusted LuciaOS boundaries;
- intentionally small enough that LuciaOS can eventually own its entire compiler.

LLVM is an implementation dependency of the first compiler, not part of Luce's language model. Luce will have its own syntax, type system, intermediate representation, runtime ABI, cache format, and diagnostics. LLVM begins at the final code-generation boundary and may later be replaced without changing Luce programs or Texels.

> **LLVM is the first machine-code engine, not the definition of Luce.**

---

## 2. What belongs where

The distinction between the Fabric and the evaluator must remain sharp.

### The Fabric owns

- Texel identity;
- Input and Output Port definitions;
- Fiber connections;
- durable content;
- current revisions;
- capabilities;
- demand;
- evaluation cache ownership;
- publication of computed outputs.

### A Luce evaluator owns

- functions;
- parameters;
- local variables;
- structures and structure values;
- expressions;
- control flow;
- temporary memory;
- the computation that reads the Texel's inputs and proposes its outputs.

### A Luce evaluator does not own

- a process;
- a thread;
- a filesystem;
- a clock;
- a network connection;
- persistent global variables;
- arbitrary access to other Texels;
- the lifetime of its cached output;
- the authority to perform effects.

This allows Luce to be a useful programming language without turning every programming-language feature into a new LuciaOS primitive.

---

## 3. The execution model

Each evaluator is one compilation unit embedded in one Texel.

The Texel defines its Ports independently of the evaluator source. The compiler receives:

```text
source bytes
Input Port schema
Output Port schema
compiler options
target description
runtime ABI version
```

The source reads from an implicit `input` value and writes to an implicit `output` value:

```luce
struct Point:
    x: Float
    y: Float

fn scale_point(point: Point, factor: Float) -> Point:
    return Point(
        x = point.x * factor,
        y = point.y * factor,
    )

fn evaluate():
    let position = input.position
    let factor = input.scale
    output.position = scale_point(position, factor)
```

The Port schema, not the source, establishes that `input.position`, `input.scale`, and `output.position` exist and determines their types. This has several advantages:

- Ports retain identity when evaluator source is replaced.
- The evaluator cannot silently add authority by declaring a new input.
- Loom can type-check Fibers before compilation.
- One evaluator can be replaced without reconstructing the Texel.
- Port names and types can appear in the editor as completion and diagnostics.

`evaluate` is the only required entry function. Other functions are private to the evaluator blob.

When an output is demanded:

1. Loom resolves and validates the Texel's inputs.
2. Loom allocates an evaluation context and a scratch output frame.
3. Loom invokes the compiled `evaluate` entry point.
4. The evaluator reads immutable inputs and writes candidate outputs.
5. If evaluation succeeds, Loom publishes all resulting outputs atomically.
6. If evaluation fails, times out, or traps, Loom publishes none of them.

This preserves the existing LuciaOS rule that an interrupted evaluation never leaves partial output.

---

## 4. Luce 0.1 language

The first language must be useful enough to build real Views and computational Texels, but small enough to implement and reason about.

### 4.1 Lexical form

- UTF-8 source.
- Indentation defines blocks.
- Four spaces are canonical; tabs are rejected.
- Newlines normally terminate statements.
- Parentheses allow expressions and calls to span lines.
- `#` begins a line comment.
- Identifiers are ASCII in 0.1; strings may contain full Unicode.
- Source locations are byte offset, line, and column so diagnostics remain stable inside a Texel.

The lexer should be written for Luce. Reusing CPython's parser would import a large grammar, Python-specific behavior, and a mismatched AST. The visual familiarity is valuable; parser compatibility is not.

### 4.2 Primitive types

The initial scalar types are:

| Luce type | Meaning |
|---|---|
| `Bool` | `true` or `false` |
| `Int` | signed 64-bit integer |
| `UInt` | unsigned 64-bit integer |
| `Float` | IEEE 754 64-bit float |
| `I8`, `I16`, `I32`, `I64` | explicitly sized signed integers |
| `U8`, `U16`, `U32`, `U64` | explicitly sized unsigned integers |
| `F32`, `F64` | explicitly sized floating point |
| `String` | immutable UTF-8 string |
| `Bytes` | immutable byte sequence |
| `None` | absence of a return value |

`Int` and `Float` have fixed meanings on every platform. They must not follow pointer width or host-language conventions. The same source should calculate the same values on macOS and Linux except where floating-point rules explicitly permit variation.

### 4.3 Variables

Luce has immutable and mutable local bindings:

```luce
let radius = input.radius
let area = pi * radius * radius

var total = 0.0
for sample in input.samples:
    total = total + sample
```

- `let` binds once.
- `var` permits local reassignment.
- Function parameters are immutable.
- Structure fields in local `var` values may be updated.
- There are no persistent globals or static mutable variables.

A local variable exists only for one evaluation. Persistent state must enter through an Input Port and leave through an Output Port, normally with an explicit State or Delay Texel in the Fabric.

This is not an arbitrary limitation. It ensures that Loom can understand when an evaluator is repeatable, cacheable, and safe to retry.

### 4.4 Functions

Functions are named, statically dispatched, and local to the evaluator:

```luce
fn clamp(value: Float, low: Float, high: Float) -> Float:
    if value < low:
        return low
    if value > high:
        return high
    return value
```

Luce 0.1 supports:

- typed parameters;
- explicit return types;
- `return`;
- calls to functions in the same evaluator;
- calls to compiler-provided intrinsic functions;
- recursion only when explicitly enabled by a compiler limit.

Luce 0.1 does not support:

- overloads;
- default parameters;
- variadic functions;
- closures;
- captured variables;
- function values;
- dynamic dispatch;
- methods;
- generics.

These can be reconsidered only when a concrete use case requires them. Ordinary code reuse begins with small named functions.

### 4.5 Structures

Structures are plain typed values:

```luce
struct Color:
    red: F32
    green: F32
    blue: F32

fn luminance(color: Color) -> F32:
    return (
        color.red * 0.2126 +
        color.green * 0.7152 +
        color.blue * 0.0722
    )
```

Structures have:

- named fields;
- fixed compile-time layout;
- value semantics;
- construction by field name;
- field access;
- equality when all fields support equality.

They do not have:

- methods;
- inheritance;
- hidden constructors;
- virtual tables;
- identity independent of their containing value;
- implicit heap allocation.

A structure inside Luce is not a Texel. It is a compact value used during computation or passed through a typed Port. A structure becomes a Texel only when the Fabric needs to address it independently.

### 4.6 Collections

The initial collection forms should be:

- fixed-size arrays, with their length known at compile time;
- immutable slices borrowed from inputs;
- mutable local buffers allocated from the evaluation arena;
- immutable `String` and `Bytes`.

An illustrative syntax is:

```luce
let first = input.values[0]

var sum = 0.0
for value in input.values:
    sum = sum + value
```

Bounds checks are enabled by default. Large images, video frames, audio buffers, database tables, and GPU resources should normally cross Ports as opaque typed handles rather than being expanded into general Luce collections.

Resizable general-purpose lists and maps are deferred until ownership, hashing, and output-transfer semantics are designed deliberately.

### 4.7 Control flow

Luce 0.1 supports:

- `if`, `elif`, and `else`;
- `for` over ranges, arrays, and slices;
- `while`;
- `break`;
- `continue`;
- `return`.

Native evaluators execute under a deadline and resource budget. The default execution environment must be preemptible at the worker-process boundary so an accidental infinite loop cannot freeze Loom.

### 4.8 Operators and conversions

Luce provides the expected arithmetic, comparison, Boolean, indexing, and field-access operators. Numeric conversions are explicit:

```luce
let count = I32(input.count)
let ratio = F64(count) / input.total
```

No implicit narrowing is allowed. Integer overflow traps by default. Explicit wrapping operations may later be provided as named intrinsics for algorithms that require them.

### 4.9 Errors

The first evaluator has three outcomes:

```text
success
structured Luce error
runtime trap
```

Compilation errors never produce a runnable blob. Runtime errors include a stable code, message, source span where available, and evaluator revision.

Typed recoverable values such as `Option[T]` and `Result[T, E]` are desirable, but they should be added after the base type and layout system works. Port-level states such as unavailable input, upstream error, and cancelled demand remain part of Loom's evaluation contract rather than being conflated with a Luce exception system.

Luce 0.1 has no exceptions.

### 4.10 Built-ins

Built-ins are compiler-known operations, not imported libraries. The initial set should remain narrow:

- numeric minimum, maximum, absolute value, and clamp;
- common floating-point functions;
- length and indexing for supported collections;
- structure and scalar conversions;
- assertions and explicit traps;
- a small set of deterministic string and byte operations.

Some built-ins lower directly to LLVM intrinsics. Others call a versioned `luce_rt_*` runtime function. Luce programs never link arbitrary host symbols.

---

## 5. Deliberate omissions from Luce 0.1

The following are not required to prove Luce:

- classes;
- methods;
- inheritance;
- modules;
- source imports;
- package management;
- dependency resolution;
- macros;
- compile-time evaluation;
- reflection;
- async/await;
- coroutines;
- threads;
- exceptions;
- garbage collection;
- foreign-function declarations;
- raw pointers;
- direct system calls;
- inline assembly;
- a user-visible linker;
- cross-compilation from within LuciaOS.

This is not a claim that none of these ideas will ever be useful. It keeps the first language aligned with the atomic nature of Texel evaluators.

Code sharing will eventually need a Lucia-native answer, but it should not begin by recreating files and packages inside the compiler. Plausible later directions include compiler-provided standard functions, source Texels expanded into an evaluator before compilation, or whole-subgraph compilation. That decision can wait until repeated real code reveals the correct shape.

---

## 6. Compiler architecture

The compiler is written in Zig and divided into backend-independent and LLVM-specific layers.

```text
Luce source
    ↓
lexer
    ↓
parser
    ↓
AST
    ↓
name and type analysis
    ↓
Luce IR
    ↓
verification and simple optimization
    ↓
LLVM lowering
    ↓
LLVM optimization and machine-code generation
    ↓
native object blob
```

### 6.1 Source

The compiler accepts a byte slice, not a path:

```zig
pub fn compile(
    allocator: Allocator,
    source: []const u8,
    ports: PortSchema,
    target: Target,
    options: CompileOptions,
) CompileResult
```

No compiler stage may assume that source has a filename. Diagnostics identify the Texel revision and source span. A View may display any friendly label it wants.

### 6.2 Lexer

The lexer produces tokens, indentation changes, and exact source spans. It must detect:

- inconsistent indentation;
- tabs;
- invalid UTF-8;
- malformed numeric literals;
- unterminated strings;
- unexpected characters.

The lexer should have no LLVM dependency and should be fuzzed independently.

### 6.3 Parser

Use a handwritten recursive-descent parser for declarations and statements, with a Pratt parser for expressions.

This is appropriate because the language is small, error recovery matters in an interactive editor, and the parser must report useful diagnostics against an in-Texel source buffer.

The parser produces a compact arena-allocated AST. Parsing should continue after recoverable errors so the editor can show multiple useful diagnostics at once.

### 6.4 Semantic analysis

Semantic analysis performs:

- declaration collection;
- name resolution;
- duplicate detection;
- function signature checking;
- structure validation;
- Input and Output Port member resolution;
- type inference for local expressions where unambiguous;
- explicit conversion checking;
- return-path checking;
- definite assignment checking;
- mutation checking for `let`;
- recursion detection;
- effect and intrinsic validation.

The type checker knows Luce types and the Texel's Port schema. It does not expose LLVM types.

### 6.5 Luce IR

A small, typed Luce intermediate representation is the most important architectural investment in the compiler.

It should use:

- functions;
- basic blocks;
- virtual registers;
- typed operations;
- block parameters for merged control flow;
- explicit calls;
- explicit input loads;
- explicit output stores;
- explicit traps;
- structure construct/extract operations.

The initial operation set should be only what the language needs. It is not intended to become a universal optimizer.

Luce IR provides:

- a stable boundary before LLVM;
- a place to verify language safety properties;
- a readable dump for compiler debugging;
- a basis for a future direct native backend;
- a way to test frontend semantics without depending on LLVM output.

Do not mirror LLVM IR unnecessarily. If Luce IR becomes a renamed subset of LLVM IR, replacing LLVM later will not actually be easier.

### 6.6 Luce IR optimization

Only cheap, predictable passes belong here initially:

- constant folding;
- unreachable-block removal;
- dead local elimination;
- trivial branch simplification;
- structure scalarization where obvious.

LLVM performs the serious machine-independent and target-specific optimization. Luce IR optimization exists mainly to simplify semantics and keep generated LLVM IR clean.

### 6.7 LLVM lowering

The LLVM backend translates verified Luce IR into LLVM IR using LLVM's C API from Zig.

Use:

- opaque LLVM pointers;
- explicit target data layout;
- one LLVM module per evaluator revision;
- internally linked helper functions;
- one exported evaluator entry symbol;
- explicit checked operations where Luce semantics require traps;
- a strict runtime-symbol allowlist.

If the LLVM C API lacks an essential ORC operation, add one very small C++ bridge isolated inside `backend/llvm`. No LLVM C++ types should cross that bridge into the rest of the compiler.

### 6.8 Optimization tiers

Use two compilation tiers:

**Interactive**

- optimized for edit-to-result latency;
- minimal Luce passes;
- LLVM `O0` or a deliberately small pass pipeline;
- full source-to-runtime diagnostics.

**Optimized**

- compiled after a short idle period or when the Texel becomes hot;
- LLVM `O2`;
- cached separately;
- atomically replaces the interactive blob only after validation.

The initial system can ship with one tier if two-tier compilation delays the vertical slice. The cache format should nevertheless include the optimization tier from the beginning.

### 6.9 Object emission

LLVM's target machine can emit an object directly to an in-memory buffer. No temporary source or object file is required.

The initial native payloads are:

- Mach-O relocatable object bytes on macOS;
- ELF relocatable object bytes on Linux.

Loom stores those bytes inside its evaluation cache envelope. LLVM ORC loads them from memory and resolves only Lucia's approved runtime symbols.

This is simpler and safer than inventing a Lucia native object format while LLVM is still responsible for code generation.

---

## 7. LLVM integration

### 7.1 Version policy

Pin one LLVM release across development and CI. Begin with LLVM 22.1.8.

Do not support an arbitrary LLVM installed on the user's system. An LLVM upgrade is an intentional LuciaOS toolchain change accompanied by:

- compiler tests;
- cache-version changes where required;
- performance comparison;
- generated-code validation;
- updated notices.

### 7.2 Development dependency

During early development:

- macOS developers may use a pinned Homebrew or locally built LLVM;
- Linux developers may use the matching official LLVM package or a locally built copy;
- CI builds against the exact pinned revision.

This is acceptable for bringing up the language. Before distributing LuciaOS, the build must produce a controlled LLVM bundle rather than asking users to install LLVM.

### 7.3 Release dependency

LuciaOS packages its compiler dependency. Users install LuciaOS, not LLVM.

Build only the components and native target required by each host:

- macOS package: AArch64 target;
- Linux x86-64 package: X86 target.

Do not include every LLVM target. Luce performs local native compilation and does not need LLVM cross-compilation initially.

The minimal component set will likely include LLVM Core, Support, Analysis, Transform passes, Target, MC, CodeGen, Object, ExecutionEngine, and ORC JIT plus the host target. The exact closure should be derived from the build, not guessed and frozen prematurely.

LLVM is licensed under Apache 2.0 with the LLVM exception. Its license and required notices must ship with LuciaOS.

### 7.4 Zig boundary

Create a single Zig package for LLVM:

```text
src/luce/backend/llvm/
    bindings.zig
    context.zig
    types.zig
    lower.zig
    passes.zig
    target.zig
    object.zig
    jit.zig
    errors.zig
```

Only this package may import LLVM headers or refer to LLVM handles. Every handle receives an owned Zig wrapper with explicit `deinit`.

LLVM errors must be copied into Lucia-owned diagnostics and disposed immediately. No LLVM message pointer or lifetime escapes the backend.

---

## 8. Native runtime ABI

The compiled evaluator should expose one stable C-compatible entry point:

```text
LuceStatus luce_evaluate(LuceEvalContext*)
```

The context points to versioned Lucia-owned structures:

```text
LuceEvalContext
├── ABI version
├── Input frame
├── scratch Output frame
├── evaluation arena
├── runtime function table
├── cancellation/deadline state
├── error sink
└── trace sink
```

### 8.1 Input frame

The Input frame contains immutable values laid out from the Texel's current Port schema.

- Scalars and small structures may be inline.
- Strings and slices are borrowed for the duration of evaluation.
- Large values use typed opaque handles.
- Capability values are opaque, non-forgeable handles.

The evaluator cannot retain a borrowed pointer after it returns.

### 8.2 Output frame

The Output frame is scratch storage owned by the current evaluation.

- Scalar results may be inline.
- Variable-size results allocate from the evaluation arena.
- Large results return typed immutable value handles.
- Each required output is marked written or unwritten.

Loom validates the completed frame before publishing it. Publishing updates all output revisions as one coherent result.

### 8.3 Runtime function table

Compiled code does not resolve libc, Zig, macOS, Linux, or arbitrary symbols. It receives a versioned table containing only approved operations:

```text
luce_rt_alloc
luce_rt_trap
luce_rt_check_cancelled
luce_rt_string_*
luce_rt_value_*
luce_rt_intrinsic_*
```

The exact table should remain smaller than this illustrative list where possible.

Runtime functions are deterministic and effect-free unless the evaluator was compiled for a specifically trusted boundary role. Ordinary Luce never directly opens a file, sends a message, reads a clock, or accesses another Texel.

### 8.4 ABI stability

The ABI is private to LuciaOS but explicitly versioned. Every cached blob records:

- Luce language version;
- compiler build identity;
- Luce IR version;
- runtime ABI version;
- Port-frame layout hash;
- target triple;
- CPU feature set;
- optimization tier.

Any mismatch invalidates the cache and triggers recompilation.

---

## 9. Cache design

The source is authoritative. Native code is derived.

A cached evaluator blob contains:

```text
header
compiler and ABI versions
source hash
Input and Output Port schema hash
target triple and CPU feature hash
optimization tier
native object bytes
entry symbol
optional diagnostic/source map
integrity checksum
```

### 9.1 Cache key

The cache key is computed from:

```text
source bytes
normalized Port schema
language version
compiler version
runtime ABI version
target
CPU features
optimization options
```

It must not depend on a path, filename, View name, or Texel location.

### 9.2 Where the cache lives

Conceptually, the cache belongs to the Texel because it derives from that Texel's evaluator. Physically, Loom may store it in a separate cache arena keyed by Texel identity and evaluator revision.

The cache is:

- local to the machine;
- disposable;
- excluded from the durable semantic identity of the Texel;
- normally excluded from synchronization;
- rebuildable from source and Port schema.

This preserves the statement that a Texel contains source and its cached compiled blob without making architecture-specific code part of the shared truth.

### 9.3 Failed recompilation

When edited source fails to compile:

- keep the source revision;
- return structured compiler diagnostics;
- retain the previous native blob only for explicit comparison, rollback, or last-good preview;
- never silently report the old blob's outputs as the result of the new source revision.

The distinction must be visible. A stale successful program must not masquerade as the current program.

---

## 10. Demand, state, and effects

Luce does not change LuciaOS's pull architecture.

A boundary observation may update an Output Port and invalidate dependent caches. Loom evaluates a Luce Texel only when a View, user action, scheduled demand, event-activated demand, or standing demand asks for its output.

### 10.1 Pure computation

An ordinary evaluator:

- reads its Input frame;
- computes;
- writes its scratch Output frame;
- returns.

It is safe to retry because it has no ambient effects.

### 10.2 Persistent state

There is no hidden mutable evaluator state.

A stateful computation uses explicit Fabric structure:

```text
previous state → evaluator input
new state      ← evaluator output
```

A State or Delay Texel advances that value across epochs. This keeps persistence, dependency, recovery, and visibility under Loom's control.

### 10.3 Effects

Ordinary Luce computes an effect intent as an output value. A trusted boundary validates an explicit capability and performs the effect under a stable intent identity.

The compiler therefore does not need filesystem, network, process, or device APIs in its ordinary runtime. Effect authority remains connected through Ports and enforced by Loom.

---

## 11. Isolation and safety

LLVM produces native code. This makes Luce fast, but native code must be treated as a powerful implementation artifact even when the source language is safe.

### 11.1 Compiler isolation

Run compilation in a dedicated compiler worker process.

Reasons:

- malformed or adversarial source must not crash Loom through an LLVM bug;
- LLVM can consume substantial memory;
- a compiler timeout can be enforced by terminating the worker;
- LLVM state and versioning remain outside the trusted storage core.

The compiler worker receives source bytes and schemas and returns either a cache blob or diagnostics.

### 11.2 Evaluator isolation

Run ordinary third-party Luce evaluators in evaluator worker processes.

Workers should have:

- no inherited filesystem descriptors except explicit shared-memory channels;
- no network access;
- no environment or process-launch authority;
- bounded memory;
- a deadline;
- a termination path;
- shared immutable input buffers;
- scratch output buffers that Loom validates before accepting.

Initially, a worker may host several evaluators for efficiency. The isolation unit and trust policy should remain explicit so sensitive or untrusted packages can receive separate workers.

Trusted LuciaOS system evaluators may later run in-process after the ABI and compiler are mature. This is a performance optimization, not the default security model.

### 11.3 Language safety

Luce source has:

- no raw pointers;
- no pointer arithmetic;
- checked indexing;
- checked integer overflow by default;
- initialized locals;
- immutable borrowed inputs;
- arena-bounded temporary allocation;
- no arbitrary symbol resolution.

The compiler inserts traps for violated language guarantees. The worker boundary handles failures that cannot safely unwind.

### 11.4 macOS JIT requirements

Apple Silicon enforces write-or-execute protection for JIT memory. A hardened LuciaOS build that executes generated native code will require the narrow JIT entitlement and `MAP_JIT`-compatible memory management.

Use LLVM ORC's JIT memory facilities and validate the complete hardened-runtime and notarization path early. Do not rely on the broader unsigned-executable-memory entitlement.

The macOS signing and entitlement configuration is a first-class release requirement, not a final packaging detail.

### 11.5 Linux isolation

The Linux worker should combine:

- ordinary process address-space isolation;
- reduced file descriptors;
- resource limits or cgroup limits where available;
- syscall filtering;
- explicit shared-memory IPC.

The first prototype can begin with process isolation and deadlines, then add syscall filtering before any untrusted Luce source is accepted.

---

## 12. Platform targets

The initial supported targets are:

| Host | Architecture | LLVM target | Priority |
|---|---|---|---|
| macOS | AArch64 / Apple Silicon | AArch64 | primary |
| Linux | x86-64 | X86 | primary |

Later:

| Host | Architecture | Reason |
|---|---|---|
| Linux | AArch64 | servers and ARM development machines |
| macOS | x86-64 | only if actual users require older Intel Macs |

Luce's type system and runtime ABI remain platform-neutral. The native object cache is platform-specific and regenerated locally.

The evaluator should not link against libc on either platform. All external operations pass through the Lucia runtime table, making the generated program substantially less dependent on differences between macOS and Linux.

---

## 13. Source organization

A proposed repository layout:

```text
src/
  luce/
    source.zig
    token.zig
    lexer.zig
    ast.zig
    parser.zig
    diagnostics.zig

    semantic/
      analyzer.zig
      scope.zig
      types.zig
      ports.zig

    ir/
      instruction.zig
      block.zig
      function.zig
      builder.zig
      verify.zig
      print.zig
      optimize.zig

    backend/
      backend.zig
      llvm/
        bindings.zig
        context.zig
        lower.zig
        passes.zig
        target.zig
        object.zig
        jit.zig
        errors.zig

    runtime/
      abi.zig
      frame.zig
      arena.zig
      values.zig
      intrinsics.zig
      traps.zig

    cache/
      key.zig
      format.zig
      validate.zig

    worker/
      compiler_worker.zig
      evaluator_worker.zig
      protocol.zig

    tests/
      cases/
      runtime/
      integration/

  loom/
    evaluation/
      demand.zig
      compiler_service.zig
      evaluator_service.zig
      publish.zig

platform/
  macos/
    jit.zig
    worker.zig
    signing/

  linux/
    jit.zig
    worker.zig
    sandbox.zig

third_party/
  llvm/
  NOTICES.md
```

This is an implementation repository layout. LuciaOS itself still exposes source as Texel content rather than files.

---

## 14. Compiler API

Keep the Loom/compiler boundary small.

### Compile request

```zig
pub const CompileRequest = struct {
    texel_id: TexelId,
    evaluator_revision: Revision,
    source: []const u8,
    input_schema: []const PortType,
    output_schema: []const PortType,
    target: Target,
    optimization: OptimizationTier,
    runtime_abi: RuntimeAbiVersion,
};
```

### Compile result

```zig
pub const CompileResult = union(enum) {
    success: CompiledBlob,
    diagnostics: []Diagnostic,
    compiler_failure: CompilerFailure,
};
```

### Evaluation request

```zig
pub const EvaluationRequest = struct {
    blob: BlobRef,
    input_frame: SharedFrame,
    deadline: Deadline,
    memory_budget: usize,
    trace_mode: TraceMode,
};
```

### Evaluation result

```zig
pub const EvaluationResult = union(enum) {
    success: SharedOutputFrame,
    luce_error: LuceError,
    trap: Trap,
    timeout,
    cancelled,
    worker_failure: WorkerFailure,
};
```

These structures are illustrative. Their important property is that Loom exchanges Lucia-owned values, never LLVM handles.

---

## 15. Diagnostics and editing

Luce is written inside a Texel, so compiler diagnostics are part of the user experience rather than terminal output.

Every diagnostic should contain:

- stable diagnostic code;
- severity;
- concise primary message;
- primary source span;
- secondary labeled spans where useful;
- optional fix suggestion;
- relevant Port name or type;
- evaluator revision.

The editor can provide:

- syntax highlighting from the Luce lexer;
- indentation;
- completion for local declarations, structure fields, built-ins, and Ports;
- hover types;
- jump to local function or structure declaration;
- inline diagnostics;
- formatted Luce IR for advanced inspection;
- compile and evaluation timing;
- last successful revision and current cache tier.

Language-server protocols may be used at the development boundary, but the internal compiler API should operate directly on Texel source and revisions.

---

## 16. Testing strategy

### 16.1 Lexer and parser

- token golden tests;
- indentation edge cases;
- malformed-source recovery tests;
- fuzzing with arbitrary byte input;
- source-span accuracy tests.

### 16.2 Semantic analysis

- one positive and several negative cases for every rule;
- Port lookup and type mismatch tests;
- immutable/mutable binding tests;
- return-path and definite-assignment tests;
- structure layout and recursion tests;
- numeric conversion tests.

### 16.3 Luce IR

- readable IR golden tests;
- verifier rejection tests;
- control-flow and block-parameter tests;
- deterministic generation from the same source and schema.

### 16.4 LLVM lowering

- LLVM module verification on every test case;
- generated object validation;
- target-specific tests on macOS AArch64 and Linux x86-64;
- checked arithmetic and bounds-trap tests;
- ABI layout comparison against Lucia runtime structures.

### 16.5 Runtime

- atomic output publication;
- no publication after trap or timeout;
- input borrowing lifetime;
- arena exhaustion;
- worker crash recovery;
- symbol allowlist enforcement;
- cache invalidation for every header field.

### 16.6 Cross-platform semantics

Run the same language corpus on macOS and Linux and compare:

- scalar outputs;
- structure outputs;
- errors and trap codes;
- source spans;
- cache-key inputs other than target-specific fields.

Native object bytes need not match across platforms. Language-level behavior should.

### 16.7 Performance

Track:

- source-to-diagnostic latency;
- source-to-interactive-code latency;
- optimized compilation latency;
- cold object load;
- warm invocation overhead;
- Input/Output frame construction;
- small scalar evaluator throughput;
- medium structure and collection workloads;
- shared large-value overhead;
- worker IPC overhead;
- cache hit rate.

A compiled scalar Texel should not require heap allocation during evaluation. Connected hot Texels may later be fused, but the first implementation must establish the cost of the unfused path honestly.

---

## 17. Implementation phases

### Phase 0 — Freeze the 0.1 contract

Deliver:

- short language reference;
- grammar;
- type table;
- Port access rules;
- evaluation ABI draft;
- cache envelope draft;
- explicit deferred-feature list.

Exit condition:

Ten representative evaluator examples can be written without inventing new syntax or runtime concepts.

Representative examples should include:

- scalar transformation;
- pointer-position transformation;
- structure transformation;
- loop over samples;
- conditional formatting for a View;
- state transition function;
- scheduled-job computation;
- autoreply intent computation;
- image-handle operation;
- structured error.

### Phase 1 — Frontend

Implement:

- source model;
- lexer;
- parser;
- AST;
- diagnostics;
- formatter sufficient for tests.

Exit condition:

All representative programs parse, malformed edits produce useful diagnostics, and arbitrary input cannot crash the frontend.

### Phase 2 — Types and Luce IR

Implement:

- primitive types;
- functions;
- `let` and `var`;
- structures;
- control flow;
- Input and Output Port binding;
- typed Luce IR;
- IR verifier and printer.

Exit condition:

Representative programs lower to verified, readable Luce IR without LLVM.

### Phase 3 — First native evaluator

Implement:

- pinned LLVM build;
- Zig LLVM boundary;
- scalar and structure lowering;
- runtime ABI;
- object emission to memory;
- ORC loading;
- direct evaluator invocation.

Exit condition:

One Texel reads typed inputs, calls several Luce functions, writes a structure output, compiles and runs natively on Apple Silicon macOS and x86-64 Linux.

### Phase 4 — Loom integration

Implement:

- compiler service;
- cache key and envelope;
- compilation on evaluator revision change;
- demand-time cache lookup;
- Input and scratch Output frames;
- atomic publication;
- structured compiler and runtime errors.

Exit condition:

A Luce Texel survives restart, recompiles when required, stays cached when valid, and participates correctly in a demanded Fabric subgraph.

### Phase 5 — Collections and practical Views

Implement:

- fixed arrays;
- borrowed slices;
- strings and bytes;
- evaluation arena;
- essential intrinsics;
- editor completion for Ports and structures.

Exit condition:

A nontrivial View can be written in Luce without escaping to a native Zig evaluator for ordinary control and data transformation.

The actual UI renderer remains a trusted specialized runtime. Luce should compute a compact interface description or command buffer rather than paint pixels one call at a time.

### Phase 6 — Worker isolation

Implement:

- compiler worker protocol;
- evaluator worker protocol;
- deadlines and cancellation;
- memory budgets;
- shared immutable inputs;
- validated output transfer;
- macOS JIT signing/entitlement path;
- Linux syscall restrictions.

Exit condition:

Infinite loops, compiler crashes, runtime traps, and malformed cache blobs cannot bring down Loom.

### Phase 7 — Optimization and profiling

Implement:

- interactive and optimized tiers;
- hotness measurements;
- background `O2` compilation;
- object load reuse;
- performance dashboard;
- copy-elision for large values.

Exit condition:

Compilation is unobtrusive during editing, cached invocation overhead is understood, and representative workloads meet defined latency budgets.

### Phase 8 — Language 0.1 freeze

Complete:

- language reference;
- conformance suite;
- cache and ABI versioning policy;
- stable diagnostic codes;
- security review;
- LLVM notices;
- migration test from pre-freeze caches.

Exit condition:

Luce 0.1 is sufficient to author the first real LuciaOS Views and services, and source written against 0.1 has a documented compatibility promise.

---

## 18. The first vertical slice

The fastest honest proof is a pointer-driven View:

```text
pointer boundary Texel
        ↓ position
Luce transform Texel
        ↓ transformed position
Luce View Texel
        ↓ interface description
trusted shell
```

The transform evaluator:

```luce
struct Point:
    x: F32
    y: F32

fn smooth(current: Point, target: Point, amount: F32) -> Point:
    return Point(
        x = current.x + (target.x - current.x) * amount,
        y = current.y + (target.y - current.y) * amount,
    )

fn evaluate():
    output.position = smooth(
        input.previous,
        input.pointer,
        input.amount,
    )
```

This slice proves:

- Port-schema binding;
- functions;
- variables;
- structures;
- LLVM native generation;
- cached native blobs;
- boundary invalidation followed by pull evaluation;
- explicit previous state;
- View computation;
- frame-rate behavior;
- macOS JIT operation;
- Linux portability.

It is more valuable than a command-line “hello world” because it exercises the reason Luce exists.

---

## 19. Principal risks

### LLVM makes LuciaOS large

This is accepted initially. Limit the packaged targets and components, measure the actual closure, and preserve the backend boundary. Do not spend the first year replacing LLVM before Luce semantics are proven.

### Python-like syntax creates Python expectations

Document the differences immediately: static types, `let` and `var`, no objects, no imports, no global mutation, no exceptions. Luce should be visually calm rather than syntactically compatible.

### Tiny evaluators create call and IPC overhead

Measure first. Use compact frames, worker reuse, shared large values, and caching. Later, fuse compatible connected Luce Texels into one compiled unit without changing their Fabric identity.

### Native code expands the trusted surface

Keep LLVM and ordinary evaluation out of the Loom storage process. Restrict runtime symbols, enforce W^X, and publish output only after validation.

### No imports make reuse awkward

Accept some repetition in 0.1. Do not prematurely recreate package management. Gather real examples and solve reuse at the Fabric level.

### Structures can become a second hidden object system

Keep them value-only: no identity, methods, inheritance, lifetime hooks, or hidden mutation. Texels remain the only independently identified elements.

### LLVM leaks into the language

Prevent this organizationally. No LLVM type, handle, target detail, intrinsic name, or object format may appear in Luce syntax, Port schemas, Luce IR semantics, or the Loom compiler API.

---

## 20. Decisions to make during Phase 0

These decisions are bounded and should be resolved with executable examples:

1. Whether the language keyword is `fn` or the more Python-like `def`.
2. Whether trailing commas are required, allowed, or omitted in multiline constructs.
3. Exact syntax for fixed arrays and typed slices.
4. Whether local structure fields may be updated directly or only by constructing a new value.
5. Whether `while` ships in 0.1 or waits for worker preemption.
6. The first set of numeric and string intrinsics.
7. Whether `Option[T]` belongs in 0.1.
8. Whether recursion is disabled or permitted with a stack budget.
9. The representation of an opaque large Fabric value in the Port type system.
10. The exact UI value emitted by the first Luce View.

None of these changes the architecture.

---

## 21. The line to hold

Luce should become expressive through combinations of a few ordinary programming ideas:

- functions organize computation;
- `let` and `var` organize temporary values;
- structures organize related data;
- Ports connect the evaluator to its Texel;
- Fibers connect the Texel to the Fabric;
- demand decides when computation occurs;
- Loom owns persistence, caching, authority, and publication.

The first implementation may depend on LLVM. Luce programs do not.

The first implementation runs on macOS and Linux. Luce semantics do not belong to either.

The evaluator is a program inside a Texel. It is not a miniature application container, and it does not need a miniature operating system hidden inside it.

That is the sweet spot: a language capable enough to make Texels genuinely programmable, but small enough that LuciaOS can eventually compile it entirely on its own.

---

## References

- [LLVM project and current releases](https://llvm.org/)
- [LLVM C TargetMachine API](https://llvm.org/docs/doxygen/llvm-c_2TargetMachine_8h.html)
- [LLVM ORC LLJIT C API](https://llvm.org/docs/doxygen/group__LLVMCExecutionEngineLLJIT.html)
- [LLVM opaque pointers](https://llvm.org/docs/OpaquePointers.html)
- [Apple: Porting JIT compilers to Apple silicon](https://developer.apple.com/documentation/Apple-Silicon/porting-just-in-time-compilers-to-apple-silicon)
- [Apple: Allow execution of JIT-compiled code entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-jit)

---

## Implementation status (LuciaOS)

Luce 0.1 is implemented in `luce/` as its own Zig module, and the lucia
terminal makes Texels compute with it.  Where this document and the
implementation differ, this section is current.

**Implemented, per the plan:**

- Frontend (`source.zig`, `lexer.zig`, `parser.zig`, `ast.zig`,
  `diagnostics.zig`): byte-span source model, indentation-aware lexer
  (four-space blocks, tabs rejected, parentheses suspend newlines),
  recursive-descent + Pratt parser with line-level recovery, structured
  diagnostics with stable codes.
- Semantic analysis (`types.zig`, `analyzer.zig`): the Port schema, not
  the source, decides input/output members; static types with no
  implicit conversion; immutable `let` and parameters; no shadowing;
  return-path checking; struct-cycle detection; named, complete struct
  construction; explicit `Int()`/`Float()` conversions; the builtin set
  (`abs min max clamp sqrt floor ceil len assert trap`).
- Typed Luce IR (`ir.zig`): functions, basic blocks, virtual registers,
  explicit input loads/output stores/traps, a full verifier, and a
  deterministic readable printer.  Registers never cross blocks —
  mutable locals carry loop/branch state, which lowers directly to
  stack slots in a native backend.
- Execution (`backend.zig`, `interpreter.zig`): the backend boundary
  runs a verified program against an immutable Input frame and a
  scratch Output frame under an explicit budget; the first engine is a
  deterministic IR interpreter with checked integer arithmetic, IEEE
  float semantics, range-checked conversions, a step budget (the
  deadline analog), and a call-depth limit.  Unavailable read inputs
  gate evaluation; failure publishes nothing.
- Loom integration (`apps/lucia/luce_service.zig`, the `code` command):
  a Texel owns Luce source as content; `eval luce` assigns the
  evaluator; compilation is cached by texel revision (derived and
  disposable); diagnostics report at code time and at demand time;
  outputs the program does not write fall back to stored sources (the
  name port keeps working).

**Decisions taken from section 20:** `fn`; trailing commas allowed;
struct fields of `var` locals update directly (as functional IR
updates); `while` ships, guarded by the step budget; recursion is
permitted under a call-depth budget; `for` iterates `range(start, end)`
over Ints; no `Option[T]`.

**Deferred, in plan order of need:** the LLVM native backend (slots in
behind `backend.zig` without changing anything in front of it), sized
integer and `F32` types, fixed arrays and borrowed slices, the durable
cache envelope with version/target hashing (today's cache is in-memory
per session, keyed by texel revision), worker-process isolation and the
macOS JIT entitlement path, and two-tier compilation.

### Since the first cut

- **Fabric builtins** (`luce/fabric.zig`): `create_texel`, `texel_input`,
  `texel_output`, `texel_content`, `texel_evaluator`, `texel_set`.  The
  language stays pure — the builtins record texel-creation *intents* in
  the evaluation arena, returned through the backend boundary on
  success and discarded on trap, exactly the effect-intent shape from
  section 10.3.  Gated by `CompileOptions.allow_fabric`: only a trusted
  host enables them.  The lucia terminal applies pending intents as one
  transaction after each dispatch, in bounded reconcile rounds.  This
  is the bootstrap loop: template texels whose Luce content writes new
  texels — including new templates.
- **`luce ID|NAME`** runs a texel's code once, on demand: inputs
  resolve through the session spool, outputs print without publishing,
  intents apply.  Templates are fired by hand as many times as needed.
- **`lucia open IMAGE --luce FILE`** runs standalone bootstrap source
  (no ports, fabric enabled) headlessly against an image — the
  scripting path for populating a Fabric with template texels.
- **The `edit` command** is the in-terminal editing surface the plan's
  section 15 anticipates: a ports pane (the schema side) and a code
  pane (line numbers, real-lexer syntax highlighting, Luce auto-indent)
  over a private clone, committed atomically with compile diagnostics
  in the status line.
- **`create_image(path, pages)`** completes the headless story: image
  creation is an intent like texel creation, performed by the host
  through the same `image.zig` code as `lucia create`.  `lucia run
  FILE.luc` (or `lucia --luce FILE.luc`) runs a standalone script that
  creates its own images and weaves texels into the first one —
  bootstrap from nothing, no terminal attached.
- **The operations layer** (`apps/lucia/ops.zig`): the same Fabric
  operations are reachable from terminal commands, from Luce fabric
  intents, and from plain Zig code; all three call one tested set of
  functions, so behavior cannot drift between access directions.
