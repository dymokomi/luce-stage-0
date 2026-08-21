#!/bin/sh
# Install the Luce 0.18 toolchain for macOS 15+ or glibc Linux.
#
# Usage:
#
#   curl -fsSL https://luce.luciaos.com/install/0.18/install.sh | bash
#
# The archive is checked before it replaces ~/.local/luce.  Running this
# command again downloads and installs a fresh copy of the same release.
set -eu

version=0.18
base_url="${LUCE_INSTALL_BASE_URL:-https://luce.luciaos.com/install/${version}}"
install_root="${LUCE_INSTALL_DIR:-$HOME/.local/luce}"
editor_extensions_dir="${LUCE_INSTALL_EDITOR_EXTENSIONS_DIR:-}"
profile_override="${LUCE_INSTALL_PROFILE:-}"
extension_id="luciaos.luce-language"
extension_version=0.6.0
termui_version=0.5.0

system=$(uname -s)
machine=$(uname -m)
case "$system:$machine" in
    Darwin:arm64|Darwin:aarch64)
        platform=macos-aarch64
        platform_name='macOS arm64'
        ;;
    Darwin:*)
        echo "luce: this macOS release requires Apple Silicon (arm64)" >&2
        echo "luce: use a native arm64 shell, not an x86_64/Rosetta shell" >&2
        exit 1
        ;;
    Linux:x86_64|Linux:amd64)
        platform=linux-x86_64
        platform_name='Linux x86-64'
        ;;
    Linux:aarch64|Linux:arm64)
        platform=linux-aarch64
        platform_name='Linux arm64'
        ;;
    Linux:*)
        echo "luce: this Linux release supports x86-64 and arm64, not $machine" >&2
        exit 1
        ;;
    *)
        echo "luce: this installer supports macOS and Linux, not $system" >&2
        exit 1
        ;;
esac
archive_name="luce-${version}-${platform}.tar.gz"

for tool in awk cp curl date dirname grep mkdir mktemp mv rm tar tr uname; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "luce: required command not found: $tool" >&2
        exit 1
    fi
done

# These values are written into shell and fish startup files.  Keep ordinary
# spaces and Unicode paths useful, but reject control characters and shell
# syntax rather than turning an environment override into code executed on a
# later `source`.
reject_profile_path() {
    label=$1
    value=$2
    cleaned=$(printf '%s' "$value" | tr -d '\001-\037\177')
    if [ "$cleaned" != "$value" ] || ! awk 'BEGIN {
        value = ARGV[1]
        forbidden = "`$\\\"();&|<>[]{}"
        for (i = 1; i <= length(forbidden); i++)
            if (index(value, substr(forbidden, i, 1)) != 0) exit 1
    }' "$value"; then
        echo "luce: $label contains shell-sensitive characters" >&2
        exit 1
    fi
}

if [ "$system" = Darwin ]; then
    if ! command -v sw_vers >/dev/null 2>&1; then
        echo "luce: cannot determine the macOS version (sw_vers is missing)" >&2
        exit 1
    fi
    macos_version=$(sw_vers -productVersion 2>/dev/null || true)
    if ! printf '%s\n' "$macos_version" | awk -F. '
        NF >= 1 && $1 ~ /^[0-9]+$/ { ok = ($1 >= 15) }
        END { exit ok ? 0 : 1 }
    '; then
        echo "luce: this release requires macOS 15 or newer; found ${macos_version:-unknown}" >&2
        exit 1
    fi
fi

if command -v sha256sum >/dev/null 2>&1; then
    checksum_tool=sha256sum
elif command -v shasum >/dev/null 2>&1; then
    checksum_tool=shasum
else
    echo "luce: SHA-256 verification needs sha256sum or shasum" >&2
    exit 1
fi

if [ "$system" = Linux ]; then
    if ! command -v getconf >/dev/null 2>&1; then
        echo "luce: this Linux release requires glibc 2.28 or newer (getconf is missing)" >&2
        exit 1
    fi
    glibc_answer=$(getconf GNU_LIBC_VERSION 2>/dev/null || true)
    glibc_version=${glibc_answer#glibc }
    if [ "$glibc_version" = "$glibc_answer" ] || ! printf '%s\n' "$glibc_version" | awk -F. '
        NF >= 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
            ok = ($1 > 2 || ($1 == 2 && $2 >= 28))
        }
        END { exit ok ? 0 : 1 }
    '; then
        echo "luce: this Linux release requires glibc 2.28 or newer; musl is not supported yet" >&2
        exit 1
    fi
fi

