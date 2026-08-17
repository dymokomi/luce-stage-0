# Generics — proposed monomorphized design

> **Status: proposed, not implemented.** Every syntax example in this document
> is `text`. The current language has built-in parameterized containers, but
> users cannot declare a generic function or type.

Generics let one declaration state an algorithm or data shape without naming
every concrete type in advance. They are useful when the relationship between
operations is the same for several types and copying the declaration would
create several sources of truth.

They are not needed to finish ARC, classes, closures, or the hidden TermUI
application loop. TermUI 0.3 is important evidence: a class model plus an
`Application` interface already lets a library own the lifecycle. Generics
must therefore justify themselves through reusable typed code, not by claiming
the current UI architecture cannot exist without them.

## The work that currently repeats

Three ordinary library problems want this feature:

1. **Algorithms over element types.** A function such as `first`, `reverse`,
   `deduplicate`, or `binary_search` should not be copied for every type it can
   store. Operations beyond storage need a named behavioral bound.
2. **Data structures with one invariant.** A stack, deque, tree, matrix, or
   typed component should express its rule once while preserving the element
   type at every call.
3. **Typed composition.** Native UI and other packages will need reusable
   state and component containers without reducing their application data to
   `str`, numeric IDs, or an erased interface too early.

The criterion is not “could use a type parameter.” A generic earns its place
when several real instantiations share an invariant or algorithm and a common
implementation materially reduces mistakes.

## Proposed syntax

Type parameters appear in brackets after the declaration name. A parameter
may name one interface bound:

```text
func first[T](values: list[T]) -> T?:
    if len(values) == 0:
        return none
    return values[0]

interface Ordered:
    func before(other: Self) -> bool

func smallest[T: Ordered](values: list[T]) -> T?:
    ...

struct Stack[T]:
    items: list[T]

    func push(value: T):
        self.items.append(value)

    func pop() -> T?:
        ...

let numbers = Stack[i64](items = [])
```

Brackets match Luce’s existing type application—`list[T]`, `map[K, V]`, and
`array[T, _]`—and avoid making `<` and `>` ambiguous with comparisons and
shifts.

At a call, type arguments are inferred from value arguments when the answer is
unique. An explicit form is available when inference has no evidence or more
than one answer:

```text
let found = first(names)
let empty = first[str]([])
```

Inference should remain local to one call or construction. It does not search
the whole program, guess from future statements, choose conversions, or rank
overloads. A missing or conflicting argument is a diagnostic that names the
parameter and every source of evidence.

## What an unbounded parameter can do

An unbounded `T` supports only operations valid for every Luce type in the
declared position:

- bind, pass, return, and store the value;
- place it in a container whose own restrictions it satisfies; and
- copy a value or retain a reference according to the concrete type.

It does not silently acquire arithmetic, ordering, hashing, methods, a zero
value, or construction syntax. Those operations require either a concrete
type or an interface bound whose requirements say they exist.

This keeps generic checking honest. The body is valid because of what its
signature states, not because the first instantiation happened to have an
extra method.

## Bounds reuse interfaces

Interfaces are the one behavioral contract in Luce. A generic bound should
reuse nominal conformance rather than add traits, concepts, structural
constraints, or compiler-known operator sets.

```text
interface Named:
    func name() -> str

func labels[T: Named](values: list[T]) -> list[str]:
    var result = new list[str]
    for value in values:
        result.append(value.name())
    return result
```

The concrete type is chosen at the call and checked for explicit `Named`
conformance. The generic body is checked against `Named`, and each specialized
call uses the concrete witness table selected by existing conformance rules.

Owned interface existentials are already in place. Generic bounds can reuse
that final payload-and-witness representation, including writing value
witnesses behind `mutating` requirements.

The first version has one bound per parameter. Multiple bounds, protocol
composition, associated types, and generic interfaces are deferred until a
real library cannot state its invariant without them.

## Monomorphization

The proposed implementation specializes a generic declaration once for each
distinct concrete argument list. `Stack[i64]` and `Stack[str]` become ordinary
concrete types before MIR; `first[i64]` becomes an ordinary concrete function.

That choice preserves the existing lower half of the compiler:

- MIR contains concrete layouts and call signatures only;
- the runtime continues to move ordinary tagged values;
- ARC insertion sees the final value/reference kind;
- the optimizer and LLVM backend need no generic calling convention;
- the interpreter oracle executes the same concrete MIR; and
- unused specializations are removed by reachability pruning.

