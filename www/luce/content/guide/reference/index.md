# About the Language Reference

The final part of the Guide specifies the language implemented by the
current toolchain. Use it when you need an exact rule, syntax form, or
diagnostic name. For explanation and examples, start in the Language Guide.

- [Lexical Structure](lexical/) — encoding, indentation, names, literals,
  keywords, and operators.
- [Types](types/) — scalar and aggregate types, conversions, optionals,
  function values, and resources.
- [Expressions](expressions/) — precedence, calls, operators, indexing,
  ownership operators, and failure handling.
- [Statements and Declarations](statements/) — functions, structs,
  enums, unions, control flow, assignment, and constants.
- [Ownership](ownership/) — the numbered ownership rules (S1–S46).
- [Errors and Traps](failure/) — stable trap/error codes and handling
  syntax.
- [Modules](modules/) — imports, visibility, projects, and packages.
- [Built-in Functions and Methods](builtins/) — free functions, host services, and receiver
  methods.

The [Tour](/tour/) gives the short introduction. Earlier chapters in this
[Guide](/guide/) teach the language through complete programs. The
[Library](/library/) documents modules and maintained packages shipped with
the release.

All Luce samples on the site are checked during the site build. If a
page and the compiler disagree, the compiler and its tests are the
authority; update the reference to match them.

## Citing a rule

The [ownership](ownership/) page gives each of the 46 ratified
situations a stable anchor such as `#s21` and `#s13`. Compiler
diagnostics that include `[OWNERSHIP.md S21]` refer to that anchor.