# Luce emits the object itself and asks the host C driver to finish the native
# link. Refuse before changing an installation if that required boundary is
# absent; a successful installer must leave a compiler that can build its
# first program.
if ! command -v cc >/dev/null 2>&1 || ! cc --version >/dev/null 2>&1; then
    echo "luce: a working C compiler driver named cc is required to link Luce programs" >&2
    case "$system" in
        Darwin)
            echo "luce: install it with: xcode-select --install" >&2
            ;;
        Linux)
            echo "luce: Debian/Ubuntu: sudo apt install build-essential" >&2
            echo "luce: Fedora/RHEL:   sudo dnf install gcc" >&2
            echo "luce: Arch:          sudo pacman -S base-devel" >&2
            ;;
    esac
    echo "luce: install the linker, then run this command again" >&2
    exit 1
fi

# Do not let an environment override turn a user installer into a request to
# replace a system tree.  Require an absolute path as well, so the directory
# being replaced cannot change with the caller's working directory.
case "$install_root" in
    /*) ;;
    *)
        echo "luce: LUCE_INSTALL_DIR must be an absolute path: $install_root" >&2
        exit 1
        ;;
esac
case "$install_root" in
    /|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/lib|/lib/*|/lib64|/lib64/*|/proc|/proc/*|/run|/run/*|/sys|/sys/*|/usr|/usr/*|/var|/var/*|/System|/System/*|/Library|/Library/*|/bin|/bin/*|/sbin|/sbin/*)
        echo "luce: refusing unsafe install directory: $install_root" >&2
        exit 1
        ;;
esac
# These two overrides make release testing hermetic and are also useful for
# managed editor/profile layouts. Defaults remain the ordinary local shelves.
if [ -n "$editor_extensions_dir" ]; then
    case "$editor_extensions_dir" in
        /*) ;;
        *)
            echo "luce: LUCE_INSTALL_EDITOR_EXTENSIONS_DIR must be an absolute path: $editor_extensions_dir" >&2
            exit 1
            ;;
    esac
    case "$editor_extensions_dir" in
        /|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/lib|/lib/*|/lib64|/lib64/*|/proc|/proc/*|/run|/run/*|/sys|/sys/*|/usr|/usr/*|/var|/var/*|/System|/System/*|/Library|/Library/*|/bin|/bin/*|/sbin|/sbin/*)
            echo "luce: refusing unsafe editor extensions directory: $editor_extensions_dir" >&2
            exit 1
            ;;
    esac
fi
if [ -n "$profile_override" ]; then
    case "$profile_override" in
        /*) ;;
        *)
            echo "luce: LUCE_INSTALL_PROFILE must be an absolute path: $profile_override" >&2
            exit 1
            ;;
    esac
    case "$profile_override" in
        /|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/lib|/lib/*|/lib64|/lib64/*|/proc|/proc/*|/run|/run/*|/sys|/sys/*|/usr|/usr/*|/var|/var/*|/System|/System/*|/Library|/Library/*|/bin|/bin/*|/sbin|/sbin/*)
            echo "luce: refusing unsafe shell profile: $profile_override" >&2
            exit 1
            ;;
    esac
fi

reject_profile_path LUCE_INSTALL_DIR "$install_root"
if [ -n "$editor_extensions_dir" ]; then
    reject_profile_path LUCE_INSTALL_EDITOR_EXTENSIONS_DIR "$editor_extensions_dir"
fi
if [ -n "$profile_override" ]; then
    reject_profile_path LUCE_INSTALL_PROFILE "$profile_override"
fi

parent=$(dirname "$install_root")
mkdir -p "$parent"
tmp=$(mktemp -d "$parent/.luce-install.XXXXXX")
backup_dir=$(mktemp -d "$parent/.luce-old.XXXXXX")
backup="$backup_dir/current"

cleanup() {
    rm -rf "$tmp" "$backup_dir"
}
trap cleanup 0 HUP INT TERM

archive="$tmp/$archive_name"
checksum="$tmp/$archive_name.sha256"
cache_bust="$(date +%s)-$$"

echo "==> downloading Luce $version for $platform_name"
curl --fail --location --silent --show-error --retry 3 \
    --header 'Cache-Control: no-cache' \
    "$base_url/$archive_name?fresh=$cache_bust" -o "$archive"
curl --fail --location --silent --show-error --retry 3 \
    --header 'Cache-Control: no-cache' \
    "$base_url/$archive_name.sha256?fresh=$cache_bust" -o "$checksum"

expected=$(awk 'NF { print $1; exit }' "$checksum" | tr 'A-F' 'a-f')
if ! printf '%s\n' "$expected" | awk \
    'length($0) == 64 && $0 !~ /[^0-9a-f]/ { ok = 1 } END { exit ok ? 0 : 1 }'; then
    echo "luce: release checksum is not a SHA-256 digest" >&2
    exit 1
fi
case "$checksum_tool" in
    sha256sum) actual=$(sha256sum "$archive" | awk '{ print $1 }') ;;
    shasum) actual=$(shasum -a 256 "$archive" | awk '{ print $1 }') ;;
esac
if [ "$actual" != "$expected" ]; then
    echo "luce: release checksum does not match" >&2
    exit 1
fi

unpack="$tmp/unpack"
mkdir "$unpack"
release="$unpack/luce-$version"

# A checksum authenticates the bytes we downloaded; it does not make an
# archive safe if the release endpoint or its signing process is compromised.
# Keep extraction confined to the expected release directory and refuse links
# or device entries, which could otherwise redirect a later file check or
# replacement outside the temporary tree.
members="$tmp/members"
if ! tar -tzf "$archive" >"$members"; then
    echo "luce: release archive cannot be listed" >&2
    exit 1
fi
if ! awk -v root="luce-$version" '
    function unsafe(path, count, parts, i) {
        if (path ~ /^\//) return 1
        count = split(path, parts, "/")
        for (i = 1; i <= count; i++) if (parts[i] == "..") return 1
        return 0
    }
    {
        path = $0
        sub(/\/$/, "", path)
        if (path == "" || unsafe(path)) bad = 1
        if (path != root && index(path, root "/") != 1) bad = 1
    }
    END { exit bad ? 1 : 0 }
' "$members"; then
    echo "luce: release archive contains an unsafe member path" >&2
    exit 1
fi
if ! tar -tvzf "$archive" | awk '
    length($0) > 0 && substr($0, 1, 1) !~ /^[-d]$/ { bad = 1 }
    END { exit bad ? 1 : 0 }
'; then
    echo "luce: release archive contains a link or special file" >&2
    exit 1
fi
tar -xzf "$archive" -C "$unpack"
if [ ! -d "$release" ]; then
    echo "luce: release archive has no luce-$version directory" >&2
    exit 1
fi
if [ "$(tr -d '[:space:]' <"$release/VERSION")" != "$version" ]; then
    echo "luce: release archive has the wrong VERSION" >&2
    exit 1
fi
manifest="$release/share/luce/BUILD-MANIFEST"
if [ ! -f "$manifest" ] ||
    ! grep -Fxq 'format luce-build-manifest-1' "$manifest" ||
    ! grep -Fxq "version $version" "$manifest" ||
    ! grep -Fxq "platform $platform" "$manifest" ||
    ! grep -Fxq 'archive-format reproducible-tar-gzip-1' "$manifest" ||
    ! grep -Fxq 'archive-mtime 2000-01-01T00:00:00Z' "$manifest" ||
    ! grep -Fxq "termui $termui_version" "$manifest" ||
    ! grep -Fxq "vscode-extension $extension_version" "$manifest"; then
    echo "luce: release archive has no matching build manifest" >&2
    exit 1
fi
source_epoch=$(awk '$1 == "source-date-epoch" { print $2; exit }' "$manifest")
if ! printf '%s\n' "$source_epoch" | awk '$0 ~ /^[0-9]+$/ { ok = 1 } END { exit ok ? 0 : 1 }'; then
    echo "luce: release archive has an invalid source timestamp" >&2
    exit 1
fi
source_commit=$(awk '$1 == "source" { print $2; exit }' "$manifest")
if ! printf '%s\n' "$source_commit" | awk \
    '(length($0) == 40 || length($0) == 64) && $0 !~ /[^0-9a-f]/ { ok = 1 } END { exit ok ? 0 : 1 }'; then
    echo "luce: release archive has an invalid source identity" >&2
    exit 1
fi
for tool in luce-0 loom; do
    # The installed name carries the stage suffix; the binary reports
    # its product identity unsuffixed.
    case "$tool" in
        luce-0) product=luce ;;
        *) product=$tool ;;
    esac
    if ! build_info=$("$release/bin/$tool" --build-info 2>/dev/null) ||
        ! printf '%s\n' "$build_info" | grep -Fxq "$product $version" ||
        ! printf '%s\n' "$build_info" | grep -Fxq "source $source_commit"; then
        echo "luce: release archive has mismatched $tool build identity" >&2
        exit 1
    fi
done
for tool in luce-0 loom editor; do
    if [ ! -x "$release/bin/$tool" ]; then
        echo "luce: release archive is missing bin/$tool" >&2
        exit 1
    fi
done
# The language server ships in the macOS archive today; a Linux
# archive that predates it installs without one, and the editors
# simply work without inline diagnostics until the next release.
case "$platform" in
    macos-*)
        if [ ! -x "$release/bin/luce-lsp-0" ]; then
            echo "luce: release archive is missing bin/luce-lsp-0" >&2
            exit 1
        fi
        ;;
    *)
        if [ ! -x "$release/bin/luce-lsp-0" ]; then
            echo "note: this platform's archive has no language server yet"
        fi
        ;;
esac
for library in libluce_rt.a libluce_start.a; do
    if [ ! -f "$release/lib/$library" ]; then
        echo "luce: release archive is missing lib/$library" >&2
        exit 1
    fi
done
third_party="$release/share/licenses/third-party"
for notice in THIRD_PARTY_NOTICES.md LLVM-LICENSE.txt ZIG-LICENSE.txt; do
    if [ ! -s "$third_party/$notice" ]; then
        echo "luce: release archive is missing third-party notice $notice" >&2
        exit 1
    fi
done
if [ "$system" = Linux ]; then
    for notice in GCC-GPL-3.txt GCC-RUNTIME-EXCEPTION.txt; do
        if [ ! -s "$third_party/$notice" ]; then
            echo "luce: Linux release is missing third-party notice $notice" >&2
            exit 1
        fi
    done
fi
termui_source="$release/lib/termui-$termui_version"
for package_file in luce.yaml termui.luc model.luc input.luc constraints.luc layout.luc widgets.luc canvas.luc view.luc runtime.luc; do
    if [ ! -f "$termui_source/$package_file" ]; then
        echo "luce: release archive is missing termui $termui_version ($package_file)" >&2
        exit 1
    fi
done
extension_source="$release/share/vscode/extensions/$extension_id-$extension_version"
if [ ! -f "$extension_source/package.json" ] ||
    [ ! -f "$extension_source/extension.js" ] ||
    [ ! -f "$extension_source/lsp.js" ] ||
    [ ! -f "$extension_source/language-configuration.json" ] ||
    [ ! -f "$extension_source/syntaxes/luce.tmLanguage.json" ]; then
    echo "luce: release archive is missing the VS Code extension" >&2
    exit 1
fi

# Rename only after the complete download, checksum, extraction and file
# checks have succeeded.  The rollback keeps an existing installation usable
# if the final rename is interrupted.
if [ -e "$install_root" ] || [ -L "$install_root" ]; then
    mv "$install_root" "$backup"
fi
if ! mv "$release" "$install_root"; then
    if [ -e "$backup" ] || [ -L "$backup" ]; then
        mv "$backup" "$install_root"
    fi
    echo "luce: could not replace $install_root" >&2
    exit 1
fi
rm -rf "$backup_dir"
extension_source="$install_root/share/vscode/extensions/$extension_id-$extension_version"

install_editor_extension() {
    extensions_root=$1
    destination="$extensions_root/$extension_id-$extension_version"
    extension_tmp=$(mktemp -d "$extensions_root/.luce-extension.XXXXXX")
    extension_backup="$extensions_root/.luce-extension-old.$$"

    cp -R "$extension_source/." "$extension_tmp/"
    rm -rf "$extension_backup"
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        mv "$destination" "$extension_backup"
    fi
    if ! mv "$extension_tmp" "$destination"; then
        if [ -e "$extension_backup" ] || [ -L "$extension_backup" ]; then
            mv "$extension_backup" "$destination"
        fi
        rm -rf "$extension_tmp"
        echo "luce: could not install the VS Code extension in $extensions_root" >&2
        return 1
    fi
    rm -rf "$extension_backup"
    echo "==> installed Luce syntax highlighting in $extensions_root"
}

install_editor_support() {
    if [ -n "$editor_extensions_dir" ]; then
        mkdir -p "$editor_extensions_dir"
        install_editor_extension "$editor_extensions_dir"
        echo "    Restart the editor (or reload its window) to use .luc highlighting."
        return 0
    fi

    installed=0
    for editor in vscode vscode-insiders cursor; do
        case "$editor" in
            vscode)
                command_name=code
                ;;
            vscode-insiders)
                command_name=code-insiders
                ;;
            cursor)
                command_name=cursor
                ;;
        esac
        editor_home="$HOME/.$editor"
        if [ -d "$editor_home" ] || command -v "$command_name" >/dev/null 2>&1; then
            mkdir -p "$editor_home/extensions"
            install_editor_extension "$editor_home/extensions"
            installed=1
        fi
    done

    # Make the default local VS Code shelf when no editor has been opened yet;
    # VS Code will discover it on its first launch.
    if [ "$installed" -eq 0 ]; then
        mkdir -p "$HOME/.vscode/extensions"
        install_editor_extension "$HOME/.vscode/extensions"
    fi
    echo "    Restart VS Code (or reload its window) to use .luc highlighting."
}

install_editor_support

add_shell_environment() {
    shell_kind=posix
    if [ -n "$profile_override" ]; then
        profile=$profile_override
    else
        shell_path=${SHELL:-/bin/sh}
        shell_name=${shell_path##*/}
        case "$shell_name" in
            zsh)
                profile_dir=${ZDOTDIR:-$HOME}
                if [ "$system" = Darwin ]; then
                    profile="$profile_dir/.zprofile"
                else
                    profile="$profile_dir/.zshrc"
                fi
                ;;
            bash)
                if [ "$system" = Darwin ]; then
                    if [ -f "$HOME/.bash_profile" ]; then
                        profile="$HOME/.bash_profile"
                    elif [ -f "$HOME/.bash_login" ]; then
                        profile="$HOME/.bash_login"
                    else
                        profile="$HOME/.bash_profile"
                    fi
                else
                    profile="$HOME/.bashrc"
                fi
                ;;
            fish)
                profile_dir=${XDG_CONFIG_HOME:-$HOME/.config}
                profile="$profile_dir/fish/config.fish"
                shell_kind=fish
                ;;
            *)
                profile="$HOME/.profile"
                ;;
        esac
    fi

    mkdir -p "$(dirname "$profile")"
    # The default path is written with $HOME so it remains valid if the home
    # directory is referred to through a different spelling in a later shell.
    if [ "$shell_kind" = fish ]; then
        if [ "$install_root" = "$HOME/.local/luce" ]; then
            path_line='fish_add_path --prepend "$HOME/.local/luce/bin"'
            path_pattern='.local/luce/bin'
            library_line='set -gx LUCE_LIB "$HOME/.local/luce/lib" $LUCE_LIB'
            library_pattern='.local/luce/lib'
        else
            path_line="fish_add_path --prepend \"$install_root/bin\""
            path_pattern="$install_root/bin"
            library_line="set -gx LUCE_LIB \"$install_root/lib\" \$LUCE_LIB"
            library_pattern="$install_root/lib"
        fi
    elif [ "$install_root" = "$HOME/.local/luce" ]; then
        path_line='export PATH="$HOME/.local/luce/bin:$PATH"'
        path_pattern='.local/luce/bin'
        library_line='export LUCE_LIB="$HOME/.local/luce/lib${LUCE_LIB:+:$LUCE_LIB}"'
        library_pattern='.local/luce/lib'
    else
        path_line="export PATH=\"$install_root/bin:\$PATH\""
        path_pattern="$install_root/bin"
        library_line="export LUCE_LIB=\"$install_root/lib\${LUCE_LIB:+:\$LUCE_LIB}\""
        library_pattern="$install_root/lib"
    fi
    if grep -Fq "$path_pattern" "$profile" 2>/dev/null; then
        echo "==> PATH already contains $install_root/bin (in $profile)"
    elif printf '\n# Luce %s\n%s\n' "$version" "$path_line" >>"$profile"; then
        echo "==> added $install_root/bin to PATH in $profile"
        if [ "$shell_kind" = fish ]; then
            echo "    Start a new shell, or run: source \"$profile\""
        else
            echo "    Start a new shell, or run: . \"$profile\""
        fi
    else
        echo "luce: installed successfully, but could not update $profile" >&2
        echo "luce: add $install_root/bin to PATH before using luce" >&2
    fi
    if grep -Fq "$library_pattern" "$profile" 2>/dev/null; then
        echo "==> LUCE_LIB already contains $install_root/lib (in $profile)"
    elif printf '%s\n' "$library_line" >>"$profile"; then
        echo "==> added $install_root/lib to LUCE_LIB in $profile"
    else
        echo "luce: installed successfully, but could not update LUCE_LIB in $profile" >&2
        echo "luce: add $install_root/lib to LUCE_LIB before importing shipped packages" >&2
    fi
}

if [ "${LUCE_INSTALL_NO_PATH:-0}" != 1 ]; then
    add_shell_environment
fi

echo "==> Luce $version installed at $install_root"
echo "    source $source_commit"
echo "    luce --version"
