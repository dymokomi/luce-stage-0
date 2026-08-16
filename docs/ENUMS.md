# Enums

An `enum` declares a set of named constants at a single integer width. It
is a value type: an enum value is its backing integer, it copies when
assigned or passed, and it costs nothing at runtime beyond the integer it
is. What an enum gives a program over a bare number is that every value of
the type is one of the named members, that dispatch over it can be checked
for exhaustiveness, and that the compiler knows the member's name.

```luce
enum Method:
    stored
    deflated

func main():
    let m = Method.deflated
    print(str(m))          # deflated
```

## Declaring an enum

A declaration mirrors a `struct`: `enum` and a TitleCase type name, then
one snake_case member per indented line.

```text
enum Colour:
    red
    green
    blue
```

A member may carry `= value`, where `value` is a constant integer
expression folded at compile time exactly as any file-scope `const` is. An
unvalued member takes the previous member's value plus one; an unvalued
first member is `0`. This is the C rule: sequential from zero, explicit
where written, and both at once.

```luce
enum Mixed:
    a          # 0
    b = 10
    c          # 11
    d = -2
    e          # -1

func main():
    assert(i32(Mixed.c) == 11)
    assert(i32(Mixed.e) == -1)
```

Because a member value is an ordinary constant expression, it may be built
from other constants and the bitwise operators:

```luce
const base = 4

enum Flag:
    none_set = 0
    one = 1 << 0
    two = 1 << 1
    four = base
    eight = base * 2

func main():
    assert(i32(Flag.two) == 2)
    assert(i32(Flag.eight) == 8)
```

Two members may not share one value; a duplicate is refused by name. (An
alias is a `let` if a program wants one.)

## The backing width

The default backing width is `int`. Writing the width in parentheses picks
another rung of the integer ladder — `byte`, `short`, `int`, or `long`:

```text
enum Small(byte):
    off = 0
    on = 255

enum Wide(long):
    huge = 9223372036854775807
    tiny = -9223372036854775808
```

Every machine question about an enum — what a register holds, what an array
cell is wide, whether a constant fits — is a question about this width. A
member value that will not fit the backing width is refused at compile time
by the same sentence a literal gets, naming the width that would hold it.

## Namespaced members

Members are namespaced, always: `Method.stored`, `Colour.red`. A bare
member name is meaningful only inside a `match` arm (below). Nothing leaks
into the enclosing scope, so two enums may share a member name without
collision.

## Converting

An enum does not convert implicitly in either direction. Both directions
are spelled.

**Enum to number** uses the numeric conversion constructors, which accept
an enum operand because they are named for what they produce. Every
numeric constructor takes an enum, not only `int` and `long`:

```luce
enum Method:
    stored = 0
    deflated = 8

func main():
    let m = Method.deflated
    assert(i32(m) == 8)
    assert(i64(m) == 8)
    assert(f64(m) == 8.0)
```

A narrowing conversion whose member does not fit the destination traps
`conversion_range`, exactly where the same narrowing of a plain number
would:

```luce
enum Big(i64):
    small = 1
    huge = 300

func main():
    var m = Big.small
    m = Big.huge
    print(str(u8(m)))    # traps conversion_range before it prints
```

**`string(m)` answers the member's name** — the name, not the number — and
an f-string hole follows, because a hole is a `string(...)` the reader did
not write:

```luce
enum Method(u8):
    stored = 0
    shrunk = 1
    deflated = 8

func main():
    print(str(Method.deflated))     # deflated
    var m = Method.shrunk
    print(f"{m} is {i32(m)}")          # shrunk is 1
```

**Number to enum is the fallible direction.** `Method(n)` answers
`Method?`: a number arrives from a file or a wire, and *unknown member* is
precisely what the caller must branch on. The caller writes `else` or
narrows, like every other absence.

```luce
enum Method:
    stored = 0
    deflated = 8

func read(raw: i64) -> str:
    let m = Method(raw)
    if m == none:
        return "unknown"
    return str(m)

func main():
    assert(read(0) == "stored")
    assert(read(8) == "deflated")
    assert(read(9) == "unknown")
```

`Method(n)` also answers `none` for a number no member holds and for a
number that would not fit the backing width, so a narrow enum asked about
an out-of-range value is `none` rather than a trap:

```luce
enum Small(u8):
    off = 0
    on = 200

func main():
    assert(Small(200) != none)
    assert(Small(300) == none)
    assert(Small(-1) == none)
```

`Method(n)` does not fold in constant position: it answers `Method?`, and a
constant is always there, so the refusal names the member the reader
wanted.

## Equality

Enums compare with `==` and `!=` and nothing else. `<` on enums is refused
by a sentence naming `int(m)`: an enum is a set of names, not a number
line, so code that means the number says the number.

```luce
enum Method(u8):
    stored = 0
    deflated = 8

func main():
    var m = Method.stored
    assert(m == Method.stored)
    assert(m != Method.deflated)
```

## match

