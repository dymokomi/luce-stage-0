#!/bin/sh
# Build one Linux release prefix in its native, pinned manylinux container.
#
#   tools/linux-release/build.sh aarch64 /absolute/output
#   tools/linux-release/build.sh x86_64 /absolute/output
set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "$here/../.." && pwd)
source_commit=$(git -C "$root" rev-parse --verify HEAD)
if [ -n "$(git -C "$root" status --porcelain --untracked-files=normal)" ]; then
    echo "linux release: source tree is not clean" >&2
    exit 1
fi

if [ "$#" -ne 2 ]; then
    echo "usage: tools/linux-release/build.sh ARCH ABSOLUTE_OUTPUT" >&2
    exit 1
fi

architecture=$1
output=$2
case "$output" in
    /*) ;;
    *)
        echo "linux release: output must be an absolute path: $output" >&2
        exit 1
        ;;
esac

case "$architecture" in
    aarch64)
        platform=linux/arm64
        base_image=quay.io/pypa/manylinux_2_28_aarch64@sha256:817404d425b2edff4657a4bbf59e5a9fdb274609d31c99c1f9edc3be4426b00b
        ;;
    x86_64)
        platform=linux/amd64
        base_image=quay.io/pypa/manylinux_2_28_x86_64@sha256:a694e7d81cdc90b1a3f4e8207d95d63a226df973dbd681a3b31599e90dd9436d
        ;;
    *)
        echo "linux release: ARCH must be aarch64 or x86_64" >&2
        exit 1
        ;;
esac

command -v docker >/dev/null 2>&1 || {
    echo "linux release: Docker is required to build the published Linux toolchains" >&2
    exit 1
}

image="luce-release-${architecture}:zig-0.16.0-llvm-22.1.8-manylinux-2.28"
context=$(mktemp -d "${TMPDIR:-/tmp}/luce-linux-image.XXXXXX")
cleanup() {
    rm -rf "$context"
}
trap cleanup 0 HUP INT TERM
cp "$here/Dockerfile" "$context/Dockerfile"
cp "$root/vendor-llvm.sh" "$context/vendor-llvm.sh"

echo "==> Linux $architecture release environment"
# The LLVM build dominates image time; a builder with more cores than the
# Dockerfile's conservative default sets LLVM_BUILD_JOBS to match.
docker build \
    --platform "$platform" \
    --build-arg "BASE_IMAGE=$base_image" \
    --build-arg "LLVM_BUILD_JOBS=${LLVM_BUILD_JOBS:-6}" \
    --tag "$image" \
    --file "$context/Dockerfile" \
    "$context"

mkdir -p "$output"
echo "==> Linux $architecture toolchain"
# Docker Desktop presents bind mounts as root-owned inside its VM, even when
# the host directory belongs to the invoking macOS user. Native Linux does
# preserve numeric ownership, so keep its output owned by that user.
case "$(uname -s)" in
    Darwin) set -- ;;
    *) set -- --user "$(id -u):$(id -g)" ;;
esac
docker run --rm \
    --platform "$platform" \
    "$@" \
    --env HOME=/tmp/luce-release-home \
    --env "LUCE_RELEASE_ARCH=$architecture" \
    --env "LUCE_RELEASE_SOURCE_COMMIT=$source_commit" \
    --volume "$root:/source:ro" \
    --volume "$output:/output" \
    "$image" \
    /source/tools/linux-release/build-inside.sh
