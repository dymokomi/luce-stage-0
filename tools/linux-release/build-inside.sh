#!/bin/sh
# Build one native Linux release prefix inside the pinned builder image.
set -eu

source_root=${LUCE_RELEASE_SOURCE:-/source}
output=${LUCE_RELEASE_OUTPUT:-/output}
architecture=${LUCE_RELEASE_ARCH:?LUCE_RELEASE_ARCH is required}
source_commit=${LUCE_RELEASE_SOURCE_COMMIT:?LUCE_RELEASE_SOURCE_COMMIT is required}
# Docker bind mounts can be owned by a different numeric user than the
# container's build user.  The source is read-only and selected by the host
# wrapper, so explicitly mark this one checkout safe for the provenance read
# instead of weakening Git's global safety policy.
source_epoch=$(git -c "safe.directory=$source_root" -C "$source_root" show -s --format=%ct "$source_commit")
case "$source_epoch" in
    ''|*[!0-9]*)
        echo "linux release: source commit has no numeric timestamp" >&2
        exit 1
        ;;
esac
export SOURCE_DATE_EPOCH="$source_epoch"

if ! printf '%s\n' "$source_commit" | awk '
    (length($0) == 40 || length($0) == 64) && $0 !~ /[^0-9a-f]/ { ok = 1 }
    END { exit ok ? 0 : 1 }
'; then
    echo "linux release: source commit is not a lowercase Git object id" >&2
    exit 1
fi

case "$(uname -m):$architecture" in
    aarch64:aarch64) target=aarch64-linux-gnu.2.28 ;;
    x86_64:x86_64) target=x86_64-linux-gnu.2.28 ;;
    *)
        echo "linux release: container architecture $(uname -m) does not match $architecture" >&2
        exit 1
        ;;
esac

for path in build.zig build.zig.zon VERSION src tools packages examples; do
    if [ ! -e "$source_root/$path" ]; then
        echo "linux release: source tree is missing $path" >&2
        exit 1
    fi
done

work=$(mktemp -d /tmp/luce-linux-release.XXXXXX)
cleanup() {
    rm -rf "$work"
}
trap cleanup 0 HUP INT TERM

mkdir -p "$output" "$work/home" "$work/local-cache" "$work/global-cache"
cd "$source_root"
HOME="$work/home" zig build \
    --prefix "$output" \
    --cache-dir "$work/local-cache" \
    --global-cache-dir "$work/global-cache" \
    -Dtarget="$target" \
    -Doptimize=ReleaseSafe \
    -Dsource-commit="$source_commit" \
    -Dllvm-config=/opt/luce-llvm/bin/llvm-config \
    --summary all

mkdir -p "$output/share/luce"
printf '%s\n' "$source_commit" >"$output/share/luce/SOURCE_COMMIT"

# These exact texts belong to code the self-contained compiler carries. Copy
# them from the same pinned builder that supplied the linked archives so the
# notice cannot drift away from the binary.
third_party="$output/share/licenses/third-party"
mkdir -p "$third_party"
cp /opt/luce-llvm/include/llvm/Support/LICENSE.TXT "$third_party/LLVM-LICENSE.txt"
cp /opt/zig/LICENSE "$third_party/ZIG-LICENSE.txt"
cp /usr/share/licenses/gcc/COPYING3 "$third_party/GCC-GPL-3.txt"
cp /usr/share/licenses/gcc/COPYING.RUNTIME "$third_party/GCC-RUNTIME-EXCEPTION.txt"
for notice in LLVM-LICENSE.txt ZIG-LICENSE.txt GCC-GPL-3.txt GCC-RUNTIME-EXCEPTION.txt; do
    test -s "$third_party/$notice" || {
        echo "linux release: required third-party notice is missing: $notice" >&2
        exit 1
    }
done

for tool in luce loom editor; do
    test -x "$output/$tool" || {
        echo "linux release: build did not produce $tool" >&2
        exit 1
    }
done
for library in libluce_rt.a libluce_start.a; do
    test -f "$output/lib/$library" || {
        echo "linux release: build did not produce lib/$library" >&2
        exit 1
    }
done

# Static LLVM is a release invariant. glibc is the declared platform
# boundary; an LLVM, C++ or optional LLVM dependency here would make the curl
# installer succeed on this image and fail on an ordinary user's machine.
# Check every executable a person receives, not only the compiler.
for tool in luce loom editor; do
    dependencies=$(ldd "$output/$tool")
    if printf '%s\n' "$dependencies" | grep -E 'libLLVM|libstdc\+\+|libz3|libxml2|libzstd|libedit|not found' >/dev/null; then
        echo "linux release: $tool has an unpublished runtime dependency" >&2
        printf '%s\n' "$dependencies" >&2
        exit 1
    fi

    glibc_floor=$(objdump -T "$output/$tool" | sed -n 's/.*(GLIBC_\([0-9][0-9.]*\)).*/\1/p' | sort -V | tail -n 1)
    if [ -n "$glibc_floor" ] && [ "$(printf '%s\n%s\n' "$glibc_floor" 2.28 | sort -V | tail -n 1)" != 2.28 ]; then
        echo "linux release: $tool requires glibc $glibc_floor, above the 2.28 release floor" >&2
        exit 1
    fi
done

echo "linux release: $architecture prefix is self-contained at $output"
