# About the Language Reference

The final part of the Guide specifies the language implemented by the
current toolchain. Use it when you need an exact rule, syntax form, or
diagnostic name. For explanation and examples, start in the Language Guide.

- [Lexical Structure](lexical/) — encoding, indentation, names, literals,
  keywords, and operators.
- [Types](types/) — scalar and aggregate types, conversions, optionals,
  function values, and resources.
- [Expressions](expressions/) — precedence, calls, operators, indexing,
  narrowing, and failure handling.
- [Statements and Declarations](statements/) — functions, structs,
  enums, unions, control flow, assignment, and constants.
- [Memory Management](memory/) — value copying, ARC, resources, interfaces,
  and worker isolation.
- [Errors and Traps](failure/) — stable trap/error codes and handling
  syntax.
- [Modules](modules/) — imports, visibility, projects, and packages.
- [Built-in Functions and Methods](builtins/) — standalone functions, host services, and receiver
  methods.

The [Tour](/tour/) gives the short introduction. Earlier chapters in this
[Guide](/guide/) teach the language through complete programs. The
[Library](/library/) documents modules and maintained packages shipped with
the release.

All Luce samples on the site are checked during the site build. If a
page and the compiler disagree, the compiler and its tests are the
authority; update the reference to match them.

## Citing a rule

The [memory](memory/) page gives each current lifetime rule a stable anchor,
such as `#m7` for last-release destruction. Compiler diagnostics use stable
diagnostic codes; they do not expose retired ownership-rule numbers.
