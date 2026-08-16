# Publishing Luce for Linux

This directory owns the Linux release build, not ordinary Linux development.
[`../linux-check/`](../linux-check/) is the fast system-LLVM environment for
the complete repository gate. This one answers a different question: can a
person download the published archive on an ordinary machine that has no LLVM
development package?

The answer is built on the `manylinux_2_28` glibc floor for both `aarch64` and
`x86_64`. The base images are named by immutable digest. Zig 0.16.0 is fetched
from ziglang.org and checked against its published SHA-256. LLVM 22.1.8 is
built by the repository's [`vendor-llvm.sh`](../../vendor-llvm.sh), which pins
and checks its own source, disables optional dependencies, and produces static
libraries. The resulting `luce` compiler depends on glibc but not libLLVM,
libstdc++, Z3, XML, zstd, or another unpublished release component.

Build either native prefix with:

```sh
tools/linux-release/build.sh aarch64 /tmp/luce-aarch64
tools/linux-release/build.sh x86_64 /tmp/luce-x86_64
```

The first image build compiles LLVM and is deliberately long. Docker caches
that layer; ordinary Luce release builds reuse it. On an Apple Silicon host,
the x86-64 image runs under emulation and is correspondingly slower.

Rosetta can lose short-lived child-process notifications during LLVM's CMake
configuration. The manual `Linux x86-64 release prefix` GitHub Actions
workflow runs this same builder on a native x86-64 host. Download and extract
its tarball, then let the site release reuse that verified prefix:

```sh
LUCE_LINUX_X86_64_PREFIX=/absolute/path/to/prefix ./www/luce/release.sh
```

The workflow names its artifact with the source commit. Keep that commit
matched to the tree used for the macOS and arm64 archives.

The public archive assembly and clean-machine installer smoke tests belong to
[`www/luce/release.sh`](../../www/luce/release.sh). Keeping those outside this
directory gives all three platforms one archive layout and one installer
contract instead of a Linux-shaped fork.
