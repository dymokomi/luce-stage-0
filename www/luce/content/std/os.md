# std.os

What machine is this? Three numbers, over the three host builtins that
ask for them, plus the small host-shell seam used by tools such as the
example editor.

```
import std.os
```

This module is **hosted**: how big the machine is belongs to the world
and not to the program, so every function here sits behind the host
gate exactly as `print` and `file_read` do. A program compiled without
host access cannot call one, and the compiler says so where it is
written rather than where it would run.

| Signature | Notes |
|---|---|
| `os.total_memory() -> long` | bytes of physical memory the machine has; fixed for the life of the run — the hardware's size, not a quota |
| `os.available_memory() -> long` | bytes it could still hand out. This one **moves**: ask twice and expect two answers |
| `os.cpu_count() -> long` | processors the host would schedule work onto — logical ones, so simultaneous multithreading counts threads |
| `os.used_memory() -> long` | total minus available; never negative |
| `os.shell.run(command: string) -> string!` | captured stdout/stderr followed by the command's exit status; quote arguments for the host shell |

```luce run
import std.os

func main():
    let total = os.total_memory()
    let available = os.available_memory()
    print(f"total is positive: {total > 0}")
    print(f"available fits inside it: {available <= total}")
    print(f"used is a part of the whole: {os.used_memory() <= total}")
    print(f"at least one processor: {os.cpu_count() >= 1}")
```

```output
total is positive: true
available fits inside it: true
used is a part of the whole: true
at least one processor: true
```

The sample prints relations rather than numbers because this page is
built on a real machine and yours is a different one. Everything above
holds on every machine; the numbers hold on none but the one that
printed them.

`os.shell.run` is deliberately a tool boundary rather than a portable
process API. It runs one command string through the host shell, and a
host that cannot start that shell reports `io_failed`.

Note what it does *not* claim: that `used_memory()` equals
`total - available` for the `available` read a line earlier. It takes
its own two readings, and the machine moved in between. This page said
otherwise until the build ran the sample and disagreed with it.

## Nothing here fails, and nothing here is absent

No function in this module answers `T?` or `T!`. A fact the host knows
is a number. A fact it does not know is a **refusal** —
[`host_unavailable`](/ref/failure/), the same trap a service the host
withheld would give.

That is a deliberate third answer rather than a missing one. There is
no `?` because "this host cannot tell you how much memory the machine
has" is not the ordinary case a program plans around, the way an unset
environment variable or the end of input is. There is no `!` because
nothing failed; what happened is that the program asked the wrong
host. And there is no zero, ever: a host that could not measure the
machine is never made to invent a number, because a number a program
cannot tell from a measurement is worse than a stop.

## What "available" means

It is the host's word, and the hosts differ. Both meanings are written
down rather than averaged into one:

| Host | "available" is |
|---|---|
| macOS | free, inactive and purgeable pages together — what the kernel can supply without swapping. Not `free` alone, which on macOS is close to meaningless: a 64 GiB machine reports about 3.7 GiB free and 38 GiB available, because almost nothing is kept idle and the difference is reclaimed on demand |
| Linux | the kernel's own `MemAvailable`, published precisely so that userland stops adding up the wrong fields. Where `/proc` is not mounted, free plus buffers — an understatement, because it leaves out the reclaimable page cache |
| anywhere else | nothing. The host answers that it cannot tell, and the program traps |

Neither is a promise. It is what was true at the moment of asking, and
it moved while the answer was being carried back.

## What these numbers are for

**Reporting and sizing, not deciding.** Memory moves between the
reading and the use of it, so `available_memory()` is a gauge and never
a guarantee — a program that checks it and then allocates has checked
nothing. Luce allocates through the runtime, which stops the run with a
trap of its own when memory runs out; that is what a program is
actually held up by, and this module is what a program *prints*.

`cpu_count()` is here although Luce has no threads. It is a fact to
report rather than one to act on, and it is in the language because the
machine's facts are one subject and one ABI version: asking for it a
release later would have cost every compiled artifact a rebuild to
learn one number.

## The builtins underneath

`os.total_memory()` is `os_total_memory()`, and so on down. The
builtins are spelled in the [reference](/ref/builtins/); this module
exists so that programs read the sentence rather than the slot name,
the way [`std.files`](/std/files/) stands in front of `file_read`.
