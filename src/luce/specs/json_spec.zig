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
    \\    return doc.root().count()
    \\
    \\func accepted(text: string) -> bool:
    \\    let size = counted(text) catch -1
    \\    return size >= 0
    \\
    \\
;

/// Reaching a member is two steps — ask, then narrow — because `get`
/// answers `Node?` and a method needs a `Node`.  This is the idiom a
/// program writes, and it is a function only because a node returns
/// from one: the flat document is what makes that legal.
const reads =
    \\import std.json
    \\
    \\func child(doc: json.Document, node: json.Node, name: string) -> json.Node:
    \\    let found = doc.get(node, name)
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

test "json: a number is read by the notation it was written in" {
    try agreeOk(
        \\import std.json
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("[42, -7, 4.2, 42.0, 4.2e1, 1e3, -0, 0]")
        \\    let root = doc.root()
        \\
        \\    # Written whole, so it is a whole number.
        \\    assert(doc.at(root, 0).as_long() else -1 == 42)
        \\    assert(doc.at(root, 1).as_long() else 0 == -7)
        \\    assert(doc.at(root, 7).as_long() else -1 == 0)
        \\
        \\    # Written with a fraction or an exponent, so it is not —
        \\    # not even when the value it names is whole.  Absence says
        \\    # "that is not how this was written", where truncating
        \\    # would throw the fraction away without saying so.
        \\    assert(doc.at(root, 2).as_long() == none)
        \\    assert(doc.at(root, 3).as_long() == none)
        \\    assert(doc.at(root, 4).as_long() == none)
        \\    assert(doc.at(root, 5).as_long() == none)
        \\
        \\    # Every one of them is a double, whole ones included.
        \\    assert(doc.at(root, 0).as_double() else 0.0 == 42.0)
        \\    assert(doc.at(root, 3).as_double() else 0.0 == 42.0)
        \\    assert(doc.at(root, 4).as_double() else 0.0 == 42.0)
        \\    assert(doc.at(root, 5).as_double() else 0.0 == 1000.0)
        \\
        \\    # A negative zero survives as one: JSON writes it, so this
        \\    # module reads it.
        \\    assert(doc.at(root, 6).as_double() else 1.0 == 0.0)
        \\    assert(doc.at(root, 6).raw() == "-0")
        \\
    );
}

test "json: a number past what a machine holds parses and reads as absent" {
    try agreeOk(
        \\import std.json
        \\
        \\func main() -> !:
        \\    # Grammatical, so the document is valid — RFC 8259 section
        \\    # 6 sets no bound and says so.  The value is another
        \\    # question, and absence is the honest answer to it: the
        \\    # same one parse_int and parse_float give.
        \\    let doc = try json.parse("[1e309, 9223372036854775808, -9223372036854775809]")
        \\    let root = doc.root()
        \\    assert(doc.at(root, 0).as_double() == none)
        \\    assert(doc.at(root, 1).as_long() == none)
        \\    assert(doc.at(root, 2).as_long() == none)
        \\    # The text is still there, exactly as it was written, for
        \\    # a caller who wants to do something else with it.
        \\    assert(doc.at(root, 1).raw() == "9223372036854775808")
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
        \\    let root = doc.root()
        \\    assert(doc.at(root, 0).as_text() else "" == "\"")
        \\    assert(doc.at(root, 1).as_text() else "" == "\\")
        \\    assert(doc.at(root, 2).as_text() else "" == "/")
        \\    assert(doc.at(root, 3).as_text() else "" == chr(8))
        \\    assert(doc.at(root, 4).as_text() else "" == chr(12))
        \\    assert(doc.at(root, 5).as_text() else "" == "\n")
        \\    assert(doc.at(root, 6).as_text() else "" == chr(13))
        \\    assert(doc.at(root, 7).as_text() else "" == "\t")
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
        \\    let root = doc.root()
        \\    assert(doc.at(root, 0).as_text() else "" == "A")
        \\    assert(doc.at(root, 1).as_text() else "" == chr(233))
        \\    assert(doc.at(root, 2).as_text() else "" == chr(8364))
        \\    assert(len(doc.at(root, 3).as_text() else "x") == 1)
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
        \\    let root = doc.root()
        \\    let clef = doc.at(root, 0).as_text() else ""
        \\    assert(len(clef) == 4)
        \\    assert(clef == chr(119070))
        \\    assert((doc.at(root, 1).as_text() else "") == chr(66615))
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
        \\
        \\    # And a string that is never closed is not a string.
        \\    assert(not accepted("\"unclosed"))
        \\    assert(not accepted("\"tail\\\""))
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
        \\    let root = doc.root()
        \\    let name = "caf" + chr(233)
        \\    assert((child(doc, root, name).as_text() else "") == chr(955) + chr(119070))
        \\    assert(doc.keys(root)[0] == name)
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
        \\    # A member name may be empty, and it is still a name: the
        \\    # module tells it from "this value is not a member at all".
        \\    let doc = try json.parse("{\"\":0}")
        \\    assert(doc.at(doc.root(), 0).key() == "")
        \\    assert(doc.root().key() == "")
        \\    assert(doc.keys(doc.root())[0] == "")
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
        \\    let root = doc.root()
        \\    assert(root.count() == 3)
        \\    assert(doc.at(root, 0).as_long() else -1 == 10)
        \\    assert(doc.at(root, 2).as_long() else -1 == 30)
        \\    # An element of an array is nobody's member.
        \\    assert(doc.at(root, 1).key() == "")
        \\
    );
}

