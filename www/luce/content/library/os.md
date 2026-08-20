# std.os

`std.os` exposes facts and services supplied by the host: console, time,
environment, one shell door, and machine facts. It is available only to
hosted programs; a host-less build cannot call these operations. The
terminal is its own module, [`std.term`](/library/term/).

```text
import std.os
```

Host implementation names are compiler-private. A program may use names such
as `clock_ms`, `run`, or `dir_create` for its own declarations; only the
qualified APIs on this page cross the OS boundary.

## Console, environment, and time

| Signature | Meaning |
|---|---|
| `os.read_line(prompt: str) -> str?` | writes the prompt and reads one line without its newline; `none` at end of input |
| `os.print_error(text: str)` | writes one sanitized line to standard error |
| `os.env(name: str) -> str?` | one environment variable, or `none` when unset |
| `os.clock_ms() -> i64` | monotonic milliseconds for measuring elapsed time |
| `os.epoch_ms() -> i64` | milliseconds since the Unix epoch |
| `os.sleep_ms(milliseconds: i64)` | waits at least this long; zero and negative durations return immediately |

## Deadlines

| Signature | Meaning |
|---|---|
| `os.deadline(after_ms: i64) -> Deadline` | the moment `after_ms` from now, on the monotonic clock |
| `Deadline.expires` | the moment itself — hand it to a blocking call's deadline form, `inbox.receive_by(stop.expires)` |
| `Deadline.remaining_ms() -> i64` | what is left of the moment, clamped at zero once it has passed |
| `Deadline.passed() -> bool` | has the moment passed? |

A `Deadline` is one budget for a whole exchange: build it once and hand
`expires` to each call, and every call takes what is *left* of the same
moment (docs/CANCEL.md).

Use `os.clock_ms` only in differences; its epoch is deliberately unspecified.
Use `os.epoch_ms` for a timestamp. An absent input line or environment value
is ordinary absence, while a host without the requested channel traps with
`host_unavailable`.

```luce run
import std.os

func main():
    let started = os.clock_ms()
    os.sleep_ms(0)
    print(f"elapsed is nonnegative: {os.clock_ms() >= started}")
    print(f"missing variable: {os.env("LUCE_NOT_A_REAL_VARIABLE") else "(unset)"}")
```

```output
elapsed is nonnegative: true
missing variable: (unset)
```

## Machine facts

| Signature | Meaning |
|---|---|
| `os.total_memory() -> i64` | physical memory in bytes; fixed for the run |
| `os.available_memory() -> i64` | memory the host could currently hand out; changes between calls |
| `os.cpu_count() -> i64` | logical processors the host schedules work onto |
| `os.used_memory() -> i64` | the host's total-minus-available reading |

The memory values are measurements, not reservations. `available_memory()`
can change before an allocation, and `used_memory()` takes its own pair of
readings. `cpu_count()` is a reporting fact and a useful bound for sizing a
batch of independent `spawn` calls. A host that cannot provide a fact traps
with `host_unavailable`; these functions do not return `none` or `!`.

All memory values are bytes and fit in `i64` on supported hosts. On macOS,
available memory includes free, inactive, and purgeable pages; on Linux it is
the kernel's `MemAvailable` estimate when present. Neither value is a quota or
an allocation guarantee. Let an allocation report exhaustion through the
runtime rather than trying to reserve memory by reading a gauge first.

```luce run
import std.os

func main():
    let total = os.total_memory()
    print(f"total is positive: {total > 0}")
    print(f"available fits inside total: {os.available_memory() <= total}")
    print(f"at least one processor: {os.cpu_count() >= 1}")
```

```output
total is positive: true
available fits inside total: true
at least one processor: true
```

## Run a host-shell command

```
os.run(command: str, input: str = "") -> str!
```

`os.run` starts `/bin/sh -c` on Unix-like hosts and the platform shell on
Windows. `input` is fed to the command's standard input, whole, before
output is collected — `os.run("sort", lines)` behaves like a pipe, and
the default is the empty feed. It captures standard output followed by
standard error and appends one final line:

```text
exit status: 0
```

A non-zero exit status is part of that transcript, not a Luce error. Failure
to start or communicate with the shell is `io_failed`; a host that withholds
the shell channel traps `host_unavailable`.

The input is intentionally one command string, not a portable argument-vector
API. Shell quoting, expansion, pipelines, redirection, and command injection
therefore have their normal host meaning. Do not concatenate untrusted text
into the command. Prefer `std.files` or another structured host API when it
already expresses the operation.

```text
import std.os

func main() -> !:
    let transcript = try os.run("printf 'hello\\n'")
    print(transcript)
```

## A child you can hold

```
os.Process(command: str) -> os.Process!     # spawn, streams piped
Process.feed(text: str) -> !                # write to the child's stdin
Process.finish_input() -> !                 # the child's end of input
Process.read(buffer: array[u8, _]) -> i64!  # io.Reader: 0 at end of output
Process.ready() -> bool!                    # would a read land right now?
Process.wait() -> i64!                      # exit status; finishes input first
```

`os.run` is the one-shot; a `Process` is the held conversation — spawn
once, feed and read as the protocol goes. It conforms to
[`io.Reader`](/library/io/), so framing code written against the
contract works on a child exactly as on a file or a connection. The
child's standard error stays on the host's, where complaints belong.
Releasing the last reference shuts the child down — input closed, and
a child still running is killed — so a dropped `Process` cannot leak.

```text
import std.io
import std.os
import std.strings

func main() -> !:
    let child = try os.Process("sort")
    try child.feed("b
a
")
    try child.finish_input()
    let sorted = try io.drain(child)
    print(strings.from_bytes(sorted) else "?")
    assert(try child.wait() == 0)
```

`ready()` answers whether a read would land without blocking — the
poll a pump asks between other work, which is how an editor holds a
language server without stalling its own loop.

## The process's own byte streams

```
os.stdin() -> os.Input!
os.stdout() -> os.Output!
os.stderr() -> os.Output!
```

The standard streams as classes speaking [`std.io`](/library/io/)'s
contract: `Input` conforms to `io.Reader` (`read(buffer) -> i64!`,
zero at end of input), `Output` to `io.Writer` (`write(buffer, count)`,
`flush`). A program that filters bytes or speaks a protocol over stdio
composes with everything else that speaks `std.io`:

```text
import std.io
import std.os

func main() -> !:
    let input = try os.stdin()
    let all = try io.drain(input)
    let out = try os.stdout()
    try io.send(out, all)
```

The descriptors belong to the process: releasing the last reference to
one of these classes does not close the real stream, and asking again
answers a fresh handle onto the same stream. Construction is fallible
for the reason `files.File`'s is — the world decides whether the
channel exists. While a `std.term` screen is up, the terminal owns
standard input; do not mix `term.read()` with byte reads of `stdin`.

## Host effects are explicit

Importing `std.os` is harmless; calling one of its services crosses the host
gate. These operations are not permitted in compile-time constants, and their
answers should not be used as reproducible test fixtures. Pass a measured
value into pure logic when that logic deserves deterministic tests.
