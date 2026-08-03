# Source text and lexical elements

## Encoding

A source file is UTF-8 text of at most 64 MiB. Lines end with LF or
CRLF; a leading byte-order mark is ignored.

What is not text is refused before parsing begins, once, naming the
file and the position inside it.

| Condition | Code |
|---|---|
| Invalid UTF-8 (the offending byte is printed) | `luce.source.utf8` |
| A NUL byte | `luce.source.binary` |
| A carriage return that does not end a line | `luce.source.line_ending` |
| A UTF-16 or UTF-32 byte-order mark | `luce.source.encoding` |
| Larger than 64 MiB | `luce.source.too_large` |

Bidirectional control characters are refused everywhere.

The program may come from standard input (`luce check -`, or any
pipe). Diagnostics then name it `<stdin>`, and imports resolve beside
the current directory.

## Indentation

Blocks are introduced by `:` at the end of a line and delimited by
indentation. One level is **four spaces**, exactly. Tabs are not
indentation and neither is any other width.

## Comments

`#` to the end of the line. There is no block comment form.

## Identifiers

`[A-Za-z_][A-Za-z0-9_]*`. Case is significant. Convention, which the
compiler relies on for type names, is TitleCase for types and
snake_case for everything else.

There is **no shadowing**: a name declared in an enclosing scope
cannot be re-declared in an inner one.

## Keywords

```
and      break    catch    continue copy     elif     else
false    for      func     give     if       import   in
let      new      none     not      or       return   struct
true     try      var      while
```

## Reserved names

The language reserves these; nothing user-declared may take them.

```
input   output   Input   output   range   Int     Float   Bool
String  Bytes    List    Map      Array   Builder None    abs
min     max      clamp   sqrt     floor   ceil    len     slice
byte_at assert   trap    str      parse_int        parse_float
chr     ord      append  pop      insert  remove  has     dim
free    print    file_read        file_write       file_exists
arg     arg_count         key_read         key_text         error
```

## Number literals

Decimal only. An integer literal is a sequence of digits and yields an
`Int`; a fraction or an exponent yields a `Float`.

```
12        Int
1.5       Float
1e10      Float
1.5e-3    Float
```

A `.` starts a fraction only when a digit follows it. There are **no**
hexadecimal, binary or octal literals and **no** `_` digit
separators — writing one is `luce.lex.number`, naming the reason,
rather than a silent misreading. A non-finite float literal such as
`1e400` is refused.

## String literals

`"..."`, on one line. The escapes are exactly four:

| Escape | Means |
|---|---|
| `\n` | line feed |
| `\t` | tab |
| `\\` | backslash |
| `\"` | double quote |

Every other escape is rejected by name — `\r`, `\0`, and hex and
unicode escapes included. A codepoint goes in with `chr(...)`.

An `f"..."` literal is an interpolated string: `{expression}` holes
are converted with `str(...)` and concatenated. `{{` and `}}` are
literal braces. A hole holds one expression, and `"..."` strings
nested inside a hole are permitted.

## Operators and punctuation

```
+  -  *  /  %          arithmetic
== != <  <= >  >=      comparison (non-associative)
=  += -= *= /= %=      assignment
:  ,  .  ->  ?  !      declaration and type syntax
(  )  [  ]  _          grouping, indexing, array shape
```

## Diagnostics

Every diagnostic carries a stable code and a byte span, and renders as
`file:line:column` in both build modes. Codes are namespaced by the
stage that raised them: `luce.source.*`, `luce.lex.*`,
`luce.parse.*`, `luce.sema.*`, `luce.import.*`.

At most 100 diagnostics are reported for one compilation.
