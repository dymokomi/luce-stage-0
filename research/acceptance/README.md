# FFI 0.21 acceptance probes

Non-normative probe programs that drive real C libraries through the
0.21 extern surface (docs/FFI.md), written the way production epoch-1
code would be.  Nothing here is a spec: the specification suite in
`src/luce/specs/ffi_spec.zig` pins the boundary's semantics against
probe symbols; these programs prove the same surface holds up against
a real foreign API's shapes.

## llvmc.luc

Drives Homebrew LLVM's C API — the epoch-1 self-hosted compiler's one
real FFI customer.  In one program it exercises:

- `extern type` named handles (`LLVMModuleRef`, `LLVMBuilderRef`,
  `LLVMTypeRef`, `LLVMValueRef`, ...) held nominal across ~30 calls;
- seamless `str` both directions (names in; `LLVMGetTarget` and
  `LLVMGetValueName2` results out);
- `LLVMValueRef?` null-on-miss decode (`LLVMGetNamedFunction`);
- `out` parameters, including C's `char **` error convention
  (`LLVMVerifyModule`) read back as `out message: foreign?` and
  released through `LLVMDisposeMessage`;
- a borrowed `list[LLVMTypeRef]` parameter crossing as C's contiguous
  `LLVMTypeRef *` beside its count (`LLVMFunctionType`);
- owned C strings taken in one call — `c.take_str(pointer,
  LLVMDisposeMessage)`, the extern's own name converting to the
  disposer `cfunc` (`LLVMPrintModuleToString`,
  `LLVMGetDefaultTargetTriple`, the verifier's `char **` messages);
- a `u64` immediate at full width (`LLVMConstInt` with `i64.max`);
- a `cfunc` diagnostic handler (`LLVMContextSetDiagnosticHandler`)
  that C really invokes — garbage bitcode fed to
  `LLVMParseBitcodeInContext2` fires the Luce callback, which itself
  calls back into LLVM-C to read and dispose the message;
- the `Dispose` discipline for everything created.

It builds a module holding `i64 add(i64, i64)` and a constant global,
verifies it (and a deliberately sick sibling), prints the IR, and
shuts down clean.

## Build and run

Requires Homebrew LLVM (`brew install llvm`; not on PATH by default).
From the repository root, with a built `build/luce`:

```sh
LLVM_LIBDIR=$(/opt/homebrew/opt/llvm/bin/llvm-config --libdir)
build/luce build research/acceptance/llvmc.luc \
    --link "$LLVM_LIBDIR/libLLVM.dylib" -o /tmp/llvmc_probe
/tmp/llvmc_probe
```

The `-lNAME` spelling works too — `--link` values reach the driver as
written, so the search path rides along the same way:

```sh
build/luce build research/acceptance/llvmc.luc \
    --link "-L$LLVM_LIBDIR" --link -lLLVM -o /tmp/llvmc_probe
```

Expected output (the triple varies by host):

```text
target: arm64-apple-darwin24.6.0
verified: true
sick module rejected: true
verifier: Basic Block in function 'hole' does not have terminator!
label %entry
found @add (3 chars)
missing lookup is none: true
--- module IR ---
; ModuleID = 'probe'
source_filename = "probe"
target triple = "arm64-apple-darwin24.6.0"

@seed = global i64 9223372036854775807

define i64 @add(i64 %0, i64 %1) {
entry:
  %sum = add i64 %0, %1
  ret i64 %sum
}
-----------------
diagnostic (severity 0): Invalid bitcode signature
bitcode parse failed: true
parsed module is none: true
clean shutdown
```
