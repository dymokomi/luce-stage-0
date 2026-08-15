# SOFTWARE_DESIGN.md

> **Where this sits.**  This is the design standard for the repository —
> how to decide what a module is, what it hides, and what it is called.
> [CODING_GUIDE.md](CODING_GUIDE.md) is the same argument expressed in
> Zig and in this tree's own conventions, and it wins on anything it
> covers: allocation and ownership, error sets, naming, comments, test
> placement, when a file may be split.  The two agree on the substance
> — deep modules, no ceremony, no splitting for length, comments that
> say why — so where this file is general, read the guide for the
> local form.

## Purpose

This file defines how coding agents should design, modify, and review software in this repository.

The goal is not merely to produce code that works. The goal is to produce code that remains understandable and easy to change as the system grows.

These rules synthesize two complementary design philosophies:

- minimize complexity by creating deep modules, hiding information, defining strong abstractions, and designing for the reader.
- use clear names, coherent functions, disciplined tests, explicit boundaries, and continuous cleanup.

Where the philosophies disagree, prefer **lower total cognitive load over mechanically small code**.

A short function is not automatically good.
A class is not automatically better than a struct.
An abstraction is not automatically better than duplication.
A comment is not automatically a failure.
A design pattern is not automatically good design.

Optimize for a codebase that a competent engineer can understand, modify, debug, and extend with confidence.

---

# 1. The Primary Goal: Minimize Complexity

Complexity is anything that makes the system harder to understand or modify.

Watch for three manifestations:

1. **Change amplification**  
   A simple conceptual change requires edits in many places.

2. **Cognitive load**  
   Understanding one operation requires keeping too many concepts, states, dependencies, or files in mind.

3. **Unknown unknowns**  
   It is unclear what must change, what depends on what, or where important behavior lives.

When choosing between designs, prefer the one that reduces these costs over the lifetime of the codebase.

Do not optimize for:
- fewest lines,
- fewest files,
- most abstractions,
- most reuse,
- most design patterns,
- smallest functions,
- cleverness,
- theoretical extensibility that has no current evidence.

---

# 2. Complexity Is Incremental

Complexity usually enters a system through many individually reasonable shortcuts.

Do not justify poor structure with:
- "it's only one special case,"
- "we can clean it up later,"
- "this is faster for now,"
- "it's just one extra flag,"
- "it's only used here."

Small compromises accumulate.

Whenever modifying code:

1. make the requested behavior correct;
2. preserve or improve the surrounding design;
3. remove nearby accidental complexity when it can be done safely;
4. do not perform unrelated large rewrites.

Leave the touched area slightly easier to understand than before.

---

# 3. Design Modules to Be Deep

A module is good when it provides substantial useful behavior through a small, simple interface.

Prefer:

```text
small interface
large hidden implementation
```

over:

```text
large interface
small implementation
```

A deep module hides:
- representation,
- algorithms,
- policy details,
- state transitions,
- protocol details,
- error-handling mechanics,
- third-party APIs,
- platform-specific behavior.

A shallow module exposes complexity without hiding enough to justify its existence.

Before creating a new abstraction, ask:

> What complexity does this abstraction hide from its callers?

If the answer is "almost none," reconsider it.

Do not create:
- one-line wrapper classes,
- pass-through managers,
- interfaces with one implementation merely for ceremony,
- helpers that simply rename another call,
- tiny types that force readers to jump between files without hiding information.

Small modules are not inherently clean. Deep modules are the target.

---

# 4. Information Hiding Is a First-Class Design Tool

Each important design decision should ideally live in one place.

Hide decisions such as:
- storage format,
- wire protocol,
- memory representation,
- parser strategy,
- caching policy,
- synchronization mechanism,
- external API conventions,
- platform quirks,
- error translation.

If several modules independently know the same internal fact, that fact has leaked.

Symptoms of information leakage:
- repeated field interpretation,
- repeated serialization rules,
- repeated magic offsets,
- repeated conditionals for the same policy,
- callers manually coordinating an object's internal state,
- callers knowing the order of internal operations,
- vendor-specific types flowing through unrelated layers.

When you notice leakage, move the knowledge behind an appropriate boundary.

---

# 5. Prefer General-Purpose Core Abstractions

Core modules should usually express the underlying capability rather than a narrow current use case.

Prefer:

```text
ByteReader.read(offset, destination)
```

over:

```text
readUserAvatarHeader()
readThumbnailChunk()
readProjectMetadataChunk()
```

when those operations are manifestations of the same underlying mechanism.

