//! `std.json`, proven the way every std module is proven: Luce
//! programs whose asserts trap on a wrong answer, run on both engines
//! and compared (`specs/agree.zig`).
//!
//! **A parser is defined by what it refuses**, so most of this suite
//! is refusals.  The grammar is RFC 8259 and the section numbers in
//! the test names are its; where RFC 8259 and ECMA-404 leave a reader
//! a choice — a duplicate member name, an unpaired surrogate escape,
//! a number too large for any machine, a document nested past all
//! reason — the choice this module made has a test that says so, and
//! that test is the documentation of it.
//!
//! **And a `Json` is a union**, so the rest of this suite is the thing
//! `docs/UNION.md` said would prove the design: a recursive owned tree
//! built, walked, copied, mutated and freed, with the two-engine leak
//! census as the witness that scope ownership needed no new rule for
//! it.
//!
//! The fixtures at the foot are Nicolas Seriot's **JSONTestSuite**
//! (`Parsing JSON is a Minefield`, 2016), whose `y_` cases every
//! parser must accept, whose `n_` cases every parser must reject, and
//! whose `i_` cases are the ones real parsers disagree about.  Each
//! row is named after the file it comes from, because a parser that
//! only reads the documents it wrote has proven nothing about JSON.

const std = @import("std");
const agree = @import("agree.zig");

/// The depth the std suite has always run at.
const budget: agree.Provided = .{ .call_depth = 4096 };

fn agreeOk(source: []const u8) !void {
    return agree.okGiven(source, budget);
}

/// The run ends as an error nobody caught, with exactly these words.
fn agreeRaises(source: []const u8, message: []const u8) !void {
    return agree.errors(source, budget, .user_error, message);
}

/// Every acceptance spec asks the same question of a text — does this
/// parse — so the two functions that ask it are written once here and
/// stand in front of the program that uses them.
const asks =
    \\import std.json
    \\
    \\func counted(text: string) -> long!:
    \\    let doc = try json.parse(text)
    \\    return doc.count()
    \\
    \\func accepted(text: string) -> bool:
    \\    let size = counted(text) catch -1
    \\    return size >= 0
    \\
    \\
;

/// Reaching a member is two steps — ask, then narrow — because
/// `member` answers `Json?` and a method needs a `Json`.  This is the
/// idiom a program writes when it wants to *keep* what it found; a
/// walk that only reads says `match` and reaches the map itself,
/// which copies nothing, and there are specs below for both.
const reads =
    \\import std.json
    \\
    \\func child(value: json.Json, name: string) -> json.Json:
    \\    let found = value.member(name)
    \\    if found != none:
    \\        return found
    \\    trap("this spec asked for a member that is not there: " + name)
    \\
    \\
;

// ---------------------------------------------------------------------------
// A document is one value (RFC 8259 section 2)
// ---------------------------------------------------------------------------

test "json: a document is one value, and any value may be the one" {
    try agreeOk(asks ++
        \\func main():
        \\    # RFC 8259 section 2 dropped RFC 4627's rule that a
        \\    # document had to be an object or an array: any value is
        \\    # a document now, and all six are.
        \\    assert(accepted("{}"))
        \\    assert(accepted("[]"))
        \\    assert(accepted("\"text\""))
        \\    assert(accepted("42"))
        \\    assert(accepted("true"))
        \\    assert(accepted("null"))
        \\
        \\    # And exactly one of them.  Nothing at all is not a
        \\    # document, and neither is a second value after the first.
        \\    assert(not accepted(""))
        \\    assert(not accepted("   "))
        \\    assert(not accepted("{} {}"))
        \\    assert(not accepted("[1][2]"))
        \\    assert(not accepted("1 2"))
        \\    assert(not accepted("nullnull"))
        \\
    );
}

test "json: whitespace is four bytes and no others" {
    try agreeOk(asks ++
        \\func main():
        \\    # RFC 8259 section 2: space, horizontal tab, line feed,
        \\    # carriage return.  Around the document and between every
        \\    # token inside it.
        \\    let blank = " " + chr(9) + chr(10) + chr(13)
        \\    assert(accepted(blank + "[1]" + blank))
        \\    assert(accepted("[" + blank + "1" + blank + "," + blank + "2" + blank + "]"))
        \\    assert(accepted("{" + blank + "\"a\"" + blank + ":" + blank + "1" + blank + "}"))
        \\
        \\    # A vertical tab and a form feed are whitespace in C and
        \\    # in nothing RFC 8259 says.
        \\    assert(not accepted("[" + chr(11) + "1]"))
        \\    assert(not accepted("[" + chr(12) + "1]"))
        \\    # And a non-breaking space is a character, not a space.
        \\    assert(not accepted("[" + chr(160) + "1]"))
        \\
    );
}

test "json: the three literal names are spelled exactly one way each" {
    try agreeOk(asks ++
        \\func main():
        \\    # RFC 8259 section 3, and the whole of it: lower case,
        \\    # complete, and nothing else beside them.
        \\    assert(accepted("true"))
        \\    assert(accepted("false"))
        \\    assert(accepted("null"))
        \\    assert(not accepted("True"))
        \\    assert(not accepted("TRUE"))
        \\    assert(not accepted("NULL"))
        \\    assert(not accepted("nul"))
        \\    assert(not accepted("tru"))
        \\    assert(not accepted("truex"))
        \\    assert(not accepted("nullx"))
        \\    # NaN and Infinity are numbers in other formats and words
        \\    # in this one, so they are refused as words.
        \\    assert(not accepted("NaN"))
        \\    assert(not accepted("Infinity"))
        \\    assert(not accepted("-Infinity"))
        \\
    );
}

// ---------------------------------------------------------------------------
// Numbers (RFC 8259 section 6)
// ---------------------------------------------------------------------------