`match` dispatches over an enum. Arms are bare member names of the
scrutinee's type — `stored:`, not `Method.stored:` — because the type is
known and the member namespace is closed.

```luce
enum Colour:
    red
    green
    blue

func name(c: Colour) -> str:
    match c:
        red:
            return "red"
        green:
            return "green"
        blue:
            return "blue"

func main():
    assert(name(Colour.green) == "green")
```

**Without an `else`, every member must appear.** A member added later turns
every non-`else` `match` that misses it into a compile error naming the
member — which is the point. A duplicate arm is refused, and an `else` that
covers nothing (every member already named) is refused by the sentence
`a else b` gets when `a` is never absent.

An `else` stands for every member the arms did not name:

```luce
enum Colour:
    red
    green
    blue

func describe(c: Colour) -> str:
    match c:
        green:
            return "green"
        else:
            return "not green"

func main():
    assert(describe(Colour.red) == "not green")
```

Arms are statements, so they assign, loop, `break`, `continue` and
`return`; and a `match` nests inside another arm like any statement.

## Methods and static functions

An enum takes the methods and namespace functions a struct takes
(`docs/SELF.md`). A plain member function is a method with an implied
`self`; a `static func` is a namespace function with none. A method may
mutate its receiver — whether a method writes `self` is inferred from its
body — and the write replaces the enum value in place:

```luce
enum Light:
    red
    green

    func flip():
        match self:
            red:
                self = Light.green
            green:
                self = Light.red

    static func of(raw: i64) -> Light:
        return Light(raw) else Light.red

func main():
    var light = Light.red
    light.flip()
    assert(light == Light.green)
    assert(Light.of(1) == Light.green)
```

Methods cannot be values, spawned, or called through the enum type; static
functions can.

## Folding, constants and defaults

A member *is* a constant, so it folds anywhere a constant folds — a
file-scope `const`, a parameter's default, a struct field's default:

```luce
enum Method:
    stored = 0
    deflated = 8

const default_method = Method.deflated
const default_name = str(Method.deflated)

struct Entry:
    size: i64
    method: Method = Method.stored

func made(method: Method = Method.deflated) -> Method:
    return method

func main():
    assert(default_name == "deflated")
    let plain = Entry(size = 3)
    assert(plain.method == Method.stored)
    assert(made() == Method.deflated)
```

## Containers, and maps keyed by an enum

Containers hold enums like any scalar, at the backing width: `list(Method)`,
`map(string, Method)`, `array(Method, n)`, and a struct field. An array of
enums fills with the first member (the enum's zero, below).

An enum may also be a map **key**, wherever a `long` or `string` key
stands, because an enum is an integer whose entire comparison surface is
equality — which is exactly what a key is for. A key travels internally as
the integer a `long` key would be and comes back out as the enum it went in
as, so `for k in m` binds `k` at the enum type and `m.keys()` answers a
`list` of the enum:

```luce
enum Key:
    left
    right
    up

enum Intent:
    move_left
    move_right
    nothing

const bindings = {Key.left: Intent.move_left, Key.right: Intent.move_right}

func intent(k: Key) -> Intent:
    return bindings.get(k) else Intent.nothing

func main():
    assert(intent(Key.left) == Intent.move_left)
    assert(intent(Key.up) == Intent.nothing)
    for k in bindings:
        print(f"{str(k)} {str(bindings[k])}")
```

Two enum types never collide as a key, and neither do an enum and a
`long`: `map(Key, V)` accepts a `Key` and nothing else. A duplicate enum
key in a `const` literal is refused and the diagnostic names the member.
Still not keys: `double`, `bool`, a struct, and the containers — and
`map(int, V)` is refused too, because the narrow widths are storage, not
key types.

## The zero value

An enum's zero is its first declared member. A late `var` starts there, an
`array(Method, n)` fills every cell with it, and any place that has a zero
value has that one:

```luce
enum Method:
    stored
    deflated

func main():
    var m: Method
    assert(m == Method.stored)
    m = Method.deflated
    assert(m == Method.deflated)
```

Zero itself is not used, because it need not be a number any member holds;
the first member is what a declaration already put first, and the one
promise an enum makes is that every value of it is a member.

## Representation

In the compiler an enum value is its backing integer, and the type carries
both the enum-table index and the rung of the integer ladder its members
are stored at. `match` lowers to the compare-and-branch tree LLVM turns
into a jump table; with every member named, the last arm is the fallthrough
and no test rejects a value that cannot occur. `string(m)` lowers to the
same compare-and-branch tree, answering a member name interned in the
program's constant pool. A hand-made module that puts a number no member
holds into an enum register is refused by the verifier.

The runtime (`libluce_rt`) learns nothing new for enums: an enum value is
an integer everywhere it travels, a container of enums is a container of
integers at the backing width, and an enum map key hashes and compares as
the integer it is. Both engines — the compiled path and the interpreter
oracle — run the same MIR, so a disagreement about a width or a name would
show up in the spec suite rather than in a program.
</content>
</invoke>
