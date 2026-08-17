#!/bin/sh
# Install the exact Zig toolchain declared by build.zig.zon into one CI-owned
# directory. Archives come from ziglang.org and are checked before extraction.
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: tools/ci/install-zig.sh ABSOLUTE_DESTINATION" >&2
    exit 1
fi

destination=$1
case "$destination" in
    /*) ;;
    *)
        echo "install-zig: destination must be absolute: $destination" >&2
        exit 1
        ;;
esac

version=0.16.0
if [ -x "$destination/zig" ]; then
    installed=$("$destination/zig" version 2>/dev/null || true)
    if [ "$installed" = "$version" ]; then
        echo "install-zig: using cached Zig $version at $destination"
        exit 0
    fi
    echo "install-zig: $destination contains Zig ${installed:-unknown}, expected $version" >&2
    exit 1
fi
if [ -e "$destination" ]; then
    echo "install-zig: destination exists but is not a complete Zig $version install" >&2
    exit 1
fi

system=$(uname -s)
machine=$(uname -m)
case "$system:$machine" in
    Darwin:arm64|Darwin:aarch64)
        platform=aarch64-macos
        checksum=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489
        ;;
    Linux:x86_64|Linux:amd64)
        platform=x86_64-linux
        checksum=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
        ;;
    Linux:aarch64|Linux:arm64)
        platform=aarch64-linux
        checksum=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17
        ;;
    *)
        echo "install-zig: unsupported CI host: $system $machine" >&2
        exit 1
        ;;
esac

for tool in awk curl dirname mkdir mktemp mv rm tar uname; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "install-zig: required command not found: $tool" >&2
        exit 1
    fi
done
if command -v sha256sum >/dev/null 2>&1; then
    checksum_tool=sha256sum
elif command -v shasum >/dev/null 2>&1; then
    checksum_tool=shasum
else
    echo "install-zig: SHA-256 verification needs sha256sum or shasum" >&2
    exit 1
fi

parent=$(dirname "$destination")
mkdir -p "$parent"
work=$(mktemp -d "$parent/.zig-install.XXXXXX")
cleanup() {
    rm -rf "$work"
}
trap cleanup 0 HUP INT TERM

archive="$work/zig.tar.xz"
url="https://ziglang.org/download/$version/zig-$platform-$version.tar.xz"
echo "install-zig: downloading Zig $version for $platform"
curl --fail --location --silent --show-error --retry 3 "$url" -o "$archive"
case "$checksum_tool" in
    sha256sum) actual=$(sha256sum "$archive" | awk '{ print $1 }') ;;
    shasum) actual=$(shasum -a 256 "$archive" | awk '{ print $1 }') ;;
esac
if [ "$actual" != "$checksum" ]; then
    echo "install-zig: archive checksum does not match" >&2
    exit 1
fi

unpacked="$work/unpacked"
mkdir "$unpacked"
tar -xJf "$archive" -C "$unpacked" --strip-components=1
if [ ! -x "$unpacked/zig" ] || [ "$("$unpacked/zig" version)" != "$version" ]; then
    echo "install-zig: archive did not contain Zig $version" >&2
    exit 1
fi
mv "$unpacked" "$destination"
echo "install-zig: installed Zig $version at $destination"