test "json: the number grammar is the whole of section 6 and nothing more" {
    try agreeOk(asks ++
        \\func main():
        \\    # int = zero / ( digit1-9 *DIGIT )
        \\    assert(accepted("0"))
        \\    assert(accepted("-0"))
        \\    assert(accepted("123"))
        \\    assert(accepted("-123"))
        \\    assert(not accepted("01"))
        \\    assert(not accepted("-01"))
        \\    assert(not accepted("00"))
        \\    assert(not accepted("+1"))
        \\    assert(not accepted("-"))
        \\
        \\    # frac = decimal-point 1*DIGIT — at least one digit on
        \\    # each side, which is what refuses .5 and 5. alike.
        \\    assert(accepted("0.5"))
        \\    assert(accepted("-0.5"))
        \\    assert(accepted("123.456"))
        \\    assert(not accepted(".5"))
        \\    assert(not accepted("5."))
        \\    assert(not accepted("0."))
        \\    assert(not accepted("1..2"))
        \\
        \\    # exp = e [ minus / plus ] 1*DIGIT
        \\    assert(accepted("1e3"))
        \\    assert(accepted("1E3"))
        \\    assert(accepted("1e+3"))
        \\    assert(accepted("1e-3"))
        \\    assert(accepted("1.5e10"))
        \\    assert(accepted("0e0"))
        \\    assert(not accepted("1e"))
        \\    assert(not accepted("1e+"))
        \\    assert(not accepted("1.e3"))
        \\    assert(not accepted("1e3.5"))
        \\
        \\    # Nothing else is a number, however familiar it looks.
        \\    assert(not accepted("0x10"))
        \\    assert(not accepted("1_000"))
        \\    assert(not accepted("1,000"))
        \\
    );
}

test "json: a number is read by the notation it was written in, and the notation is the member" {
    try agreeOk(
        \\import std.json
        \\
        \\func name_of(value: json.Json) -> string:
        \\    return string(value)
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("[42, -7, 4.2, 42.0, 4.2e1, 1e3, -0, 0]")
        \\
        \\    # Written whole, so it is a whole number — and the union
        \\    # says so before any accessor is called.  This is the rule
        \\    # `as_long` used to enforce by re-reading the text, now
        \\    # held by the member the value is.
        \\    assert(name_of(doc.element(0)) == "integer")
        \\    assert(name_of(doc.element(2)) == "real")
        \\    assert(doc.element(0).as_long() else -1 == 42)
        \\    assert(doc.element(1).as_long() else 0 == -7)
        \\    assert(doc.element(7).as_long() else -1 == 0)
        \\
        \\    # Written with a fraction or an exponent, so it is not —
        \\    # not even when the value it names is whole.  Absence says
        \\    # "that is not how this was written", where truncating
        \\    # would throw the fraction away without saying so.
        \\    assert(doc.element(2).as_long() == none)
        \\    assert(doc.element(3).as_long() == none)
        \\    assert(doc.element(4).as_long() == none)
        \\    assert(doc.element(5).as_long() == none)
        \\
        \\    # Every one of them is a double, whole ones included: a
        \\    # long widens, which is the one conversion Luce makes on
        \\    # its own.
        \\    assert(doc.element(0).as_double() else 0.0 == 42.0)
        \\    assert(doc.element(3).as_double() else 0.0 == 42.0)
        \\    assert(doc.element(4).as_double() else 0.0 == 42.0)
        \\    assert(doc.element(5).as_double() else 0.0 == 1000.0)
        \\
        \\    # A negative zero written whole is the integer zero, as it
        \\    # is for Python's json and Go's encoding/json.  Written as
        \\    # a real it stays one, and survives the round trip.
        \\    assert(name_of(doc.element(6)) == "integer")
        \\    assert(doc.element(6).as_long() else -1 == 0)
        \\    let signed = try json.parse("-0.0")
        \\    assert(signed.write() == "-0.0")
        \\
    );
}

test "json: a whole number past a long is a real, and a number past a double is refused" {
    try agreeOk(asks ++
        \\func main() -> !:
        \\    # Grammatical, so the document is valid — RFC 8259 section
        \\    # 6 sets no bound on the notation.  A whole number too
        \\    # large for a long is a real, which is where its precision
        \\    # honestly is: `as_long` answers absence exactly as it did
        \\    # when the module re-read the text.
        \\    let doc = try json.parse("[9223372036854775808, -9223372036854775809]")
        \\    assert(string(doc.element(0)) == "real")
        \\    assert(doc.element(0).as_long() == none)
        \\    assert(doc.element(1).as_long() == none)
        \\    assert(doc.element(0).as_double() != none)
        \\
        \\    # Past a double there is nothing left to hold it with, and
        \\    # section 6 lets an implementation set limits on the range
        \\    # it accepts.  Storing an infinity would be storing a value
        \\    # this module could never write back.
        \\    assert(not accepted("[1e999]"))
        \\    assert(accepted("[1e308]"))
        \\
    );
}

// ---------------------------------------------------------------------------
// Strings (RFC 8259 section 7)
// ---------------------------------------------------------------------------

test "json: the eight escapes decode, and nothing else is an escape" {
    try agreeOk(asks ++
        \\func main() -> !:
        \\    let doc = try json.parse("[\"\\\"\", \"\\\\\", \"\\/\", \"\\b\", \"\\f\", \"\\n\", \"\\r\", \"\\t\"]")
        \\    assert(doc.element(0).as_text() else "" == "\"")
        \\    assert(doc.element(1).as_text() else "" == "\\")
        \\    assert(doc.element(2).as_text() else "" == "/")
        \\    assert(doc.element(3).as_text() else "" == chr(8))
        \\    assert(doc.element(4).as_text() else "" == chr(12))
        \\    assert(doc.element(5).as_text() else "" == "\n")
        \\    assert(doc.element(6).as_text() else "" == chr(13))
        \\    assert(doc.element(7).as_text() else "" == "\t")
        \\
        \\    # RFC 8259 section 7 lists those eight and \u, and the
        \\    # list is closed.
        \\    assert(not accepted("\"\\a\""))
        \\    assert(not accepted("\"\\x41\""))
        \\    assert(not accepted("\"\\'\""))
        \\    assert(not accepted("\"\\0\""))
        \\
    );
}