General-purpose does **not** mean speculative abstraction.

A general-purpose module should:
- solve current requirements,
- expose the fundamental capability cleanly,
- avoid baking one caller's policy into the lower layer.

Do not add hooks, strategies, interfaces, or configuration for imagined future requirements.

Generalize around a real underlying concept, not around hypothetical reuse.

---

# 6. Separate General-Purpose Mechanism from Special-Purpose Policy

Lower layers should implement mechanisms.
Higher layers should decide policy.

Examples:

```text
storage layer:
    read block
    write block
    flush

document layer:
    choose which blocks represent a document

compiler IR:
    represent control flow

optimizer:
    decide which transformations to apply
```

Do not force low-level modules to know high-level use cases merely because doing so saves a few lines in one caller.

Dependency direction should generally point from volatile outer concerns toward stable inner concepts.

---

# 7. Define Errors Out of Existence When Possible

The best error handling is often an interface where a potential error is no longer exceptional.

Before adding an error case, ask whether the API can make the condition harmless or structurally impossible.

Examples:
- deleting a nonexistent item can be idempotent;
- closing an already closed resource may be safe;
- requesting an empty range may return an empty result;
- a collection lookup can return an optional instead of throwing;
- invalid state transitions can be made unrepresentable.

Do not erase genuinely important failures.

Use this principle when simplifying semantics does not hide information the caller needs.

---

# 8. Make Invalid States Difficult or Impossible to Represent

Prefer types and APIs that encode invariants.

Use:
- enums instead of arbitrary integers,
- dedicated IDs instead of interchangeable numeric values,
- validated constructors,
- tagged unions for distinct states,
- immutable values where mutation is unnecessary,
- explicit ownership and lifetime rules,
- result/error types where failure is part of normal control flow.

Do not rely on comments such as:

```text
// must be non-negative
// call initialize() first
// only valid after finalize()
```

when the interface can enforce the rule.

---

# 9. Names Must Reveal the Model

Names are part of the architecture.

Choose names that reveal:
- what a thing represents,
- why it exists,
- what operation it performs,
- what abstraction level it belongs to.

Prefer domain terms over vague generic words.

Avoid names such as:
- `data`,
- `info`,
- `item`,
- `object`,
- `thing`,
- `manager`,
- `processor`,
- `helper`,
- `utils`,
- `handler`

unless those words genuinely describe the concept.

Do not create multiple terms for the same concept without a semantic distinction.

If the code uses `load`, `fetch`, `get`, and `retrieve`, they should mean different things or be unified.

Short names are acceptable in narrow conventional scopes:

```text
i
x
lhs
rhs
ty
pc
ir
ast
```

Long-lived or broad concepts deserve more descriptive names.

Do not encode information already provided by the type system or tooling.

---

# 10. Prefer Obvious Code Over Clever Code

Code should be optimized for the reader.

Avoid:
- surprising operator tricks,
- unnecessary metaprogramming,
- hidden control flow,
- clever one-liners,
- dense boolean expressions,
- unnecessary abstraction tricks,
- unconventional constructs without a strong benefit.

If a reader must stop and decode how the syntax works before understanding what the program means, simplify it.

A straightforward implementation is usually better than an ingenious implementation with the same behavior.

---

# 11. Functions Should Be Cohesive, Not Mechanically Tiny

A function should perform one coherent conceptual task.

That does **not** imply an arbitrary line limit.

Do not split a function merely because it is long.

Extract a function when doing so:
- introduces a meaningful concept,
- hides implementation detail,
- removes distracting complexity,
- isolates reusable behavior,
- clarifies an abstraction boundary,
- makes a unit independently testable for a good reason.

Keep code together when:
- the statements form one algorithm,
- local state is important to understanding it,
- extraction would require many parameters,
- extraction would hide control flow,
- extraction would force readers to jump around without reducing complexity.

Prefer a readable 40-line cohesive algorithm over fifteen 3-line functions that must be mentally reassembled.

Method length is a signal, not a rule.

---

# 12. Keep Abstraction Levels Coherent

Within a function, avoid mixing high-level intent with unrelated low-level mechanics.

Bad:

```text
compile module
    resolve imports
    malloc 48 bytes
    check types
    write byte 0x7f
    optimize
```

Better:

```text
compile module
    resolve imports
    check types
    lower module
    optimize module
    emit module
```

with lower-level details hidden behind those operations.

Do not over-extract simple operations merely to make code read like prose.

The goal is conceptual consistency, not theatrical formatting.

---

# 13. Keep Important Logic Together

