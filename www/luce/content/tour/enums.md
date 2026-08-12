# Enums

Some numbers are secretly a set. A ZIP entry's compression method is
0 or 8; a DEFLATE block is 0, 1 or 2; a key press is one of fifteen
things. Written as numbers they need a comment beside them, and
written as an `elif` chain they need a final arm that says "and
anything else is a bug I did not think about".

An `enum` gives every value in the set a name, and `match` makes the
compiler check you have covered them.

```luce run
enum Method:
    stored
    deflated

func main():
    let m = Method.deflated
    print(string(m))
```

```output
deflated
```

`Method` is a type, `Method.stored` and `Method.deflated` are its two
values, and there are no others. Members are **namespaced always**:
there is no `stored` floating in the file, which is the one mistake C
made that Luce does not inherit.

## The numbers underneath

A member holds a number. Say nothing and they count from zero; write
`= value` and the members after it continue from there — C's rule,
verbatim, because the numbers are usually somebody else's.

```luce run
enum Method:
    stored = 0
    shrunk = 1
    deflated = 8

func main():
    print(f"{Method.stored} is {int(Method.stored)}")
    print(f"{Method.deflated} is {int(Method.deflated)}")
```

```output
stored is 0
deflated is 8
```

Neither direction is implicit. `int(m)` asks for the number and
`string(m)` asks for the name — the same conversion constructors every
other type uses, named for what they produce. An f-string hole is a
`string(...)` you did not write, which is why `{m}` above printed the
name.

A member is a **constant**, so it folds like any other: it may be a
file-scope `const`, a parameter's default, or a struct field's.

```luce run
enum Method:
    stored
    deflated

struct Entry:
    name: string
    method: Method = Method.stored

func main():
    let plain = Entry(name = "notes.txt")
    print(string(plain.method))
    let packed = Entry(name = "big.log", method = Method.deflated)
    print(string(packed.method))
```

```output
stored
deflated
```

## Choosing the width

An enum is stored at an integer width — `int` unless you say
otherwise. Write the width in parentheses when the set has to fit
somewhere narrow, such as an array with a cell per element.

```luce run
enum Cell(byte):
    empty
    wall
    door

func main():
    var room = new array(Cell, 3, 3)
    room[1, 1] = Cell.wall
    room[0, 2] = Cell.door
    var walls = 0
    for row in range(0, 3):
        for column in range(0, 3):
            if room[row, column] == Cell.wall:
                walls = walls + 1
    print(f"{walls} wall, and room[0,2] is {room[0, 2]}")
```

```output
1 wall, and room[0,2] is door
```

A member the width cannot hold is refused where it is written, and the
message says which width would hold it.

```luce fail
enum Method(byte):
    stored = 0
    deflated = 300

func main():
    return
```

```output
luce: compile failed
main.luc:3:5: deflated = 300 does not fit byte, which holds 0 to 255; write the enum's width wider — enum Method(long): [luce.sema.enum]
        deflated = 300
        ^~~~~~~~~~~~~~
```

Two members may not share a number, either. An enum is a set of
names, and a second name for one number would make `string(m)` a coin
toss — if you want an alias, `let` is what makes one.

## match

`match` dispatches on an enum. Arms are bare member names, and each
one opens a block the way every colon in Luce does.

```luce run
enum Colour:
    red
    green
    blue

func describe(c: Colour) -> string:
    match c:
        red:
            return "stop"
        green:
            return "go"
        blue:
            return "neither"

func main():
    print(describe(Colour.red))
    print(describe(Colour.blue))
```

```output
stop
neither
```

**Without an `else`, every member must have an arm.** That is the
whole reason the statement exists: the day somebody adds a member,
every match that did not name it stops compiling, and the compiler
tells you where.

```luce fail
enum Colour:
    red
    green
    blue

func main():
    let c = Colour.red
    match c:
        red:
            print("stop")
        green:
            print("go")
```