test "json: a \\u escape is four hexadecimal digits, in either case" {
    try agreeOk(asks ++
        \\func main() -> !:
        \\    let doc = try json.parse("[\"\\u0041\", \"\\u00e9\", \"\\u20AC\", \"\\u0000\"]")
        \\    assert(doc.element(0).as_text() else "" == "A")
        \\    assert(doc.element(1).as_text() else "" == chr(233))
        \\    assert(doc.element(2).as_text() else "" == chr(8364))
        \\    assert(len(doc.element(3).as_text() else "x") == 1)
        \\
        \\    assert(not accepted("\"\\u041\""))
        \\    assert(not accepted("\"\\u00g1\""))
        \\    assert(not accepted("\"\\u\""))
        \\    assert(not accepted("\"\\u00\""))
        \\
    );
}

test "json: a surrogate pair is one codepoint, and half of one is refused" {
    try agreeOk(asks ++
        \\func main() -> !:
        \\    # RFC 8259 section 7's own example: G-clef, U+1D11E, is
        \\    # written as two escapes and read as one character —
        \\    # four bytes of UTF-8, not two characters of three.
        \\    let doc = try json.parse("[\"\\ud834\\udd1e\", \"\\uD801\\uDC37\"]")
        \\    let clef = doc.element(0).as_text() else ""
        \\    assert(len(clef) == 4)
        \\    assert(clef == chr(119070))
        \\    assert((doc.element(1).as_text() else "") == chr(66615))
        \\
        \\    # Half a pair has no UTF-8 and a Luce string is UTF-8, so
        \\    # the choice is refuse or quietly substitute, and this
        \\    # module refuses (RFC 8259 section 8.2 warns; ECMA-404
        \\    # permits the code unit).
        \\    assert(not accepted("\"\\ud834\""))
        \\    assert(not accepted("\"\\udd1e\""))
        \\    assert(not accepted("\"\\ud834\\u0041\""))
        \\    assert(not accepted("\"\\ud834\\ud834\""))
        \\    assert(not accepted("\"\\ud834x\""))
        \\
    );
}

test "json: a control character inside a string must be escaped" {
    try agreeOk(asks ++
        \\func main():
        \\    # RFC 8259 section 7: a string holds any character except
        \\    # a quote, a backslash, and the control characters, which
        \\    # is what makes a raw newline inside a string an error and
        \\    # the escape for it fine.
        \\    assert(not accepted("\"a" + chr(10) + "b\""))
        \\    assert(not accepted("\"a" + chr(9) + "b\""))
        \\    assert(not accepted("\"a" + chr(0) + "b\""))
        \\    assert(accepted("\"a\\nb\""))
        \\    assert(accepted("\"a\\tb\""))
        \\    # And one after an escape, where the decoding path meets
        \\    # it rather than the scanning one.
        \\    assert(not accepted("\"a\\nb" + chr(10) + "c\""))
        \\
        \\    # A string that is never closed is not a string, with and
        \\    # without an escape in front of the end.
        \\    assert(not accepted("\"unclosed"))
        \\    assert(not accepted("\"tail\\\""))
        \\    assert(not accepted("\"a\\nb"))
        \\
    );
}

test "json: text outside ASCII arrives as itself" {
    try agreeOk(reads ++
        \\func main() -> !:
        \\    # The input is a Luce string, so it is valid UTF-8 before
        \\    # the parser sees a byte of it (RFC 8259 section 8.1) —
        \\    # there is no encoding question here to get wrong.
        \\    let doc = try json.parse("{\"caf" + chr(233) + "\": \"" + chr(955) + chr(119070) + "\"}")
        \\    let name = "caf" + chr(233)
        \\    assert((child(doc, name).as_text() else "") == chr(955) + chr(119070))
        \\    match doc:
        \\        object(fields):
        \\            assert(fields.keys()[0] == name)
        \\        else:
        \\            trap("a parsed object is an object")
        \\
    );
}

// ---------------------------------------------------------------------------
// Objects and arrays (RFC 8259 sections 4 and 5)
// ---------------------------------------------------------------------------

test "json: an object is names and values, and the punctuation is not optional" {
    try agreeOk(asks ++
        \\func main() -> !:
        \\    assert(accepted("{}"))
        \\    assert(accepted("{\"a\":1}"))
        \\    assert(accepted("{\"a\":1,\"b\":2}"))
        \\    assert(accepted("{\"\":0}"))
        \\
        \\    assert(not accepted("{\"a\"}"))
        \\    assert(not accepted("{\"a\" 1}"))
        \\    assert(not accepted("{\"a\":}"))
        \\    assert(not accepted("{a:1}"))
        \\    assert(not accepted("{'a':1}"))
        \\    assert(not accepted("{1:2}"))
        \\    assert(not accepted("{\"a\":1,}"))
        \\    assert(not accepted("{,}"))
        \\    assert(not accepted("{"))
        \\    assert(not accepted("{\"a\":1"))
        \\    assert(not accepted("{]"))
        \\
        \\    # A member name may be empty, and it is still a name.
        \\    let doc = try json.parse("{\"\":0}")
        \\    assert(doc.count() == 1)
        \\    assert(doc.member("") != none)
        \\    assert(doc.write() == "{\"\":0}")
        \\
    );
}

test "json: an array is values in order, and the punctuation is not optional" {
    try agreeOk(asks ++
        \\func main() -> !:
        \\    assert(accepted("[]"))
        \\    assert(accepted("[1]"))
        \\    assert(accepted("[1,2,3]"))
        \\    assert(accepted("[[],[[]]]"))
        \\
        \\    assert(not accepted("[1,]"))
        \\    assert(not accepted("[,1]"))
        \\    assert(not accepted("[1 2]"))
        \\    assert(not accepted("["))
        \\    assert(not accepted("[1"))
        \\    assert(not accepted("[}"))
        \\    assert(not accepted("]"))
        \\    assert(not accepted("}"))
        \\
        \\    let doc = try json.parse("[10,20,30]")
        \\    assert(doc.count() == 3)
        \\    assert(doc.element(0).as_long() else -1 == 10)
        \\    assert(doc.element(2).as_long() else -1 == 30)
        \\
    );
}

