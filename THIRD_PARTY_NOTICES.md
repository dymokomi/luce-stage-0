# Third-party notices

Luce release archives contain compiled portions of the following projects.
The archive places their complete license texts under
`share/licenses/third-party/`.

| component | why it is present | license shipped |
|---|---|---|
| LLVM 22.1.8 | statically linked into the `luce` compiler | Apache License 2.0 with LLVM Exceptions, including LLVM's legacy notice |
| Zig 0.16.0 runtime components | compiler runtime support in release binaries and runtime archives | MIT; compiler-rt portions are covered by the LLVM license text |
| GNU libstdc++ and libgcc (Linux only) | statically linked C++ runtime and unwinder for the pinned static LLVM build | GPLv3 with the GCC Runtime Library Exception 3.1 |

Luce, loom, the editor, TermUI, and the VS Code/Cursor extension remain under
Luce's dual MIT/Apache-2.0 terms. Operating-system libraries and frameworks
are not copied into the archive.

The release builder fails if any required notice is absent. This inventory is
part of the release contract; adding a statically linked or copied dependency
requires updating it and the archive check in the same change.
