# Source text and lexical elements

## Encoding

Source is UTF-8 text no larger than 64 MiB. A leading UTF-8 byte-order
mark is ignored. Lines may end in LF or CRLF. A carriage return in any
other position, a NUL byte, invalid UTF-8, UTF-16/UTF-32 byte-order
marks, and bidirectional control characters are rejected before parsing.

| Condition | Code |
|---|---|
| Invalid UTF-8 | `luce.source.utf8` |
| NUL byte | `luce.source.binary` |
| Carriage return not ending a line | `luce.source.line_ending` |
| UTF-16 or UTF-32 byte-order mark | `luce.source.encoding` |
| Source larger than 64 MiB | `luce.source.too_large` |

`luce check -` reads standard input. Such diagnostics use `<stdin>`;
imports resolve relative to the current directory.

## Indentation

`:` opens a block. One indentation level is exactly four spaces. Tabs
are not indentation, and another number of spaces is invalid.

| Condition | Code |
|---|---|
| Tab used for indentation | `luce.lex.tab` |
| Indentation step is not four spaces | `luce.lex.indent` |

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

Indentation is suspended inside `()`, `[]`, and map literal `{}`
delimiters.

## Comments

`#` starts a comment that runs to the end of the line. There is no block
comment syntax.

## Identifiers

An identifier matches `[A-Za-z][A-Za-z0-9_]*`; case is significant.
Type names conventionally use `TitleCase`; other names use `snake_case`.
Names cannot begin with `_`, and `_` is reserved as the array-shape
wildcard. Names cannot shadow a name from an enclosing scope.

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

## Keywords

```
and      break    catch    const    continue copy     elif
else     enum     false    for      func     give     if
import   in       let      match    new      none     not
or       private  public   return   self     spawn    static
struct   true     try      union    var      while
```

`private` and `public` mark visibility. Inside a struct they can also be
region labels (`private:` and `public:`). `self` is the receiver of a
method. `static` marks a namespace function declared inside a struct,
enum, or union. `const` declares a file-scope constant; `let` and `var`
are function-scope bindings. `spawn` starts a worker call.

`static` belongs immediately before `func`.

## Reserved names

The following names are reserved for builtins and compiler syntax. A
declaration using one is `luce.sema.reserved`.

```
range       long         double       string              None
abs         min          max          clamp               sqrt
floor       ceil         trunc        len                 byte_at
assert      trap         parse_int    parse_float         chr
ord         append       pop          insert              remove
has         dim          free         print               file_read
file_write  path_kind    key_read     key_text            error
read_line   print_error  clock_ms     sleep_ms            env
file_append file_delete  file_rename  dir_list            term_rows
term_cols   term_clear   term_move    term_style          term_write
term_flush  exit         os_total_memory os_available_memory os_cpu_count
file_open   parse_string shell_run    term_event_data     dir_create
epoch_ms    gpu_backend  ui_window_open  ui_window_surface
gpu_surface_size  gpu_surface_clear  gpu_surface_fill_rect  gpu_surface_present
```

Most receiver methods are not reserved: a user function may be named
`sort`, `find`, `contains`, `clear`, `keys`, `values`, `get`, or `build`.
The historical method names `append`, `insert`, `pop`, `remove`, `has`,
`dim`, and `byte_at` remain reserved.

## Number literals

An unannotated integer literal has type `int`; an unannotated fraction
or exponent literal has type `float`. A context can select another
numeric type.

```
12        int
1.5       float
1e10      float
1.5e-3    float
```

Hexadecimal (`0xFF`) and binary (`0b1010`) integer literals are
case-insensitive. `_` separates digits: `1_000_000`, `0xFF_FF`, and
`0b1010_1010`. A separator may not be leading, trailing, doubled, or
next to a prefix or decimal point. Octal literals are not supported;
`0o17` is rejected. A non-finite float literal such as `1e400` is
rejected.

## String literals

`"..."` is a single-line string literal. The only escapes are:

| Escape | Value |
|---|---|
| `\n` | line feed |
| `\t` | tab |
| `\\` | backslash |
| `\"` | double quote |

Other escapes, including `\r`, `\0`, hexadecimal, and Unicode escapes,
are invalid. Use `chr(...)` for a code point.

`f"..."` is an interpolated string. `{expression}` is converted with
`string(...)`; `{{` and `}}` produce literal braces. A hole contains
one expression and may contain nested string literals. A hole may end
with `:.Nf`, which formats a `double` to N decimal places (rounded half
away from zero) through `std.strings.format_float`; that form requires
`import std.strings`. A colon inside brackets is part of a slice, so
`f"{s[1:3]}"` is not a format spec. See [formatting](/guide/strings/#formatting-and-byte-conversion).

## Operators and punctuation

```
+  -  *  /  %  //          arithmetic
&  |  ^  ~  << >>          bitwise (int and long only)
== != <  <= >  >=          comparison (non-associative)
=  += -= *= /= //= %=      assignment
&= |= ^= <<= >>=           bitwise assignment
:  ,  .  ->  ?  !          declarations and types
(  )  [  ]  {  }  _        grouping, indexing, map literals, array shape
```

Bitwise precedence follows Go: `&`, `<<`, and `>>` bind at the
multiplication level; `|` and `^` bind at the addition level. Shift
counts must be in range or the operation traps with
`shift_out_of_range`; high bits shifted out are discarded and right
shift is signed.

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

Diagnostics include a stable code and byte span, rendered as
`file:line:column` in both build modes. Codes use stage prefixes:
`luce.source.*`, `luce.lex.*`, `luce.parse.*`, `luce.sema.*`, and
`luce.import.*`. A compilation reports at most 100 diagnostics.

## The entry point

A program has exactly one `main`, in one of these forms:

```
func main():
func main() -> !:
func main(args: list(string)):
func main(args: list(string)) -> !:
```

There is no value result and no other parameter list. A missing or
invalid entry is `luce.sema.main`.

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
