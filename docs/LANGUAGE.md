# The Luce language

This is the current language map. It states the rules that connect the focused
references in [README.md](README.md); those pages carry exhaustive operator,
numeric, lifetime, declaration, and diagnostic detail.

Luce is statically typed with inference. Every expression has one type known
at compile time. The syntax is indentation-based and deliberately familiar,
while representation changes, failure, host effects, and object identity stay
explicit.

> Values copy. References share identity. ARC keeps references alive. Weak
> references break cycles. Resources close at the last strong release.
> Workers never share object identity.

[MEMORY.md](MEMORY.md) is the complete ownership contract.

## Source files and layout

A source file is UTF-8, uses an `.luc` suffix, and may use LF or CRLF line
endings. A leading UTF-8 byte-order mark is ignored. Invalid UTF-8, NUL,
unsupported encodings, stray carriage returns, bidi controls, tabs, and files
larger than the source limit are diagnosed before or during lexing.

Blocks are introduced by `:` and indented exactly four spaces. A block whose
body is a single statement may instead be written inline after the `:` on the
same line (`if done: return 0`); every block-opening construct accepts it, and
an inline block holds exactly one statement. Newlines end statements;
semicolons do not join them. `#` begins a line comment. Names begin
with an ASCII letter and continue with letters, digits, or `_`; a leading `_`
is not a privacy convention, and bare `_` is reserved for array rank syntax.
Declarations conventionally use TitleCase type names and snake_case value
names.

## Types

### Built-in values

The numeric vocabulary states representation:

```text
u8  u16  u32  u64
i8  i16  i32  i64
f16 f32  f64
```

An unconstrained integer literal defaults to `i64`; an unconstrained floating
literal defaults to `f64`. A literal may land directly on another numeric type
when it fits. Once a value has a concrete type, changing width, signedness, or
integer/floating family requires the destination constructor. All integer
widths use checked arithmetic; floating values follow their IEEE formats.
[NUMERICS.md](NUMERICS.md) specifies every operator and conversion.

`bool` has only `true` and `false`, and conditions require it—there is no
truthiness. `char` is one Unicode scalar. `str` is immutable valid UTF-8 whose
length, indexing, slicing, and iteration use scalar positions. `bytes` is
immutable binary data indexed as `u8`. [STRINGS.md](STRINGS.md) and
[BYTES.md](BYTES.md) separate text and binary operations.

`none` is a value, not a type. `T?` is one optional layer. A present `T` may
land in `T?`; reading the wrapped operations requires narrowing or an `else`
fallback. `T??` does not exist.

### Values and references

A value copies on assignment, argument passing, return, and aggregate copy.
Numbers, `bool`, `char`, `str`, `bytes`, structures, enumerations, unions, and
plain function values are values. A copied value retains any reference fields
it contains.

A reference shares one ARC object. Classes, `list[T]`, `map[K, V]`,
`array[T, _, ...]`, `builder`, and `task[...]` are references — as are the
library's resource classes (`files.File`, `ui.Window`), which privately
own the std-only `handle` descriptor currency. Assignment and argument
passing retain the same identity. The last strong
release destroys containers and classes, closes descriptors, and joins unfinished
tasks. Closure environments are internal references carried by the ordinary
function-value representation.

### Transparent aliases

`alias Name = Type` creates another source spelling for exactly the target
type. Aliases work in every type position, constructors, member namespaces,
visibility, imports, and chains. They add no nominal identity or runtime tag
and are erased before HIR. Cycles, unknown targets, privacy leaks, collisions,
and hidden double optionals are diagnosed even when unused.
[ALIASES.md](ALIASES.md) is the complete contract.

## Bindings and assignment

`let name = expression` creates an immutable binding. `var` creates a mutable
binding and may include an annotation, an initializer, or both. A declaration
without an initializer receives its type's zero; function and interface
values, which have no semantic zero, require an optional slot or initializer.

Immutability belongs to the binding. A `let` value structure cannot have a
field replaced. A `let` class or container binding may mutate the object it
names because the binding continues to name the same identity.

Assignment includes simple, compound, nested field/index, and parallel
multi-value forms. The right side and every replacement value are prepared
before an old target is released. A failed guarded assignment commits none of
its replacement stores; ordinary effects already performed while evaluating
the right side remain visible. [RETURNS.md](RETURNS.md) owns parallel receives,
and [MEMORY.md](MEMORY.md) owns replacement lifetime.

`weak var name: T?` and `weak field: T?` create non-owning storage for a class,
list, map, array, or builder. Assignment records a generation-checked handle
without retaining. Each read is an owned optional snapshot. Weak storage does
not cross workers and is not a `weak[T]` type.

## Operators and expressions

Calls, field access, indexing, and slicing are postfix expressions. Arithmetic,
bitwise, comparison, boolean, and assignment precedence is fixed by the parser
and listed in the public Language Reference. Concrete numeric operands have
the same type; conversions are explicit. Integer overflow, division by zero,
invalid shifts, bounds failures, and impossible conversions trap rather than
wrap or become undefined behavior.

