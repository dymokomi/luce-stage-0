# Research notes

Brainstorming and deep-research documents that informed language and
toolchain decisions. **Nothing here is normative.** The language design
of record is the self-host repository's `LUCE_LANGUAGE_DESIGN.md`; the
stage-0 boundary contract is `../docs/FFI.md`. These files record how
the decisions were reached — the per-library demand matrices, the
comparative language studies, and the external research passes — and
are kept for the reasoning, not the rulings.

| File | Subject |
|---|---|
| `NATIVE_PLATFORM_RESEARCH.md` | Cross-platform native survey: SDL3, GPU stacks, input/gestures, packaging, ABI reality |
| `NATIVE_PLATFORM_CODEX_REPORT.md` | External deep-research pass on dependency distribution, C ABI lowering, binding generation |
| `NATIVE_INTEROP_DESIGN.md` | Null at the boundary, beautiful C imports, merging the ObjC shim step |
| `NATIVE_INTEROP_CODEX_REPORT.md` | External pass on ObjC/C++ glue-as-build-artifact architectures |
| `NATIVE_TOOLKIT_DESIGN.md` | Plain-language plan: what makes Metal/SDL3/CUDA easy in Luce |
| `NATIVE_TOOLKIT_CODEX_REPORT.md` | External pass on the per-library requirements matrix |