Related behavior should be physically close when practical.

Avoid designs where understanding one operation requires visiting many unrelated files.

Prefer locality for:
- state transitions,
- algorithms,
- invariants,
- parsing rules,
- protocol handling,
- optimization passes,
- lifecycle logic.

Do not confuse separation with modularity.

Splitting code into more files, classes, services, or functions does not automatically reduce complexity.

A good module hides complexity while keeping its internal implementation coherent.

---

# 14. Avoid Temporal Coupling

Code should not require callers to know secret sequences such as:

```text
create()
set_mode()
initialize()
prepare()
execute()
finalize()
```

unless the domain genuinely contains those phases.

When ordering matters:
- encode it in the API,
- encapsulate the sequence,
- use distinct state types,
- or make the required transition explicit.

Do not force callers to memorize hidden protocols.

---

# 15. Avoid Excessive Parameters, but Keep Data Flow Explicit

Large parameter lists can indicate missing structure.

If several values naturally belong together, group them into a meaningful value type.

However, do not reduce parameter count by hiding dependencies in:
- globals,
- singletons,
- mutable object fields,
- service locators,
- ambient context.

Explicit data flow is often easier to reason about than hidden state.

A function with five meaningful inputs can be cleaner than a zero-argument method that reads five mutable fields.

Boolean parameters are suspicious when they select substantially different behavior.

Prefer:

```text
renderPreview(...)
renderFinal(...)
```

or:

```text
render(..., RenderMode.preview)
```

over:

```text
render(..., true)
```

Choose based on whether the behaviors are genuinely one operation with modes or distinct operations.

---

# 16. Minimize Mutable Shared State

Mutable shared state increases cognitive load because readers must understand:
- who can mutate it,
- when mutation occurs,
- what order matters,
- what invariants are preserved,
- whether concurrent access is possible.

Prefer:
- local state,
- explicit ownership,
- immutable values,
- narrowly scoped mutation,
- message passing,
- clear synchronization boundaries.

When mutation is necessary, make its location and lifetime obvious.

---

# 17. Objects and Data Are Different Tools

Do not force every concept into an object hierarchy.

Use objects when:
- representation should be hidden,
- behavior belongs with state,
- implementations may vary behind a stable interface.

Use plain data when:
- the representation is intentionally transparent,
- many independent operations operate over a stable set of variants,
- exhaustive traversal is valuable,
- serialization or layout matters.

For closed sets of variants, tagged unions and exhaustive switches may be better than polymorphism.

For open sets of interchangeable implementations, polymorphism may be better.

Choose based on the likely axis of change.

---

# 18. Avoid Shallow Class Hierarchies and Ceremony

Do not introduce:
- factories,
- interfaces,
- abstract base classes,
- dependency-injection layers,
- visitor frameworks,
- strategy objects

unless they solve an actual dependency or variability problem.

An interface with one implementation is acceptable when it forms a deliberate architectural boundary, but not merely because "interfaces are cleaner."

Every abstraction has a cost:
- another name,
- another concept,
- another location,
- another dependency edge,
- another thing to navigate.

Require the abstraction to repay that cost.

---

# 19. Prefer Composition and Explicit Boundaries

Inheritance creates semantic coupling between base and derived behavior.

Use inheritance only when substitutability is genuine and stable.

Prefer composition when:
- behavior is assembled from capabilities,
- implementation details vary independently,
- inheritance would expose protected internals,
- a subclass would need to disable or reinterpret base behavior.

Subtypes must preserve the behavioral contract of their base abstraction.

Matching method signatures is not enough.

---

# 20. Use Comments for Information Code Cannot Express

Do not comment obvious syntax.

Bad:

```c
// Increment count.
count++;
```

Good comments explain:
- why a design is this way,
- invariants,
- constraints,
- subtle ownership rules,
- non-obvious performance decisions,
- protocol quirks,
- numerical assumptions,
- concurrency requirements,
- specification references,
- why a tempting alternative is incorrect.

Examples:

```text
// Recovery intentionally leaves the closing delimiter unconsumed;
// the enclosing production owns it.
```

```text
// Keep nodes in insertion order. Serialized IDs are externally stable
// and changing this ordering would invalidate existing cache entries.
```

```text
// Do not merge these loads. On ARM this mapping may point to device memory.
```

Comments should describe information that would otherwise be lost.

If a comment merely compensates for bad naming or tangled code, improve the code instead.

Delete stale comments aggressively.

---

# 21. Document Interfaces Before Implementations

For important public interfaces, document:

