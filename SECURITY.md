# Security policy

## Report a vulnerability privately

Do not publish an exploit, malicious `.lcm`/`.lc` artifact, or vulnerability
before there is a fix. Email **dy@dymokomi.com** with the subject
`[Luce security]` and include:

- the affected Luce version and operating system;
- the smallest reproduction or artifact you can safely share;
- the impact you observed or believe is possible; and
- whether the report may be credited to you.

An acknowledgement should arrive within three business days. The first reply
will establish a private channel, severity, and a reasonable disclosure date.
There is no bug bounty program.

## Supported versions

Until 1.0, only the newest published Luce release receives security fixes.
Native `.lc` libraries and standalone executables have the same authority as
other native programs. Run them only when you trust their source or publisher.
Serialized `.lcm` modules are untrusted compiler input and must be rejected
cleanly when malformed; they are not a sandbox.

The release archive and checksum are served by the same HTTPS endpoint. The
checksum detects transfer or publication corruption, but it is not a detached
signature: a compromised release host could replace both files. The current
provenance and installer checks are recorded in
[docs/RELEASE_SECURITY.md](docs/RELEASE_SECURITY.md); a future signing-key and
rotation policy is required before treating a mirror as independently
trusted.

The release supports macOS 15 or newer on Apple Silicon and glibc Linux 2.28+
on ARM64 and x86-64. Other platforms do not receive security support yet.
