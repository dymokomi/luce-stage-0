# Vendored: MIR

- Upstream: https://github.com/vnmakarov/mir
- Commit: a8ab7c31cd5f9b23b77d84c60b3d83e62d9d304c
- License: MIT (see LICENSE in this directory)
- Local changes: one three-line patch, each line marked
  `LUCE PATCH`: `struct MIR_func` gains `machine_code_len`
  (mir.h), zeroed at func creation (mir.c) and set beside
  `machine_code` after `_MIR_publish_code` (mir-gen.c).  MIR
  retains each generated function's address but not its length;
  the length is what lets loom byte-compare generated code (the
  hermeticity oracle in `src/luce/native_spec.zig`) and, later,
  capture it into the native image (docs/NATIVE.md milestone 5).
  Re-apply when updating the snapshot.
  Otherwise a pristine copy of the runtime sources (tests, c2mir,
  llvm2mir, and driver programs omitted).

MIR is the optimizing JIT behind loom's native engine
(`src/luce/native.zig`): the verified Luce IR lowers to MIR's
textual form, `MIR_scan_string` assembles it, and `MIR_gen` emits
machine code in-process — x86-64 and aarch64, Linux, macOS, and
Windows, with no runtime dependency beyond this directory.

Only `mir.c` and `mir-gen.c` compile as translation units (see
`build.zig`); everything else is `#include`d by them.  To update:
copy the same file list from a newer upstream commit, record the
commit here, run the full test suite plus `bench/run.sh`.