test "json: a duplicate member resolves to the last, and an object is a mapping" {
    try agreeOk(reads ++
        \\func main() -> !:
        \\    # RFC 8259 section 4: names SHOULD be unique, and what
        \\    # happens when they are not is unpredictable.  An object
        \\    # here is a map(string, Json), so the second "a" replaces
        \\    # the first in the place the first claimed — which is what
        \\    # JavaScript's JSON.parse, Python's json and Go's
        \\    # encoding/json all do, and unlike the flat document this
        \\    # module used to build, both are not kept: a mapping with
        \\    # two entries under one name is not a mapping.
        \\    let doc = try json.parse("{\"a\":\"first\",\"b\":2,\"a\":\"last\"}")
        \\    assert((child(doc, "a").as_text() else "") == "last")
        \\    assert(doc.count() == 2)
        \\    match doc:
        \\        object(fields):
        \\            let names = fields.keys()
        \\            assert(len(names) == 2)
        \\            assert(names[0] == "a" and names[1] == "b")
        \\        else:
        \\            trap("a parsed object is an object")
        \\    assert(doc.write() == "{\"a\":\"last\",\"b\":2}")
        \\
    );
}

test "json: a member name is compared decoded, however it was written" {
    try agreeOk(reads ++
        \\func main() -> !:
        \\    # The same name, spelled three ways.  Escapes are spent on
        \\    # the way in, so a lookup is a map lookup and nothing is
        \\    # decoded twice.
        \\    let doc = try json.parse("{\"a\\nb\": 1, \"\\u0041\": 2, \"plain\": 3}")
        \\    assert((child(doc, "a\nb").as_long() else -1) == 1)
        \\    assert((child(doc, "A").as_long() else -1) == 2)
        \\    assert(doc.member("plain") != none)
        \\    assert(doc.member("a\\nb") == none)
        \\    match doc:
        \\        object(fields):
        \\            assert(fields.keys()[0] == "a\nb")
        \\            assert(fields.keys()[1] == "A")
        \\        else:
        \\            trap("a parsed object is an object")
        \\
    );
}

// ---------------------------------------------------------------------------
// Nesting (RFC 8259 section 9)
// ---------------------------------------------------------------------------

test "json: nesting is bounded at 64, and a deeper document is refused rather than run out of stack" {
    try agreeOk(asks ++
        \\func nest(depth: long) -> string:
        \\    var out = new builder()
        \\    for step in range(0, depth):
        \\        out.append("[")
        \\    out.append("1")
        \\    for step in range(0, depth):
        \\        out.append("]")
        \\    return out.build()
        \\
        \\func main():
        \\    # RFC 8259 section 9 lets a parser set a limit.  This one
        \\    # is half of loom's 128-call budget, because a tree is
        \\    # walked by recursion at both ends: this module's reader
        \\    # and writer take one frame a level, and so does every
        \\    # caller that reads what they answer.
        \\    assert(accepted(nest(63)))
        \\    assert(accepted(nest(64)))
        \\    assert(not accepted(nest(65)))
        \\    # The one the owner asked about: ten thousand deep is an
        \\    # error with a name, not a machine falling over.
        \\    assert(not accepted(nest(10000)))
        \\
    );
}

test "json: a document at the bound parses, walks and writes inside loom's own call budget" {
    // loom's real policy, not the suite's roomy one: `src/apps/host.zig`
    // lets a program nest 128 calls, and the bound is half of it so that
    // both ends of the walk fit with room over.
    try agree.printsGiven(
        \\import std.json
        \\
        \\func nest(depth: long) -> string:
        \\    var out = new builder()
        \\    for step in range(0, depth):
        \\        out.append("[")
        \\    out.append("1")
        \\    for step in range(0, depth):
        \\        out.append("]")
        \\    return out.build()
        \\
        \\func deepest(value: json.Json) -> long:
        \\    match value:
        \\        array(items):
        \\            var best: long = 0
        \\            for item in items:
        \\                let here = deepest(item)
        \\                if here > best:
        \\                    best = here
        \\            return best + 1
        \\        object(fields):
        \\            var best: long = 0
        \\            for name, entry in fields:
        \\                let here = deepest(entry)
        \\                if here > best:
        \\                    best = here
        \\            return best + 1
        \\        else:
        \\            return 0
        \\
        \\func under(padding: long, text: string) -> long!:
        \\    # Fifty frames of somebody else's program before this
        \\    # module is called at all.
        \\    if padding > 0:
        \\        let answer = try under(padding - 1, text)
        \\        return answer
        \\    let doc = try json.parse(text)
        \\    let again = try json.parse(doc.write())
        \\    return deepest(doc) + deepest(again)
        \\
        \\func main() -> !:
        \\    print(string(try under(50, nest(64))))
        \\
    , .{ .call_depth = 128 },
        \\128
        \\
    );
}

// ---------------------------------------------------------------------------
// A value is a union
// ---------------------------------------------------------------------------

test "json: a match over a Json needs no else, and names all seven members" {
    try agreeOk(
        \\import std.json
        \\
        \\func label(held: json.Json) -> string:
        \\    # No else: the day an eighth member arrives this function
        \\    # stops compiling and names it.
        \\    match held:
        \\        null:
        \\            return "null"
        \\        boolean(value):
        \\            return "boolean " + string(value)
        \\        integer(value):
        \\            return "integer " + string(value)
        \\        real(value):
        \\            return "real " + string(value)
        \\        text(value):
        \\            return "text " + value
        \\        array(items):
        \\            return "array of " + string(len(items))
        \\        object(fields):
        \\            return "object of " + string(len(fields))
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("[null, true, 7, 7.5, \"s\", [1], {\"a\": 1}]")
        \\    match doc:
        \\        array(items):
        \\            assert(label(items[0]) == "null")
        \\            assert(label(items[1]) == "boolean true")
        \\            assert(label(items[2]) == "integer 7")
        \\            assert(label(items[3]) == "real 7.5")
        \\            assert(label(items[4]) == "text s")
        \\            assert(label(items[5]) == "array of 1")
        \\            assert(label(items[6]) == "object of 1")
        \\        else:
        \\            trap("a parsed array is an array")
        \\
        \\    # string(u) is the member's name, which is the nearest
        \\    # thing this module has to the old `kind()`.
        \\    assert(string(json.Json.null) == "null")
        \\    assert(string(json.Json.text(value = "x")) == "text")
        \\
    );
}

