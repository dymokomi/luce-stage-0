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

Both are refused by name rather than misread, because a file that
looks one way and runs another is the failure this rule exists to
prevent.

| Written | Code |
|---|---|
| A tab where indentation belongs | `luce.lex.tab` |
| Any step that is not four spaces | `luce.lex.indent` |

```luce fail
func main():
  print("two spaces")
```

```output
luce: compile failed
main.luc:2:1: a block is indented exactly 4 spaces past the one containing it, not 2 [luce.lex.indent]
      print("two spaces")
    ^~
```

## Comments

`#` to the end of the line. There is no block comment form.

## Identifiers

`[A-Za-z][A-Za-z0-9_]*`. Case is significant. Convention, which the
compiler relies on for type names, is TitleCase for types and
snake_case for everything else.

**A name starts with a letter.** A leading underscore is refused
everywhere a word can stand — `luce.lex.name` — because the language
has a real `private` keyword, so a sigil has nothing left to encode
and would only grow folklore meanings the compiler does not enforce.
Interior and trailing underscores are the house style (`word_end`,
`append_text`), and the lone `_` stays what it is: the array-shape
wildcard, which is not a name.

```luce fail
func main():
    let _total = 1
```

```output
luce: compile failed
main.luc:2:9: a name starts with a letter: _total is not a name [luce.lex.name]
        let _total = 1
            ^~~~~~
```

```luce fail
func main():
    let _ = read_count()

func read_count() -> long:
    return 3
```

```output
luce: compile failed
main.luc:2:9: _ is the array-shape wildcard, not a name (array(long, _)); a binding needs a name [luce.parse.expected]
        let _ = read_count()
            ^
```

There is **no shadowing**: a name declared in an enclosing scope
cannot be re-declared in an inner one.

## Keywords

```
and      break    catch    const    continue copy     elif
else     enum     false    for      func     give     if
import   in       let      match    new      none     not
or       private  public   return   self     spawn    static
struct   true     try      var      while
```

`spawn` runs a call on a [worker](/tour/threads/) instead of making
it here.  A keyword rather than a builtin because its operand is a
call that must *not* be made at the site — which is not something a
builtin's arguments can say.