`and` and `or` short-circuit and answer `bool`. Chained comparisons are
refused. `not` applied to a comparison requires parentheses so Python and C
read the source the same way. `is` compares two references of the same nominal
class; `==` remains value or reference-identity equality for types that support
it and is not synthesized for classes or function values.

Text literals use double quotes and the escapes `\n`, `\t`, `\r`, `\\`, and `\"`.
An f-string begins `f"..."` and evaluates expressions inside braces through
`str(...)`. There are no character literals; `chr` and `ord` cross the
numeric/scalar boundary.

## Collections

- `list[T]` is a growable ordered reference sequence.
- `map[K, V]` is a reference mapping. Current keys are `i64`, `str`, or an
  enum of the exact declared key type.
- `array[T, _, ...]` is a fixed-shape, densely stored reference grid of one to
  four dimensions. Each `_` states one rank in a type; construction supplies
  the extents with `array[T](sizes...)`.
- `builder` is a mutable text accumulator whose `build()` result is `str`.

Bracket literals infer a `list` unless an array landing type supplies rank.
Nonempty brace literals infer a map; `{}` needs an explicit `map[K, V]()`.
Containers share identity. Slices create a new outer list while reference
elements remain shared and retained. Optional element types are deliberately
restricted; function slots use the storable optional form described in
[FUNCTIONS.md](FUNCTIONS.md).

## Declarations

### Functions

`func name(parameters) -> Result:` declares a function; omitting the arrow
means no result. Parameters have names and types. Calls may begin positional
and switch once to named arguments. Defaults are trailing and folded at the
declaration. A fallible function writes `-> T!` or bare `-> !`.

A function may answer two or more values with `-> (A, B, ...)`. This is a
return shape, not a tuple type. A destructuring `let`, `var`, or assignment
receives it. [ARGS.md](ARGS.md), [RETURNS.md](RETURNS.md), and
[FAILURE.md](FAILURE.md) specify calls and effects.

`func(T, ...) -> R` is a function value type. Named functions and static
functions land in it directly. `(parameters) -> expression` is a concise
capture-free lambda. `func(parameters):` is a block closure with an
ARC-managed environment: immutable values snapshot, references capture
strongly, and mutable locals share one cell. `[weak name]` and
`[copy = expression]` select weak and creation-time snapshot behavior.
Function values have no equality, ordering, or worker transfer.
[FUNCTIONS.md](FUNCTIONS.md) and [BINDING.md](BINDING.md) are exhaustive.

### Structures

A `struct` is a value aggregate with named fields, memberwise construction,
methods, static functions, visibility, and folded field defaults. A method has
an implied `self`; the compiler infers whether it writes the receiver. A
writing value method requires a mutable bare receiver so its result can be
stored back. [SELF.md](SELF.md) and the Guide's Structures chapter carry the
member rules.

### Classes

A `class` is a final ARC reference type. Assignment shares identity, fields
and methods may mutate through a stable `let`, and `is` compares identity.
Construction is an ordinary call — `Name(...)` — the same spelling every
value constructs by; there is no `new` keyword. Without `init`, the call
is memberwise. One `init(parameters)`
body may instead define the class's construction surface; every successful
path establishes
every field before the compiler creates and returns the object. A fallible
initializer writes `-> !`. During initialization `self` may access stored
fields but cannot escape or call instance methods. Classes may conform to
interfaces, appear in ordinary storage, and declare one bare `deinit` that ARC
runs once before releasing fields. Resurrection from `deinit` is refused.
Classes do not cross workers and have no inheritance, method overrides, or
synthesized equality. A class is final; use an explicit interface for
polymorphism and composition for reuse.
[CLASSES.md](CLASSES.md) is the complete contract.

### Enumerations

An `enum` is a closed set of names with an explicit or inferred integer
backing width. Members are always namespaced. Converting out is explicit;
constructing from a number answers an optional member. `match` without `else`
is exhaustive, so adding a member finds every unhandled use.
[ENUMS.md](ENUMS.md) specifies layout, conversion, matching, and members.

### Tagged unions

A `union` is a tagged choice whose members may carry named fields. Members are
constructed through the union namespace, and `match` is the only door to a
payload. Each arm binds only the fields of that member. A recursive value
layout passes through absence, a reference, or an `indirect union`, whose
members may hold the union itself behind a hidden ARC box (D20); the first
member stays the type's zero and may not recurse. [UNION.md](UNION.md) is
the complete contract.

### Interfaces

An `interface` is a nominal list of method signatures. A struct or class opts
in explicitly and must satisfy every slot, including parameter count/order and
types, results, receiver effect, and directional fallibility. Requirement
parameter names are call labels; witness parameter names are local details. A
non-fallible witness may satisfy a fallible requirement; the reverse is
refused.