- what the abstraction represents,
- caller-visible behavior,
- inputs and outputs,
- ownership,
- mutation,
- failure modes,
- thread-safety expectations,
- performance characteristics when relevant,
- invariants callers may rely on.

Documentation should describe the abstraction, not narrate its implementation.

A user of a module should not need to read its source to use it correctly.

If the interface cannot be documented simply, the abstraction may itself be too complicated.

---

# 22. Comments Are Part of Design

Write interface documentation early enough that it can expose a bad API before implementation hardens.

If describing a module requires:
- many exceptions,
- subtle ordering rules,
- extensive knowledge of internal state,
- many warnings,
- long descriptions of parameter interactions,

redesign the interface.

Documentation is not merely cleanup performed after coding.

---

# 23. Separate Interface Complexity from Implementation Complexity

It is often acceptable for an implementation to be sophisticated if that sophistication produces a simple interface.

Do not push complexity onto every caller merely to keep one module internally simple.

A difficult implementation may be the correct design when it:
- centralizes knowledge,
- removes repeated logic,
- hides protocol details,
- eliminates special cases for callers,
- produces a strong abstraction.

Complexity should live in as few places as possible.

---

# 24. Pull Complexity Downward

When deciding which layer should handle a complexity, prefer placing it in the lower-level module if that module can hide it cleanly for many callers.

Examples:
- normalize paths inside the path abstraction;
- translate vendor errors inside the vendor adapter;
- handle byte ordering inside serialization;
- manage cache consistency inside the cache module.

Do not make every caller repeat defensive or mechanical logic that can be encapsulated once.

Do not pull application-specific policy downward.

---

# 25. Avoid Configuration When a Good Default Exists

Configuration increases the public surface area and forces every user to understand another decision.

Before exposing an option, ask:

> Can the module make the right choice automatically?

Prefer good defaults and adaptive behavior.

Expose configuration when:
- users genuinely need different semantics,
- automatic selection is unreliable,
- performance tradeoffs materially differ,
- external constraints require control.

Do not expose implementation knobs simply because they already exist internally.

---

# 26. Eliminate Special Cases

Special cases multiply complexity.

When possible, design representations and algorithms so edge cases flow through normal logic.

Prefer:
- sentinel objects,
- empty collections,
- normalized representations,
- uniform state machines,
- canonical forms,
- idempotent operations,

when they simplify the whole system.

Do not introduce a more complicated abstraction solely to eliminate one obvious branch.

The metric is total complexity.

---

# 27. Duplication Is a Smell, Not an Automatic Refactoring Command

Remove duplication when duplicated code represents duplicated knowledge.

Do not unify code simply because two blocks currently look similar.

Ask:

> Must these pieces change together for the same conceptual reason?

If yes, centralize the knowledge.

If no, keeping them separate may be safer than creating a false abstraction.

Prefer a little duplication over the wrong abstraction.

---

# 28. Different Layers May Need Different Representations

Do not force one universal data model through the entire system.

A parser, semantic analyzer, optimizer, serializer, UI, and database may each need different representations.

Translate at meaningful boundaries.

A representation optimized for one phase should not distort every other phase merely to avoid conversion code.

Conversion code is often cheaper than permanent cross-layer coupling.

---

# 29. Dependency Boundaries Should Protect the Core

Third-party libraries and platform APIs should touch as little core code as practical.

Wrap volatile dependencies behind interfaces owned by the application when doing so provides meaningful isolation.

Translate:
- external types,
- external errors,
- external lifecycle rules,
- platform-specific concepts

into internal concepts at the boundary.

Do not reproduce an entire third-party API behind a pointless one-to-one wrapper.

Wrap semantics, not syntax.

---

# 30. Preserve Important Options

Delay difficult-to-reverse decisions when doing so has low cost.

Examples:
- storage engine,
- compiler backend,
- transport,
- UI framework,
- persistence format,
- vendor API.

This does not mean abstract everything in advance.

Keep options open by establishing narrow boundaries around volatile decisions, not by building speculative frameworks.

Make irreversible decisions when enough information exists to justify them.

---

# 31. Prefer Deterministic and Explicit Behavior

Given the same explicit inputs, code should behave predictably whenever the domain permits it.

Avoid:
- hidden environmental dependencies,
- global mutable configuration,
- implicit current directories,
- ambient locale assumptions,
- unordered output where ordering matters,
- invisible time dependencies,
- nondeterministic tests.

Pass important dependencies explicitly or encapsulate them behind controlled boundaries.

Determinism improves debugging, testing, caching, and reproducibility.

