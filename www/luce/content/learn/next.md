# Where to go next

You have seen the core language and the host services that are currently
part of it. Learn is an introduction, not a complete index of every
signature. Use the reference when you need an exact grammar or diagnostic
rule; use the guides when you want the design rationale.

## Choose by task

- [Guides](/guide/) take one theme at a time—structures, unions,
  ownership, failure, modules and packages, strings, the toolchain, and
  testing—and include complete programs you can copy and change.
- [Guide](/guide/) lists the accepted syntax, types, expressions,
  statements, ownership situations, failure codes, modules, and builtins.
- [Standard library](/library/) documents the modules shipped with the
  compiler.

## The language boundary

Luce has static types, checked integer arithmetic and bounds checks. Values
such as numbers, strings, structs, enums and function values copy. Lists,
maps, arrays and builders are owned container objects. Files and tasks are
owned resources and cannot be copied. `T?` represents absence; `T!` marks a
fallible function; `give`, `copy` and `free` make ownership decisions
explicit where the compiler cannot infer them.

Luce does not currently provide user-defined generics, closures, operator
overloading, exceptions, shadowing, or `defer`. Some omissions are design
decisions and some are unfinished work. The [status page](/status/) is the
current source for that distinction.

## Build a program

The simplest development loop is to make the native executable and run it:

```sh
luce build program.luc
./program
```

The toolchain guide explains the available artifact forms and build modes.
