"use strict";

// The Luce language server, spoken directly.  The client is deliberately
// dependency-free like the rest of the extension: LSP over stdio is a
// Content-Length frame around a JSON body, and the ~hundred lines here
// are cheaper to own than a library dependency is to carry.  The pure
// halves — frame extraction and diagnostic mapping — are exported for
// the node test harness; everything process- and vscode-shaped stays in
// `startClient`.

/** Extract complete Content-Length frames from `pending` (a Buffer).
 *  Returns { bodies: [...strings], rest: Buffer } with the incomplete
 *  tail left in `rest`. */
function extractFrames(pending) {
  const bodies = [];
  let rest = pending;
  for (;;) {
    const split = rest.indexOf("\r\n\r\n");
    if (split < 0) break;
    const header = rest.slice(0, split).toString("utf8");
    let length = -1;
    for (const line of header.split("\r\n")) {
      const colon = line.indexOf(":");
      if (colon < 0) continue;
      if (line.slice(0, colon).trim().toLowerCase() === "content-length") {
        length = Number.parseInt(line.slice(colon + 1).trim(), 10);
      }
    }
    if (!Number.isInteger(length) || length < 0) {
      // A frame without a length cannot be resynchronized; drop the
      // broken header and try again from past it.
      rest = rest.slice(split + 4);
      continue;
    }
    if (rest.length < split + 4 + length) break;
    bodies.push(rest.slice(split + 4, split + 4 + length).toString("utf8"));
    rest = rest.slice(split + 4 + length);
  }
  return { bodies, rest };
}

/** One frame, ready for the wire. */
function frame(body) {
  const payload = Buffer.from(body, "utf8");
  return Buffer.concat([
    Buffer.from(`Content-Length: ${payload.length}\r\n\r\n`, "ascii"),
    payload,
  ]);
}

/** The diagnostics of a publishDiagnostics body for `uri`, or null when
 *  the body is something else.  Rows come back as plain objects the
 *  vscode adapter turns into vscode.Diagnostic. */
function publishedFor(body, uri) {
  let message;
  try {
    message = JSON.parse(body);
  } catch {
    return null;
  }
  if (message.method !== "textDocument/publishDiagnostics") return null;
  const params = message.params;
  if (!params || params.uri !== uri) return null;
  const rows = [];
  for (const row of params.diagnostics || []) {
    const range = row.range || {};
    const start = range.start || { line: 0, character: 0 };
    const end = range.end || start;
    rows.push({
      line: start.line | 0,
      column: start.character | 0,
      endLine: end.line | 0,
      endColumn: end.character | 0,
      message: String(row.message || ""),
      code: row.code === undefined ? "" : String(row.code),
    });
  }
  return rows;
}

/** Where the server lives.  An explicit setting wins; otherwise PATH
 *  (a development toolchain), and then the installer's default home —
 *  a GUI-launched editor often has no shell PATH, and the installed
 *  toolchain should still answer. */
function findServer(setting) {
  if (setting && setting !== "luce-lsp") return setting;
  const path = require("path");
  const fs = require("fs");
  for (const dir of (process.env.PATH || "").split(path.delimiter)) {
    if (!dir) continue;
    try {
      fs.accessSync(path.join(dir, "luce-lsp"), fs.constants.X_OK);
      return "luce-lsp";
    } catch {}
  }
  const installed = path.join(require("os").homedir(), ".local", "luce", "bin", "luce-lsp");
  try {
    fs.accessSync(installed, fs.constants.X_OK);
    return installed;
  } catch {}
  return "luce-lsp";
}

/** Start the server and wire one document's diagnostics.  Everything
 *  vscode- and process-shaped lives here so the functions above stay
 *  pure for the tests. */
function startClient(vscode, context) {
  const configured = vscode.workspace.getConfiguration("luce");
  if (configured.get("lsp.enabled") === false) return;
  const command = findServer(configured.get("lsp.serverPath"));

  const { spawn } = require("child_process");
  let server;
  try {
    server = spawn(command, [], { stdio: ["pipe", "pipe", "ignore"] });
  } catch {
    return;
  }
  server.on("error", () => {});

  const collection = vscode.languages.createDiagnosticCollection("luce");
  context.subscriptions.push(collection);
  context.subscriptions.push({ dispose: () => server.kill() });

  let nextId = 1;
  const send = (body) => {
    if (!server.stdin.writable) return;
    server.stdin.write(frame(JSON.stringify(body)));
  };
  send({ jsonrpc: "2.0", id: nextId++, method: "initialize", params: {} });
  send({ jsonrpc: "2.0", method: "initialized", params: {} });

  const opened = new Set();
  const tell = (document, kind) => {
    if (document.languageId !== "luce") return;
    const uri = document.uri.toString();
    if (kind === "open" || !opened.has(uri)) {
      opened.add(uri);
      send({
        jsonrpc: "2.0",
        method: "textDocument/didOpen",
        params: {
          textDocument: {
            uri,
            languageId: "luce",
            version: 1,
            text: document.getText(),
          },
        },
      });
      return;
    }
    send({
      jsonrpc: "2.0",
      method: "textDocument/didChange",
      params: {
        textDocument: { uri },
        contentChanges: [{ text: document.getText() }],
      },
    });
  };

  let pending = Buffer.alloc(0);
  server.stdout.on("data", (chunk) => {
    pending = Buffer.concat([pending, chunk]);
    const { bodies, rest } = extractFrames(pending);
    pending = rest;
    for (const body of bodies) {
      for (const document of vscode.workspace.textDocuments) {
        const uri = document.uri.toString();
        const rows = publishedFor(body, uri);
        if (rows === null) continue;
        collection.set(
          document.uri,
          rows.map(
            (row) =>
              new vscode.Diagnostic(
                new vscode.Range(row.line, row.column, row.endLine, row.endColumn),
                row.message,
                vscode.DiagnosticSeverity.Error,
              ),
          ),
        );
      }
    }
  });

  // A change waits a beat so a typing run costs one didChange, not one
  // per keystroke; open and close are immediate.
  let timer = null;
  context.subscriptions.push(
    vscode.workspace.onDidOpenTextDocument((document) => tell(document, "open")),
    vscode.workspace.onDidChangeTextDocument((event) => {
      if (event.document.languageId !== "luce") return;
      if (timer !== null) clearTimeout(timer);
      timer = setTimeout(() => tell(event.document, "change"), 150);
    }),
    vscode.workspace.onDidCloseTextDocument((document) => {
      const uri = document.uri.toString();
      if (!opened.delete(uri)) return;
      collection.delete(document.uri);
      send({
        jsonrpc: "2.0",
        method: "textDocument/didClose",
        params: { textDocument: { uri } },
      });
    }),
  );
  for (const document of vscode.workspace.textDocuments) tell(document, "open");
}

module.exports = { extractFrames, findServer, frame, publishedFor, startClient };
