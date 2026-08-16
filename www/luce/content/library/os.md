# std.os

`std.os` exposes facts and services supplied by the host. It is available
only to hosted programs; a host-less build cannot call these operations.

```text
import std.os
```

## Machine facts

| Signature | Meaning |
|---|---|
| `os.total_memory() -> i64` | physical memory in bytes; fixed for the run |
| `os.available_memory() -> i64` | memory the host could currently hand out; changes between calls |
| `os.cpu_count() -> i64` | logical processors the host schedules work onto |
| `os.used_memory() -> i64` | the host's total-minus-available reading |
| `os.shell.run(command: str) -> str!` | runs one command through the host shell and returns captured output plus its exit status |

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

```text
os.shell.run(command: str) -> str!
```

`shell.run` starts `/bin/sh -c` on Unix-like hosts and the platform shell on
Windows. It captures standard output followed by standard error and appends
one final line:

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
    let transcript = try os.shell.run("printf 'hello\\n'")
    print(transcript)
```

## Terminal facade

`os.term` groups terminal output, geometry, and input. `std.term` is a
shorter alias for the same facade. New terminal programs normally import
`std.term`; the methods are repeated here so code that already needs machine
facts does not require another namespace.

| Method | Purpose |
|---|---|
| `os.term.rows()`, `os.term.cols()` | terminal dimensions |
| `os.term.clear()` | clear the screen |
| `os.term.move(row, column)` | move the cursor |
| `os.term.style(foreground, background = -1, bold = false)` | set terminal style |
| `os.term.write(text)`, `os.term.flush()` | write and flush output |

`os.term.io.read()` returns the next event name or `none` at end of input.
After a read, `os.term.io.text()` is printable text for a text event;
`row()`, `column()`, `button()`, `modifiers()`, and `value()` return the
numeric data associated with mouse, wheel, and resize events. Coordinates
are zero based. Buttons are left `0`, middle `1`, and right `2`; modifier
bits are shift `1`, alt `2`, and ctrl `4`; wheel values are `+1` up and `-1`
down.

The event names include `text`, `enter`, `ctrl_s`, `up`, `escape`,
`mouse_press`, `mouse_release`, `mouse_drag`, `mouse_move`, `mouse_wheel`,
`resize`, and `none`.

`os.term.ui` is pure geometry. Its methods are `horizontal`, `vertical`,
`top_left`, `top_right`, `bottom_left`, `bottom_right`, `junction`,
`shadow`, and `shadow_dark`. `junction(top, right, bottom, left)` returns
the Unicode line glyph for the four continuing sides; all returned glyphs
occupy one ordinary terminal cell.

```text
import std.os

os.term.clear()
os.term.move(0, 0)
os.term.write(os.term.ui.top_left() + " hello")
os.term.flush()
let event = os.term.io.read()
```

Loom owns raw mode, alternate-screen setup, escape sequences, and output
sanitization. A Luce program receives terminal events and writes text; it
does not need to implement those host details.

[`std.term`](/library/term/) documents the complete frame, color, coordinate,
event, end-of-input, and restoration behavior. [`termui`](/library/termui/)
adds declarative layout and owns the application loop.

## Host effects are explicit

Importing `std.os` is harmless; calling one of its services crosses the host
gate. These operations are not permitted in compile-time constants, and their
answers should not be used as reproducible test fixtures. Pass a measured
value into pure logic when that logic deserves deterministic tests.