---

# 32. Error Handling Must Preserve the Main Story

The normal algorithm should remain readable.

Do not bury every operation beneath repetitive error plumbing.

Use the language's appropriate error mechanism:
- typed results,
- exceptions,
- error unions,
- optionals,
- status values,

according to its idioms and failure semantics.

Do not mechanically translate Java exception advice into languages where explicit error values are clearer.

Errors should carry enough context to answer:
- what failed,
- on what input/resource,
- during which operation,
- why, when known.

Do not swallow failures.

---

# 33. Tests Are Part of the Design

Tests must be:
- readable,
- deterministic,
- easy to run,
- isolated where appropriate,
- fast enough for their intended feedback loop,
- focused on behavior rather than implementation trivia.

Prefer one conceptual behavior per test.

Multiple assertions are acceptable when they describe one coherent result.

Do not couple tests unnecessarily to:
- private implementation details,
- call counts,
- arbitrary internal decomposition,
- exact incidental formatting,
- temporary object structure.

Tests should enable refactoring, not prevent it.

---

# 34. Test Boundaries and Invariants Aggressively

Pay particular attention to:
- zero,
- one,
- empty,
- maximum/minimum,
- overflow,
- malformed input,
- invalid state transitions,
- resource failure,
- concurrency,
- repeated operations,
- cancellation,
- partial failure.

When fixing a defect, add a regression test when practical.

For compilers, parsers, protocols, storage engines, and similar systems, also consider:
- fuzzing,
- property testing,
- golden tests,
- round-trip tests,
- differential testing,
- mutation testing,
- optimization-equivalence tests.

---

# 35. Do Not Mock Everything

Mocks create coupling to interaction details.

Prefer real, lightweight dependencies when they are:
- deterministic,
- fast,
- local,
- easy to construct.

Use test doubles when they isolate:
- expensive systems,
- nondeterministic systems,
- external services,
- failure scenarios,
- difficult boundary conditions.

Test behavior, not implementation choreography.

---

# 36. Keep Build and Test Workflows Obvious

A developer or agent should be able to discover and execute the primary workflows easily.

Prefer one obvious command for:
- build,
- unit tests,
- full tests,
- lint/format,
- package or release validation.

Avoid undocumented rituals and machine-specific setup.

Do not declare work complete if the relevant build or tests have not been run, unless they cannot be run in the current environment. State that limitation explicitly.

---

# 37. Refactor in Small Behavior-Preserving Steps

When restructuring existing code:

1. understand the current behavior;
2. establish or inspect tests;
3. make one conceptual change;
4. run relevant tests;
5. continue.

Do not mix broad refactoring with broad behavior changes unless necessary.

Small transformations make failures easier to localize and reasoning easier to verify.

---

# 38. Do Not Refactor Merely to Match Personal Taste

Preserve established project conventions unless they create meaningful complexity.

Do not:
- rename whole subsystems casually,
- reformat unrelated files,
- replace working patterns with preferred patterns,
- rewrite code solely because another style is fashionable.

Every change has review and regression cost.

Refactor when the result materially improves clarity, correctness, isolation, testability, or changeability.

---

# 39. Red Flags: Shallow Modules

Watch for modules whose interface is nearly as complicated as their implementation.

Typical symptoms:
- dozens of getters,
- one method per field,
- pass-through wrappers,
- callers orchestrating internal operations,
- classes that contain almost no logic,
- interfaces mirroring vendor APIs.

Consider merging, deepening, or removing them.

---

# 40. Red Flags: Information Leakage

Watch for:
- the same constant interpreted in multiple modules,
- repeated serialization logic,
- repeated knowledge of object internals,
- duplicated state-transition rules,
- multiple modules knowing a storage layout,
- vendor-specific types leaking through the core,
- callers manually maintaining invariants.

Centralize the knowledge.

---

# 41. Red Flags: Temporal Decomposition

Do not split modules merely according to execution order.

Weak decomposition:

```text
ReadPhase
ParsePhase
ValidatePhase
SavePhase
```

may be appropriate for a real compiler pipeline, but it is harmful when each phase manipulates the same hidden concept and exposes intermediate details only because "this happens next."

Prefer decomposition around coherent knowledge and abstractions, not just chronology.

Ask whether each phase owns a distinct representation, invariant, or responsibility.

---

# 42. Red Flags: Pass-Through Methods

A method that simply forwards arguments to another method may indicate:
- a shallow layer,
- misplaced responsibility,
- excessive decomposition.

