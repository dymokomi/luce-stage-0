# Reproducible Linux release builder for Luce.
#
# The host script selects one of the two immutable manylinux 2.28 base images.
# This image adds only the pinned Zig release and the repository's pinned,
# static LLVM. The resulting `luce` binary therefore needs glibc, not an LLVM
# development installation on the user's machine.
ARG BASE_IMAGE=quay.io/pypa/manylinux_2_28_x86_64@sha256:a694e7d81cdc90b1a3f4e8207d95d63a226df973dbd681a3b31599e90dd9436d
FROM ${BASE_IMAGE}

ARG ZIG_VERSION=0.16.0
ARG LLVM_BUILD_JOBS=6

RUN set -eu; \
    architecture=$(uname -m); \
    case "$architecture" in \
        aarch64) zig_sha256=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;; \
        x86_64) zig_sha256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;; \
        *) echo "linux release: unsupported builder architecture: $architecture" >&2; exit 1 ;; \
    esac; \
    zig_archive="zig-${architecture}-linux-${ZIG_VERSION}.tar.xz"; \
    curl -fL "https://ziglang.org/download/${ZIG_VERSION}/${zig_archive}" -o "/tmp/${zig_archive}"; \
    printf '%s  %s\n' "$zig_sha256" "/tmp/${zig_archive}" | sha256sum -c -; \
    mkdir -p /opt/zig; \
    tar xf "/tmp/${zig_archive}" -C /opt/zig --strip-components=1; \
    rm "/tmp/${zig_archive}"; \
    test "$(/opt/zig/zig version)" = "$ZIG_VERSION"

COPY vendor-llvm.sh /opt/luce-source/vendor-llvm.sh

# Build and keep only the static install. Source, tarball and build tree are
# removed in the same layer so they never inflate the finished image.
RUN set -eu; \
    cd /opt/luce-source; \
    LLVM_BUILD_JOBS="$LLVM_BUILD_JOBS" ./vendor-llvm.sh; \
    mv .llvm/install /opt/luce-llvm; \
    rm -rf .llvm; \
    test "$(/opt/luce-llvm/bin/llvm-config --version)" = 22.1.8; \
    test "$(/opt/luce-llvm/bin/llvm-config --shared-mode)" = static

ENV PATH=/opt/zig:/opt/luce-llvm/bin:/opt/rh/gcc-toolset-14/root/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WORKDIR /work
ENTRYPOINT []
CMD ["/bin/bash"]