test "json: an accessor of the wrong member answers absence, and null is not absence" {
    try agreeOk(
        \\import std.json
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("[\"s\", 1, true, false, null, {}, []]")
        \\    let text = doc.element(0)
        \\    let number = doc.element(1)
        \\    let yes = doc.element(2)
        \\    let no = doc.element(3)
        \\    let nothing = doc.element(4)
        \\
        \\    assert((text.as_text() else "") == "s")
        \\    assert(text.as_long() == none)
        \\    assert(text.as_double() == none)
        \\    assert(text.as_bool() == none)
        \\    assert(not text.is_null())
        \\
        \\    assert(number.as_long() else -1 == 1)
        \\    assert(number.as_text() == none)
        \\    assert(number.as_bool() == none)
        \\
        \\    assert(yes.as_bool() else false)
        \\    assert(not (no.as_bool() else true))
        \\    assert(yes.as_long() == none)
        \\
        \\    # JSON's null is a value that is there.  "There is no such
        \\    # member" is a different sentence, and `member` says that
        \\    # one.
        \\    assert(nothing.is_null())
        \\    assert(nothing.as_bool() == none)
        \\    assert(nothing.as_text() == none)
        \\    assert(doc.element(5).member("anything") == none)
        \\
        \\    # A leaf has no members and no elements.
        \\    assert(doc.element(6).count() == 0)
        \\    assert(number.count() == 0)
        \\    assert(number.member("a") == none)
        \\
    );
}

test "json: member answers absence for a name that is not there and for a value that is not an object" {
    try agreeOk(reads ++
        \\func main() -> !:
        \\    let doc = try json.parse("{\"here\": 1}")
        \\    # `has` is a reserved name in Luce, so `member(…) != none`
        \\    # is the membership question, and it is the same one call.
        \\    assert(doc.member("here") != none)
        \\    assert(doc.member("there") == none)
        \\    assert(doc.member("") == none)
        \\    assert(doc.member("her") == none)
        \\    assert(doc.member("heree") == none)
        \\    # A value that is not an object has no members, which is
        \\    # the same news to a caller looking for a field.
        \\    assert(child(doc, "here").member("here") == none)
        \\
    );
}

test "json: element walks arrays and objects alike, and past the end is a bug that traps" {
    try agreeOk(reads ++
        \\func main() -> !:
        \\    let doc = try json.parse("[1, [2, 3], {\"a\": 4}, 5]")
        \\    assert(doc.count() == 4)
        \\    assert(doc.element(0).as_long() else -1 == 1)
        \\    assert(doc.element(1).element(1).as_long() else -1 == 3)
        \\    assert(child(doc.element(2), "a").as_long() else -1 == 4)
        \\    assert(doc.element(3).as_long() else -1 == 5)
        \\
        \\    # An object's members are positioned too, in the order
        \\    # they were first named.
        \\    let record = try json.parse("{\"a\": 1, \"b\": 2}")
        \\    assert(record.element(0).as_long() else -1 == 1)
        \\    assert(record.element(1).as_long() else -1 == 2)
        \\
        \\    # And what element hands back is a copy the caller owns,
        \\    # so it outlives the walk that found it.
        \\    var kept: list(json.Json) = []
        \\    kept.append(doc.element(1))
        \\    assert(kept[0].count() == 2)
        \\
    );

    try agree.trapGiven(
        \\import std.json
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("[1, 2]")
        \\    print(string(doc.element(2).as_long() else -1))
        \\
    , budget, .explicit_trap);
}

// ---------------------------------------------------------------------------
// Building, and the ownership that comes with it
// ---------------------------------------------------------------------------

test "json: a value is built the way it is taken apart, and ownership is taken once" {
    try agree.printsGiven(
        \\import std.json
        \\
        \\func main():
        \\    # docs/UNION.md's own construction paragraph, run: every
        \\    # inner value is fresh and silent (S20), and the one verb
        \\    # is on the last line, where a named object moves into a
        \\    # value that outlives the name (S24).
        \\    var fields = new map(string, json.Json)
        \\    fields["name"] = json.Json.text(value = "luce")
        \\    fields["version"] = json.Json.integer(value = 2)
        \\    fields["ratio"] = json.Json.real(value = 0.5)
        \\    fields["tags"] = json.Json.array(items = [json.Json.text(value = "lang")])
        \\    fields["nothing"] = json.Json.null
        \\    let doc = json.Json.object(fields = give fields)
        \\    print(doc.write())
        \\    print(doc.pretty(2))
        \\
    , budget,
        \\{"name":"luce","version":2,"ratio":0.5,"tags":["lang"],"nothing":null}
        \\{
        \\  "name": "luce",
        \\  "version": 2,
        \\  "ratio": 0.5,
        \\  "tags": [
        \\    "lang"
        \\  ],
        \\  "nothing": null
        \\}
        \\
    );
}

test "json: a parsed tree is walked, mutated through its containers, and written back" {
    try agree.printsGiven(
        \\import std.json
        \\
        \\func bump(value: json.Json):
        \\    # An arm's payload binding aliases what the scrutinee owns
        \\    # (UNION.md D10), so mutating the list or the map it names
        \\    # mutates the tree — no verb, no copy, no second owner.
        \\    match value:
        \\        object(fields):
        \\            if fields.has("port"):
        \\                let held = fields["port"].as_long() else 0
        \\                fields["port"] = json.Json.integer(value = held + 1)
        \\            for name, entry in fields:
        \\                bump(entry)
        \\        array(items):
        \\            for item in items:
        \\                bump(item)
        \\            items.append(json.Json.boolean(value = true))
        \\        else:
        \\            return
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("{\"servers\":[{\"port\":80},{\"port\":8080}],\"port\":1}")
        \\    bump(doc)
        \\    print(doc.write())
        \\
    , budget,
        \\{"servers":[{"port":81},{"port":8081},true],"port":2}
        \\
    );
}

