# Traps and errors

Three shapes, and one rule that decides between them.

> A failure is an **error** if and only if a correct program, given
> correct input, can still meet it — because the world decided, not
> the program. Everything else is a trap. And if the answer is simply
> "there is nothing there", with no reason worth carrying, it is
> neither: it is a `T?`.
>
> **Traps are bugs. Errors are news.**

[Traps are bugs, errors are news](/guide/failure/) is the working
guide to applying it.

## Traps

A trap is deterministic, carries a stable code, and ends the program
without publishing anything. Every check that raises one is part of
the language and cannot be disabled: there is no build mode in which
`long` arithmetic wraps or an index goes unchecked.

A debug build reports `code`, message, `file:line:column` and the call
trace. `--release` keeps the code, the message and the function names
and drops the lines. A trace keeps the innermost 64 frames and counts
the rest.

### The codes

| Code | Message | Raised when |
|---|---|---|
| `integer_overflow` | integer overflow | a checked `int` or `long` operation leaves its width |
| `divide_by_zero` | division by zero | integer `//` or `%` with a zero divisor; real `/` follows IEEE and does not trap |
| `conversion_range` | conversion out of range | an explicit numeric conversion or storage narrowing cannot represent its value |
| `assertion_failed` | assertion failed | `assert(false)` |
| `explicit_trap` | explicit trap | `trap(message)` |
| `missing_return` | function ended without returning a value | compiler defense: sealing typed MIR after stage 4 has already refused a source path that falls off |
| `call_depth_exceeded` | call depth exceeded | the call-depth budget ran out |
| `string_bounds` | string index out of bounds | a `string` index or slice past the end |
| `string_boundary` | string slice splits a UTF-8 sequence | a `string` slice cutting a character |
| `host_unavailable` | host service unavailable | an effect the host does not implement |
| `index_bounds` | index out of bounds | a list or array index past the end |
| `key_missing` | key not found in map | indexing a map with an absent key |
| `empty_collection` | pop from an empty list | `pop()` on an empty list |
| `use_after_free` | object used after free | an alias or resource handle used after its owner released it ([S9](../ownership/#s9)) |
| `null_object` | null object reference | using an unfilled container/resource handle slot ([S41](../ownership/#s41)) |
| `bad_codepoint` | invalid character code | `chr` outside Unicode, or `append_ascii` outside 0..127 |
| `not_owned` | object is owned by a container | never, from source — see below ([S23](../ownership/#s23)) |
| `shift_out_of_range` | shift count out of range | `x << n` or `x >> n` with `n < 0` or `n` at or past the operand's width — C leaves this undefined and Go silently masks; Luce says it |
| `allocation_failed` | not enough memory for this container | the allocator refuses container storage or a resource row |
| `immutable_object` | constant container is immutable | mutating a program-root constant through a parameter that hid its provenance ([S46](../ownership/#s46)) |
| `ownership_cycle` | attempted store would create an ownership cycle | an alias-hidden retaining store would place an owner inside itself or one of its descendants ([S20](../ownership/#s20), [S33](../ownership/#s33)) |

Four stable messages predate the container/resource vocabulary.
`use_after_free`, `null_object`, and defense-only `not_owned` use
“object” in the runtime's broad heap-handle sense, so they can include a
`file` or `task`; `allocation_failed` says “container” even when the
allocator refused a resource row. The source reference otherwise uses
*object* for containers. A coordinated wording migration is tracked in
the language-lock ledger rather than changing one stable message here.

Two codes are compiler defenses rather than paths correct source can
reach. **`missing_return`** seals a typed MIR block only after stage 4
has diagnosed a source function that can fall off its end.
**`not_owned`** was S23's dynamic check — `give` through an alias —
until 2026-08-04, when that became a compile error because the compiler
already knows an alias where it stands. The runtime check remains
because the IR verifier trusts instruction types and a `.lc` is an
executable: a damaged or forged module can still present a `give` that
names a binding owning nothing. A correct compiler cannot emit either
defense path.

Call depth is a **policy** limit, not a native-stack accident:
compiled code carries its remaining depth as a hidden argument and
refuses the call that would exhaust it. Runaway recursion is a trap
with a message and a call stack, never a segmentation fault.

```luce trap
func main():
    var xs = [1, 2, 3]
    print("before")
    print(string(xs[7]))
```

```output
before
loom: trap: index out of bounds [index_bounds]
    at main (main.luc:4:5)
```

## Errors

An error carries a stable code and a message. There are exactly two
codes.

| Code | Raised by |
|---|---|
| `io_failed` | the host's file services |
| `user_error` | `error(message)` |

Not `not_found` and not `permission_denied` — a host service answers
yes, no, or out of memory, and cannot tell those two apart, so
inventing the codes would be inventing the distinction.

There are no typed error sets and no error payload beyond the message.

### Declaring, raising, propagating, handling

`-> T!` on a function says it may raise. `-> !` says it returns
nothing or an error. `T!` is not a type: fallibility is an attribute
of the function.

`error(message)` raises. It never returns, so it may stand where a
value belongs.

`try CALL` propagates, releasing what this frame owns
([S4](../ownership/#s4)). It requires the enclosing function to
declare `!`.

`catch` handles. `EXPR catch FALLBACK` supplies one value. The block
forms `CALL catch:` and `CALL catch NAME:` guard exactly one call and
attach to a call statement, a single-place assignment, or an
existing-name multi-return assignment.

```
left, right = try read_pair()
left, right = read_pair() catch reason:
    print(reason)
```

On success the multi-return assignment performs both replacement
stores; on failure it performs neither. Ordinary side effects from
evaluating the right side have already happened and remain visible in
the handler. `catch VALUE` cannot supply a return shape because it
supplies only one value; there are still no tuple or comma-list
expressions.

`NAME` is an immutable `string` scoped to the handler block, released
with it, and subject to the no-shadowing rule. It carries the message
only — not the code, and not the raise position. The expression form
takes no binding.

A fallible call whose outcome is neither tried nor caught is
`luce.sema.fallible`.

### The report

An uncaught error out of `main() -> !` ends the run. The host prints
the words and the **one** place it was raised — one line, not a stack.

```luce raise
func check(n: long) -> long!:
    if n < 0:
        error(f"negative: {n}")
    return n

func main() -> !:
    print(string(try check(1)))
    print(string(try check(-5)))
```

```output
1
loom: error: negative: -5 [user_error]
    raised in check (main.luc:3:9)
```

A debug build names the position; `--release` keeps the function name
and drops the line. An error records that position **once**, where it
was raised, and never assembles a trace — which is what keeps the
success path of a `try` free of anything to save and restore.

### No errdefer

There is none, and there will not be. Cleanup is scope ownership,
which already knows that `return` moves what it hands back and `try`
moves nothing. The one bit `errdefer` encodes is already a parameter
of the unwinder.

## Absence

Neither a trap nor an error. `T?` is the shape when the only fact is
that there is nothing there.

In the language: `parse_int` and `parse_float` answer `long?` and
`double?`.

In the standard library: `math.mean`, `math.vmin`, `math.vmax`,
`math.variance` and `math.stddev` answer `double?`, because an empty
array has no mean.

The seven traps that remain in `std.math` are domains the caller was
handed and could have checked: `ln` of a non-positive number, `pow`
and `ipow` outside theirs, a shape mismatch in `dot` or `axpy`, and
`in_range` with an empty range.
