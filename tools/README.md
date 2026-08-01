# tools

Developer tooling that ships with the repo but isn't part of loom.

## Local x86-64 testing on an Apple-silicon Mac

The self-written backend has two targets — `codegen.zig` (aarch64)
and `codegen_x86.zig` (x86-64) — but each only compiles for the host
it runs on, so `zig build test` on an ARM Mac exercises only the
aarch64 emitter.  These scripts run the **x86-64** emitter locally,
under Docker's amd64 emulation (Rosetta on this machine), with no x86
hardware:

```sh
tools/x86-test.sh verify   # x86 zig backend vs interpreter, every
                           #   bench + bundled program (fast, reliable)
tools/x86-test.sh test     # full `zig build test` in the amd64 image
tools/x86-test.sh bench    # bench/run.sh output cross-check (not timed)
tools/x86-test.sh sh       # a shell in the container, repo mounted
tools/x86-test.sh build    # rebuild the image (Zig is cached in it)
```

The first run builds the image (downloads Zig 0.16 x86-64); later runs
reuse it, and a named volume keeps amd64 build artifacts out of the
host `.zig-cache`.

### What emulation can and can't host

The x86 emitter produces **static** machine code, so the emulator
just runs those instructions — `codegen_x86` is fully testable this
way, and `verify` proves it against the interpreter for every
benchmark and program.  This is exactly how a real bug was caught
(the x86 scratch pool had two registers where a three-operand
instruction needs three).

The **vendored MIR JIT** is different: it generates and runs code at
run time, and the emulator's translation cache can't keep up once
many MIR contexts churn in one process (every program runs correctly
on MIR *standalone*; only the many-contexts test binary trips it — a
Rosetta limitation, not our code or MIR's).  So `x86-test.sh` sets
`LOOM_TEST_NO_MIR=1`, which makes `native_spec`'s oracle validate the
interpreter against the self-written backend and skip the vendored
JIT.  MIR is proven on the aarch64 host locally (`zig build test`
there runs all three engines) and on real x86 in CI.

Timings under emulation are meaningless; real-x86 benchmarks are a
job for actual hardware.
