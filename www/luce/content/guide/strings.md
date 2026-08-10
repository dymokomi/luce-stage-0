# Strings and copies

A `string` in Luce is immutable UTF-8, and it is a **value**. It
copies on assignment and on call, it goes into a container with no
ceremony, and nobody frees it. This page is what that costs, what it
buys, and the one benchmark row where the bill is still visible.

## The problem it solved

A string's bytes used to live in a run-lifetime arena that was never
reclaimed. A program that built and discarded text grew without bound
even when it retained nothing at all — and the flagship program did
exactly that. `examples/editor/editor.luc` splices a line as

```
value[0:cursor] + extra + value[cursor:len(value)]
```

on every keystroke. Twenty thousand keystrokes into a 40 KB file
peaked at **1204 MB** of resident memory.

Reference counting would have fixed it. So would copy-on-write, and so
would a tracing collector. All three are refused in Luce at every
layer, permanently, so the fix had to be something else.

## The fix: the language's own claim, made literal

*Values copy.* A `string`'s bytes and a struct's field run have
exactly one owner, and **any store into something that outlives the
current statement copies them**. No owner ever holds a view of bytes
it did not allocate, so every one of them has a death point, and the
same machinery that frees a `list` frees a `string`'s bytes.

The measurements, on a churn loop that builds and discards one string
per iteration and retains nothing.  These are the runtime's own arena,
read off the reference implementation the test suite compares against;
compiled code hands the same allocations to the system allocator,
whose working set for this loop is 20.4 MB and equally flat:

| iterations | 0.5M | 1M | 2M | 4M |
|---|---|---|---|---|
| before | 15.5 MB | 29.4 MB | 59.9 MB | 121.0 MB |
| after | **1.8 MB** | **1.8 MB** | **1.9 MB** | **1.8 MB** |

Flat, and flat out to sixteen million iterations. The editor
simulation went from 1204 MB to **3.3 MB** peak, with the same output,
at 24 µs a keystroke instead of 9 — three orders of magnitude inside a
frame either way.

## What it cost, and what took most of it back

The bill arrived in one place. `bench/strings` went from **2.35× its C
twin to 3.40×**: 400,000 `string(i)` results and 400,001 split pieces
that used to be unreclaimed bump allocations and shared views became
800,000 allocate-and-free pairs. The other five benchmarks moved less
than 1%, exactly as predicted.

**Small-string optimisation took roughly three quarters of that
back.** A string of 22 bytes or fewer now lives inside the value that
carries it, so `string(long)` and `chr` allocate nothing at all. The
average split piece in that benchmark is 11.7 bytes and every `string(i)`
is at most 7, so almost every allocation the change added went away
again.

| benchmark | before SSO | after SSO | delta |
|---|---|---|---|
| loops | 85.4 ms | 83.5 ms | −2.2% |
| math | 108.9 ms | 107.4 ms | −1.3% |
| **strings** | 68.2 ms | 52.0 ms | **−23.8%** |
| arrays | 46.4 ms | 46.4 ms | −0.0% |
| matmul | 11.7 ms | 11.7 ms | +0.4% |
| stats | 33.8 ms | 34.2 ms | +1.2% |

Against the commit *before* copy-on-store, `strings` is still 11.6%
slower, and the five parity rows are within ±0.5%. The prediction that
SSO would remove "essentially all" of the regression was too strong,
and the repository says so rather than rounding it off.

What remains is **the copying itself**, not allocation: 400,001
twelve-byte duplications into list elements. Phase timing confirms it —
building 400,000 pieces with a `builder` costs exactly what it cost
before; the extra time appears in the phases that store pieces into
lists.

## What this means when you write Luce

**Values in containers are free of ceremony and not free of cost.**
Appending a `string` to a list copies its bytes. For 11-byte pieces
that is a `memcpy` you will never notice; for a megabyte of text in a
loop it is real.

**A `builder` is the answer for accumulation.** Repeated `+` allocates
a new `string` per step; a `builder` does not, and `append_ascii` puts
a byte in without the `string` a `chr()` would have made.

```luce run
func main():
    # The shape that allocates per step.
    var slow = ""
    for i in range(0, 5):
        slow += string(i) + ","

    # The shape that does not.
    var fast = new builder()
    for i in range(0, 5):
        fast.append(string(i))
        fast.append_ascii(44)

    print(slow)
    print(fast.build())
```

```output
0,1,2,3,4,
0,1,2,3,4,
```

**Slices are values, and cheap ones.** `s[a:b]` on a `string` stays a
value and does not allocate an object; what it may do is copy bytes
when it is stored somewhere lasting. `xs[a:b]` on a *list* is
different — that allocates a new list the receiver owns.

## Search is a primitive because the library builds on it

The language keeps `len`, `byte_at` and `find_byte`, and nothing else
about searching. That is deliberate: `strings.find` locates a
needle's first byte with `find_byte` and only then compares the rest,
so the scan is one runtime call the implementation may vectorize
rather than a Luce loop over `byte_at`. `fold_case` emits folded bytes
with `append_ascii`, which needs no `string` per character.

Those two are why the whole `strings` module can stay written in
ordinary Luce and still be fast enough to keep. `fold_case` is also
marked `private`: it is an internal of `lower` and `upper`, and
[visibility](/tour/visibility/) is what keeps a fast internal from
becoming a public promise by accident.

```luce run
import std.strings

func main():
    let haystack = "alpha;beta;gamma;delta"
    var at: long = 0
    var found = 0
    while true:
        let next = haystack.find(";", at) else -1
        if next < 0:
            break
        found += 1
        at = next + 1
    print(f"{found} separators, {len(haystack.split(";"))} pieces")
```

```output
3 separators, 4 pieces
```

## Returning a slice of a parameter

Returning a borrowed *object* is a compile error. A `string` is not an
object, so it copies instead: `strings.trim` ends with
`return s[first:last]`, a view of its parameter, and what comes out is
a copy the caller owns. That is why the rule about returns is stated
as being about objects.
