#!/bin/sh
# Build the LLVM that `luce` links, from pinned source, statically.
#
# Luce compiles through libLLVM in process.  Linking a system LLVM
# works and stays supported, but it makes the toolchain depend on
# whatever the machine happens to have installed, and drift in it is
# invisible until something breaks.  This script removes that: one
# pinned tarball, one hash, one set of flags, one static link.
#
#   ./vendor-llvm.sh          # fetch, configure, build, install
#   ./build.sh                # picks up .llvm/install automatically
#
# Everything lands in .llvm/ (gitignored): ~161 MB tarball, ~2.3 GB of
# source, ~1.6 GB of build tree.  The build takes roughly half an hour
# on sixteen cores and is needed once per pinned version — `zig build`
# never triggers it.  Delete .llvm/ to go back to the system LLVM.
#
# Requires cmake and ninja.

set -e
root="$(cd "$(dirname "$0")" && pwd)"
cd "$root"

version=22.1.8
sha256=922f1817a0df7b1489272d18134ee0087a8b068828f87ac63b9861b1a9965888
url="https://github.com/llvm/llvm-project/releases/download/llvmorg-$version/llvm-project-$version.src.tar.xz"

for tool in cmake ninja; do
    command -v "$tool" >/dev/null || {
        echo "vendor-llvm: $tool is required (macOS: brew install $tool)" >&2
        exit 1
    }
done

work="$root/.llvm"
tarball="$work/llvm-$version.src.tar.xz"
source_dir="$work/llvm-project-$version.src"
build_dir="$work/build"
prefix="$work/install"
mkdir -p "$work"

# The hash is the pin.  A tarball that does not match it is not the
# LLVM this compiler was tested against, so refuse rather than build
# something else and call it version 22.1.8.
if [ ! -f "$tarball" ]; then
    echo "vendor-llvm: fetching LLVM $version"
    curl -fL --progress-bar -o "$tarball.part" "$url"
    mv "$tarball.part" "$tarball"
fi
# macOS ships `shasum` and no `sha256sum`; most Linux distributions do
# the opposite.  Either one checks the pin, and a machine with neither
# is told so rather than having the check quietly skipped.
if command -v shasum >/dev/null; then
    checksum="shasum -a 256 -c -"
elif command -v sha256sum >/dev/null; then
    checksum="sha256sum -c -"
else
    echo "vendor-llvm: neither shasum nor sha256sum is here, so the pin cannot be checked" >&2
    exit 1
fi
echo "$sha256  $tarball" | $checksum >/dev/null || {
    echo "vendor-llvm: $tarball does not match the pinned hash; delete it and retry" >&2
    exit 1
}

[ -d "$source_dir" ] || {
    echo "vendor-llvm: extracting"
    tar xf "$tarball" -C "$work"
}

# Only what the backend reaches: three targets, no tests, no
# examples, no bindings, and every optional external library off so
# the static link needs nothing beyond libm and the C++ runtime.
# AArch64 and X86 are the hosts we build on; WebAssembly is kept
# because a .lc is portable and cross-compiling to wasm32 should not
# require rebuilding LLVM.
echo "vendor-llvm: configuring"
cmake -G Ninja -S "$source_dir/llvm" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DLLVM_TARGETS_TO_BUILD='AArch64;X86;WebAssembly' \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_LINK_LLVM_DYLIB=OFF \
    -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_ENABLE_PIC=ON -DLLVM_APPEND_VC_REV=OFF \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_CURL=OFF \
    -DLLVM_ENABLE_HTTPLIB=OFF -DLLVM_ENABLE_BINDINGS=OFF \
    >/dev/null

echo "vendor-llvm: building (this is the long part)"
ninja -C "$build_dir"
ninja -C "$build_dir" install >/dev/null

"$prefix/bin/llvm-config" --version >/dev/null
echo "vendor-llvm: installed $("$prefix/bin/llvm-config" --version) ($("$prefix/bin/llvm-config" --shared-mode)) in $prefix"
echo "vendor-llvm: ./build.sh will use it from here on"