Interface values support multiple methods, multi-value answers, returns,
optionals, fields, closure captures, and heterogeneous lists/maps/arrays. A
class witness may mutate its shared identity. A `mutating` requirement permits
a writing value-struct witness; the call must use a mutable bare local so the
updated payload can be written back. [INTERFACES.md](INTERFACES.md) states the
complete boundary and deliberate non-goals.

## Control flow

`if`/`elif`/`else`, `while`, counted `for`, `for value in sequence`, `break`,
`continue`, `return`, and `match` are statements. Conditions require `bool`.
`match` dispatches over an enum or union by member name, and over a scalar
value — an integer, `char`, `str`, or `bool` — by literal arms: exact
values, several per arm behind commas, and inclusive `low .. high` ranges
for the ordered scalars. The first arm that admits the value wins, and a
value match requires `else` unless the arms provably cover everything,
which only `bool` can. Floats are refused as scrutinees.
Optional narrowing is flow-sensitive for stable locals and parameters and is
joined conservatively at branches and loops. A weak read is a fresh snapshot,
so testing the place does not permanently narrow a later read; bind the
snapshot first.

All exits release locals and statement temporaries they leave behind.
`return`, `break`, `continue`, recoverable propagation, and traps therefore
share one ARC cleanup model.

## Absence, errors, and traps

Absence (`T?`) is ordinary data. Recoverable failure (`T!`) is an effect on a
declared function result. `try` propagates it; `catch` handles it with a value,
named reason, or block. Ignoring a fallible result is a compile error.

A trap is a terminal violation such as overflow, bounds failure, explicit
`trap`, call-depth exhaustion, or a missing host service. Traps preserve a
stable code, message, source location in debug artifacts, and call trace. They
are not caught by `catch`. [FAILURE.md](FAILURE.md) owns the full distinction.

## Constants, modules, visibility, and packages

File scope permits declarations and `const`, not mutable global `var`.
Constants are folded once; supported flat list/map/rank-one-array constants
become immutable per-runtime program roots. [CONSTANTS.md](CONSTANTS.md)
specifies what can fold and what may escape.

Declarations are private to their file unless marked `pub`. Privacy is
file-scoped; `pub` signatures cannot expose private types. `pub` is the one
visibility marker — there is no region form; each field states its own.
[VISIBILITY.md](VISIBILITY.md) carries the complete rule.

`import std.name` loads an embedded standard module. A rootless source imports
single-segment sibling modules. A `luce.yaml` project enables root-relative
dotted modules and exact-version package requirements. Imports may bind with
`as`; each module is loaded once under an opaque root identity.
`from name import a, b` binds the named `pub` members bare — any
declaration kind, with an optional per-member `as` — while leaving the
module namespace unbound; members are checked on the import line, and a
member binding collides like any other name. The current
toolchain consumes local/store/shelf/path packages but does not publish to a
registry. [PACKAGES.md](PACKAGES.md) owns this boundary.

## Workers

`spawn declared_function(arguments)` creates a worker with a runtime, heap,
and call-depth budget of its own and returns a `task[...]`. Permitted scalar,
value, and container graphs are copied into the worker while preserving aliases
and cycles within the new snapshot. The caller keeps its independent graph.

Files, tasks, classes, function values, interface dispatch values, and weak
storage are refused transitively at the boundary. A worker may create and use
its own such values locally. `wait()` observes one result/error/trap once; the
last release joins an unfinished unobserved task. Luce exposes no shared heap,
locks, atomics, thread identifiers, or `async` color.
[THREADS.md](THREADS.md) is the complete concurrency contract.

## Host effects and entry

A program enters through one of these declarations:

```text
func main():
func main() -> !:
func main(args: list[str]):
func main(args: list[str]) -> !:
```

The command line is the optional `args` parameter. `print` and `exit` are the
two host-facing prelude operations. Input, clocks, sleep, environment, files,
directories, terminal events, process execution, UI/GPU operations, and
machine facts are namespaced standard-library APIs. Their implementation
services are compiler-private and reserve no program names. A compiler option
gates host access; at runtime a missing optional service traps
`host_unavailable` instead of touching the host through another path.

The one other door is the FFI (docs/FFI.md): `extern func name(...) -> R`
declares a foreign function's C shape and a call crosses directly into
machine code the language never saw. The vocabulary at that boundary is
closed — 32- and 64-bit integers, the opaque `foreign` token, an `f64`
answer — and **every guarantee ends at the boundary**: checked arithmetic,
traps, the leak census, and worker isolation resume the instant the call
returns, and what the callee did in between is its own affair. `luce build
--link` is how the foreign code joins the artifact.

## Deliberate boundaries

The current language has no tuples or user-defined generics; generics are a
post-1.0 design proposal. It also has no class inheritance, method overrides,
interface inheritance/default bodies, operator overloading, mutable globals,
unsafe pointers, unsafe unowned references, tracing garbage collector, reflection,
macros, exceptions separate from `T!`, or shared mutable state between
workers. [ROADMAP.md](ROADMAP.md) records the completed ARC, class, closure,
TermUI, editor, and owned-existential proofs, plus the separate native-UI,
package, platform, and release tracks.