test "json: a duplicate member resolves to the last, and the document keeps both" {
    try agreeOk(reads ++
        \\func main() -> !:
        \\    # RFC 8259 section 4: names SHOULD be unique, and what
        \\    # happens when they are not is unpredictable.  Every
        \\    # mainstream parser keeps the last, and so does `get`.
        \\    let doc = try json.parse("{\"a\":\"first\",\"b\":2,\"a\":\"last\"}")
        \\    let root = doc.root()
        \\    assert((child(doc, root, "a").as_text() else "") == "last")
        \\
        \\    # The document is not edited to match: it said what it
        \\    # said, and a reader who wants to know that can find out.
        \\    assert(root.count() == 3)
        \\    let names = doc.keys(root)
        \\    assert(len(names) == 3)
        \\    assert(names[0] == "a" and names[1] == "b" and names[2] == "a")
        \\    assert(doc.write(root) == "{\"a\":\"first\",\"b\":2,\"a\":\"last\"}")
        \\
    );
}

test "json: a member name is compared decoded, however it was written" {
    try agreeOk(reads ++
        \\func main() -> !:
        \\    # The same name, spelled three ways.  A lookup decodes
        \\    # only the names that hold a backslash, which is almost
        \\    # none of them in almost every document.
        \\    let doc = try json.parse("{\"a\\nb\": 1, \"\\u0041\": 2, \"plain\": 3}")
        \\    let root = doc.root()
        \\    assert((child(doc, root, "a\nb").as_long() else -1) == 1)
        \\    assert((child(doc, root, "A").as_long() else -1) == 2)
        \\    assert(doc.get(root, "plain") != none)
        \\    assert(doc.get(root, "a\\nb") == none)
        \\    assert(doc.keys(root)[0] == "a\nb")
        \\    assert(doc.at(root, 1).key() == "A")
        \\
    );
}

// ---------------------------------------------------------------------------
// Nesting (RFC 8259 section 9)
// ---------------------------------------------------------------------------

test "json: nesting is bounded at 128, and a deeper document is refused rather than run out of stack" {
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
        \\    # RFC 8259 section 9 lets a parser set a limit; this one
        \\    # is loom's own call-depth policy, so every document this
        \\    # module accepts is one a recursive Luce function can walk.
        \\    assert(accepted(nest(127)))
        \\    assert(accepted(nest(128)))
        \\    assert(not accepted(nest(129)))
        \\    # The one the owner asked about: ten thousand deep is an
        \\    # error with a name, not a machine falling over.
        \\    assert(not accepted(nest(10000)))
        \\
    );
}

// ---------------------------------------------------------------------------
// Reading what was parsed
// ---------------------------------------------------------------------------

test "json: kind is six names, and a match over them needs no else" {
    try agreeOk(
        \\import std.json
        \\
        \\func label(kind: json.Kind) -> string:
        \\    match kind:
        \\        object:
        \\            return "object"
        \\        array:
        \\            return "array"
        \\        text:
        \\            return "text"
        \\        number:
        \\            return "number"
        \\        boolean:
        \\            return "boolean"
        \\        null:
        \\            return "null"
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("[{}, [], \"s\", 1, true, null]")
        \\    let root = doc.root()
        \\    assert(label(root.kind()) == "array")
        \\    assert(label(doc.at(root, 0).kind()) == "object")
        \\    assert(label(doc.at(root, 1).kind()) == "array")
        \\    assert(label(doc.at(root, 2).kind()) == "text")
        \\    assert(label(doc.at(root, 3).kind()) == "number")
        \\    assert(label(doc.at(root, 4).kind()) == "boolean")
        \\    assert(label(doc.at(root, 5).kind()) == "null")
        \\
    );
}

