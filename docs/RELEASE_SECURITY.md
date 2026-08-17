# Release security and provenance

This is the current release checklist for Luce 0.18. It describes what the
repository proves before an archive is published and what the installer does
not pretend to prove.

## Inputs are pinned

- The archive manifest names the exact source commit and its commit timestamp.
- Linux release builds use immutable manylinux 2.28 image digests.
- Zig 0.16.0 archives are checked against an architecture-specific SHA-256
  before they enter a builder image.
- LLVM 22.1.8 is fetched from its release tarball and checked against the
  pinned SHA-256 before it is built. The release link is static; the user does
  not need an LLVM installation.
- GitHub Actions are referenced by commit SHA and have `contents: read`
  permissions. The x86-64 prefix workflow is manual and its short-lived
  artifact is consumed only after its source-commit marker is checked.

The release script refuses a dirty source tree, a missing or mismatched
component, an unsupported deployment target, and a Linux prefix built from a
different commit.

## The archive and installer boundary

`www/luce/archive.sh` creates a canonical tar/gzip stream: member order,
ownership, modes, timestamps, and the gzip header are fixed. Two complete
assemblies of the 0.18 release at commit `4f0e36f1b9933c2dc768eab2737d80bea649f9f1`
produced byte-for-byte identical macOS ARM64, Linux ARM64, and Linux x86-64
archives and checksums.

Before replacing an installation, `install.sh`:

1. checks the host family, architecture, macOS/Linux floor, and C linker;
2. verifies the archive's SHA-256 and exact build manifest;
3. rejects absolute, traversal, link, and special-file members outside the
   expected `luce-VERSION/` root;
4. checks binary identity, runtime libraries, notices, TermUI, and the editor
   extension; and
5. downloads into a private temporary directory and replaces the old tree by
   a temporary-directory-backed rename with rollback.

Install and profile override paths are absolute, refuse system trees, and
reject control or shell-sensitive characters before they can be written into
startup files. The installer contract tests cover unsupported hosts, old
system floors, missing linkers, unsafe paths, malicious archive members, and
repeated installation.

## Trust model

The `.tar.gz` and its `.sha256` file are served by the same HTTPS release
endpoint. SHA-256 proves that the downloaded archive matches the downloaded
checksum; it does not authenticate the endpoint if the web host, deployment
credentials, or TLS trust store is compromised. Until a signing-key and key
rotation policy exists, publishing an archive means trusting the release host
and the maintainer's deployment path. Do not treat a checksum as a signature,
and do not run native `.lc` or executable artifacts from an untrusted source.

The serialized `.lcm` loader is hardened against malformed input, but Luce is
not a sandbox. A package or executable has the host permissions of its caller.
Security reports remain private under [SECURITY.md](../SECURITY.md).

## Required release proof

From a clean checkout at the intended commit:

```text
./www/luce/build.sh --fast
./www/luce/release.sh
```

The release command must pass the full macOS 15+ ARM64 and glibc Linux 2.28+
ARM64/x86-64 build matrix, archive checks, and isolated two-install smoke for
each target. Save the checksums and manifest with the published archives.
