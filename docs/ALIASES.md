# Type aliases

`alias` gives an existing type another source name:

```luce
alias UserId = i64
alias UserIds = list[UserId]
alias MaybeUserId = UserId?

func find(ids: UserIds, wanted: UserId) -> MaybeUserId:
    for id in ids:
        if id == wanted:
            return id
    return none

func main():
    var ids: UserIds = UserIds()
    ids.append(42)
    let found: i64? = find(ids, 42)
    assert((found else 0) == 42)
```

The alias and its target are exactly the same type. There is no conversion,
wrapper, layout, runtime tag, allocation, dispatch rule, or distinct identity.
`UserId` above is interchangeable with `i64` at annotations, parameters,
results, fields, optionals, container elements, interface boundaries, and
module boundaries.

## Declaration and visibility

An alias is a file-scope declaration:

```text
alias Name = Type
public alias Name = Type
private alias Name = Type
```

It is public by default, like a function or structure. `private alias` keeps
the name inside its declaring file. An importer that reaches a private alias
gets `luce.sema.private`; private names are not hidden behind an “unknown
type” diagnostic.

A public alias may name any public type, including a type imported from
another module. It may therefore serve as a deliberate re-export. A public
alias may not expose a private nominal type; either the alias or the target
must become public. A private alias may name a private type in the same file.

Aliases share the file-scope declaration namespace with constants, functions,
structures, classes, interfaces, enums, unions, and imports. A collision is
reported at the later declaration. An alias may not replace a builtin type or
use a reserved name.

## Resolution

The target is the ordinary type grammar, so aliases may name scalars,
optionals, functions, containers, resources, structures, classes, interfaces,
enums, and unions. They may refer to later declarations and may form chains:

```luce
alias Item = Button
alias Element = UIElement
alias Elements = list[Element]

interface UIElement:
    func render(value: i64) -> i64

struct Button: Element:
    offset: i64

    func render(value: i64) -> i64:
        return value + self.offset

func main():
    var elements: Elements = Elements()
    let item: Item = Item(offset = 2)
    elements.append(item)
    print(str(elements[0].render(40)))
```

Resolution is eager. An unused alias is still checked, so an unknown target
or a cycle cannot hide until some later use. Direct and indirect cycles are
refused with the complete path, such as `A -> B -> C -> A`. Optionality is
also resolved through the alias: if `MaybeId` is `i64?`, then `MaybeId?` is
rejected because Luce has one level of absence.

## Construction and members

Transparency includes expression sites that name the type:

- an alias of a structure may construct it and reach its static functions;
- an alias of an enum or union may reach its members and methods;
- an alias of a numeric type or `str` may be used as that conversion
  constructor;
- an alias of a class, `list`, `map`, `array`, or `builder` may follow `new`;
- an alias of a class constructs it only through `new`: the bare call is
  refused with the class's own rule.

The target still decides how values are created. An alias of `task[...]` is
created by `spawn` and never becomes callable or constructible with `new`.
An alias of `bool`, an optional, or a function type is a type, not a
callable runtime value.

## Compiler boundary and evidence

Aliases are collected and resolved entirely during semantic analysis. The
resolved target type is cached, and no alias node or tag crosses into HIR,
MIR, serialized modules, either execution engine, or the ARC runtime.

The differential specification is
[`src/luce/specs/aliases_spec.zig`](../src/luce/specs/aliases_spec.zig).
It covers type boundaries, chains, forward references, constructors,
constants, function values, static/member namespaces, interfaces,
heterogeneous containers, resources, and multi-file re-exports on both
engines with a zero-object census. Parser and exact negative coverage includes
missing syntax, unknown targets, cycles, double optionals, reserved names,
every top-level collision kind, privacy, and non-callable targets.
