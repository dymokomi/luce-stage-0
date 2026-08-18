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
archive_external="/tmp/luce-installer-contract.$$"
cleanup() {
    rm -rf "$work" "$archive_external"
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
expect_failure shell-sensitive-prefix 'contains shell-sensitive characters' "$full_bin" \
    TEST_SYSTEM=Linux TEST_MACHINE=x86_64 'LUCE_INSTALL_DIR=/tmp/$(touch /tmp/luce-installer-contract-owned)'

# A checksum only authenticates the archive bytes. Exercise the extraction
# boundary with a complete (but deliberately malicious) fixture so a future
# change cannot reintroduce path traversal or link extraction.
archive_base="$work/archive"
archive_tree="$archive_base/luce-$version"
archive_name="luce-${version}-linux-x86_64.tar.gz"
mkdir -p "$archive_tree/bin" "$archive_tree/lib/termui-0.4.0" \
    "$archive_tree/share/licenses/third-party" \
    "$archive_tree/share/vscode/extensions/luciaos.luce-language-0.4.0/syntaxes" \
    "$archive_tree/share/luce"
printf '%s\n' "$version" >"$archive_tree/VERSION"
archive_source=0123456789012345678901234567890123456789
printf '%s\n' \
    'format luce-build-manifest-1' \
    "version $version" \
    'platform linux-x86_64' \
    "source $archive_source" >"$archive_tree/share/luce/BUILD-MANIFEST"
for tool in luce loom editor; do
    printf '%s\n' '#!/bin/sh' \
        'if [ "$1" = "--build-info" ]; then' \
        "    printf '%s\\n' '$tool $version' 'source $archive_source'" \
        'fi' >"$archive_tree/bin/$tool"
    chmod +x "$archive_tree/bin/$tool"
done
: >"$archive_tree/lib/libluce_rt.a"
: >"$archive_tree/lib/libluce_start.a"
for notice in THIRD_PARTY_NOTICES.md LLVM-LICENSE.txt ZIG-LICENSE.txt \
    GCC-GPL-3.txt GCC-RUNTIME-EXCEPTION.txt; do
    printf '%s\n' fixture >"$archive_tree/share/licenses/third-party/$notice"
done
for package_file in luce.yaml termui.luc model.luc input.luc layout.luc \
    canvas.luc view.luc runtime.luc; do
    printf '%s\n' fixture >"$archive_tree/lib/termui-0.4.0/$package_file"
done
extension_tree="$archive_tree/share/vscode/extensions/luciaos.luce-language-0.4.0"
printf '%s\n' '{}' >"$extension_tree/package.json"
printf '%s\n' fixture >"$extension_tree/extension.js"
printf '%s\n' fixture >"$extension_tree/language-configuration.json"
printf '%s\n' '{}' >"$extension_tree/syntaxes/luce.tmLanguage.json"
ln -s /tmp/luce-installer-outside "$archive_tree/unsafe-link"
(cd "$archive_base" && tar -czf "$archive_name" "luce-$version")
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$archive_base" && sha256sum "$archive_name" >"$archive_name.sha256")
else
    (cd "$archive_base" && shasum -a 256 "$archive_name" >"$archive_name.sha256")
fi
archive_output="$work/archive-output.txt"
if env PATH="$full_bin" HOME="$work/archive-home" \
    LUCE_INSTALL_BASE_URL="file://$archive_base" \
    LUCE_INSTALL_DIR="$archive_external/install" \
    LUCE_INSTALL_EDITOR_EXTENSIONS_DIR="$archive_external/extensions" \
    LUCE_INSTALL_PROFILE="$archive_external/profile" \
    LUCE_INSTALL_NO_PATH=1 "$installer" >"$archive_output" 2>&1; then
    echo "installer contract: unsafe archive unexpectedly succeeded" >&2
    exit 1
fi
if ! grep -Fq 'release archive contains a link or special file' "$archive_output"; then
    echo "installer contract: archive refusal had unexpected output" >&2
    cat "$archive_output" >&2
    exit 1
fi

# Archive bytes must not depend on the builder's clock, umask, or directory
# traversal order.  The helper normalizes those inputs; changing them between
# two assemblies is the regression test for that promise.
repro_base="$work/repro"
repro_tree="$repro_base/luce-$version"
mkdir -p "$repro_tree/bin/nested"
printf '%s\n' executable >"$repro_tree/bin/luce"
printf '%s\n' data >"$repro_tree/bin/nested/data"
chmod 755 "$repro_tree/bin/luce"
"$here/archive.sh" "$repro_base" "luce-$version" "$work/repro-one.tar.gz"
find "$repro_tree" -exec touch -h -t 202501010000.00 {} +
chmod 700 "$repro_tree" "$repro_tree/bin" "$repro_tree/bin/nested"
chmod 744 "$repro_tree/bin/luce"
chmod 600 "$repro_tree/bin/nested/data"
"$here/archive.sh" "$repro_base" "luce-$version" "$work/repro-two.tar.gz"
if ! cmp -s "$work/repro-one.tar.gz" "$work/repro-two.tar.gz"; then
    echo "installer contract: reproducible archive bytes changed" >&2
    exit 1
fi

echo "installer contract: platform version, libc, linker, path, archive safety, and reproducibility passed"
