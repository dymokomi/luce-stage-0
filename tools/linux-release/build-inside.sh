#!/bin/sh
# Build one native Linux release prefix inside the pinned builder image.
set -eu

source_root=${LUCE_RELEASE_SOURCE:-/source}
output=${LUCE_RELEASE_OUTPUT:-/output}
architecture=${LUCE_RELEASE_ARCH:?LUCE_RELEASE_ARCH is required}

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
    -Dllvm-config=/opt/luce-llvm/bin/llvm-config \
    --summary all

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