test "json: an accessor of the wrong kind answers absence, and null is not absence" {
    try agreeOk(
        \\import std.json
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("[\"s\", 1, true, false, null, {}, []]")
        \\    let root = doc.root()
        \\    let text = doc.at(root, 0)
        \\    let number = doc.at(root, 1)
        \\    let yes = doc.at(root, 2)
        \\    let no = doc.at(root, 3)
        \\    let nothing = doc.at(root, 4)
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
        \\    # member" is a different sentence, and `get` says that one.
        \\    assert(nothing.is_null())
        \\    assert(nothing.as_bool() == none)
        \\    assert(nothing.as_text() == none)
        \\    assert(doc.get(doc.at(root, 5), "anything") == none)
        \\
        \\    # A container is not a leaf and has no text of its own.
        \\    assert(doc.at(root, 5).raw() == "")
        \\    assert(doc.at(root, 6).count() == 0)
        \\    assert(len(doc.items(number)) == 0)
        \\    assert(len(doc.keys(number)) == 0)
        \\
    );
}

test "json: get answers absence for a name that is not there and for a value that is not an object" {
    try agreeOk(reads ++
        \\func main() -> !:
        \\    let doc = try json.parse("{\"here\": 1}")
        \\    let root = doc.root()
        \\    # `has` is a reserved name in Luce, so `get(…) != none` is
        \\    # the membership question, and it is the same one call.
        \\    assert(doc.get(root, "here") != none)
        \\    assert(doc.get(root, "there") == none)
        \\    assert(doc.get(root, "") == none)
        \\    assert(doc.get(root, "her") == none)
        \\    assert(doc.get(root, "heree") == none)
        \\    # A value that is not an object has no members, which is
        \\    # the same news to a caller looking for a field.
        \\    assert(doc.get(child(doc, root, "here"), "here") == none)
        \\
    );
}

test "json: items and at agree, and at past the end is a bug that traps" {
    try agreeOk(reads ++
        \\func main() -> !:
        \\    let doc = try json.parse("[1, [2, 3], {\"a\": 4}, 5]")
        \\    let root = doc.root()
        \\    let all = doc.items(root)
        \\    assert(len(all) == 4)
        \\    for index in range(0, 4):
        \\        assert(doc.at(root, index).raw() == all[index].raw())
        \\    # A node handed out of `items` navigates like any other:
        \\    # it is a value that knows where it lives.
        \\    assert((doc.at(all[1], 1).as_long() else -1) == 3)
        \\    assert((child(doc, all[2], "a").as_long() else -1) == 4)
        \\    assert((all[3].as_long() else -1) == 5)
        \\
    );

    try agree.trapGiven(
        \\import std.json
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("[1, 2]")
        \\    let root = doc.root()
        \\    print(string(doc.at(root, 2).as_long() else -1))
        \\
    , budget, .explicit_trap);
}

