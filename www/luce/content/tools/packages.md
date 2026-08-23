# Packages and Projects

Luce has two useful boundaries:

- a **module** is one `.luc` file with one namespace;
- a **package** is a directory of modules with a name and version that another
  project can import; only the installed copy gets the `name-version`
  directory name.

This guide authors a small package in the project tree, then shows where the
same package goes when it is installed as a dependency. That distinction is
important: `.luce/packages/` is a resolved package store, not your working
directory. A source package is just a direct child folder; `.luce` is for
installed copies and generated state.

## What we are going to build

The finished project looks like this:

```text
hello-app/
├── luce.yaml
├── main.luc
├── greet/                     # source package you are authoring
│   ├── luce.yaml
│   ├── greet.luc
│   └── format.luc
└── .luce/
    └── cache/                 # generated; do not edit
```

`hello-app` is both the consuming project and the package's source tree. The
`greet/` directory is ordinary source under version control. When a
package manager eventually installs that package, it will have a separate
store directory such as `.luce/packages/greet-0.1.0/`; the source directory
does not need the installed name or the `.luce` prefix.

## Package commands

Run these commands from the project root:

```sh
luce package new greet
luce package version greet 0.2.0
luce package publish greet
```

`new` creates the direct `greet/` source folder, its `luce.yaml`, its entry
module, and the root `packages:` want with `path:greet`. If the directory is
still rootless, it also creates a small root `luce.yaml`. `version` updates
both manifests together. `publish` is the stable command boundary, but it
currently refuses with a clear message because no package registry or upload
protocol exists yet; it never claims an upload succeeded.

## 1. Create the project root and package skeleton

Create the project root:

```sh
mkdir -p hello-app
cd hello-app
```

Create `luce.yaml` at the project root with the project identity:

```luce module file=luce.yaml
name: hello_app
version: 0.1.0
```

The top-level `name` and `version` identify the project. An optional
`main:` key names the project-root-relative source a bare `luce build`
compiles, so `luce build` with no file works from anywhere under the root.
The `packages:` map is the project's **want list**; every entry has one
exact version. Now let the tool create the package directory and add the
development want:

```sh
luce package new greet 0.1.0
```

The resulting root manifest is:

```luce module file=luce.yaml
name: hello_app
version: 0.1.0

packages:
  greet: 0.1.0 path:greet
```

`path:greet` says “while developing, resolve this package from the
source directory”; it is a root-only development override. There are no
version ranges: to upgrade, edit the number deliberately.

The compiler finds this manifest by walking upward from the source file. Once
it finds one, project imports are relative to this root, not to whichever
subdirectory happened to contain the importing file.

The manifest format is a small YAML subset:

- values are bare words; do not quote them;
- use spaces, never tabs, for indentation;
- maps are one level deep (`packages:` and `override:`);
- comments begin with `#`;
- YAML anchors, aliases, flow style, and multiple documents are refused.

## 2. Author the package as a normal source folder

The command created `greet/` as an ordinary source directory. There is no
version suffix and no `.luce` directory while you are authoring it. Its
manifest is:

```luce module file=greet/luce.yaml
name: greet
version: 0.1.0
```

The name and version identify what this source directory will become when it
is installed. While `path:` is present, they must agree with the root want:

1. the project's want, `greet: 0.1.0`;
2. the package manifest, `name: greet` and `version: 0.1.0`.

If they disagree, Luce refuses the package and names the mismatch. The
versioned directory is only required after promotion to the installed store.

## 3. Write the package's modules

The file named after the package is its entry module. `import greet` loads
`greet.luc`:

```luce module file=greet/greet.luc
import format

func hello(name: str) -> str:
    return format.greeting(name)
```

`greet.luc` imports `format` without a package prefix. That import is anchored
inside the package, so it loads the package's `format.luc`, never a
same-named file in the consuming project:

```luce module file=greet/format.luc
func greeting(name: str) -> str:
    return "Hello, " + name + "!"
```

The consuming program imports the package by name:

```luce module file=main.luc
import greet

func main():
    print(greet.hello("Ada"))
```

Build and run from `hello-app`:

```sh
luce check main.luc
luce build main.luc --emit=library -o hello.lc
loom run hello.lc
```

```output
Hello, Ada!
```

The `.luce/cache/` directory may be created while building. It is derived
state; the package source and both manifests are the files that define the
program.

## 4. Choose the package's public surface

Declarations are private to their file unless marked `pub`. Treat the entry
module as the package's front door: keep `greet.hello` small and `pub`, and
leave representation helpers unmarked or in separate modules.

```luce module file=internal.luc
func normalize(name: str) -> str:
    return name
```

