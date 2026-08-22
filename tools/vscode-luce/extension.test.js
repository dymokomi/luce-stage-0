"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const {
  indentationCorrection,
  layoutDepth,
  lineEndsWithColon,
  markFoldingRanges,
} = require("./extension.js");

test("layout depth follows grouping and ignores comments and strings", () => {
  assert.equal(layoutDepth("let values = {\n    \"key\": [1, 2]"), 1);
  assert.equal(layoutDepth("let text = \"{[(}\" # {\n"), 0);
  assert.equal(layoutDepth("let text = f\"{len({ \"key\": f\"{name}\" })}\""), 0);
  assert.equal(layoutDepth("let values = {\n}\n"), 0);
});

test("only a code colon ends a block-looking line", () => {
  assert.equal(lineEndsWithColon("    if ready: # now"), true);
  assert.equal(lineEndsWithColon("    \"key\":"), true);
  assert.equal(lineEndsWithColon("    let text = \"not a block:\""), false);
  assert.equal(lineEndsWithColon("    call(value): suffix"), false);
});

test("a real layout block keeps VS Code's normal four-space indent", () => {
  assert.equal(indentationCorrection("func main():", "func main():", "    "), null);
});

test("a colon inside grouping does not create a layout indent", () => {
  const map = "func main():\n    let values = {\n        \"key\":";
  assert.equal(indentationCorrection(map, "        \"key\":", "            "), "        ");

  const call = "func main():\n    consume(\n        option:";
  assert.equal(indentationCorrection(call, "        option:", "            "), "        ");
});

test("on-type correction leaves nonblank lines and settled indentation alone", () => {
  const source = "let values = {\n    \"key\":";
  assert.equal(indentationCorrection(source, "    \"key\":", "    "), null);
  assert.equal(indentationCorrection(source, "    \"key\":", "        value"), null);
});

test("# mark: opens a section that folds to the next mark or the file end", () => {
  const source =
    "# mark: first\nlet a = 1\nlet b = 2\n\n# mark: second\nfunc f():\n    return\n\n";
  assert.deepEqual(markFoldingRanges(source), [
    { start: 0, end: 2 },
    { start: 4, end: 6 },
  ]);
});

test("marks fold at any indent, ignore case and spacing, and never span a string", () => {
  // Indented mark, a caps/spacing variant, and a `# mark:` sitting inside
  // code — which never starts a line and so is not a section head.
  const source =
    "func f():\n    #  MARK: inner\n    let a = 1\n    let s = \"# mark: text\"\n";
  assert.deepEqual(markFoldingRanges(source), [{ start: 1, end: 3 }]);
});

test("spacing is elastic around #, mark, and the colon", () => {
  // Every spelling below is one section head: indent before #, runs of
  // spaces or tabs between the parts, a space before the colon, mixed case.
  const heads = [
    "# mark: a",
    "   # mark: a",
    "\t#\tMARK\t: a",
    "#   MaRk : a",
    "      #mark:a",
  ];
  for (const head of heads) {
    assert.deepEqual(
      markFoldingRanges(head + "\nx = 1\ny = 2\n"),
      [{ start: 0, end: 2 }],
      head,
    );
  }
  // "marked:" and "mark up:" are not marks — the word must be exactly mark.
  assert.deepEqual(markFoldingRanges("# marked: x\ny = 1\n"), []);
  assert.deepEqual(markFoldingRanges("# mark up: x\ny = 1\n"), []);
});

test("a mark with nothing under it makes no fold, and none means no ranges", () => {
  assert.deepEqual(markFoldingRanges("# mark: a\n# mark: b\nx\n"), [
    { start: 1, end: 2 },
  ]);
  assert.deepEqual(markFoldingRanges("let a = 1\nlet b = 2\n"), []);
});
