#!/bin/sh
# Exercise the public installer and the installed product in an isolated home.
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: www/luce/install-smoke.sh RELEASE_DIRECTORY SMOKE_DIRECTORY" >&2
    exit 1
fi

release_output=$1
smoke=$2
here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "$here/../.." && pwd)
release_version=$(tr -d '[:space:]' <"$root/VERSION")
termui_version=$(awk '/^[[:space:]]*termui[[:space:]]*:/ { print $2; exit }' "$root/examples/editor/luce.yaml")
extension_version=$(awk -F'"' '/^[[:space:]]*"version"[[:space:]]*:/ { print $4; exit }' "$root/tools/vscode-luce/package.json")
extension_id=luciaos.luce-language

smoke_install="$smoke/luce"
smoke_extensions="$smoke/extensions"
smoke_profile="$smoke/profile"
smoke_program="$smoke/hello.luc"
smoke_home="$smoke/home"

case "$smoke" in
    ''|/)
        echo "installer smoke: refusing unsafe smoke directory: $smoke" >&2
        exit 1
        ;;
esac
mkdir -p "$smoke"
# The Linux release runs this script with $smoke as a bind-mount root. Empty
# that directory without trying to remove the mount point itself.
find "$smoke" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
mkdir -p "$smoke_home"

run_installer() {
    HOME="$smoke_home" \
    SHELL=/bin/sh \
    LUCE_INSTALL_BASE_URL="file://$release_output" \
    LUCE_INSTALL_DIR="$smoke_install" \
    LUCE_INSTALL_EDITOR_EXTENSIONS_DIR="$smoke_extensions" \
    LUCE_INSTALL_PROFILE="$smoke_profile" \
    LUCE_INSTALL_NO_PATH=0 \
        "$release_output/install.sh"
}

# Replacement is part of the public promise. A private marker from the first
# install must disappear, while profile entries and the extension stay singular.
run_installer
printf '%s\n' stale >"$smoke_install/stale-from-first-install"
run_installer
test ! -e "$smoke_install/stale-from-first-install"

test "$("$smoke_install/bin/luce" --version)" = "luce $release_version"
test "$("$smoke_install/bin/loom" --version)" = "loom $release_version"
test -x "$smoke_install/bin/editor"
test -f "$smoke_install/lib/termui-$termui_version/termui.luc"
test -f "$smoke_extensions/$extension_id-$extension_version/package.json"
test "$(grep -Fc "$smoke_install/bin" "$smoke_profile")" -eq 1
test "$(grep -Fc "$smoke_install/lib" "$smoke_profile")" -eq 1

printf '%s\n' 'func main():' '    print("installer works")' >"$smoke_program"
(cd "$smoke" && "$smoke_install/bin/luce" build hello.luc)
test "$("$smoke/hello")" = "installer works"

(cd "$smoke" && "$smoke_install/bin/luce" build hello.luc --emit=library -o hello.lc)
test "$("$smoke_install/bin/loom" run "$smoke/hello.lc")" = "installer works"

printf '%s\n' \
    'func test_installed_toolchain():' \
    '    assert(6 * 7 == 42)' >"$smoke/toolchain_test.luc"
(cd "$smoke" && "$smoke_install/bin/luce" test toolchain_test.luc >test-output.txt)
grep -Fq '1 passed, 0 failed' "$smoke/test-output.txt"

printf '%s\n' 'name: smoke' 'version: 0.1.0' 'packages:' "  termui: $termui_version" >"$smoke/luce.yaml"
printf '%s\n' \
    'import termui' \
    'func main():' \
    '    let frame = termui.snapshot(termui.Panel("ok", termui.Label("ready")), 3, 10)' \
    '    print(frame.line(1))' >"$smoke/package_app.luc"
(cd "$smoke" && . "$smoke_profile" && "$smoke_install/bin/luce" build package_app.luc)
test "$("$smoke/package_app")" = "│ready   │"

if [ "$(uname -s)" = Linux ]; then
    for tool in luce loom editor; do
        dependencies=$(ldd "$smoke_install/bin/$tool")
        if printf '%s\n' "$dependencies" | grep -E 'libLLVM|libstdc\+\+|libz3|libxml2|libzstd|libedit|not found' >/dev/null; then
            echo "installer smoke: installed $tool has an unpublished Linux dependency" >&2
            printf '%s\n' "$dependencies" >&2
            exit 1
        fi
    done
fi

echo "installer: replacement, checksum, PATH, package, editor, test, executable, and library paths passed"
