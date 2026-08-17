#!/bin/sh
# Fast failure-contract tests for the public installer. Supported installs are
# exercised against real archives by install-smoke.sh; these cases prove that
# unsupported or unsafe requests stop before curl can change anything.
set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "$here/../.." && pwd)
version=$(tr -d '[:space:]' <"$root/VERSION")
installer="$here/install/$version/install.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/luce-installer-contract.XXXXXX")
cleanup() {
    rm -rf "$work"
}
trap cleanup 0 HUP INT TERM

full_bin="$work/bin"
no_cc_bin="$work/no-cc"
mkdir -p "$full_bin" "$no_cc_bin"

# Give the child exactly the ordinary commands the installer declares. Curl is
# present but every case below must stop before invoking it.
for tool in awk cp curl date dirname grep mkdir mktemp mv rm shasum tar tr; do
    path=$(command -v "$tool" 2>/dev/null || true)
    if [ -n "$path" ]; then
        ln -s "$path" "$full_bin/$tool"
        ln -s "$path" "$no_cc_bin/$tool"
    fi
done
if command -v sha256sum >/dev/null 2>&1; then
    path=$(command -v sha256sum)
    ln -s "$path" "$full_bin/sha256sum"
    ln -s "$path" "$no_cc_bin/sha256sum"
fi

printf '%s\n' \
    '#!/bin/sh' \
    'case "$1" in' \
    '    -s) printf "%s\n" "${TEST_SYSTEM:-Linux}" ;;' \
    '    -m) printf "%s\n" "${TEST_MACHINE:-x86_64}" ;;' \
    '    *) exit 1 ;;' \
    'esac' >"$full_bin/uname"
cp "$full_bin/uname" "$no_cc_bin/uname"

printf '%s\n' \
    '#!/bin/sh' \
    'if [ "${TEST_LIBC:-glibc}" = glibc ]; then' \
    '    printf "glibc %s\n" "${TEST_GLIBC:-2.28}"' \
    'else' \
    '    exit 1' \
    'fi' >"$full_bin/getconf"
cp "$full_bin/getconf" "$no_cc_bin/getconf"

printf '%s\n' \
    '#!/bin/sh' \
    'if [ "$1" = -productVersion ]; then' \
    '    printf "%s\n" "${TEST_MACOS:-15.0}"' \
    'else' \
    '    exit 1' \
    'fi' >"$full_bin/sw_vers"
cp "$full_bin/sw_vers" "$no_cc_bin/sw_vers"

printf '%s\n' '#!/bin/sh' 'exit 0' >"$full_bin/cc"
chmod +x "$full_bin/uname" "$full_bin/getconf" "$full_bin/sw_vers" \
    "$full_bin/cc" "$no_cc_bin/uname" "$no_cc_bin/getconf" \
    "$no_cc_bin/sw_vers"

expect_failure() {
    name=$1
    expected=$2
    bin=$3
    shift 3
    output="$work/$name.txt"
    if env PATH="$bin" HOME="$work/home" "$@" "$installer" >"$output" 2>&1; then
        echo "installer contract: $name unexpectedly succeeded" >&2
        exit 1
    fi
    if ! grep -Fq "$expected" "$output"; then
        echo "installer contract: $name did not say: $expected" >&2
        cat "$output" >&2
        exit 1
    fi
    if grep -Fq 'downloading Luce' "$output"; then
        echo "installer contract: $name reached the download" >&2
        exit 1
    fi
}

expect_failure unsupported-os 'supports macOS and Linux, not FreeBSD' "$full_bin" \
    TEST_SYSTEM=FreeBSD TEST_MACHINE=x86_64
expect_failure unsupported-linux-arch 'supports x86-64 and arm64, not riscv64' "$full_bin" \
    TEST_SYSTEM=Linux TEST_MACHINE=riscv64
expect_failure old-macos 'requires macOS 15 or newer; found 14.7' "$full_bin" \
    TEST_SYSTEM=Darwin TEST_MACHINE=arm64 TEST_MACOS=14.7
expect_failure old-glibc 'requires glibc 2.28 or newer' "$full_bin" \
    TEST_SYSTEM=Linux TEST_MACHINE=x86_64 TEST_GLIBC=2.27
expect_failure musl 'musl is not supported yet' "$full_bin" \
    TEST_SYSTEM=Linux TEST_MACHINE=x86_64 TEST_LIBC=musl
expect_failure missing-cc 'sudo apt install build-essential' "$no_cc_bin" \
    TEST_SYSTEM=Linux TEST_MACHINE=x86_64
expect_failure relative-prefix 'LUCE_INSTALL_DIR must be an absolute path' "$full_bin" \
    TEST_SYSTEM=Linux TEST_MACHINE=x86_64 LUCE_INSTALL_DIR=relative
expect_failure system-prefix 'refusing unsafe install directory: /var/lib/luce' "$full_bin" \
    TEST_SYSTEM=Linux TEST_MACHINE=x86_64 LUCE_INSTALL_DIR=/var/lib/luce

echo "installer contract: platform version, libc, linker, and path refusals passed"
