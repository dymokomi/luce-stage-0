# Memory without a collector

Luce releases owned values at scope boundaries. There is no garbage
collector and no reference counting. A program does not normally call a
destructor or a memory-management API; it gives a name to the value it
owns, and the scope that owns it releases it.

The rule is simple:

> The binding that receives a fresh container or resource owns it. Its
> owning scope releases it when that scope ends, returns, breaks, continues,
> propagates an error, or replaces the binding.

## Which values are owned

These are heap objects: `list`, `map`, `array`, and `builder`. A struct that
contains one of them is owned too. `file` and `task` are resources with the
same lifetime rule. `long`, `double`, `bool`, `string`, and structs made only
of values are ordinary values: assignment and return copy their value.

An unnamed object temporary lives until the statement that created it is
finished. A file-scope constant container belongs to the program root and
lives until that runtime ends. The [ownership reference](/reference/ownership/)
lists the rule for every form of statement.

```luce run
func main():
    var numbers: list(long) = [1, 2]
    numbers.append(3)
    numbers = [10]       # the first list is released here
    print(string(numbers[0]))
```

```output
10
```

## Aliases do not copy

`let alias = owner` creates a second name for the same object. The alias can
read and mutate it, but it does not become another owner:

```luce run
func main():
    var numbers: list(long) = [1, 2]
    let alias = numbers
    alias.append(3)
    print(string(len(numbers)))
```

```output
3
```

The owner must remain alive while an alias is used. `free owner` releases an
object early; using an alias afterwards traps with `use_after_free`. The
runtime checks object generations, so a stale alias cannot accidentally read
a newer object that reused the same storage.

## Moving and copying

Most ownership decisions use four words:

- `give value` moves an owned object into a container, field, or `give`
  parameter. The old name cannot be used afterwards.
- `copy value` makes an independent copy of a copyable object graph.
- `free value` releases a directly owned object before its scope ends.
- `return value` moves the returned object to the caller automatically.

A fresh expression does not need `give`: nobody has a name that could still
own it. A graph containing a `file` or `task` is not copyable; move it or
restructure the data instead.

```luce run
func store(values: list(list(long)), item: give list(long)):
    values.append(give item)

func main():
    var all: list(list(long)) = []
    var first: list(long) = [1, 2]
    store(all, give first)

    var template: list(long) = [7]
    all.append(copy template)
    template.append(8)
    all.append([9])

    print(f"{len(all)} {len(template)}")
```

```output
3 2
```

After `give first`, `first` is moved and cannot be read again. This is a
compile-time error, not a convention to remember. Likewise, storing a named
object without either `give` or `copy` is refused because a container must
always own the object it stores.

## Calls borrow by default

A normal object parameter is a borrow. The callee may inspect or mutate the
object while the caller remains its owner, but it may not store, return,
give, or free that borrowed object.

```luce run
func add_squares(values: list(long), count: long):
    for i in range(0, count):
        values.append(i * i)

func main():
    var values: list(long) = []
    add_squares(values, 3)
    print(string(values[2]))
```

```output
4
```

Use a `give` parameter when a function is meant to keep the object. The
caller writes `give` at the call site too, so the handoff is visible on both
sides. Return values are always owned by their receiver, which is why a
function cannot return a borrowed object.

## Resources follow the same rule

`std.files.open`, `create`, and `append_to` return an owned `file`. The file
closes when its owner leaves scope, or when `free` releases it early. There
is no `close` keyword to forget, and a closed handle used later traps like
any other use-after-free. `task` has the same lifetime shape and joins when
its owning scope ends.

This model makes cleanup predictable without making every value shared. If
multiple parts of a program need the same data, keep one owner and pass
borrows, or make an explicit `copy` of a copyable graph. Shared ownership,
weak references, and user-visible arenas are not part of Luce.