Pass-through methods are justified when they:
- preserve an abstraction boundary,
- translate concepts,
- enforce invariants,
- add meaningful policy,
- hide dependency structure.

Otherwise, remove the layer or expose the appropriate underlying abstraction.

---

# 43. Red Flags: Repetition

Repetition can mean:
- duplicated knowledge,
- missing abstraction,
- poor API design,
- leaked implementation details.

But verify conceptual sameness before deduplicating.

Do not create a generic abstraction whose parameters are more complicated than the original duplicated code.

---

# 44. Red Flags: Special-General Mixtures

A general-purpose module should not contain one caller's special-case policy.

Bad signs:
- `if caller == ...`,
- UI rules inside storage,
- application names inside generic utilities,
- platform-specific behavior inside domain models,
- compiler backend rules inside language semantics.

Move special policy upward.

---

# 45. Red Flags: Vague Objects

Be suspicious of classes named:
- `Manager`,
- `Context`,
- `Service`,
- `Engine`,
- `Helper`,
- `Processor`,
- `Controller`,
- `Util`

These names can be valid, but often indicate an abstraction whose responsibility is unclear.

Ask:
- What knowledge does this object own?
- What complexity does it hide?
- Why do these operations belong together?

Rename or redesign when the answer is weak.

---

# 46. Red Flags: Too Many Tiny Methods

Tiny methods can create:
- navigation overhead,
- hidden control flow,
- poor locality,
- excessive parameter passing,
- state stored in fields merely to share it.

Do not extract code just to shorten a method.

A method should be as long as necessary to present one coherent abstraction clearly, and no longer.

---

# 47. Red Flags: Excessive Exposure

Do not expose:
- fields,
- getters,
- setters,
- configuration,
- internal collections,
- implementation types

without a caller-level need.

Every public element is a commitment.

Prefer the smallest interface that provides the full useful abstraction.

---

# 48. Red Flags: Comments Explaining Bad APIs

If correct usage requires paragraphs of warnings, consider redesigning the API.

Comments should explain inherent complexity, not accidental complexity created by the interface.

---

# 49. Red Flags: Clever Reuse

Do not reuse an abstraction merely because it can technically support another use case.

Reuse is good when semantics align.

If two concepts have different invariants, ownership, lifecycle, or reasons to change, sharing an abstraction may make both worse.

Prefer clarity over maximum reuse.

---

# 50. Red Flags: Premature Extensibility

Do not design for imaginary plugins, backends, transports, databases, or alternate algorithms without evidence that the variation is likely.

Each extension point creates permanent complexity.

Build today's system so its important decisions are well isolated. That usually makes tomorrow's extension easier without predicting its exact form.

---

# 51. Red Flags: Hidden Global Context

Avoid code whose behavior depends on invisible state such as:
- process globals,
- singleton registries,
- mutable static variables,
- current working directory,
- global allocators,
- hidden thread-local state,
- implicit environment configuration.

Use explicit ownership and dependency boundaries.

Global state may be justified for immutable process-wide constants or carefully controlled infrastructure. Treat mutable global state as a significant design decision.

---

# 52. Red Flags: Boolean Blindness

Calls like:

```text
open(path, true, false, true)
```

are unacceptable.

Use named options, enums, or distinct functions.

The call site should reveal intent without requiring the reader to inspect the function declaration.

---

# 53. Red Flags: Magic Values

Important numbers, strings, flags, offsets, sentinel values, and bit masks should be represented by meaningful concepts.

Do not replace every literal mechanically.

`0`, `1`, and simple local mathematical constants may be obvious.

Name values when their *meaning*, not merely their value, matters.

---

# 54. Red Flags: Long Dependency Chains

Avoid code that navigates through another module's internal object graph:

```text
a.getB().getC().getD().perform()
```

This creates coupling to intermediate structure.

Ask the abstraction that owns the operation to perform it, or expose deliberate data if the structure is genuinely public.

Do not apply this rule mechanically to transparent data structures.

---

# 55. Red Flags: Excessive Inheritance

If understanding a class requires reading several ancestors, the hierarchy carries significant cognitive cost.

Prefer:
- shallow hierarchies,
- explicit composition,
- capability interfaces,
- direct data representations.

Inheritance should model true substitutability, not code reuse alone.

---

# 56. Red Flags: Dependency Cycles

Module dependency cycles make independent reasoning, testing, and reuse difficult.

When a cycle appears:
- identify the shared concept,
- move it to an appropriate lower-level module,
- introduce a narrow dependency inversion if meaningful,
- reconsider the module boundaries.