test "json: give, copy and the scope are the whole of a tree's memory" {
    try agreeOk(
        \\import std.json
        \\
        \\func swallow(value: give json.Json) -> long:
        \\    # The parameter takes ownership, so this scope frees the
        \\    # whole tree when it ends.
        \\    return value.count()
        \\
        \\func main() -> !:
        \\    for step in range(0, 50):
        \\        let doc = try json.parse("{\"a\": [1, 2, {\"b\": \"c\"}], \"d\": null}")
        \\        # A copy is a second tree with a second owner: editing
        \\        # it leaves the first alone.
        \\        var twin = copy doc
        \\        match twin:
        \\            object(fields):
        \\                fields["a"] = json.Json.null
        \\            else:
        \\                trap("a parsed object is an object")
        \\        assert(doc.member("a") != none)
        \\        assert(twin.member("a") != none)
        \\        assert(doc.element(0).count() == 3)
        \\        assert(twin.element(0).count() == 0)
        \\        assert(swallow(give twin) == 2)
        \\
        \\    # A refused parse frees what it had built so far too.
        \\    for step in range(0, 50):
        \\        let refused = json.parse("[1, 2, [3, 4") catch json.Json.null
        \\        assert(refused.is_null())
        \\
    );
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

test "json: write puts the value back and the whitespace nowhere" {
    try agreeOk(reads ++
        \\func main() -> !:
        \\    let spaced = "{\n  \"a\" : [ 1, 2 ] ,\n  \"b\" : { \"c\" : null }\n}"
        \\    let doc = try json.parse(spaced)
        \\    assert(doc.write() == "{\"a\":[1,2],\"b\":{\"c\":null}}")
        \\    # A subtree writes on its own.
        \\    assert(child(doc, "b").write() == "{\"c\":null}")
        \\    # Empty containers keep their own shape.
        \\    let empty = try json.parse("[{},[],[{}]]")
        \\    assert(empty.write() == "[{},[],[{}]]")
        \\
    );
}

test "json: write re-encodes the value, and parsing what it wrote gives the same value" {
    try agreeOk(
        \\import std.json
        \\
        \\func main() -> !:
        \\    # The value is what survived the parse, so `write` is a
        \\    # re-encoding and not an echo: an escape that had a
        \\    # shorter spelling gets it, a solidus loses the one it did
        \\    # not need, and a real is written with the point that
        \\    # keeps it a real.
        \\    let doc = try json.parse("[1e3,42.0,-0,\"\\u0041\",\"a\\/b\",\"caf" + chr(233) + "\"]")
        \\    let once = doc.write()
        \\    assert(once == "[1000.0,42.0,0,\"A\",\"a/b\",\"caf" + chr(233) + "\"]")
        \\    # And that is a fixed point: what comes out reads back as
        \\    # the same value and writes the same bytes again.
        \\    let again = try json.parse(once)
        \\    assert(again.write() == once)
        \\
    );
}

test "json: parse, write, parse is a fixed point over a rich document" {
    try agreeOk(reads ++
        \\func main() -> !:
        \\    let source = "{\n  \"name\": \"luce\",\n  \"version\": 2,\n  \"ratio\": -1.5e-3,\n  \"tags\": [\"lang\", \"runtime\", []],\n  \"nested\": {\"a\": {\"b\": {\"c\": [true, false, null]}}},\n  \"escaped\": \"quote \\\" slash \\\\ newline \\n clef \\ud834\\udd1e\",\n  \"empty\": {},\n  \"none\": null\n}"
        \\    let first = try json.parse(source)
        \\    let once = first.write()
        \\    let second = try json.parse(once)
        \\    let twice = second.write()
        \\    assert(once == twice)
        \\
        \\    # And the document says the same things after the trip.
        \\    assert(second.count() == 8)
        \\    assert(child(second, "tags").count() == 3)
        \\    let decoded = child(second, "escaped").as_text() else ""
        \\    let clef = decoded[len(decoded) - 4:]
        \\    assert(clef == chr(119070))
        \\    assert(decoded[0:14] == "quote \" slash ")
        \\
        \\    # Pretty is the same value with room around it, and
        \\    # parsing it gives the same value back.
        \\    let indented = second.pretty(2)
        \\    let third = try json.parse(indented)
        \\    assert(third.write() == once)
        \\
    );
}

test "json: pretty indents by the count it is given" {
    try agree.printsGiven(
        \\import std.json
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("{\"a\":[1,{\"b\":2}],\"c\":{},\"d\":[]}")
        \\    print(doc.pretty(2))
        \\    print(doc.pretty(0))
        \\
    , budget,
        \\{
        \\  "a": [
        \\    1,
        \\    {
        \\      "b": 2
        \\    }
        \\  ],
        \\  "c": {},
        \\  "d": []
        \\}
        \\{"a":[1,{"b":2}],"c":{},"d":[]}
        \\
    );
}

test "json: a real that is not a number has no JSON to be written as" {
    // Nothing this module parses can hold an infinity — a number past
    // a double is refused on the way in — but a program can build one
    // out of arithmetic, and there is no text that would read back as
    // what it was given (RFC 8259 section 6).
    try agree.trapGiven(
        \\import std.json
        \\
        \\func main():
        \\    let huge: double = 1.0e308
        \\    let doc = json.Json.real(value = huge * 10.0)
        \\    print(doc.write())
        \\
    , budget, .explicit_trap);
}

test "json: quote escapes what must be escaped and leaves the rest alone" {
    try agreeOk(
        \\import std.json
        \\
        \\func main() -> !:
        \\    assert(json.quote("") == "\"\"")
        \\    assert(json.quote("plain") == "\"plain\"")
        \\    assert(json.quote("a\"b") == "\"a\\\"b\"")
        \\    assert(json.quote("a\\b") == "\"a\\\\b\"")
        \\    assert(json.quote("a\nb") == "\"a\\nb\"")
        \\    assert(json.quote("a\tb") == "\"a\\tb\"")
        \\    assert(json.quote(chr(8) + chr(12) + chr(13)) == "\"\\b\\f\\r\"")
        \\    # A control character with no short name goes out as four
        \\    # hexadecimal digits, lower case, as JavaScript writes it.
        \\    assert(json.quote(chr(11)) == "\"\\u000b\"")
        \\    assert(json.quote(chr(1)) == "\"\\u0001\"")
        \\    # The solidus may be escaped and need not be, so it is not.
        \\    assert(json.quote("a/b") == "\"a/b\"")
        \\    # Text outside ASCII is UTF-8 in the output, which is what
        \\    # RFC 8259 section 8.1 asks for.
        \\    assert(json.quote(chr(233)) == "\"" + chr(233) + "\"")
        \\
        \\    # And what it writes is what this module reads back — and
        \\    # what `write` puts around a string of its own.
        \\    let awkward = "a\"b\\c" + chr(11) + "d/e" + chr(233)
        \\    let doc = try json.parse(json.quote(awkward))
        \\    assert((doc.as_text() else "") == awkward)
        \\    assert(json.Json.text(value = awkward).write() == json.quote(awkward))
        \\
    );
}

// ---------------------------------------------------------------------------
// What a refusal says
// ---------------------------------------------------------------------------

test "json: a refusal names the problem and the byte it happened at" {
    try agreeRaises(
        \\import std.json
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("")
        \\
    , "json: there is no value in the text");

    try agreeRaises(
        \\import std.json
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("{} {}")
        \\
    , "json: text after the document's one value, at byte 3");

    try agreeRaises(
        \\import std.json
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("[1, 2")
        \\
    , "json: the text ends inside the array opened at byte 0");

    try agreeRaises(
        \\import std.json
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("{\"a\": 1 \"b\": 2}")
        \\
    , "json: a comma or a close was expected at byte 8");

    try agreeRaises(
        \\import std.json
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("{a: 1}")
        \\
    , "json: a member name must be a string, at byte 1");

    try agreeRaises(
        \\import std.json
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("{\"a\" 1}")
        \\
    , "json: a member name must be followed by a colon, at byte 5");

    try agreeRaises(
        \\import std.json
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("[01]")
        \\
    , "json: a number may not have a leading zero, at byte 1");

    try agreeRaises(
        \\import std.json
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("[1.]")
        \\
    , "json: a fraction needs a digit after the point, at byte 3");

    try agreeRaises(
        \\import std.json
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("[1e999]")
        \\
    , "json: the number at byte 1 is past what a double can hold");

    try agreeRaises(
        \\import std.json
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("[\"a\\qb\"]")
        \\
    , "json: unknown escape at byte 3");

    try agreeRaises(
        \\import std.json
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("[\"\\ud834\"]")
        \\
    , "json: a high surrogate escape at byte 2 is not followed by its low half");

    try agreeRaises(
        \\import std.json
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("[\"\\udd1e\"]")
        \\
    , "json: a low surrogate escape stands alone at byte 2");

    try agreeRaises(
        \\import std.json
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("[garbage]")
        \\
    , "json: a value was expected at byte 1");

    try agreeRaises(
        \\import std.json
        \\
        \\func main() -> !:
        \\    var deep = new builder()
        \\    for step in range(0, 65):
        \\        deep.append("[")
        \\    deep.append("1")
        \\    for step in range(0, 65):
        \\        deep.append("]")
        \\    let doc = try json.parse(deep.build())
        \\
    , "json: values nested deeper than 64, at byte 64");
}

// ---------------------------------------------------------------------------
// JSONTestSuite (Seriot 2016)
// ---------------------------------------------------------------------------

test "json: the JSONTestSuite y_ cases, which every parser must accept" {
    try agreeOk(asks ++
        \\func main():
        \\    assert(accepted("null"))                              # y_structure_lonely_null
        \\    assert(accepted("42"))                                # y_structure_lonely_int
        \\    assert(accepted("-0.1"))                              # y_structure_lonely_negative_real
        \\    assert(accepted("\"asd\""))                           # y_structure_lonely_string
        \\    assert(accepted("true"))                              # y_structure_lonely_true
        \\    assert(accepted("\"\""))                              # y_structure_string_empty
        \\    assert(accepted("[]"))                                # y_array_empty
        \\    assert(accepted("[\"\"]"))                            # y_array_empty_string
        \\    assert(accepted("[ 4]"))                              # y_number_after_space
        \\    assert(accepted("[1E22]"))                            # y_number_real_capital_e
        \\    assert(accepted("[1E-2]"))                            # y_number_real_capital_e_neg_exp
        \\    assert(accepted("[-0]"))                              # y_number_minus_zero
        \\    assert(accepted("[0e+1]"))                            # y_number_0e+1
        \\    assert(accepted("[123e65]"))                          # y_number
        \\    assert(accepted("{}"))                                # y_object_empty
        \\    assert(accepted("{\"\":0}"))                          # y_object_empty_key
        \\    assert(accepted("{\"a\":\"b\",\"a\":\"c\"}"))         # y_object_duplicated_key
        \\    assert(accepted("{\"a\":[]}"))                        # y_object_empty_array_value
        \\    assert(accepted("[\"\\u0022\"]"))                     # y_string_unicode_escaped_double_quote
        \\    assert(accepted("[\"\\uD801\\udc37\"]"))              # y_string_accepted_surrogate_pair
        \\    assert(accepted("[\"new\\u00A0line\"]"))              # y_string_nbsp_uescaped
        \\    assert(accepted("[\"\\u0000\"]"))                     # y_string_null_escape
        \\    assert(accepted("[\"a/*b*/c\"]"))                     # y_string_comments
        \\    assert(accepted("[\"\\\\a\"]"))                       # y_string_backslash_and_a
        \\    assert(accepted("[[[[[[[[[[[[[[[[[[[\"deep\"]]]]]]]]]]]]]]]]]]]"))  # y_structure_deep
        \\
    );
}

test "json: the JSONTestSuite n_ cases, which every parser must refuse" {
    try agreeOk(asks ++
        \\func main():
        \\    assert(not accepted(""))                              # n_structure_no_data
        \\    assert(not accepted(" "))                             # n_single_space
        \\    assert(not accepted("[][]"))                          # n_structure_double_array
        \\    assert(not accepted("[\"\"],"))                       # n_array_comma_after_close
        \\    assert(not accepted("[\"\",]"))                       # n_array_extra_comma
        \\    assert(not accepted("[,1]"))                          # n_array_just_comma
        \\    assert(not accepted("[1,,2]"))                        # n_array_double_comma
        \\    assert(not accepted("[\"a\",]"))                      # n_array_comma_and_number
        \\    assert(not accepted("{\"id\":0,}"))                   # n_object_trailing_comma
        \\    assert(not accepted("{\"a\":\"b\",,\"c\":\"d\"}"))    # n_object_double_comma
        \\    assert(not accepted("{key: 'value'}"))                # n_object_key_with_single_quotes
        \\    assert(not accepted("{\"a\" \"b\"}"))                 # n_object_missing_colon
        \\    assert(not accepted("[0.e1]"))                        # n_number_0.e1
        \\    assert(not accepted("[2.e3]"))                        # n_number_2.e3
        \\    assert(not accepted("[1 000.0]"))                     # n_number_1_000
        \\    assert(not accepted("[-01]"))                         # n_number_neg_int_starting_with_zero
        \\    assert(not accepted("[012]"))                         # n_number_with_leading_zero
        \\    assert(not accepted("[0x1]"))                         # n_number_hex_1_digit
        \\    assert(not accepted("[Infinity]"))                    # n_number_infinity
        \\    assert(not accepted("[NaN]"))                         # n_number_NaN
        \\    assert(not accepted("[- 1]"))                         # n_number_minus_space_1
        \\    assert(not accepted("[1.]"))                          # n_number_real_without_fractional_part
        \\    assert(not accepted("['single quote']"))              # n_string_single_quote
        \\    assert(not accepted("[\"\\a\"]"))                     # n_string_invalid_backslash_esc
        \\    assert(not accepted("[\"\\uD800\\u\"]"))              # n_string_1_surrogate_then_escape_u
        \\    assert(not accepted("[\"\\uD834\\uDd\"]"))            # n_string_incomplete_surrogate
        \\    assert(not accepted("[\"a" + chr(9) + "b\"]"))        # n_string_unescaped_tab
        \\    assert(not accepted("[\"line" + chr(10) + "\"]"))     # n_string_unescaped_newline
        \\    assert(not accepted("[\"unclosed"))                   # n_string_unclosed
        \\    assert(not accepted("[{"))                            # n_structure_open_array_open_object
        \\    assert(not accepted("{]"))                            # n_structure_object_with_comment_like
        \\    assert(not accepted("[1]x"))                          # n_structure_trailing_hash
        \\
    );
}

test "json: the JSONTestSuite i_ cases, which parsers disagree about, and what this one decided" {
    try agreeOk(asks ++
        \\func main() -> !:
        \\    # i_number_too_big_pos_int: grammatical, so it parses; too
        \\    # large for a long, so it is a real, which is where its
        \\    # precision honestly is.
        \\    assert(accepted("[100000000000000000000]"))
        \\    let big = try json.parse("[100000000000000000000]")
        \\    assert(big.element(0).as_long() == none)
        \\    assert(big.element(0).as_double() != none)
        \\
        \\    # i_number_huge_exp: refused, and this is the one row the
        \\    # union moved.  A lazy document could accept 1e999 and
        \\    # answer absence when asked for its value; an eager one
        \\    # would have to store an infinity, and infinity is not
        \\    # JSON — so it could never be written back.  RFC 8259
        \\    # section 6 allows an implementation to limit the range it
        \\    # accepts, and this is that limit, named at the byte.
        \\    assert(not accepted("[1e999]"))
        \\
        \\    # i_string_lone_second_surrogate, i_string_1st_surrogate_but_2nd_missing:
        \\    # refused.  A Luce string is UTF-8 and half a pair has
        \\    # none, so the alternative would be quietly substituting a
        \\    # replacement character for what the document said.
        \\    assert(not accepted("[\"\\uDFAA\"]"))
        \\    assert(not accepted("[\"\\uD800\"]"))
        \\
        \\    # i_structure_500_nested_arrays: refused, at 65 (see the
        \\    # nesting spec above for why that number).
        \\    var deep = new builder()
        \\    for step in range(0, 500):
        \\        deep.append("[")
        \\    for step in range(0, 500):
        \\        deep.append("]")
        \\    assert(not accepted(deep.build()))
        \\
    );
}

// ---------------------------------------------------------------------------
// The value as an object graph
// ---------------------------------------------------------------------------

test "json: documents parsed in a loop leave nothing behind" {
    try agreeOk(asks ++
        \\func main() -> !:
        \\    # Every one of these owns a tree of lists and maps, and
        \\    # every one of them is freed by the scope that received it
        \\    # — recursively, through the containers, which is what the
        \\    # leak census at the end of this run checks.
        \\    var total: long = 0
        \\    for step in range(0, 50):
        \\        let doc = try json.parse("{\"a\": [1, 2, {\"b\": \"c\"}], \"d\": null}")
        \\        total += doc.count()
        \\        total += doc.element(0).count()
        \\    assert(total == 250)
        \\
        \\    # A refused parse frees what it had built so far too.
        \\    for step in range(0, 50):
        \\        assert(not accepted("[1, 2, [3, 4"))
        \\
    );
}

test "json: the recipe for a file is three calls, and none of them is this module's" {
    var provided = budget;
    provided.world = .withFile("config.json", "{\"port\": 8080, \"host\": \"localhost\"}\n");
    try agree.printsGiven(
        \\import std.files
        \\import std.strings
        \\import std.json
        \\
        \\func main() -> !:
        \\    # json touches nothing: the bytes come off the disk, the
        \\    # text is a validation of those bytes, and the value is a
        \\    # reading of that text.
        \\    let bytes = try files.read_bytes("config.json")
        \\    let text = strings.from_bytes(bytes) else ""
        \\    let doc = try json.parse(text)
        \\    # The walking form: the map inside the value is reached by
        \\    # `match` and nothing is copied.
        \\    match doc:
        \\        object(fields):
        \\            var host = "?"
        \\            var port: long = 0
        \\            if fields.has("host"):
        \\                host = fields["host"].as_text() else "?"
        \\            if fields.has("port"):
        \\                port = fields["port"].as_long() else 0
        \\            print(host + ":" + string(port))
        \\        else:
        \\            trap("a config file is an object")
        \\
    , provided,
        \\localhost:8080
        \\
    );
}
