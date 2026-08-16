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

`os.shell.run` is intentionally a single command string, not a portable
argument-vector API. Quote arguments for the host shell. A host that cannot
start the command returns `io_failed`.

## Terminal facade

`os.term` groups terminal output, geometry, and input. `std.term` is a
shorter alias for the same facade.

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
