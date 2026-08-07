# Traps are bugs, errors are news

Most languages have one mechanism for everything that can go wrong and
then a culture around when to use it. Luce has three, and one sentence
that decides between them.

> A failure is an **error** if and only if a correct program, given
> correct input, can still meet it — because the world decided, not
> the program. Everything else is a trap. And if the answer is simply
> "there is nothing there", with no reason worth carrying, it is
> neither: it is a `T?`.

Operationally, ask one question: **could the caller have prevented
this with a check that is not racy?**

If yes, it is a **trap**. The check is the program's job, and reaching
the failure means the program did not do its job. Index out of bounds,
a missing map key, integer overflow, popping an empty list — every one
of those is preventable by a check the caller could have written, so
every one of them is a bug.

If the check is inherently racy or impossible, it is an **error**.
Reading a file is the canonical case: `file_exists` before `file_read`
is a race no program can close, and the answer could change between
the two calls. So the read is fallible and says `!`.

If there is no reason worth carrying — just absence — it is a `T?`.
`parse_int("hello")` fails the same way every time, and the function
name already says what it wanted, so absence carries all the
information there is.

## What the rule moved

Applying that rule to the trap codes Luce had then moved exactly one
of them. What it moved was the host's file boundary — reads and writes
became fallible — and the five whole-array reductions in
`std.math`, which took `?` rather than `!` because an empty array has
no mean and that is absence rather than failure.

The seven traps left in `std.math` are domains the caller was handed
and could have checked: `ln` of a non-positive number, `pow` and
`ipow` outside theirs, a shape mismatch in `dot` or `axpy`, and
`in_range` with an empty range. Those are bugs, and bugs trap.

## Why not a `Result` type

Because Luce has no tagged unions. `Result<T, E>` needs one, and
adding tagged unions to get error handling would have been the tail
wagging the dog.

What Luce did instead is make fallibility an **attribute of the
function** rather than a type. `T!` is not a type: there is no `T!` to
declare a variable of, to put in a `list`, or to write in a struct
field, and `return x` in a `-> T!` function just returns `x`, with
nothing to wrap it in.

That turned out better than "probably right". The attribute is what
gave Luce Ok-wrapping for free — you never write the wrapper — and it
kept the type system entirely out of the feature: not one exhaustive
switch over the type union grew an arm. It is, however, the third
design in the language bent around the same missing hole, and the
[status page](/status/) says so.

## try is return with one terminator changed

`try` releases what this frame owns, innermost scope first, and
leaves. That is the same three lines `return` emits, with the last one
different. The one difference is what it *keeps*: `return` passes the
returned binding as moved and skips freeing it, and `try` passes
nothing, because it hands back no value.

That single bit is the whole of what Zig spells `errdefer`, and it was
already a parameter of Luce's unwinder before errors existed. Which is
why there is no `errdefer` and never will be.

```luce run
import std.files
import std.strings

func load(path: string) -> list(string)!:
    var found: list(string) = []
    let text = try files.read(path)       # `found` is released if this leaves
    for line in text.split("\n"):
        if line != "":
            found.append(line)
    return found                          # …and moved out if it does not

func main() -> !:
    try files.write("data.txt", "alpha\nbeta\n\ngamma\n")
    let lines = try load("data.txt")
    print(f"{len(lines)} non-empty lines, first {lines[0]}")

    let missing = load("nothing.txt") catch new list(string)
    print(f"missing: {len(missing)}")
```

```output
3 non-empty lines, first alpha
missing: 0
```

Note the last line: `catch` and the call must agree on ownership. The
call hands over a fresh list, so the fallback does too.

## catch guards one call

The block form of `catch` attaches to exactly one call. That is what
separates it from an exception block, where a handler covers a region
and you have to work out which statement inside it failed.

```luce run
import std.files

func main() -> !:
    var status = "unknown"

    files.write("/nowhere/at/all", "x") catch:
        status = "write refused"
    print(status)

    # The expression form supplies a value instead.
    let text = files.read("/nowhere/at/all") catch "(default)"
    print(text)
```

```output
write refused
(default)
```

The block form attaches to a call written as a statement and to a
plain assignment, and to nothing else — a `let` would need the handler
to supply the value the name binds, and only `catch EXPR` can say
that.

## catch NAME: reads the reason

A handler that only knows *that* something failed usually ends up
guessing at why, in words of its own that go stale. Name the error and
it can say what actually happened.

```luce run
import std.files

func parse_port(text: string) -> long!:
    let port = parse_int(text) else error(f"not a number: {text}")
    if port < 1 or port > 65535:
        error(f"out of range: {port}")
    return port

func main():
    parse_port("nope") catch reason:
        print(f"bad port — {reason}")

    files.read("/nowhere/at/all") catch reason:
        print(f"no config — {reason}")

    # The handler's own message, unchanged, is what the runtime wrote.
    parse_port("99999") catch reason:
        print(reason)
```

```output
bad port — not a number: nope
no config — cannot read /nowhere/at/all
out of range: 99999
```

The name binds the error's **message** and nothing else: an immutable
`string`, scoped to the handler block, released with it, and subject
to the no-shadowing rule. Reading it below the block is
`luce.sema.name`.

It is not the code, because a `catch` guards one call and one call
raises with one code — there is nothing to branch on. It is not the
raise position either; that belongs to the report an *uncaught* error
gets, which the next section shows. And the expression form takes no
binding: a fallback that reads the reason is a message being built,
which is a statement, and that is the block form.

## An error's report is one line

An uncaught error out of `main() -> !` ends the run and prints the
words and the **one** place it was raised.

```luce raise
func read_setting(text: string) -> long!:
    return parse_int(text) else error(f"not a number: {text}")

func configure(text: string) -> long!:
    return try read_setting(text) * 2

func main() -> !:
    print(string(try configure("21")))
    print(string(try configure("x")))
```

```output
42
loom: error: not a number: x [user_error]
    raised in read_setting (main.luc:2:5)
```

A trap is a bug and the stack is its diagnosis. An error is news, and
where it came from is the news — so an error records its position once
and never assembles a trace. That is not only tidiness: carrying a
full trace would charge the **success** path of every `try` for
something to save and restore, and Luce's mode rules forbid making the
working path pay for the failing one.

## Two error codes, and no more

`io_failed`, raised by the host's file services, and `user_error`,
raised by `error(...)`. Not `not_found`, not `permission_denied` — a
host service answers yes, no, or out of memory, and genuinely cannot
tell those two apart. Inventing the codes would be inventing the
distinction.

There are no typed error sets and no error payloads beyond the
message. If your program needs to *branch* on why something failed,
that is a design conversation, not a `catch`.

## Choosing, in practice

| Situation | Shape |
|---|---|
| The caller indexed past the end | trap |
| The caller asked for a key it never inserted | trap |
| A sum overflowed 64 bits | trap |
| A function was handed a value outside its domain | trap |
| The disk refused a read or a write | error (`!`) |
| The program itself decided the input is unusable | error (`error(...)`) |
| The text was not a number | absence (`T?`) |
| The array was empty and there is no mean | absence (`T?`) |

When you are unsure between an error and a trap, the tell is whether
a *reason* is worth carrying to the caller. If there is exactly one
reason and the function's name already implies it, you wanted `T?`.
