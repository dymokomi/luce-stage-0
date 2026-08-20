# std.build

`std.build` is the vocabulary a project's `build.luc` uses to declare its
plan. A build script is an ordinary compiled Luce program: it constructs a
`Plan`, declares steps, connects them, and `emit()` prints the plan as one
JSON document on standard output. The script never builds anything itself —
the `luce` tool compiles the script through the ordinary compile cache, runs
it in the project root, reads the plan, and executes the steps in dependency
order. Only the chosen step's own dependency closure runs.

```text
import std.build
```

A project is script-built when a `build.luc` sits beside its `luce.yaml`;
a bare `luce build` then runs the plan (and takes no options — the script
decides everything). Without a script, the manifest's `main:` key is the
no-script fast path. See [Command line](/tools/command-line/).

## Plan

| Method | Meaning |
|---|---|
| `program(name, source, output = "", release = false) -> Step` | compile a Luce source to a standalone executable — `luce build SOURCE`, as a step |
| `library(name, source, output = "", release = false) -> Step` | the same compile, emitting the `.lc` library loom loads |
| `object(name, source, output = "", release = false) -> Step` | the same compile, emitting a relocatable object |
| `command(name, argv) -> Step` | one host command run in the project root — a C compiler, a code generator; argv as given: no shell, no splitting |
| `default(step)` | the step a bare `luce build` builds; without one, a plan with exactly one step builds it, and several refuse |
| `emit()` | print the plan — the last thing a build script does |

Paths in a plan — `source` and `output` — are project-root-relative, and
an empty `output` means the tool's default: the artifact named after the
source. Step names must be unique; a duplicate traps in the script, where
the author is.

## Step

A `Step` is a reference made by the `Plan`'s own constructors. It carries
one method and one question:

| Method | Meaning |
|---|---|
| `needs(other)` | this step runs only after `other` has finished |
| `step_name() -> str` | the name the step was declared under |

## A whole build script

```luce run
import std.build

func main():
    var b = build.Plan()
    let tool = b.command("tool", ["cc", "-o", "gen", "gen.c"])
    var app = b.program("app", "src/app.luc")
    app.needs(tool)
    b.default(app)
    b.emit()
```

```output
{"plan":1,"default":"app","steps":[{"name":"tool","kind":"command","argv":["cc","-o","gen","gen.c"],"needs":[]},{"name":"app","kind":"luce","source":"src/app.luc","emit":"exe","output":"","release":false,"needs":["tool"]}]}
```

Run under `luce build`, that plan compiles `gen.c` first and `src/app.luc`
after it, reporting one line per step. A step that fails stops the plan and
names itself; a dependency cycle is refused before anything runs.

The JSON is the whole contract between the script and the tool, which is
why `emit` prints it rather than handing over an object: the plan is
inspectable by eye, by a test, or by any other tool, and the schema is
versioned by its `plan` field.
