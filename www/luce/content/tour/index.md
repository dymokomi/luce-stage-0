# A Luce tour

This is the short version of Luce. Read it once to see the shape of a
program, the values it works with, and the rules that keep it predictable.
You do not need to memorize every detail here. The [Guide](/guide/) explains
each idea carefully and ends with the exact Language Reference.

## Install and make a program

The current release installs the compiler, the Luce editor, the runtime
libraries, and the Luce VS Code extension for macOS on Apple Silicon:

```sh
curl -fsSL https://luce.luciaos.com/install/0.18/install.sh | bash
```

Create `hello.luc`, then build and run it:

```text
luce build hello.luc
./hello
```

The default output is an executable named after the source file. You only
choose `--emit=library` or `--emit=object` when you need a loadable `.lc` or a
relocatable object instead.

## Values and decisions

Luce has explicit values and explicit types. `let` binds a value that does not
change; `var` allows reassignment. The compiler infers simple types, while an
annotation makes an important boundary visible.

```luce run
func main():
    let name: string = "Luce"
    var visits: long = 0
    for step in range(0, 3):
        visits = visits + 1
    if visits == 3:
        print(name + " is ready")
    else:
        print("not ready")
```

```output
Luce is ready
```

Blocks are introduced by `:` and indentation. Conditions must be boolean;
there is no truthiness conversion from numbers or strings.

## Functions and data

Functions take typed parameters and state their result after `->`. A `struct`
keeps related values and their operations together. Lists, maps, and arrays
hold collections; choose the shape that expresses the data instead of hiding
it behind an untyped value.

```luce run
struct Point:
    x: long
    y: long

    func moved(dx: long, dy: long) -> Point:
        return Point(x = self.x + dx, y = self.y + dy)

func total(values: list(long)) -> long:
    var sum: long = 0
    for value in values:
        sum = sum + value
    return sum

func main():
    let start = Point(x = 2, y = 3)
    let end = start.moved(4, -1)
    print(f"point {end.x},{end.y}; total {total([1, 2, 3])}")
```

```output
point 6,2; total 6
```

Structs are values and copy when assigned. Lists, maps, arrays, and builders
are shared reference objects. Luce keeps them alive with automatic reference
counting.

## Memory is automatic

Assigning a list or passing it to a function shares the same object. A
mutation through either reference is visible through both. The compiler
inserts retain and release operations. There are no memory-management keywords
to write. The development compiler is still finishing last-release
reclamation on every control-flow and resource path; [Status](/status/) names
the remaining gates.

The completed ARC contract closes a file and joins an unfinished task at its
last reference. Current development builds still have lifecycle gaps. Workers have
separate runtimes; permitted container graphs are copied between them, and no
object identity is shared. Container arguments currently have a caller-lifetime
bug, so use value arguments for now. The [memory guide](/guide/memory/) and
[exact memory rules](/guide/reference/memory/) show every form.

## Absence and failure are different

Use `T?` when a value may simply be absent, such as a number that cannot be
parsed. Use `T!` when the outside world may refuse a valid request. A trap is
for a violated program precondition, such as an out-of-bounds index.

```luce run
func parse_port(text: string) -> long!:
    let port = parse_int(text) else error("not a number")
    if port < 1 or port > 65535:
        error("port out of range")
    return port

func main() -> !:
    print(string(try parse_port("8080")))
    print(string(parse_port("nope") catch -1))
```

```output
8080
-1
```

`try` passes a failure to the caller. `catch` handles it at the point where
you have a useful fallback. [Error Handling](/guide/errors/) explains
which outcome to choose.

## Modules and the outside world

One `.luc` file is one module. Imports name standard modules or project
modules, and visibility controls what another file may use. Host-facing work
is explicit and fallible:

```text
import std.files
import std.strings
```

The [Library](/library/) documents every shipped module.
[Packages and Projects](/guide/packages/)
shows how a direct source folder becomes a versioned package.

## Workers

`spawn` starts a named function on a worker with its own runtime. `wait()`
joins it and observes the task's result once. Value arguments and permitted
results are copied between runtimes; live resources and function values do not
cross. The recursive argument copier exists, but its current container ARC bug
is tracked on [Status](/status/#ordered-work).

```luce run
func square(n: long) -> long:
    return n * n

func main():
    let task = spawn square(12)
    print(string(task.wait()))
```

```output
144
```

There are no shared mutable objects or locks in this model. See
[Concurrency](/guide/concurrency/) when you are ready to design
parallel work.

## Continue

- Begin with [The Basics](/guide/basics/) and follow the Language Guide in
  order.
- Use [Tools and Projects](/guide/#tools-and-projects) for the compiler,
  editor, packages, and tests.
- Use the [Language Reference](/guide/reference/) when you need an exact
  rule.
- Look up a module in the [Library](/library/).
- Check [Status](/status/) for current platform and feature boundaries.