Do not break cycles with arbitrary interfaces that preserve the same conceptual coupling.

---

# 57. Decide What Matters

Not every decision deserves equal attention.

Spend design effort on choices that:
- affect many modules,
- are difficult to reverse,
- establish long-lived abstractions,
- determine data ownership,
- determine persistence formats,
- define concurrency behavior,
- define public APIs,
- define language or protocol semantics.

Do not spend the same energy on:
- local variable spelling,
- trivial private helper structure,
- formatting handled by tools,
- easily reversible implementation details.

Focus design attention where mistakes become expensive.

---

# 58. Consistency Matters, but Good Design Matters More

Follow existing conventions for:
- naming,
- formatting,
- errors,
- testing,
- ownership,
- file organization.

However, do not perpetuate a harmful pattern merely for consistency.

When introducing a better pattern:
- keep the scope deliberate,
- avoid half-migrations,
- explain the architectural reason if non-obvious.

Mechanical consistency is subordinate to reducing complexity.

---

# 59. Performance Is Part of Correct Design When It Matters

Do not sacrifice clear architecture for speculative micro-optimization.

Also do not use abstraction purity to ignore real performance requirements.

For hot paths:
- measure first;
- understand allocation,
- memory layout,
- cache behavior,
- branch behavior,
- synchronization,
- copying,
- algorithmic complexity.

Keep performance-sensitive algorithms locally understandable.

A contiguous loop can be cleaner than five abstractions that hide its costs.

Record non-obvious performance decisions in comments with enough rationale to prevent accidental regression.

---

# 60. Concurrency Requires Stronger Boundaries

Concurrency multiplies complexity.

Prefer:
- ownership partitioning,
- immutable messages,
- independent workers,
- narrowly scoped locks,
- minimal shared mutable state.

Separate concurrency policy from domain logic where practical.

Do not add concurrency until the workload justifies it.

Tests for concurrent code should include:
- startup,
- shutdown,
- cancellation,
- partial failure,
- different worker counts,
- repeated execution,
- race detection when tooling permits.

Never dismiss intermittent failures as harmless.

---

# 61. Agent-Specific Rule: Read Before Editing

Before making a significant change:

1. inspect the relevant module;
2. inspect its callers;
3. inspect relevant tests;
4. identify existing conventions;
5. understand the abstraction boundary;
6. determine whether the requested change belongs there.

Do not infer architecture from filenames alone.

Do not create a new abstraction before checking whether an existing one already owns the concept.

---

# 62. Agent-Specific Rule: Preserve the Existing Mental Model

When modifying an established system, prefer changes that fit its existing conceptual vocabulary.

Do not introduce synonymous concepts casually.

If the repository calls something a `Module`, do not introduce `Package`, `Unit`, or `Component` for the same thing without a real distinction.

Vocabulary fragmentation creates complexity.

---

# 63. Agent-Specific Rule: Prefer the Smallest Coherent Change

Implement the requested behavior with the smallest change that leaves the design coherent.

"Smallest" does not mean fewest characters.

A slightly larger change is preferable when it:
- puts responsibility in the correct module,
- prevents duplication,
- preserves an invariant,
- avoids leaking a dependency.

Do not perform speculative architectural rewrites.

---

# 64. Agent-Specific Rule: Never Hide Uncertainty Behind Architecture

If you do not understand a concept yet, do not create a generic abstraction around it.

Prefer a direct implementation until the shape of the problem becomes clear.

Wrong abstractions are more expensive than modest duplication.

---

# 65. Agent-Specific Rule: Do Not Manufacture Patterns

Do not introduce a named design pattern merely because the code resembles a textbook opportunity.

Patterns are vocabulary for recurring solutions, not objectives.

Use a pattern only when it clearly lowers complexity.

---

# 66. Agent-Specific Rule: Explain Non-Obvious Design Changes

When a change alters module boundaries, ownership, persistence, concurrency, or public APIs, explain the reason in the change summary.

State:
- what complexity existed,
- what responsibility moved,
- what invariant or boundary now exists,
- why this structure is preferable.

Do not narrate obvious line-by-line edits.

---

# 67. Agent-Specific Rule: Verify After Editing

After modifying code:

1. format using project tooling;
2. build the affected target;
3. run focused relevant tests;
4. run broader tests when feasible;
5. inspect the diff for accidental changes;
6. check for dead code or stale comments introduced by the change.

Do not claim success if verification failed.

Report failures accurately.

---

# 68. Agent-Specific Rule: Review the Diff as a Reader

