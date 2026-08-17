#!/bin/sh
# Build and prove every public Luce archive in www/luce/out.
set -eu

# macOS copy and archive tools otherwise preserve Finder metadata as pax
# headers. Linux tar ignores those headers but prints warnings during the
# one-command install, so public archives contain product files only.
export COPYFILE_DISABLE=1

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
linux_aarch64_prefix_override=${LUCE_LINUX_AARCH64_PREFIX:-}
linux_x86_64_prefix_override=${LUCE_LINUX_X86_64_PREFIX:-}

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

    mkdir -p "$release_tree/bin" "$release_tree/lib" "$extension_tree/syntaxes" "$release_tree/share/licenses/luce"
    for tool in luce loom editor; do
        if [ ! -x "$prefix/$tool" ]; then
            echo "luce release: $platform prefix is missing $tool" >&2
            exit 1
        fi
        cp "$prefix/$tool" "$release_tree/bin/$tool"
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
    for module in termui model input layout canvas view runtime; do
        cp "$termui_source/$module.luc" "$termui_release/$module.luc"
    done

    printf '%s\n' "$release_version" >"$release_tree/VERSION"
    cp "$root/LICENSE-MIT" "$release_tree/share/licenses/luce/LICENSE-MIT"
    cp "$root/LICENSE-APACHE" "$release_tree/share/licenses/luce/LICENSE-APACHE"
    cp "$extension_source/package.json" "$extension_tree/package.json"
    cp "$extension_source/extension.js" "$extension_tree/extension.js"
    cp "$extension_source/language-configuration.json" "$extension_tree/language-configuration.json"
    cp "$extension_source/README.md" "$extension_tree/README.md"
    cp "$extension_source/syntaxes/luce.tmLanguage.json" "$extension_tree/syntaxes/luce.tmLanguage.json"

    tar --no-xattrs --no-mac-metadata \
        -czf "$release_output/$archive" \
        -C "$tree_root" "luce-$release_version"
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
    for tool in luce loom editor; do
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
(cd "$root" && zig build \
    --prefix "$macos_prefix" \
    -Dtarget=aarch64-macos.15.0 \
    -Doptimize=ReleaseSafe \
    -Dsysroot="$macos_sdk" \
    --global-cache-dir "$zig_global_cache" \
    --summary all)
verify_macos_minimum "$macos_prefix"
assemble_archive macos-aarch64 "$macos_prefix"

for architecture in aarch64 x86_64; do
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
    assemble_archive "linux-$architecture" "$linux_prefix"
done

echo "==> macOS installer smoke"
"$here/install-smoke.sh" "$release_output" "$release_work/smoke-macos-aarch64"

for architecture in aarch64 x86_64; do
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

echo "==> release complete: macOS arm64, Linux arm64, and Linux x86-64"