```output
luce: compile failed
main.luc:8:5: this match has no arm for member blue of Colour; write one, or an else for everything the arms above do not name [luce.sema.match]
        match c:
        ^~~~~~~
```

Write `else:` when you mean it, and it stands for every member the
arms above did not name.

```luce run
enum Colour:
    red
    green
    blue

func main():
    for raw in range(0, 3):
        let c = Colour(raw) else trap("0, 1 and 2 are all members")
        match c:
            green:
                print("green")
            else:
                print("not green")
```

```output
not green
green
not green
```

An `else` that covers nothing is refused, for the same reason: an arm
that catches nothing today would quietly catch the member somebody
adds tomorrow.

## Numbers from outside

The line above turned a number into a member with `Colour(raw)`. That
direction is **fallible**, because the number comes from a file, a
wire or a spec field, and *unknown member* is exactly what the caller
has to branch on. So `Colour(n)` answers `Colour?` — an
[optional](../absence/) like any other, with `none` where no member
holds that number.

```luce run
enum Method:
    stored = 0
    deflated = 8

func read(raw: long) -> string:
    let m = Method(raw)
    if m == none:
        return f"method {raw} is one I cannot read"
    return f"method {raw} is {m}"

func main():
    print(read(0))
    print(read(8))
    print(read(14))
```

```output
method 0 is stored
method 8 is deflated
method 14 is one I cannot read
```

That is the shape `std.zip` uses to read a real archive: the number in
the central directory becomes a `Method?`, an unknown one is named in
an error, and the two it can read become the two arms of a `match`.

## Equality, and no order

Members compare with `==` and `!=` and nothing else. An enum is a set
of names, not a number line, so `<` is refused — and the message says
what to write when you really did mean the numbers.

```luce fail
enum Priority:
    low
    high

func main():
    let a = Priority.low
    let b = Priority.high
    assert(a < b)
```

```output
luce: compile failed
main.luc:8:12: Priority is a set of names and has no order; write int(a) < int(b) to compare the numbers behind them [luce.sema.type]
        assert(a < b)
               ^~~~~
```

## An enum keys a map

A map may be keyed by an enum wherever it may be keyed by a `long` or a
`string`, and the reason is the one this whole chapter is about: an
enum is an integer at a chosen width whose entire comparison surface is
equality, which is exactly what a key is for.

The key stays the enum on the way out, too — `for k in m` binds a
`Key`, so a `match` on it is checked for exhaustiveness like any other,
and `m.keys()` answers a `list(Key)`.

```luce run
enum Key:
    left
    right
    quit

enum Intent:
    move_left
    move_right
    stop
    nothing

const bindings = {Key.left: Intent.move_left, Key.quit: Intent.stop}

func intent(pressed: Key) -> Intent:
    return bindings.get(pressed) else Intent.nothing

func main():
    print(string(intent(Key.left)))
    print(string(intent(Key.right)))
    for k in bindings:
        print(f"{k} -> {bindings[k]}")
```

```output
move_left
nothing
left -> move_left
quit -> stop
```

## Methods

An enum takes the methods and namespace functions a
[struct](../functions/) takes, under the same rules — a plain member
has implied `self`, while a namespace member says `static func`.

```luce run
enum Light:
    red
    green

    func go() -> bool:
        return self == Light.green

    func flip():
        match self:
            red:
                self = Light.green
            green:
                self = Light.red

func main():
    var light = Light.red
    print(string(light.go()))
    light.flip()
    print(f"{light}, and go is {light.go()}")
```

```output
false
green, and go is true
```

## What an enum is not

It is not a set of flags: `Method.stored | Method.deflated` is not a
`Method`, and the language will not pretend it is. Bit sets are
[integers with the bit operators](../values/), and an enum's job is
the other one — naming a value that is exactly one of a few things.

And a member carries no payload. A member is a name and a number, not
a name and a value — when each name needs to carry facts of its own,
that is a [union](../unions/), and its `match` arms extend the ones
you just learned with payload bindings rather than introducing a
second statement.
