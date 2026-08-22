#!/bin/sh
# Build and prove every public Luce archive in www/luce/out.
set -eu

# macOS copy and archive tools otherwise preserve Finder metadata as pax
# headers. Linux tar ignores those headers but prints warnings during the
# one-command install, so public archives contain product files only.
export COPYFILE_DISABLE=1
export LC_ALL=C
umask 022

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "$here/../.." && pwd)
release_version=$(tr -d '[:space:]' <"$root/VERSION")
release_source="$here/install/$release_version/install.sh"
release_work="$here/work/release"
release_output="$here/out/install/$release_version"
zig_global_cache="$here/work/zig-global-cache"
termui_version=$(awk '/^[[:space:]]*termui[[:space:]]*:/ { print $2; exit }' "$root/examples/editor/luce.yaml")
termui_source="$root/packages/termui-$termui_version"
extension_source="$root/tools/vscode-luce"
extension_version=$(awk -F'"' '/^[[:space:]]*"version"[[:space:]]*:/ { print $4; exit }' "$extension_source/package.json")
extension_id=luciaos.luce-language
macos_minimum=15.0
zig_version=0.16.0
llvm_version=22.1.8
linux_aarch64_prefix_override=${LUCE_LINUX_AARCH64_PREFIX:-}
linux_x86_64_prefix_override=${LUCE_LINUX_X86_64_PREFIX:-}

source_commit=$(git -C "$root" rev-parse --verify HEAD)
if [ -n "$(git -C "$root" status --porcelain --untracked-files=normal)" ]; then
    echo "luce release: source tree is not clean" >&2
    exit 1
fi
source_epoch=$(git -C "$root" show -s --format=%ct "$source_commit")
case "$source_epoch" in
    ''|*[!0-9]*)
        echo "luce release: cannot read the source commit timestamp" >&2
        exit 1
        ;;
esac
export SOURCE_DATE_EPOCH="$source_epoch"
module_format=$(awk '/pub const format_version: u32 =/ { value = $6; gsub(/;/, "", value); print value; exit }' "$root/src/luce/mir/module.zig")
host_abi=$(awk '/pub const version: u32 =/ { value = $6; gsub(/;/, "", value); print value; exit }' "$root/src/luce/codegen/abi.zig")
if [ -z "$module_format" ] || [ -z "$host_abi" ]; then
    echo "luce release: cannot read the module-format or host-ABI version" >&2
    exit 1
fi

if [ "$(uname -s)" != Darwin ]; then
    echo "luce release: the complete matrix must run on macOS so it can build the Apple archive" >&2
    exit 1
fi
command -v docker >/dev/null 2>&1 || {
    echo "luce release: Docker is required for the Linux archives" >&2
    exit 1
}
if [ ! -f "$here/out/index.html" ]; then
    echo "luce release: the site is not built; run ./www/luce/build.sh first" >&2
    exit 1
fi
if [ ! -x "$release_source" ]; then
    echo "luce release: missing executable installer: $release_source" >&2
    exit 1
fi
if ! grep -Fq "version=$release_version" "$release_source"; then
    echo "luce release: installer version does not match VERSION ($release_version)" >&2
    exit 1
fi
if ! grep -Fq "extension_version=$extension_version" "$release_source"; then
    echo "luce release: installer extension version does not match package.json ($extension_version)" >&2
    exit 1
fi
if [ -z "$termui_version" ] || [ ! -f "$termui_source/luce.yaml" ] || [ ! -f "$termui_source/termui.luc" ]; then
    echo "luce release: termui $termui_version is incomplete" >&2
    exit 1
fi
if ! grep -Fq "termui_version=$termui_version" "$release_source"; then
    echo "luce release: installer termui version does not match the editor manifest ($termui_version)" >&2
    exit 1
fi
if [ -z "$extension_version" ] || [ ! -f "$extension_source/package.json" ] || [ ! -f "$extension_source/extension.js" ]; then
    echo "luce release: VS Code extension package is incomplete" >&2
    exit 1