A consumer cannot call a private declaration. A `pub` function also cannot
expose a private type in its signature. If callers need to create a value
without knowing its fields, provide a `pub` factory and keep the fields
private. [Access Control](/guide/access-control/) explains the language
rules; the [modules reference](/guide/reference/modules/#visibility) lists every
diagnostic.

## 5. Version the package deliberately

The version is part of the package's identity, not a suggestion to a solver.
The resolver accepts exact versions only.

When you change the package's public contract:

1. update the package's public code and tests;
2. choose the new version, for example `0.2.0`, and run:

   ```sh
   luce package version greet 0.2.0
   ```

   This updates the source package manifest and the root want together.
3. update any other consuming project's want from `greet: 0.1.0` to
   `greet: 0.2.0`.

Commit the package source under `greet/` with the rest of the
project. Keep only `.luce/cache/` out of source control. Luce does not impose a
Git workflow; the important part is that the source and its manifest travel
together.

An optional content hash makes a want stronger:

```yaml
packages:
  greet: 0.2.0 sha256:<64 hexadecimal digits>
```

When present, Luce hashes the package directory and refuses a changed copy.
There is not yet a command that calculates this hash, so most local packages
start without one.

## 6. Promote the source package to an installed package

The source tree and the installed store have different jobs:

```text
greet/                              # the directory you edit and commit
.luce/packages/greet-0.1.0/        # an installed, versioned copy
```

For local development, keep the `path:` override in the root manifest. It
points at the source directory and Luce prints the choice so a build cannot
silently depend on a machine-local path:

```yaml
name: hello_app
version: 0.1.0

packages:
  greet: 0.1.0 path:greet
```

The source directory must contain `luce.yaml` saying `name: greet` and
`version: 0.1.0`. The override replaces the
`.luce/packages/greet-0.1.0` probe.

Only the root project chooses `path:`. A package cannot redirect one of its
own dependencies this way; that decision belongs in the consuming root.

A package published as a zip archive installs itself: give its want row a
`url:` and a `sha256:` (the tree hash of the unpacked package), and
`luce install` fetches it, verifies the hash and the inner manifest, and
lands it in the store in one rename. A `url:` row without `sha256:` is
refused — an unverifiable download never installs — and a row already in
the store is verified and skipped, so `luce install` is safe to run
repeatedly. For a local package you can also promote the source directory
by hand:

```sh
mkdir -p .luce/packages
mkdir -p .luce/packages/greet-0.1.0
cp -R greet/. .luce/packages/greet-0.1.0/
```

Then remove `path:` from the root manifest. The installed copy now resolves
from `.luce/packages/greet-0.1.0/`, while `greet/` remains the source
you edit. Do not edit the installed copy by hand; make changes in the source
directory and repeat the promotion step.

## 7. Package dependencies and conflicts

A package can have its own `packages:` section. Its imports resolve inside the
package first, then through the package's declared dependencies. The consuming
project does not need to copy those dependencies into its source tree.

Every package in the transitive dependency graph still has one exact version.
If two packages require different versions of the same dependency, Luce
refuses the diamond instead of choosing silently. The root project can record
the decision with `override:`:

```yaml
name: hello_app
version: 0.1.0

packages:
  greet: 0.2.0
  report: 1.1.0

override:
  format: 1.0.0
```

`override:` belongs only in the root manifest. It pins the version (and may
carry `path:` or `sha256:`) for every edge that asks for that package. If the
pin is incompatible with the code, the root owner has made that trade-off
explicit and gets the diagnostic at the import that exposed it.

## What Luce does today

The current package workflow is intentionally manual:

- Luce reads source packages; compiled `.lc` files are programs, not package
  contents.
- Author packages in an ordinary source directory such as `greet/`.
- A root `path:` entry connects that source directory to an import while you
  develop it.
- The project store is `.luce/packages/NAME-VERSION/`.
- `LUCE_LIB` may name additional shelves with the same `NAME-VERSION` layout,
  but a package must still be listed in the root `packages:` want list.
- Luce probes the project store and every shelf and refuses ambiguity; there
  is no “first directory wins.”
- `luce package new` and `luce package version` maintain local source
  packages. `luce package publish` reports that no registry is configured
  until the publishing protocol exists.

That is enough to share a package by committing its source, copying it into a
project's store when needed, and naming its exact version. It also makes a
build reviewable: the root manifest tells you what is wanted, `path:` tells you
which source tree is being developed, the store directory tells you what is
installed, and the package manifest tells you what the package claims to be.

## Before you commit a package

- Does the source package manifest name and version match the consuming root's
  want?
- Is the package listed at the exact version in the consuming root's
  `packages:` map?
- Does the entry module expose a small, intentional API?
- Are package-internal helpers private where callers should not depend on
  them?
- Did you run `luce check` and `luce build` from the project root, then run
  the resulting `.lc` with `loom`?
- If you used `path:`, did you remove it or document why the project remains
  tied to that development directory?

For the complete resolution rules and diagnostics, see the [modules
reference](/guide/reference/modules/#packages). For the language's first
introduction to imports and project roots, start with [Modules](/guide/modules/).
