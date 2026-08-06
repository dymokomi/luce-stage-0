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
and      break    catch    continue copy     elif     else
false    for      func     give     if       import   in
let      new      none     not      or       private  public
return   self     struct   true     try      var      while
```

`private` and `public` mark a declaration's
[visibility](../statements/#visibility), and inside a struct they also
stand as the region labels `private:` and `public:`.

`self` is the receiver of a [method](../statements/#methods). It is a
keyword rather than a convention so that nothing can shadow it and no
declaration can call something else by that name — which is what makes
`p.length()` readable as a call on `p` and nothing else.

## Reserved names

The language reserves these; nothing user-declared may take them, and
one that does is `luce.sema.reserved`.

```
range       long         double       bool        string
list        map         array       builder     None
abs         min         max         clamp       sqrt
floor       ceil        len         slice       byte_at
assert      trap        str         parse_int   parse_float
chr         ord         append      pop         insert
remove      has         dim         free        print
file_read   file_write  file_exists key_read    key_text
error       read_line   print_error clock_ms    sleep_ms
env         file_append file_delete file_rename dir_list
term_rows   term_cols   term_clear  term_move   term_style
term_write  term_flush  exit        trunc

os_total_memory          os_available_memory     os_cpu_count
```

The **methods** are not on that list. `sort`, `has`, `get` and the rest
are resolved by the type of the receiver they are called on, so a
function of the same name collides with nothing and a program may
declare one.

## Number literals

Decimal only. An integer literal is a sequence of digits and yields an
`long`; a fraction or an exponent yields a `double`.

```
12        long
1.5       double
1e10      double
1.5e-3    double
```

A `.` starts a fraction only when a digit follows it. There are **no**
hexadecimal, binary or octal literals and **no** `_` digit
separators — writing one is `luce.lex.number`, naming the reason,
rather than a silent misreading. A non-finite float literal such as
`1e400` is refused.

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

There are 59 codes and this site names about 26 of them. That is
deliberate rather than partial: most of the rest are ordinary
"expected `X`, found `Y`" parse errors whose message *is* the
documentation, and a page repeating it would add nothing to search
for. What is named is every code a reader might want to look up
because the message alone does not say why the rule exists — the four
above, the import rules on [modules](/ref/modules/), the ownership
codes, and the two entry-point rules below.

## The entry point

A program is exactly `func main():`, or `func main() -> !:` when the
world can stop it. Anything else — no `main` at all, or a `main` that
takes parameters or returns a value — is `luce.sema.main`.

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
