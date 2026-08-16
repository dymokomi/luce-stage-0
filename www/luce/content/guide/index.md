# The Luce guide

This is the language book. Its first part teaches Luce in dependency order;
its second part states the exact grammar and semantics for lookup. Both
describe the current compiler. Planned features appear on [Status](/status/),
not mixed into examples a reader is supposed to run.

## Language Guide

Begin with [About Luce](/guide/about/) for the language’s goals and memory,
failure, effect, and concurrency boundaries. [Version
Compatibility](/guide/compatibility/) explains the intentionally breaking 0.x
period before you depend on a particular release.

The teaching sequence then follows the same questions that arise while a
program grows:

1. **Values and expressions:** [The Basics](/guide/basics/), [Basic
   Operators](/guide/operators/), [Strings and Text](/guide/strings/), and
   [Collection Types](/guide/collections/).
2. **Behavior:** [Control Flow](/guide/control/), [Functions](/guide/functions/),
   and [Closures](/guide/closures/).
3. **Data modeling:** [Enumerations](/guide/enums/),
   [Structures](/guide/structures/), [Methods](/guide/methods/),
   [Classes](/guide/classes/), [Initialization](/guide/initialization/), and
   [Deinitialization](/guide/deinitialization/).
4. **Alternative outcomes:** [Optionals](/guide/optionals/),
   [Unions](/guide/unions/), and [Error Handling](/guide/errors/).
5. **Larger programs:** [Concurrency](/guide/concurrency/),
   [Interfaces](/guide/interfaces/), [Memory and ARC](/guide/memory/),
   [Access Control](/guide/access-control/), [Global
   Constants](/guide/constants/), [Modules and Imports](/guide/modules/), and
   [Host Effects](/guide/host/).

Each chapter starts with the common use, explains the model behind it, then
covers mutation, lifetime, failure, and important refused shapes at the point
where they matter. Examples are checked by the current toolchain; displayed
output, expected errors, and expected traps are verified separately.

You do not need to read the whole book before writing useful code. Follow the
sequence until you can build the program in front of you, then return when a
new design question appears.

## Language Reference

The reference closes this same book because explanation and specification are
different reading modes, not different languages.

- [About the Language Reference](/guide/reference/) explains its scope.
- [Lexical Structure](/guide/reference/lexical/) defines source characters,
  indentation, names, literals, keywords, and punctuation.
- [Types](/guide/reference/types/) lists every current type form and its value,
  reference, optional, result, and equality behavior.
- [Expressions](/guide/reference/expressions/) fixes precedence, calls,
  lambdas, indexing, slicing, construction, narrowing, `try`, and `catch`.
- [Statements and Declarations](/guide/reference/statements/) covers file
  structure, bindings, assignment, control flow, and every declaration.
- [Memory Management](/guide/reference/memory/) states the exact copy, ARC,
  weak, closure, interface, resource, and worker rules.
- [Errors and Traps](/guide/reference/failure/) lists stable outcome codes and
  their conditions.
- [Modules](/guide/reference/modules/) defines imports, visibility, projects,
  packages, and the `std.` namespace.
- [Built-in Functions and Methods](/guide/reference/builtins/) is the complete
  intrinsic surface with signatures.

Use search or the reference directly when you already know the concept and
need an exact answer. Teaching chapters link to the relevant rule so a reader
can move from intent to specification without guessing which document is
authoritative.

Installation, artifacts, the editor, packages, testing, complete programs, and
performance live under [Tools](/tools/). Imported modules and maintained
packages live in the [Library](/library/).