`private` and `public` mark a declaration's
[visibility](../statements/#visibility), and inside a struct they also
stand as the region labels `private:` and `public:`.

`self` is the receiver of a [method](../statements/#methods). It is a
keyword rather than a convention so that nothing can shadow it and no
declaration can call something else by that name — which is what makes
`p.length()` readable as a call on `p` and nothing else.

`static` belongs immediately before `func` inside a struct or enum. It
marks the namespace member that has no implied `self`; a file-scope
function is already a namespace function and does not say it.

`const` declares a file-scope folded value or program-root constant
container. `let` and `var` declare inside functions; a top-level `let`
is refused with `const` named as the fix.

## Reserved names

The language reserves these; nothing user-declared may take them, and
one that does is `luce.sema.reserved`.

```
range       long         double       string              None
abs         min          max          clamp               sqrt
floor       ceil         trunc        len                 byte_at
assert      trap         parse_int    parse_float         chr
ord         append       pop          insert              remove
has         dim          free         print               file_read
file_write  file_exists  key_read     key_text            error
read_line   print_error  clock_ms     sleep_ms            env
file_append file_delete  file_rename  dir_list            term_rows
term_cols   term_clear   term_move    term_style          term_write
term_flush  exit         os_total_memory os_available_memory os_cpu_count
file_open   parse_string shell_run
```

**Most methods** are not reserved. `sort`, `find`, `contains`, `clear`,
`keys`, `values`, `get` and `build` are resolved by receiver type, so a
program may declare a function of the same name. Seven historical
exceptions are reserved anyway: `append`, `insert`, `pop`, `remove`,
`has`, `dim` and `byte_at`. Thus `func sort` is legal while `func has`
is refused, even though both method calls name a receiver.

## Number literals

A literal has no type until it lands on a context. Decimal integer and
floating-point literals use the spellings below. An integer defaults
to `int` when nothing supplies a type; a fraction or exponent defaults
to `float`. An annotation, argument, return or container element may
instead land the same text directly on another width.

```
12        int, without a context
1.5       float, without a context
1e10      float, without a context
1.5e-3    float, without a context
```

A `.` starts a fraction only when a digit follows it. A non-finite
float literal such as `1e400` is refused.

**Hexadecimal and binary integers** are written `0xFF` and `0b1010`
(case-insensitive digits and prefix), and `_` **digit separators** sit
between digits of any literal: `1_000_000`, `0xFF_FF`, `0b1010_1010`.
A separator anywhere else — leading, trailing, doubled, or beside the
prefix or the point — is `luce.lex.number` naming the rule. There are
**no octal literals**: `0o17` is refused by name, and a decimal
integer may not start with a zero, so C's silent `0755` cannot be
written at all.

## string literals

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
are converted with `string(...)` and concatenated. `{{` and `}}` are
literal braces. A hole holds one expression, and `"..."` strings
nested inside a hole are permitted.

A hole may end with a format spec, and `:.Nf` is the only one there
is — a `double` to N decimal places, rounded half away from zero. It
lowers to `strings.format_float(value, N)`, so a program using one
needs `import std.strings` exactly as any other string service does.
A colon inside brackets belongs to the brackets: `f"{s[1:3]}"` is a
slice, not a spec. [Format specs](/tour/strings/#format-specs) has the
worked examples.

## Operators and punctuation

```
+  -  *  /  %  //          arithmetic
&  |  ^  ~  << >>          bitwise (int and long only)
== != <  <= >  >=          comparison (non-associative)
=  += -= *= /= //= %=      assignment
&= |= ^= <<= >>=           assignment, the bit set's five
:  ,  .  ->  ?  !          declaration, type and lambda syntax
(  )  [  ]  {  }  _        grouping, indexing, map literals, array shape
```

Indentation is suspended inside parentheses, brackets and map braces,
so a multiline `{key: value}` literal needs no continuation marker.
Braces inside an f-string still follow the f-string rules above.

The bitwise precedence is Go's, not C's: `&`, `<<` and `>>` bind at
the multiply level, `|` and `^` at the add level — so
`flags & mask != 0` means `(flags & mask) != 0`, the reading C
famously gets wrong. Shifts move bits rather than multiply: `<<`
discards high bits without trapping, `>>` sign-extends (the operands
are signed), and the one thing that traps is a **count** below zero
or at the operand's width — `shift_out_of_range`, where C leaves
undefined behavior and Go silently masks.

```luce run
func main():
    let flags = 0b1010
    print(string(flags & 0b0010 != 0))
    print(string(0xF0 | 0x0F))
    print(string(~0))
    print(string(-8 >> 1))
    print(string(1_000_000 >> 3))
```

```output
true
255
-1
-4
125000
```

## Diagnostics

Every diagnostic carries a stable code and a byte span, and renders as
`file:line:column` in both build modes. Codes are namespaced by the
stage that raised them: `luce.source.*`, `luce.lex.*`,
`luce.parse.*`, `luce.sema.*`, `luce.import.*`.

At most 100 diagnostics are reported for one compilation.

This site names the codes a reader might want to look up because the
message alone does not say why the rule exists: the lexical families
above, the import rules on [modules](/ref/modules/), the ownership
codes, and the entry-point rules below. It does not try to catalogue
ordinary "expected `X`, found `Y`" parse errors whose message already
states the rule.

## The entry point

A program has exactly one `main`, with either no parameter or one
`list(string)` command-line parameter, and with optional `-> !` on
either shape. Anything else — no `main` at all, another parameter
list, or a value result — is `luce.sema.main`.

```luce fail
func start():
    print("x")
```

```output
luce: compile failed
main.luc:1:1: missing func main(): [luce.sema.main]
    func start():
    ^
```
