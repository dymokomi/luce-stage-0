# std.json

`std.json` parses JSON text into a Luce value, lets a program inspect or
construct that value, and writes it back to JSON. It is pure Luce: it does
not read files or perform host calls.

```text
import std.json
```

The parser follows RFC 8259. It consumes one complete JSON value, allows the
four JSON whitespace bytes around it, and reports malformed input as an
error with a byte offset.

## `Json` is a union

Every JSON value is one of these members:

```text
union Json:
    null
    boolean(value: bool)
    integer(value: long)
    real(value: double)
    text(value: string)
    array(items: list(Json))
    object(fields: map(string, Json))
```

JSON has one number grammar while Luce has `long` and `double`, so the union
keeps both `integer` and `real`. JSON strings are named `text` because
`string` is already the Luce type name. Use `match` to read a union value:

```luce run
import std.json

func describe(doc: json.Json) -> string:
    match doc:
        null:
            return "null"
        boolean(value):
            return "boolean " + string(value)
        integer(value):
            return "integer " + string(value)
        real(value):
            return "real " + string(value)
        text(value):
            return "text " + value
        array(items):
            return "array " + string(len(items))
        object(fields):
            return "object " + string(len(fields))

func main() -> !:
    let value = try json.parse("[null, true, 7, 7.5, \"s\"]")
    match value:
        array(items):
            for item in items:
                print(describe(item))
        else:
            print("not an array")
```

```output
null
boolean true
integer 7
real 7.5
text s
```

## Parse and inspect

| Signature | Result |
|---|---|
| `json.parse(content: string) -> Json!` | one parsed value, or an error naming the byte where the document is invalid |
| `json.quote(content: string) -> string` | a JSON string literal with quotes and escapes |
| `value.is_null() -> bool` | whether the member is `null` |
| `value.as_bool() -> bool?` | boolean payload, or `none` for another member |
| `value.as_long() -> long?` | integer payload; a real number returns `none` |
| `value.as_double() -> double?` | either numeric member, widening an integer |
| `value.as_text() -> string?` | text payload, or `none` |
| `value.count() -> long` | array elements or object members; `0` for a leaf |
| `value.member(name: string) -> Json?` | object member as a value, or `none` when absent/not an object |
| `value.element(index: long) -> Json` | array element or object member by insertion position; out of range traps |
| `value.write() -> string` | compact JSON text |
| `value.pretty(spaces: long) -> string` | indented JSON; `spaces == 0` is the compact form |

For a read-only walk, match the value and iterate its `fields` or `items`.
`member` and `element` return a `Json` value. Leaf payloads copy; any list or
map inside the returned subtree remains a shared reference. `element` is
deliberately checked like ordinary indexing;
call `count()` before using an index supplied by input.

```luce run
import std.json

func main() -> !:
    let doc = try json.parse("{\"name\": \"Luce\", \"port\": 8080, \"debug\": false}")
    match doc:
        object(fields):
            print(fields["name"].as_text() else "?")
            print(string(fields["port"].as_long() else 0))
            print(string(fields["debug"].as_bool() else true))
        else:
            print("not an object")
```

```output
Luce
8080
false
```

## Build a value

Constructors use the union member names. A map or list stored in a `Json`
value remains the same shared reference:

```luce run
import std.json

func main():
    var fields = new map(string, json.Json)
    fields["name"] = json.Json.text(value = "Luce")
    fields["version"] = json.Json.integer(value = 1)
    fields["tags"] = json.Json.array(items = [json.Json.text(value = "language")])
    let doc = json.Json.object(fields = fields)
    print(doc.write())
    print(doc.pretty(2))
```

```output
{"name":"Luce","version":1,"tags":["language"]}
{
  "name": "Luce",
  "version": 1,
  "tags": [
    "language"
  ]
}
```

`Json` follows the language's value/reference rules. The union value copies,
while array and object payloads share their list or map through ARC. There is
no JSON-specific arena or cleanup call.

## Numbers and round trips

The notation determines the numeric member: `42` is `integer`, while `42.0`,
`4.2`, and `4.2e1` are `real`. `as_long` does not silently round a real;
`as_double` widens either numeric member. A whole number too large for a
`long` is represented as a `real`, where its precision is explicit.

`write` re-encodes the value rather than preserving the original spelling.
It keeps the value's meaning: a `real` is written with a decimal point so it
parses back as a `real`, and escaped text is written in canonical JSON form.

```luce run
import std.json

func main() -> !:
    let doc = try json.parse("[42, 42.0, 4.2e1, \"\\u0041\"]")
    print(string(doc.element(0).as_long() else -1))
    print(string(doc.element(1).as_long() == none))
    print(doc.write())
    print(json.quote("say \"hi\""))
```

```output
42
true
[42,42.0,42.0,"A"]
"say \"hi\""
```

Duplicate object names replace the previous value. The key keeps its first
insertion position, while its value is the last one written. A number beyond
the range of a `double`, `NaN`, or `Infinity` is rejected because JSON has no
text that can represent it.

## Input limits and refusals

`parse` rejects malformed JSON, including leading-zero numbers, missing
digits after a decimal or exponent, trailing text, unpaired surrogate
escapes, and unknown literal names. Nested arrays and objects are limited to
64 levels so the parser and writer stay below the runtime call-depth limit.
The exact error message names the byte offset; handle it with `try` or
`catch` rather than treating malformed input as ordinary absence.

Reading a document from a file is deliberately three separate operations:

```text
let bytes = try files.read_bytes(path)
let text = strings.from_bytes(bytes) else ""
let value = try json.parse(text)
```

`std.json` receives a Luce `string`, so UTF-8 validation has already happened
before parsing begins. `std.files` handles the host interaction and
`std.strings.from_bytes` handles the byte-to-text conversion.