Before finishing, reread the change without relying on the context used to write it.

Ask:

- Can I tell what each new concept represents?
- Is the control flow obvious?
- Did I leak information between modules?
- Did I create a shallow abstraction?
- Did I create a new special case?
- Did I hide a dependency?
- Are comments explaining why rather than what?
- Can the new behavior be tested independently?
- Did I make future changes easier or harder?
- Would another engineer know where to modify this six months from now?

Fix problems found during this review.

---

# 69. Decision Framework for New Abstractions

Before creating a new module, class, interface, function family, or generic mechanism, answer:

### What complexity does it hide?
If little or none, do not create it.

### Who owns the knowledge?
Put the abstraction near the information needed to implement it correctly.

### What is likely to change?
Separate things that change for different reasons.

### What should callers not need to know?
Hide those details.

### Is this variation real today?
If not, avoid speculative extension points.

### Will the abstraction reduce total cognitive load?
If it only moves complexity elsewhere, reconsider.

### Can the interface be explained simply?
If not, redesign before adding more implementation.

---

# 70. Decision Framework for Function Extraction

Extract when the new function:

- names a real concept;
- hides distracting mechanics;
- removes meaningful duplication;
- isolates a distinct abstraction level;
- makes control flow clearer.

Do not extract when it:

- merely shortens the parent function;
- requires passing most local variables;
- hides a simple sequential algorithm;
- creates one-line forwarding methods;
- makes the reader navigate elsewhere for trivial details.

---

# 71. Decision Framework for Comments

Add a comment when future readers need information that cannot be recovered reliably from the code.

Good subjects:
- why,
- invariants,
- constraints,
- protocol behavior,
- external requirements,
- rejected alternatives,
- performance reasoning,
- concurrency assumptions.

Do not comment:
- syntax,
- obvious control flow,
- names that should simply be improved,
- historical edits available in version control.

---

# 72. Decision Framework for Reuse

Before deduplicating, ask:

1. Are these implementations expressing the same knowledge?
2. Must they evolve together?
3. Can one abstraction describe both without flags and special cases?
4. Does the shared abstraction become simpler than the separate versions?

If not, keep them separate.

---

# 73. Decision Framework for Public APIs

Before exposing a public method, field, option, or type, ask:

- Does the caller genuinely need this?
- Can this decision stay internal?
- Is the name precise?
- Are semantics unsurprising?
- Can invalid use be prevented?
- Is ownership clear?
- Is mutation clear?
- Is failure clear?
- Does exposing this lock us into an implementation detail?

Public surface area should grow reluctantly.

---

# 74. Decision Framework for Performance Changes

Before optimizing:

1. identify the performance requirement;
2. measure the current behavior;
3. locate the actual bottleneck;
4. make the smallest effective optimization;
5. verify correctness;
6. benchmark again;
7. document surprising constraints.

Do not scatter complexity across the architecture for hypothetical speed.

Do not hide expensive work behind innocent-looking APIs.

---

# 75. Priority Order

When principles conflict, use this order:

1. **Correctness**
2. **Clear semantics and invariants**
3. **Low total system complexity**
4. **Strong module boundaries and information hiding**
5. **Readability and local clarity**
6. **Testability and verifiability**
7. **Consistency**
8. **Performance requirements proven to matter**
9. **Reuse**
10. **Brevity**

Never sacrifice correctness for elegance.

Do not sacrifice architecture merely to achieve tiny functions.

Do not sacrifice readability merely to remove every duplicated line.

Do not sacrifice measurable performance merely to satisfy an abstract style rule.

---

# 76. The Core Standard

A strong design should allow a reader to answer these questions quickly:

- What does this module do?
- What does it hide?
- What assumptions does it maintain?
- What can change without affecting callers?
- Where would I modify a particular behavior?
- What state can mutate?
- Who owns that state?
- How are failures represented?
- What dependencies cross this boundary?
- How do I verify that it works?

If these answers are difficult to discover, the design is not finished.

---

# 77. Final Instruction to Coding Agents

Do not optimize code for demonstrating sophistication.

Optimize it for the next engineer who must understand and change it.

Prefer:
- deep modules over shallow wrappers,
- explicit models over vague abstractions,
- coherent algorithms over arbitrary fragmentation,
- information hiding over dependency leakage,
- meaningful names over explanatory noise,
- comments about intent over comments about syntax,
- verified behavior over confidence,
- small safe improvements over grand rewrites,
- simple interfaces even when their implementations require effort.

When uncertain between two designs, choose the one that requires the reader to know fewer things.
