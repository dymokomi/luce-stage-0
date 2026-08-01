# tools

Developer tooling that ships with the repo but isn't part of loom.

## Testing every capability, on the right hardware

loom has three execution engines — the interpreter, the MIR JIT
(`native.zig`), and the self-written backend (`codegen.zig` for
aarch64, `codegen_x86.zig` for x86-64) — and each backend only
compiles for the host it runs on.  A single machine can't natively
build all of them, so the full matrix is covered in three ways, each
using hardware that can faithfully run what it tests.  Nothing is
skipped; the split is by *what the hardware can honestly do*, not by
what's convenient.

| capability | how it's tested | where |
|---|---|---|
| interpreter | `zig build test` | any host |
| MIR JIT, aarch64 | `zig build test` | this Mac (native) |
| self-written backend, aarch64 | `zig build test` | this Mac (native) |
| self-written backend, x86-64 | `tools/x86-test.sh verify` | this Mac (emulated) |
| MIR JIT, x86-64 | `tools/aws-test.sh` | real x86 (AWS) |

### `zig build test` — the primary suite (this Mac, native)

Interpreter, MIR, and the aarch64 self-written backend, all native,
all green.  The two-/three-engine oracle in `native_spec.zig` runs
every program on all engines present and demands identical results.
This is the suite to run for everyday work.

### `tools/x86-test.sh` — the x86 self-written backend (emulated)

```sh
tools/x86-test.sh verify   # x86 backend vs interpreter, every bench + program
tools/x86-test.sh bench    # output cross-check (timings under emulation are meaningless)
tools/x86-test.sh sh       # shell in the amd64 container
tools/x86-test.sh build    # rebuild the image
```

Runs the **x86-64** emitter under Docker's amd64 emulation (Rosetta on
this machine), so `codegen_x86` is testable with no x86 hardware.  Its
output is *static* machine code, which the emulator runs faithfully —
that's how a real register-allocation bug was found (the x86 scratch
pool was two registers where a three-operand instruction needs three).

It deliberately does **not** run the full `zig build test`: that
exercises MIR's JIT, which generates and runs code at run time, and a
CPU emulator cannot host a guest JIT reliably (Rosetta's translation
cache mistranslates it — every program runs correctly on real x86;
only long-lived JIT churn in one process trips it).  Emulating a JIT
isn't testing a JIT, so MIR-x86 is tested on real hardware instead.

### `tools/aws-test.sh` — MIR on real x86-64 (AWS)

```sh
tools/aws-test.sh          # launch, full `zig build test`, tear down
tools/aws-test.sh bench    # also bench/run.sh (real x86-64 timing)
tools/aws-test.sh keep     # leave the box up (prints the ssh line)
```

Launches a real x86-64 Linux instance, rsyncs the working tree
(tracked + untracked, minus build/cache — so it tests exactly what's
checked out, no commit needed), installs Zig, runs the full suite with
MIR included, and terminates everything it created on exit — even on
failure.  This is where MIR-x86 and real x86 benchmark numbers come
from.
