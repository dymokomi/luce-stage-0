# A Luce tour

This page shows the whole shape of Luce in one sitting. It moves quickly on
purpose: run the examples, notice what feels familiar, and use the linked
Guide chapters when you want the complete model. You do not need to memorize
the details on a first read.

## Install Luce

The current release supports macOS 15 or newer on Apple Silicon and glibc Linux
2.28+ on x86-64 or ARM64. It installs the compiler, runtime, terminal editor,
maintained packages, and Luce highlighting for local VS Code, VS Code
Insiders, or Cursor:

```sh
curl -fsSL https://luce.luciaos.com/install/0.30/install.sh | bash
```

Open a new terminal after the installer finishes. Create `hello.luc`:

```luce run args=Ada
func greeting(name: str = "world") -> str:
    return f"Hello, {name}."

func main(args: list[str]):
    var name = "world"
    if len(args) > 0:
        name = args[0]
    print(greeting(name))
```

```output
Hello, Ada.
```

Build and run it as a native executable:

```text
luce build hello.luc
./hello Ada
```

The executable name comes from the source file. You do not need a project,
manifest, runner, or build configuration for a one-file program.

## Bind values and make decisions

`let` introduces a binding that will not be reassigned. `var` introduces one
that may change. The compiler infers a local type when the initializer is
unambiguous; an annotation makes a width or API boundary explicit.

```luce run
func main():
    let title: str = "field notes"
    var total: i64 = 0

    for value in [3, 7, 11]:
        total += value

    if total >= 20:
        print(f"{title}: {total}")
    else:
        print("not enough data")
```

```output
field notes: 21
```

Blocks begin after `:` and use four-space indentation. Conditions must be
`bool`; numbers, strings, and objects are not implicitly truthy. Arithmetic
is checked in debug and release builds, and numeric width changes are explicit
through constructors such as `u32(value)` or `f64(value)`.

The primitive vocabulary is sized where representation matters: signed and
unsigned integers from 8 through 64 bits, `f16`, `f32`, and `f64`, plus
`bool`, Unicode `char`, UTF-8 `str`, binary `bytes`, and `none` for absence.

## Write functions

A function names every parameter type and writes its result after `->`.
Calls may use positional arguments, named arguments, or constant defaults.
One call can answer several values without introducing a tuple type:

```luce run
func minmax(values: list[i64]) -> (i64, i64):
    var low = values[0]
    var high = values[0]
    for value in values:
        if value < low:
            low = value
        if value > high:
            high = value
    return low, high

func padded(value: str, left: str = "[", right: str = "]") -> str:
    return left + value + right

func main():
    let low, high = minmax([8, 3, 12, 5])
    print(padded(f"{low}..{high}", right = ">"))
```

```output
[3..12>
```

Parameters and results follow the type's ordinary memory rule. Values copy;
reference types share one ARC-managed object. There are no call-site borrow,
move, clone, or retain annotations.

Named functions can also be stored in a `func(...)` value. An expression
lambda is a short non-capturing function, while a block closure can retain
local state.

## Use the collection that describes the data

A `list[T]` grows and shrinks. A `map[K, V]` preserves insertion order and
associates keys with values. An `array[T, ...]` has a fixed shape after
construction and stores elements at their declared width.

```luce run
func main():
    var names = ["Ada", "Grace"]
    names.append("Lin")

    var scores = {"Ada": 9, "Grace": 10}
    scores["Lin"] = 8

    let pixels: array[u8, _] = [10, 20, 30]
    for index, name in names:
        let score = scores.get(name) else 0
        print(f"{index}: {name} {score} {pixels[index]}")
```

```output
0: Ada 9 10
1: Grace 10 20
2: Lin 8 30
```

Lists, maps, arrays, and builders are reference types. Assigning one shares
its object. A list slice creates an independent outer list; any reference
elements inside it remain shared. Indexing asserts that an element exists,
while `map.get` answers an optional for ordinary absence.

## Model copied data with a structure

A `struct` groups named fields as one value. Construction names the fields,
and an instance method receives an implied `self`:

```luce run
struct Point:
    var x: i64
    var y: i64

    func moved(dx: i64, dy: i64) -> Point:
        return Point(x = self.x + dx, y = self.y + dy)

    func translate(dx: i64, dy: i64):
        self.x += dx
        self.y += dy

func main():
    let origin = Point(x = 2, y = 3)
    var cursor = origin
    cursor.translate(4, -1)
    let end = origin.moved(10, 10)
    print(f"origin {origin.x},{origin.y}")
    print(f"cursor {cursor.x},{cursor.y}")
    print(f"end {end.x},{end.y}")
```

```output
origin 2,3
cursor 6,2
end 12,13
```

`cursor` is an independent copy. A writing structure method requires a
writable value place, which is why it is declared with `var`. Structures can
contain reference fields; copying the structure copies its value fields and
retains those references.

## Name alternatives with enums and unions

An `enum` is a closed set of names with an integer representation. A `union`
is a closed set of shapes whose members may carry different named payloads.
`match` handles either one and is exhaustive unless it has `else`.

```luce run
enum Priority:
    low
    normal
    high

union State:
    idle
    running(progress: i64)
    failed(reason: str)

func describe(state: State) -> str:
    match state:
        idle:
            return "idle"
        running(progress):
            return f"running {progress}%"
        failed(reason):
            return f"failed: {reason}"

func main():
    let priority = Priority.high
    let state = State.running(progress = 75)
    print(f"{priority}: {describe(state)}")
```