test "json: a node is a value that copies, and the document is the one object" {
    try agreeOk(
        \\import std.json
        \\
        \\func deepest(doc: json.Document, node: json.Node) -> json.Node:
        \\    # The shape the flat document buys: a node returns from a
        \\    # function, goes into a list, and costs a copy of six
        \\    # fields to do either.  A nested tree of owning containers
        \\    # could not answer this signature at all.
        \\    var here = node
        \\    while here.count() > 0:
        \\        here = doc.at(here, 0)
        \\    return here
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("[[[[\"bottom\"]]]]")
        \\    let found = deepest(doc, doc.root())
        \\    assert((found.as_text() else "") == "bottom")
        \\
        \\    var kept: list(json.Node) = []
        \\    for item in doc.items(doc.root()):
        \\        kept.append(item)
        \\    assert(len(kept) == 1)
        \\    assert(kept[0].count() == 1)
        \\
    );
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

test "json: write puts every token back and the whitespace nowhere" {
    try agreeOk(reads ++
        \\func main() -> !:
        \\    let spaced = "{\n  \"a\" : [ 1, 2 ] ,\n  \"b\" : { \"c\" : null }\n}"
        \\    let doc = try json.parse(spaced)
        \\    let root = doc.root()
        \\    assert(doc.write(root) == "{\"a\":[1,2],\"b\":{\"c\":null}}")
        \\    # A subtree writes on its own.
        \\    assert(doc.write(child(doc, root, "b")) == "{\"c\":null}")
        \\    # Empty containers keep their own shape.
        \\    let empty = try json.parse("[{},[],[{}]]")
        \\    assert(empty.write(empty.root()) == "[{},[],[{}]]")
        \\
    );
}

test "json: the tokens that come back are the ones that went in" {
    try agreeOk(
        \\import std.json
        \\
        \\func main() -> !:
        \\    # Numbers keep their notation and strings keep their
        \\    # escapes: `write` is not a re-encoding, it is the same
        \\    # tokens with the whitespace taken out.
        \\    # Written with no whitespace, because that is the one
        \\    # thing `write` does not put back: everything else in this
        \\    # line survives the round trip byte for byte.
        \\    let source = "[1e3,42.0,-0,\"\\u0041\",\"a\\/b\",\"caf" + chr(233) + "\"]"
        \\    let doc = try json.parse(source)
        \\    assert(doc.write(doc.root()) == source)
        \\
    );
}

test "json: parse, write, parse is a fixed point over a rich document" {
    try agreeOk(reads ++
        \\func main() -> !:
        \\    let source = "{\n  \"name\": \"luce\",\n  \"version\": 2,\n  \"ratio\": -1.5e-3,\n  \"tags\": [\"lang\", \"runtime\", []],\n  \"nested\": {\"a\": {\"b\": {\"c\": [true, false, null]}}},\n  \"escaped\": \"quote \\\" slash \\\\ newline \\n clef \\ud834\\udd1e\",\n  \"empty\": {},\n  \"none\": null\n}"
        \\    let first = try json.parse(source)
        \\    let once = first.write(first.root())
        \\    let second = try json.parse(once)
        \\    let twice = second.write(second.root())
        \\    assert(once == twice)
        \\
        \\    # And the document says the same things after the trip.
        \\    assert(second.root().count() == 8)
        \\    assert(child(second, second.root(), "tags").count() == 3)
        \\    let decoded = child(second, second.root(), "escaped").as_text() else ""
        \\    let clef = decoded[len(decoded) - 4:]
        \\    assert(clef == chr(119070))
        \\    assert(decoded[0:14] == "quote \" slash ")
        \\
        \\    # Pretty is the same document with room around it, and
        \\    # parsing it gives the same tokens back.
        \\    let indented = second.pretty(second.root(), 2)
        \\    let third = try json.parse(indented)
        \\    assert(third.write(third.root()) == once)
        \\
    );
}

test "json: pretty indents by the count it is given" {
    try agree.printsGiven(
        \\import std.json
        \\
        \\func main() -> !:
        \\    let doc = try json.parse("{\"a\":[1,{\"b\":2}],\"c\":{},\"d\":[]}")
        \\    print(doc.pretty(doc.root(), 2))
        \\    print(doc.pretty(doc.root(), 0))
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
        \\    # And what it writes is what this module reads back.
        \\    let quoted = json.quote("a\"b\\c" + chr(11) + "d/e" + chr(233))
        \\    let doc = try json.parse(quoted)
        \\    assert((doc.root().as_text() else "") == "a\"b\\c" + chr(11) + "d/e" + chr(233))
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
        \\    # i_number_huge_exp, i_number_too_big_pos_int: grammatical,
        \\    # so the document parses; the value is out of range, so the
        \\    # accessor answers absence.  Accepting and then saying "not
        \\    # a double" keeps the two questions apart.
        \\    assert(accepted("[1e999]"))
        \\    assert(accepted("[100000000000000000000]"))
        \\    let huge = try json.parse("[1e999]")
        \\    assert(huge.at(huge.root(), 0).as_double() == none)
        \\
        \\    # i_string_lone_second_surrogate, i_string_1st_surrogate_but_2nd_missing:
        \\    # refused.  A Luce string is UTF-8 and half a pair has
        \\    # none, so the alternative would be quietly substituting a
        \\    # replacement character for what the document said.
        \\    assert(not accepted("[\"\\uDFAA\"]"))
        \\    assert(not accepted("[\"\\uD800\"]"))
        \\
        \\    # i_structure_500_nested_arrays: refused, at 129 (see the
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
// The document as an object
// ---------------------------------------------------------------------------

test "json: documents parsed in a loop leave nothing behind" {
    try agreeOk(asks ++
        \\func main() -> !:
        \\    # Every one of these owns a list of nodes, and every one
        \\    # of them is freed by the scope that received it — which
        \\    # is what the leak census at the end of this run checks.
        \\    var total: long = 0
        \\    for step in range(0, 50):
        \\        let doc = try json.parse("{\"a\": [1, 2, {\"b\": \"c\"}], \"d\": null}")
        \\        total += doc.root().count()
        \\        let items = doc.items(doc.root())
        \\        total += len(items)
        \\    assert(total == 200)
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
        \\func child(doc: json.Document, node: json.Node, name: string) -> json.Node:
        \\    let found = doc.get(node, name)
        \\    if found != none:
        \\        return found
        \\    trap("no such member: " + name)
        \\
        \\func main() -> !:
        \\    # json touches nothing: the bytes come off the disk, the
        \\    # text is a validation of those bytes, and the document is
        \\    # a reading of that text.
        \\    let bytes = try files.read_bytes("config.json")
        \\    let text = strings.from_bytes(bytes) else ""
        \\    let doc = try json.parse(text)
        \\    let root = doc.root()
        \\    let host = child(doc, root, "host").as_text() else "?"
        \\    let port = child(doc, root, "port").as_long() else 0
        \\    print(host + ":" + string(port))
        \\
    , provided,
        \\localhost:8080
        \\
    );
}