fi
for prefix_override in "$linux_aarch64_prefix_override" "$linux_x86_64_prefix_override"; do
    case "$prefix_override" in
        '') ;;
        /*) ;;
        *)
            echo "luce release: Linux prefix overrides must be absolute paths: $prefix_override" >&2
            exit 1
            ;;
    esac
done

"$here/test-installer.sh"

rm -rf "$release_work" "$release_output"
mkdir -p "$release_work" "$release_output" "$zig_global_cache"
cp "$release_source" "$release_output/install.sh"
chmod +x "$release_output/install.sh"

checksum_archive() {
    archive=$1
    if command -v sha256sum >/dev/null 2>&1; then
        (cd "$release_output" && sha256sum "$archive" >"$archive.sha256")
    elif command -v shasum >/dev/null 2>&1; then
        (cd "$release_output" && shasum -a 256 "$archive" >"$archive.sha256")
    else
        echo "luce release: sha256sum or shasum is required" >&2
        exit 1
    fi
}

assemble_archive() {
    platform=$1
    prefix=$2
    tree_root="$release_work/tree-$platform"
    release_tree="$tree_root/luce-$release_version"
    extension_tree="$release_tree/share/vscode/extensions/$extension_id-$extension_version"
    archive="luce-${release_version}-${platform}.tar.gz"
    third_party_source="$prefix/share/licenses/third-party"

    mkdir -p "$release_tree/bin" "$release_tree/lib" "$extension_tree/syntaxes" \
        "$release_tree/share/licenses/luce" "$release_tree/share/luce"
    # Stage 0 installs under suffixed names — the unsuffixed `luce`
    # and `luce-lsp` belong to the next language, which will need to
    # test its own install beside this one.
    for tool in luce loom editor luce-lsp; do
        if [ ! -x "$prefix/$tool" ]; then
            echo "luce release: $platform prefix is missing $tool" >&2
            exit 1
        fi
        case "$tool" in
            luce) shipped=luce-0 ;;
            luce-lsp) shipped=luce-lsp-0 ;;
            *) shipped=$tool ;;
        esac
        cp "$prefix/$tool" "$release_tree/bin/$shipped"
    done
    for library in libluce_rt.a libluce_start.a; do
        if [ ! -f "$prefix/lib/$library" ]; then
            echo "luce release: $platform prefix is missing lib/$library" >&2
            exit 1
        fi
        cp "$prefix/lib/$library" "$release_tree/lib/$library"
    done

    termui_release="$release_tree/lib/termui-$termui_version"
    mkdir -p "$termui_release"
    cp "$termui_source/luce.yaml" "$termui_release/luce.yaml"
    for module in termui model input constraints layout widgets canvas view runtime; do
        cp "$termui_source/$module.luc" "$termui_release/$module.luc"
    done

    printf '%s\n' "$release_version" >"$release_tree/VERSION"
    case "$platform" in
        macos-aarch64) platform_floor="macOS $macos_minimum" ;;
        linux-*) platform_floor='glibc 2.28' ;;
        *)
            echo "luce release: no platform floor for $platform" >&2
            exit 1
            ;;
    esac
    printf '%s\n' \
        'format luce-build-manifest-1' \
        "version $release_version" \
        "source $source_commit" \
        "source-date-epoch $source_epoch" \
        "platform $platform" \
        "platform-floor $platform_floor" \
        "optimize ReleaseSafe" \
        "zig $zig_version" \
        "llvm $llvm_version" \
        "module-format $module_format" \
        "host-abi $host_abi" \
        "termui $termui_version" \
        "vscode-extension $extension_version" \
        'archive-format reproducible-tar-gzip-1' \
        'archive-mtime 2000-01-01T00:00:00Z' \
        >"$release_tree/share/luce/BUILD-MANIFEST"
    cp "$root/LICENSE-MIT" "$release_tree/share/licenses/luce/LICENSE-MIT"
    cp "$root/LICENSE-APACHE" "$release_tree/share/licenses/luce/LICENSE-APACHE"
    third_party_release="$release_tree/share/licenses/third-party"
    mkdir -p "$third_party_release"
    cp "$root/THIRD_PARTY_NOTICES.md" "$third_party_release/THIRD_PARTY_NOTICES.md"
    for notice in LLVM-LICENSE.txt ZIG-LICENSE.txt; do
        if [ ! -s "$third_party_source/$notice" ]; then
            echo "luce release: $platform prefix is missing $notice" >&2
            exit 1
        fi
        cp "$third_party_source/$notice" "$third_party_release/$notice"
    done
    case "$platform" in
        linux-*)
            for notice in GCC-GPL-3.txt GCC-RUNTIME-EXCEPTION.txt; do
                if [ ! -s "$third_party_source/$notice" ]; then
                    echo "luce release: $platform prefix is missing $notice" >&2
                    exit 1
                fi
                cp "$third_party_source/$notice" "$third_party_release/$notice"
            done
            ;;
    esac
    cp "$extension_source/package.json" "$extension_tree/package.json"
    cp "$extension_source/extension.js" "$extension_tree/extension.js"
    cp "$extension_source/lsp.js" "$extension_tree/lsp.js"
    cp "$extension_source/language-configuration.json" "$extension_tree/language-configuration.json"
    cp "$extension_source/README.md" "$extension_tree/README.md"
    cp "$extension_source/syntaxes/luce.tmLanguage.json" "$extension_tree/syntaxes/luce.tmLanguage.json"

    "$here/archive.sh" "$tree_root" "luce-$release_version" "$release_output/$archive"
    checksum_archive "$archive"
    tar -tzf "$release_output/$archive" >/dev/null
    echo "release: $release_output/$archive"
}

verify_macos_minimum() {
    prefix=$1
    command -v otool >/dev/null 2>&1 || {
        echo "luce release: otool is required to verify the macOS deployment target" >&2
        exit 1
    }
    for tool in luce loom editor luce-lsp; do
        minimum=$(otool -l "$prefix/$tool" | awk '
            $1 == "cmd" && $2 == "LC_BUILD_VERSION" { in_build = 1; next }
            in_build && $1 == "minos" { print $2; exit }
        ')
        if [ "$minimum" != "$macos_minimum" ]; then
            echo "luce release: $tool targets macOS ${minimum:-unknown}, expected $macos_minimum" >&2
            exit 1
        fi
    done
    echo "release: macOS tools require macOS $macos_minimum"
}

echo "==> macOS arm64 toolchain"
macos_prefix="$release_work/prefix-macos-aarch64"
macos_sdk=$(xcrun --sdk macosx --show-sdk-path)
if [ "$(zig version)" != "$zig_version" ]; then
    echo "luce release: Zig $zig_version is required" >&2
    exit 1
fi
macos_llvm="$root/.llvm/install/bin/llvm-config"
if [ ! -x "$macos_llvm" ] || [ "$("$macos_llvm" --version)" != "$llvm_version" ]; then
    echo "==> pinned LLVM $llvm_version"
    (cd "$root" && ./vendor-llvm.sh)
fi
(cd "$root" && zig build \
    --prefix "$macos_prefix" \
    -Dtarget=aarch64-macos.15.0 \
    -Doptimize=ReleaseSafe \
    -Dsource-commit="$source_commit" \
    -Dllvm-config="$macos_llvm" \
    -Dsysroot="$macos_sdk" \
    --global-cache-dir "$zig_global_cache" \
    --summary all)
macos_third_party="$macos_prefix/share/licenses/third-party"
mkdir -p "$macos_third_party"
macos_llvm_license="$("$macos_llvm" --includedir)/llvm/Support/LICENSE.TXT"
if [ ! -s "$macos_llvm_license" ]; then
    echo "luce release: pinned LLVM install has no license text" >&2
    exit 1
fi
cp "$macos_llvm_license" "$macos_third_party/LLVM-LICENSE.txt"
cp "$root/LICENSE-ZIG" "$macos_third_party/ZIG-LICENSE.txt"
verify_macos_minimum "$macos_prefix"
assemble_archive macos-aarch64 "$macos_prefix"

# `LUCE_RELEASE_SKIP_LINUX=1` refreshes only the macOS archive — for a
# change that does not touch the Linux binaries — and the publisher is
# responsible for carrying the existing Linux archives forward.
skip_linux="${LUCE_RELEASE_SKIP_LINUX:-}"
for architecture in x86_64; do
    if [ -n "$skip_linux" ]; then
        echo "==> Linux $architecture skipped (LUCE_RELEASE_SKIP_LINUX)"
        continue
    fi
    case "$architecture" in
        aarch64) linux_prefix=$linux_aarch64_prefix_override ;;
        x86_64) linux_prefix=$linux_x86_64_prefix_override ;;
    esac
    if [ -n "$linux_prefix" ]; then
        echo "==> Linux $architecture verified prefix: $linux_prefix"
    else
        linux_prefix="$release_work/prefix-linux-$architecture"
        "$root/tools/linux-release/build.sh" "$architecture" "$linux_prefix"
    fi
    if [ ! -f "$linux_prefix/share/luce/SOURCE_COMMIT" ] ||
        [ "$(tr -d '[:space:]' <"$linux_prefix/share/luce/SOURCE_COMMIT")" != "$source_commit" ]; then
        echo "luce release: Linux $architecture prefix does not come from $source_commit" >&2
        exit 1
    fi
    assemble_archive "linux-$architecture" "$linux_prefix"
done

echo "==> macOS installer smoke"
"$here/install-smoke.sh" "$release_output" "$release_work/smoke-macos-aarch64"

for architecture in x86_64; do
    if [ -n "$skip_linux" ]; then
        echo "==> Linux $architecture installer smoke skipped (LUCE_RELEASE_SKIP_LINUX)"
        continue
    fi
    case "$architecture" in
        aarch64)
            platform=linux/arm64
            base_image=quay.io/pypa/manylinux_2_28_aarch64@sha256:817404d425b2edff4657a4bbf59e5a9fdb274609d31c99c1f9edc3be4426b00b
            ;;
        x86_64)
            platform=linux/amd64
            base_image=quay.io/pypa/manylinux_2_28_x86_64@sha256:a694e7d81cdc90b1a3f4e8207d95d63a226df973dbd681a3b31599e90dd9436d
            ;;
    esac
    smoke="$release_work/smoke-linux-$architecture"
    mkdir -p "$smoke"
    echo "==> Linux $architecture installer smoke"
    docker run --rm \
        --platform "$platform" \
        --entrypoint /bin/sh \
        --env HOME=/tmp/luce-installer-home \
        --volume "$root:/source:ro" \
        --volume "$release_output:/release:ro" \
        --volume "$smoke:/smoke" \
        "$base_image" \
        /source/www/luce/install-smoke.sh /release /smoke
done

if [ -n "$skip_linux" ]; then
    echo "==> release complete: macOS arm64 (Linux archives carried forward unchanged)"
else
    echo "==> release complete: macOS arm64 and Linux x86-64"
fi
