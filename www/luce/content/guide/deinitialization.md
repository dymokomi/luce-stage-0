# Deinitialization

A class may declare one `deinit` body for deterministic cleanup immediately
before its object is destroyed. ARC calls it automatically when the last
strong reference disappears. Source code never calls `deinit`, and there is no
manual `delete` or `free` operation.

Most classes do not need a deinitializer. Use one only when the class itself
owns a cleanup action that ordinary field release cannot express.

## The last strong release

Every class binding, field, optional, collection element, interface value,
bound method, and strongly capturing closure keeps an object alive. Aliasing a
class therefore delays `deinit` until the last alias is gone:

```luce run
class Session:
    name: str

    deinit:
        print("closed " + self.name)

func main():
    if true:
        let first = Session(name = "work")
        let second = first
        print(second.name)
    print("after scope")
```

```output
work
closed work
after scope
```

Leaving the inner scope releases both bindings. The first release leaves one
strong reference; the second is the transition to zero and runs the body once.

`deinit` is not tied to the lexical scope where the object was created. A
returned object, a stored object, or an object retained by a callback lives
until its actual last owner releases it.

## Fields remain alive during the body

The deinitializer runs while all fields can still be read. After the body
returns, ARC releases reference-valued fields in the object’s ordinary teardown
order:

```luce run
class Child:
    name: str

    deinit:
        print("child " + self.name)

class Parent:
    child: Child

    deinit:
        print("parent sees " + self.child.name)

func main():
    if true:
        let parent = Parent(child = Child(name = "one"))
        print(parent.child.name)
    print("done")
```

```output
one
parent sees one
child one
done
```

The parent can inspect its child during cleanup. The child’s last release then
happens after the parent body finishes.

Do not duplicate cleanup already provided by a field’s lifetime. Files close,
unfinished tasks join, windows and GPU surfaces release, closures release their
captures, and child classes run their own `deinit` when their last reference
disappears.

## Cleanup on every ordinary path

The last release can happen through normal fallthrough, `return`, `break`,
`continue`, recoverable error propagation, a handled error, replacement of a
field or collection element, or worker-runtime teardown. Those paths use one
ARC cleanup model, so a class does not need separate success and error
destructors.

An initializer that fails is different: no class identity was published, so
its established fields unwind as ordinary values and `deinit` does not run for
the nonexistent object.

A trap raised by the body remains a trap with its source location and call
trace. Deinitializers should therefore be short and dependable. They are a
poor place for optional work, retries, user interaction, or a recoverable
operation whose failure needs a caller.

## Deinitializers cannot resurrect an object

At the start of `deinit`, the strong count has already reached zero. Allowing
the dying `self` to escape into a global, field, closure, return value, or new
owner would revive an object whose teardown has begun.

Luce refuses resurrection. The body may inspect fields and perform allowed
cleanup effects; it may not return, store, capture, or otherwise publish
`self`. Instance calls that could hide such an escape are not an alternate
door.

A weak observation of `self` does not revive it. A weak upgrade during
deinitialization sees no live target.

## Cycles must be broken before zero

ARC only runs `deinit` after the strong count reaches zero. Two unreachable
objects that strongly retain each other never reach that transition. A
deinitializer is not a cycle collector and cannot be used to break a cycle
that prevents the deinitializer from running.

Make the semantically non-owning back-edge weak:

```luce run
class Node:
    value: i64
    weak parent: Node?

    deinit:
        print("closed " + str(self.value))

func main():
    weak var observed: Node?
    if true:
        let parent = Node(value = 1)
        let child = Node(value = 2, parent = parent)
        observed = parent
        assert((child.parent else child) is parent)
    print(str(observed == none))
```

```output
closed 2
closed 1
true
```

The child does not own its parent. When the strong root disappears, both
objects can reach zero and the weak observation is cleared before storage can
be reused. Stored closure cycles use `[weak self]` for the same ownership
shape.

## When to use `deinit`

A good deinitializer has one obvious responsibility and no meaningful caller
who should handle failure. Examples include unregistering an in-process native
handle owned by the class or recording deterministic lifecycle evidence in a
test.

Prefer an explicit fallible method when cleanup can fail in a way the
application must respond to. Prefer ordinary field lifetime when dropping the
fields is sufficient. Deterministic destruction is a safety net and ownership
boundary, not a replacement for clear application commands.

Luce has at most one deinitializer per final class. Structures, enumerations,
and unions are values and do not declare `deinit`; their reference fields are
released automatically when the value’s place is abandoned.

The exact lifetime ordering is in [Memory Management](/guide/reference/memory/)
and the class declaration form is in [Statements and Declarations:
class](/guide/reference/statements/#class). Continue with
[Optionals](/guide/optionals/).
