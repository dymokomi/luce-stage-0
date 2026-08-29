# Self, implied — and a call site that cannot lie

A method's receiver is `self`, supplied implicitly. A plain member
function is a method with a receiver; a `static func` member has none.
This is the reference for how the two are declared, how a method reads
or writes its receiver, and the rule the call site keeps.

## The rule the call site keeps

**`f(x)` never mutates a value. `x.advance(8)` may — and reads like
it.** Mutation's whole grammar is *a method on a receiver you hold*, the
way containers already read (`xs.sort()`), so structs and containers
share one mutation story. A free call cannot change a value under the
caller's feet; a method call on a receiver can, and the syntax shows it.

## `self` is implied

A struct's or enum's member function declares no `self`
parameter. Its body names `self` and `self.field` directly, and the
written signature lists only the arguments a caller passes:

```luce
struct Counter:
    var value: i64

    func read() -> i64:
        return self.value

    func bump():
        self.value += 1

func main():
    var counter = Counter(value = 4)
    print(str(counter.read()))
    counter.bump()
    print(str(counter.read()))
```

`counter.read()` and `counter.bump()` are the call shape: the receiver
in front of the dot, the passed arguments in the parentheses.

## `static func` — a member with no receiver

`static func` declares a member function with no `self` — the factories
and namespace helpers. It is called through the type, not through a
value:

```luce
struct Cursor:
    var pos: i64

    static func start() -> Cursor:
        return Cursor(pos = 0)

    func advance(by: i64):
        self.pos += by

func main():
    var c = Cursor.start()
    c.advance(8)
    print(str(c.pos))
```

`Cursor.start()` is a namespace call; `c.advance(8)` is a method call.
The keyword is the only thing that tells the two kinds apart — where a
first `self` parameter once would have.

State that a mutable value parameter might otherwise have threaded
through is expressed another way: multi-return into existing bindings,

```luce
func read_bits(data: i64, pos: i64, count: i64) -> (i64, i64):
    let value = data >> pos & ((1 << count) - 1)
    return value, pos + count

func main():
    var pos: i64 = 3
    var bits: i64 = 0
    bits, pos = read_bits(255, pos, 5)
    print(str(bits))
    print(str(pos))
```

a member function, a fresh construction, or a reference object whose
contents change through its own methods.

## Reader methods and writer methods

Whether a method **writes** its receiver is inferred from its body, to a
fixed point. A method is a **writer** when it stores to `self`, stores to
one of `self`'s value fields, or calls another writer on `self` — and the
inference follows those calls through forward declarations and several
wrappers. A method that only reads `self`, or that mutates the contents
of a referenced field such as `self.items.append(value)`, is a
**reader**. There is no per-method mutation marker: the receiver's own
mutability is the whole permission, exactly as it is for `xs.append`.

- A **reader** may be called on any binding — a `let`, a `var`, or a
  temporary.
- A **writer** requires the receiver to be a **bare mutable binding** — a
  `var` that names the value directly. Calling a writer on a `let` is
  refused with the sentence `let` refusals already use, and calling one
  on a nested place is not accepted; a receiver is replaced only through
  the bare `var` that names it.

```luce
struct Cursor:
    var pos: i64

    func advance(by: i64):
        self.pos += by

func main():
    let frozen = Cursor(pos = 0)
    print(str(frozen.pos))     # reading a let is fine
    var moving = Cursor(pos = 0)
    moving.advance(8)             # a writer needs a var
    print(str(moving.pos))
```

A writer may declare zero, one, or several ordinary results; the receiver
is never one of them. Because mutation is in place, every write completed
before an error remains visible while the error unwinds — there is no
hidden copy-back to undo it.

## The call surface stays honest in both directions

A method is called only as `value.method(...)`. It cannot be called
through its type, and a **writing** method cannot become a function value
(see `docs/BINDING.md`). A `static func` is called through its type, may
become a function value, and may be a `spawn` target.

## Where it lands in the pipeline

The parser accepts `static` before `func` inside a type and drops `self`
from the parameter grammar. Stage 4 keys method-versus-namespace
resolution on `static` and checks receiver mutability where `self` is
written. In MIR a method still lowers with the receiver as a hidden first
operand; a writing call needs the caller's slot itself rather than its
current value, so a writer lowers through `call_inout` with an `inout`
local zero. The interpreter aliases that slot and the LLVM backend
forwards an internal place descriptor through nested writers, so both
engines refuse and accept the same calls by construction.
