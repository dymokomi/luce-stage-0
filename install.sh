#!/bin/sh
# Install the built LuciaOS toolchain into a user-owned prefix.
#
# The default is ~/.local, so this never needs sudo and never replaces the
# repository's build/ tree with an installed symlink.  Development commands
# keep using build/luce, build/loom, and build/editor; an install is a
# separate snapshot.
#
#   ./install.sh                  build, install, and update the shell profile
#   ./install.sh --no-build       install the existing build/ tree
#   ./install.sh --prefix DIR     install below DIR instead of ~/.local
#   ./install.sh --no-path        do not edit a shell profile
set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
os=$(uname -s)
case "$os" in
    Darwin|Linux) ;;
    *)
        echo "install: unsupported operating system: $os" >&2
        echo "install: build.sh remains available for this host" >&2
        exit 1
        ;;
esac

if [ -n "${PREFIX:-}" ]; then
    prefix=$PREFIX
elif [ -n "${LUCIAOS_PREFIX:-}" ]; then
    prefix=$LUCIAOS_PREFIX
else
    prefix=$HOME/.local
fi
build_first=1
update_path=1

usage() {
    cat >&2 <<'EOF'
usage: ./install.sh [--no-build] [--no-path] [--prefix DIR]

Builds the ReleaseSafe toolchain and installs luce, loom, editor, and
their static libraries into a user-owned prefix (default: ~/.local).
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-build)
            build_first=0
            ;;
        --no-path)
            update_path=0
            ;;
        --prefix)
            if [ "$#" -lt 2 ]; then
                echo "install: --prefix needs a directory" >&2
                exit 1
            fi
            prefix=$2
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "install: unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
    shift
done

case "$prefix" in
    /*) ;;
    *) prefix="$PWD/$prefix" ;;
esac

# Installing into the checkout would make the installed snapshot and the
# development tree indistinguishable.  Keep the boundary explicit.
case "$prefix" in
    "$here"|"$here"/*)
        echo "install: prefix must be outside the repository: $prefix" >&2
        exit 1
        ;;
esac

if [ "$build_first" -eq 1 ]; then
    echo "==> building ReleaseSafe toolchain"
    "$here/build.sh"
else
    echo "==> using existing build/ tree"
fi

for tool in luce loom; do
    if [ ! -x "$here/build/$tool" ]; then
        echo "install: $here/build/$tool is missing; run ./build.sh first" >&2
        exit 1
    fi
done
if [ ! -x "$here/build/editor" ]; then
    echo "install: $here/build/editor is missing; run ./build.sh first" >&2
    exit 1
fi
for library in libluce_rt.a libluce_start.a; do
    if [ ! -f "$here/build/lib/$library" ]; then
        echo "install: $here/build/lib/$library is missing; run ./build.sh first" >&2
        exit 1
    fi
done

bin_dir="$prefix/bin"
lib_dir="$prefix/lib"
mkdir -p "$bin_dir" "$lib_dir"
cp "$here/build/luce" "$bin_dir/luce"
cp "$here/build/loom" "$bin_dir/loom"
cp "$here/build/editor" "$bin_dir/editor"
cp "$here/build/lib/libluce_rt.a" "$lib_dir/libluce_rt.a"
cp "$here/build/lib/libluce_start.a" "$lib_dir/libluce_start.a"
chmod 755 "$bin_dir/luce" "$bin_dir/loom" "$bin_dir/editor"
chmod 644 "$lib_dir/libluce_rt.a" "$lib_dir/libluce_start.a"

profile=
path_line=
case "$(basename "${SHELL:-sh}")" in
    fish)
        profile=${XDG_CONFIG_HOME:-"$HOME/.config"}/fish/config.fish
        path_line="fish_add_path --prepend '$bin_dir'"
        mkdir -p "$(dirname "$profile")"
        ;;
    zsh)
        profile=${ZDOTDIR:-"$HOME"}/.zprofile
        path_line="export PATH=\"$bin_dir:\$PATH\""
        ;;
    bash)
        if [ "$os" = Darwin ]; then
            profile="$HOME/.bash_profile"
        else
            profile="$HOME/.profile"
        fi
        path_line="export PATH=\"$bin_dir:\$PATH\""
        ;;
    *)
        profile="$HOME/.profile"
        path_line="export PATH=\"$bin_dir:\$PATH\""
        ;;
esac

path_updated=0
if [ "$update_path" -eq 1 ]; then
    if [ ! -f "$profile" ] || ! grep -Fqx "$path_line" "$profile"; then
        {
            if [ -s "$profile" ]; then
                printf '\n'
            fi
            printf '%s\n' '# LuciaOS user-local toolchain' "$path_line"
        } >> "$profile" && path_updated=1 || {
            echo "install: could not update $profile" >&2
        }
    else
        path_updated=1
    fi
fi

version=$("$bin_dir/luce" --version)
loom_version=$("$bin_dir/loom" --version)
echo "installed $version, $loom_version, and editor"
echo "  binaries: $bin_dir"
echo "  libraries: $lib_dir"

if [ "$path_updated" -eq 1 ]; then
    echo "PATH update: $profile"
    echo "Open a new shell, or run:"
    if [ "$(basename "${SHELL:-sh}")" = fish ]; then
        echo "  fish_add_path --prepend '$bin_dir'"
    else
        echo "  export PATH=\"$bin_dir:\$PATH\""
    fi
else
    echo "Add $bin_dir to PATH before using luce or loom."
fi

echo "Development and benchmark commands continue to use build/luce, build/loom, and build/editor."
