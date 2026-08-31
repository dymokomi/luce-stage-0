# About the Language Reference

The final part of the Guide specifies the language implemented by the
current toolchain. Use it when you need an exact rule, syntax form, or
diagnostic name. For explanation and examples, start in the Language Guide.

The reference is intentionally less conversational than the teaching
chapters. It states accepted forms, type requirements, evaluation order,
storage behavior, and refused shapes. A rule applies to both compiled programs
and the differential oracle unless the page explicitly identifies a host or
artifact boundary.

## Find the kind of rule you need

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

Start with the source form when the question is “how is this written?” Start
with Types when the question is “what can this value contain or become?” Use
Memory Management for copy, ARC, weak, resource, and worker-boundary questions.
Use Errors and Traps only after deciding whether the operation is absence,
recoverable failure, or a violated precondition.

The Built-in chapter covers language-owned functions and receiver methods.
Imported `std.*` modules and maintained packages are documented in the
[Library](/library/); command-line behavior is documented under
[Tools](/tools/).

The [Tour](/tour/) gives the short introduction. Earlier chapters in this
[Guide](/guide/) teach the language through complete programs. The
[Library](/library/) documents modules and maintained packages shipped with
the release.

All Luce samples on the site are checked during the site build. If a
page and the compiler disagree, the compiler and its tests are the
authority; update the reference to match them.

## Notation and scope

Code-shaped synopsis blocks use placeholders such as `Name`, `Type`, and
`expression`; they are grammar explanations, not literal programs. Runnable
examples are compiled and executed. Refusal examples are passed through
`luce check`, and their displayed diagnostics are compared with the current
compiler.

“Value” and “reference” have their precise memory meanings. A value copies its
own storage; a reference retains and shares one ARC identity. A value may
contain references, in which case copying the outer value retains those
fields. “Host” means the service table supplied by the executable or runner,
not the operating system reached directly from language semantics.

The reference describes release 0.30 and does not preserve retired syntax.
Luce is pre-1.0, so an older release may have accepted a form this reference
does not mention. [Version Compatibility](/guide/compatibility/) explains
that policy, while [Status](/status/) keeps planned features separate from
implemented rules.

## Citing a rule

The [memory](memory/) page gives each current lifetime rule a stable anchor,
such as `#m7` for last-release destruction. Compiler diagnostics use stable
diagnostic codes; they do not expose retired ownership-rule numbers.

When another document needs an exact claim, link to the narrowest heading or
stable rule anchor rather than copying the rule into a second source. A
teaching chapter may paraphrase the model; this reference owns the exhaustive
form.
