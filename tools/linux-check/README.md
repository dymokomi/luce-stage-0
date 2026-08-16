# Building and testing this tree on Linux

The tree is developed on macOS on Apple Silicon.  Everything in it is
portable by construction — Zig, one `llvm-config`, one `cc` — but
"portable by construction" is a claim, and a claim nobody has run is a
guess.  This is what runs it.

`Dockerfile` builds a `linux/arm64` image with exactly the things
the build asks for and nothing else:

- **Zig**, at the version `build.zig.zon` pins (`ZIG_VERSION`, the
  official tarball, not a distribution package — no distribution has
  it).
- **LLVM 22**, the major `vendor-llvm.sh` pins, from apt.llvm.org.
  Debian trixie's own LLVM is 19, which predates the bitcode Zig 0.16's
  builder writes.  The package installs `/usr/bin/llvm-config-22`,
  which is a name `build.zig` already looks for, so nothing has to be
  passed to the build.
- **`cc`**, because compiling a Luce program is a link.
- **Info-ZIP's `zip` and `unzip`**, so `src/apps/loom/zipping.zig`'s
  agreement test runs instead of skipping.  It is the one test that
  checks zipper against another implementation, and a machine without
  them says so and passes anyway — which is worth nothing.
- **Node.js**, because the full release gate owns the dependency-free VS Code
  extension tests too. A container that omitted it could prove the language
  and still fail the repository's actual gate before those tests began.

## Running it

Build the image once, then copy the tree in and work on the copy.  The
build writes `.zig-cache/`, `build/` and `.lc` files beside sources, so
the host tree is never mounted writable — and `git archive` is the
cleanest copy there is, because it carries what is committed and no
build output, no worktrees, and no `.llvm/`.

```sh
docker build --platform linux/arm64 -t luce-linux tools/linux-check
git archive HEAD -o /tmp/luce-src.tar

docker run -d --name luce-lin --platform linux/arm64 luce-linux sleep infinity
docker cp /tmp/luce-src.tar luce-lin:/tmp/src.tar
docker exec luce-lin sh -c 'mkdir -p /work/luce && tar xf /tmp/src.tar -C /work/luce'

docker exec luce-lin sh -c 'cd /work/luce && ./build.sh'
docker exec luce-lin sh -c 'cd /work/luce && zig build test --summary all'
```

If you copy an *uncommitted* tree with `tar` on macOS instead, set
`COPYFILE_DISABLE=1`: without it macOS writes an AppleDouble `._NAME`
beside every file with an extended attribute, and `tools/documents.zig`
correctly reports thirty documents in `docs/` that are in no catalogue.

`linux/amd64` works the same way — the Dockerfile reads `uname -m` for
the Zig tarball — but on an Apple Silicon host it runs under emulation
and is slow enough that it is worth doing only after arm64 is green.

## What Linux does differently

Three things this image exists to catch, all of them invisible on
macOS and all of them now handled in the tree rather than here:

- **Threads and libm are separate at the compatibility floor.** glibc
  before 2.34 needs `-pthread`, and float `%` needs `-lm`; Darwin's
  libSystem has both already.
- **`std.c` needs libc asked for.**  Darwin links libc into every
  binary, so a module that reads `std.c.environ` compiles there whether
  or not it said it needed libc.
- **`dlopen("name.lc")` is a library name, not a file.**  Only dyld
  falls back to the working directory, so a path with no separator in
  it has to be spelled `./name.lc` before the loader sees it.
