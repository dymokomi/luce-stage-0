"use strict";

// The client's pure halves, held by the same dependency-free harness
// as the indentation logic.

const test = require("node:test");
const assert = require("node:assert/strict");
const { extractFrames, frame, publishedFor } = require("./lsp.js");

test("frames survive arbitrary chunk boundaries", () => {
  const whole = Buffer.concat([frame('{"a":1}'), frame('{"b":2}')]);
  let pending = whole.slice(0, 9);
  let out = extractFrames(pending);
  assert.equal(out.bodies.length, 0);
  pending = Buffer.concat([out.rest, whole.slice(9, whole.length - 3)]);
  out = extractFrames(pending);
  assert.deepEqual(out.bodies, ['{"a":1}']);
  pending = Buffer.concat([out.rest, whole.slice(whole.length - 3)]);
  out = extractFrames(pending);
  assert.deepEqual(out.bodies, ['{"b":2}']);
  assert.equal(out.rest.length, 0);
});

test("the length counts bytes, not characters", () => {
  const body = '{"text":"héllo"}';
  const out = extractFrames(frame(body));
  assert.deepEqual(out.bodies, [body]);
});

test("published diagnostics arrive for the right uri only", () => {
  const body = JSON.stringify({
    jsonrpc: "2.0",
    method: "textDocument/publishDiagnostics",
    params: {
      uri: "file:///a.luc",
      diagnostics: [
        {
          range: { start: { line: 2, character: 4 }, end: { line: 2, character: 9 } },
          message: "unknown name x",
          code: "luce.sema.name",
        },
      ],
    },
  });
  const rows = publishedFor(body, "file:///a.luc");
  assert.equal(rows.length, 1);
  assert.equal(rows[0].line, 2);
  assert.equal(rows[0].column, 4);
  assert.equal(rows[0].message, "unknown name x");
  assert.equal(publishedFor(body, "file:///b.luc"), null);
  assert.equal(publishedFor('{"jsonrpc":"2.0","id":1,"result":null}', "file:///a.luc"), null);
});