The cost is compile time and code size per specialization. The compiler must
intern instantiations by declaration identity plus concrete arguments, compile
each one once, detect recursive expansion, and measure growth. A generic that
creates a larger instantiation of itself must stop with a diagnostic instead
of exhausting the compiler.

Generic syntax alone does not require a serialized-module or host-ABI bump if
all templates disappear before MIR. A future design that serializes templates
would be a different boundary and would pay the corresponding format cost.

## Pipeline ownership

The change belongs in the source-facing half of the compiler:

- **Parser and AST:** record parameter declarations, optional bounds, and
  explicit type arguments.
- **Semantic declarations:** give each type parameter a scoped identity that
  cannot escape its generic declaration.
- **Generic body checking:** validate operations against the parameter and its
  bound before relying on any concrete use.
- **Instantiation:** infer or accept arguments, check constraints, substitute
  concrete types, intern the result, and emit ordinary typed HIR.
- **HIR onward:** accept concrete declarations only. A type parameter reaching
  lowering is a compiler invariant failure, not a runtime case.

Cross-module templates must retain source locations and visibility so an
error in an imported instantiation can show both the generic declaration and
the call that selected the concrete type.

## Memory semantics

Generics add no ownership category. After substitution:

- a value argument copies;
- a reference argument retains and shares identity;
- a generic structure copies its value fields and retains its reference
  fields;
- a generic class remains a final ARC reference;
- a specialization that stores a weak-capable reference may use ordinary weak
  storage where its declaration says so; and
- resources retain their existing deterministic cleanup.

There is no `T: Copy`, `T: Reference`, borrow annotation, move marker, or
generic ARC API. If a declaration needs behavior such as cloning, equality,
or ordering, it names an interface that provides that behavior.

## First milestone

The first generics milestone includes:

- generic functions;
- generic structures;
- generic final classes after functions and structures prove the
  instantiation model;
- one type parameter or several independent parameters;
- one interface bound per parameter;
- local argument inference and explicit type arguments;
- constructors, methods, static functions, aliases, optionals, functions,
  built-in containers, and nested generic applications;
- public/private declarations and cross-module/package use; and
- monomorphized output before MIR.

It excludes:

- generic interfaces or existential type arguments;
- associated types;
- higher-kinded parameters;
- variadic parameters or packs;
- specialization/overload ranking;
- variance or subtyping between instantiations;
- partial specialization;
- runtime reflection over type arguments; and
- implicit structural bounds.

Generic enumerations and unions may follow if a real data model needs them.
They are not required to prove the core with algorithms, stacks, trees, typed
components, and class-backed state.

## Diagnostics and limits

Typical mistakes must be designed with the feature, not after it:

- unknown, duplicated, unused, or shadowed type parameters;
- a type parameter used outside its declaration;
- missing, extra, or conflicting explicit arguments;
- inference with no evidence or contradictory evidence;
- a concrete type that does not satisfy its bound;
- a body operation not promised by the bound;
- recursive or mutually recursive instantiation growth;
- a specialization that exposes a private concrete type;
- incompatible specializations reached under one module identity; and
- an instantiation count, nesting depth, or generated-code limit.

Diagnostics should lead with the generic declaration and failed relationship,
then show the concrete call that supplied the type. Dumping a fully expanded
internal name is evidence for a compiler engineer, not a useful primary error
for a user.

## Acceptance matrix

The feature is complete only when all of these work or refuse on both engines:

1. identity, optional-returning, and multiple-parameter generic functions;
2. inferred and explicit calls with the same specialization identity;
3. a `Stack[T]` containing values and a `Stack[T]` containing ARC references;
4. a generic class whose aliases observe shared mutation;
5. bounded method dispatch for both structure and class conformers;
6. generic values in lists, maps, arrays, optionals, fields, returns, errors,
   closures, and interface conversions where the final concrete type permits;
7. public templates instantiated from another module and package;
8. allocation failure, recoverable unwinding, traps, and destruction with no
   leaked or double-released objects;
9. stable module fingerprints and one emitted specialization per concrete
   argument list;
10. recursive-instantiation and code-growth limits with precise source spans;
11. compile-time and artifact-size measurements across repeated and distinct
    instantiations; and
12. a real generic library structure used by an application, not only a
    compiler fixture.

The first userland proof should be small enough to understand and substantial
enough to need the feature: a typed tree or deque plus one bounded algorithm,
followed by a native UI component that keeps its application data concrete.
