# std.c

`std.c` is the helper shelf for the C boundary. An `extern` declaration
speaks 32- and 64-bit integers and opaque `foreign` tokens; this module
spells the two things a program cannot otherwise say safely: hand a
callee the address of some bytes for the duration of one call, and
prepare text the way C expects text.

```text
import std.c
```

The guarantees of the language end at an extern call. A token that
escapes the scope `with_bytes` opens is dangling by contract, and
nothing checks what the callee does with the memory. Keep the boundary
small and audited.

## Scoped buffer access

| Signature | Result |
|---|---|
| `c.with_bytes(buffer: list[u8], body: func(foreign) -> i64) -> i64` | calls `body` with the buffer's address and answers what it answers |
| `c.with_bytes_foreign(buffer: list[u8], body: func(foreign) -> foreign) -> foreign` | the same scope for a callee that answers a token |

The buffer is the scope's parameter, so it stays alive for exactly the
call. The token is the address of the list's bytes — an empty list hands
over the null token. The callee learns the count some other way, because
C does. The buffer must not grow, shrink, or be released while the token
lives, and the token must not outlive the call.

## C strings

| Signature | Result |
|---|---|
| `c.zstring(text: str) -> list[u8]` | the UTF-8 bytes of `text` with one terminating zero |

The result is an ordinary byte list; `with_bytes` hands its address to a
callee that expects a NUL-terminated `char *`.

```luce run
import std.c

extern func luce_ffi_probe_sum_bytes(at: foreign, count: u64) -> i64

func main():
    var data = c.zstring("AB")
    let total = c.with_bytes(data, (p) -> luce_ffi_probe_sum_bytes(p, 3))
    print(str(total))
```

```output
131
```

The probe sums the bytes it is handed: `'A' + 'B' + 0` is `131`. Real
programs name real symbols and link their objects with
[`luce build --link`](/tools/command-line/).