```output
high: running 75%
```

Use an enum when the names are the whole value, a union when alternatives
carry data, and a structure when every field exists together. Adding a member
to an exhaustively matched enum or union points the compiler at each decision
that must be reconsidered.

## Represent absence, errors, and traps separately

`T?` means a value may be absent and there is no reason to carry. `T!` means a
valid operation may fail with a reason. A trap means the program violated a
checked precondition or called a service its host does not provide.

```luce run
func parse_port(text: str) -> i64!:
    let port = parse_i64(text) else error("not a number")
    if port < 1 or port > 65535:
        error("port out of range")
    return port

func main() -> !:
    let maybe = parse_i64("42")
    if maybe != none:
        print(f"optional: {maybe}")

    print(f"port: {try parse_port("8080")}")
    print(f"fallback: {parse_port("nope") catch -1}")
```

```output
optional: 42
port: 8080
fallback: -1
```

`try` propagates an error to the caller. `catch` handles it where a fallback
or recovery is meaningful. An out-of-bounds index, integer overflow, or
failed assertion traps instead; those are not ordinary alternative results a
caller should ignore.

## Use classes for shared identity

A `class` is a final ARC reference type. Construction writes `new`, the
keyword that creates every reference identity. The initializer establishes the
object before identity escapes. Assignment shares the same object, and `is`
compares that identity.

```luce run
class Counter:
    var value: i64

    init(start: i64 = 0):
        self.value = start

    func next() -> i64:
        self.value += 1
        return self.value

    func reader() -> func() -> i64:
        return func():
            return self.next()

func main():
    let counter = Counter(start = 40)
    let same = counter
    let next: func() -> i64 = counter.reader()
    assert(counter is same)
    print(str(next()))
    print(str(same.value))
```

```output
41
41
```

The closure retains the counter it captures. Captured mutable locals share
one cell; a capture list can request a creation-time snapshot or a zeroing
weak edge. A class may define `deinit` for deterministic non-fallible cleanup
at the last strong release. Weak class or container references break cycles.

Choose a structure for independently copied data and a class only when shared
mutable identity is part of the model.

## Share behavior with an interface

An `interface` names instance-method requirements. A structure or class opts
in explicitly, and the compiler checks every method before a value can be
used through the contract.

```luce run
interface Named:
    func name() -> str

struct FileName: Named:
    let path: str

    func name() -> str:
        return self.path

class User: Named:
    let label: str

    func name() -> str:
        return self.label

func main():
    var values = list[Named]()
    values.append(FileName(path = "notes.luc"))
    values.append(User(label = "Ada"))
    for value in values:
        print(value.name())
```

```output
notes.luc
Ada
```

Each list element keeps its own concrete value and dispatch. Interfaces can
have several methods, fallible and multi-value results, and may appear in
maps, arrays, fields, results, and optionals. A `mutating` requirement permits
a value-structure witness to write back through a mutable local; a class
witness keeps its shared identity. There are no interface casts, inheritance,
default methods, or associated types.

## Let ARC own lifetime

Luce source has no `retain`, `release`, `free`, `borrow`, or `clone` operation.
The compiler applies one rule from the concrete type:

> Values copy. References share identity. ARC keeps references alive. Weak
> references break cycles. Resources close at the last strong release.

Files, tasks, windows, and GPU surfaces use the same lifetime mechanism as
lists and classes. A file closes and an unfinished task joins when its last
strong reference disappears. Copying an outer value retains any reference
fields it contains. Workers are the deliberate isolation boundary rather
than a second memory model.

## Split a program into modules and packages

One `.luc` file is one module. A sibling import uses the file name, and
declarations remain qualified:

```text
import geometry

let point = geometry.Point(x = 2, y = 3)
print(str(geometry.distance(point)))
```

A `luce.yaml` marks a project root. Dotted imports then map to direct
subfolders from that root, so `import geometry.shapes` reads
`geometry/shapes.luc`. A source package begins as another direct folder with
its own manifest and entry module. Installed dependencies use the same source
shape under `.luce/packages/NAME-VERSION/`.

The standard library is embedded and uses the reserved namespace:

```text
import std.files
import std.json
import std.strings
```

Host-facing operations are explicit and usually fallible. Pure modules such
as `std.paths` and most of `std.strings` work without a host.

## Run independent work on workers

`spawn` starts a named function in a separate worker runtime. `wait()` joins
the task and receives its result once.

```luce run
func square(value: i64) -> i64:
    return value * value

func main():
    let left = spawn square(12)
    let right = spawn square(9)
    print(str(left.wait() + right.wait()))
```

```output
225
```

Value arguments and permitted container graphs are copied into the worker.
Aliases within the graph remain aliases in the independent copy; no identity
is shared with the caller. Live resources, classes, interfaces, function
values, and tasks do not cross the boundary. There are no shared mutable
objects or locks in this model.

## Continue from here

- Read [The Basics](/guide/basics/) and follow the Language Guide when you
  want the concepts in teaching order.
- Use the [Language Reference](/guide/reference/) for exact grammar, type,
  storage, and diagnostic rules.
- Use [Tools](/tools/) for the compiler, editor, packages, testing, complete
  programs, and performance.
- Look up shipped modules and maintained packages in the [Library](/library/).
- Read [Status](/status/) for the current platform boundary and the small set
  of work that remains before 1.0.
