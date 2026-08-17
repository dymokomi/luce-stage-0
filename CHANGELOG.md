# Changelog

Luce is pre-1.0. The source language, module format, host ABI, package
manifests, and command-line surface may change between 0.x releases; each
release is a complete toolchain rather than a compatibility promise.

## 0.18 — release candidate

This is the published release candidate described by `VERSION` and the
checked installer under
`www/luce/install/0.18/install.sh`.

- ARC is the one lifetime model for classes, containers, closures, interfaces,
  files, tasks, windows, and GPU surfaces. Weak references break supported
  cycles, and workers copy permitted graphs without sharing identity.
- The language has explicit-width numeric types, `char`, `str`, `bytes`,
  transparent `alias`, final classes with custom initialization, nominal
  interfaces, multiple returns, recoverable errors, and local package
  creation/versioning commands.
- TermUI 0.3 and the bundled editor are ordinary Luce programs. TermUI owns
  the terminal loop and the editor can compile and run the current file.
- `std.ui` and `std.gpu` expose the current low-level host surfaces. Native
  window and Metal support is available on the published macOS target; other
  hosts fail closed where the service is unavailable.
- The installer supplies `luce`, `loom`, the editor, runtime libraries,
  TermUI, and the VS Code/Cursor syntax extension on macOS 15+ ARM64 and glibc
  Linux 2.28+ ARM64/x86-64. Archives carry source identity, toolchain and
  ABI metadata, licenses, and reproducible tar/gzip metadata.

The complete release gate, clean-room journeys, and deployment proof have
passed for the published candidate. It remains pre-1.0: the source language,
module format, host ABI, package manifests, and command-line surface may still
change between 0.x releases.
