"use strict";

// Luce suspends layout inside every grouping delimiter. VS Code's
// declarative indentation regex cannot carry that state across lines,
// so this small on-type formatter removes the block indent it would
// otherwise add after a colon inside (), [], or {}.

const MAX_STRING_NESTING = 400;

function isWordByte(character) {
  if (character === "_") return true;
  const code = character.charCodeAt(0);
  return (
    (code >= 48 && code <= 57) ||
    (code >= 65 && code <= 90) ||
    (code >= 97 && code <= 122)
  );
}

function skipQuoted(text, open, quote) {
  let index = open + 1;
  while (index < text.length && text[index] !== "\n") {
    if (text[index] === "\\") {
      if (index + 1 >= text.length || text[index + 1] === "\n") return index;
      index += 2;
      continue;
    }
    if (text[index] === quote) return index + 1;
    index += 1;
  }
  return index;
}

function skipFormattedString(text, open, nesting) {
  let index = open + 1;
  let braceDepth = 0;
  while (index < text.length && text[index] !== "\n") {
    const character = text[index];
    if (braceDepth === 0) {
      if (character === "\"") return index + 1;
      if (character === "\\") {
        if (index + 1 >= text.length || text[index + 1] === "\n") return index;
        index += 2;
        continue;
      }
      if (character === "{") {
        if (text[index + 1] === "{") {
          index += 2;
          continue;
        }
        braceDepth = 1;
      }
      index += 1;
      continue;
    }

    if (
      character === "f" &&
      text[index + 1] === "\"" &&
      (index === 0 || !isWordByte(text[index - 1]))
    ) {
      index =
        nesting < MAX_STRING_NESTING
          ? skipFormattedString(text, index + 1, nesting + 1)
          : skipQuoted(text, index + 1, "\"");
      continue;
    }
    if (character === "\"" || character === "'") {
      index = skipQuoted(text, index, character);
      continue;
    }
    if (character === "#") {
      while (index < text.length && text[index] !== "\n") index += 1;
      continue;
    }
    if (character === "{") braceDepth += 1;
    if (character === "}") braceDepth -= 1;
    index += 1;
  }
  return index;
}

function layoutDepth(text) {
  let depth = 0;
  let index = 0;
  while (index < text.length) {
    const character = text[index];
    if (character === "#") {
      while (index < text.length && text[index] !== "\n") index += 1;
      continue;
    }
    if (
      character === "f" &&
      text[index + 1] === "\"" &&
      (index === 0 || !isWordByte(text[index - 1]))
    ) {
      index = skipFormattedString(text, index + 1, 0);
      continue;
    }
    if (character === "\"" || character === "'") {
      index = skipQuoted(text, index, character);
      continue;
    }
    if (character === "(" || character === "[" || character === "{") depth += 1;
    if ((character === ")" || character === "]" || character === "}") && depth > 0) {
      depth -= 1;
    }
    index += 1;
  }
  return depth;
}

function lineEndsWithColon(line) {
  let lastCode = "";
  let index = 0;
  while (index < line.length) {
    const character = line[index];
    if (character === "#") break;
    if (
      character === "f" &&
      line[index + 1] === "\"" &&
      (index === 0 || !isWordByte(line[index - 1]))
    ) {
      lastCode = "\"";
      index = skipFormattedString(line, index + 1, 0);
      continue;
    }
    if (character === "\"" || character === "'") {
      lastCode = character;
      index = skipQuoted(line, index, character);
      continue;
    }
    if (character !== " " && character !== "\t" && character !== "\r") {
      lastCode = character;
    }
    index += 1;
  }
  return lastCode === ":";
}

// `# mark: title` sections. A mark line opens a foldable region that runs
// to the line just above the next mark (at any indent) or the end of the
// file, so a reader can collapse a whole section and keep only its title.
// Trailing blank lines are left out so the blank between two sections stays
// visible when the section above is folded. A line only opens a section when
// its first non-blank content is the comment — a `# mark:` inside code or a
// string never starts with `#` at the line's head, so no scan of those is
// needed (Luce strings do not span lines).
//
// Spacing and case are all elastic, so a mark reads the same however it is
// tabulated: any indent before `#`, any run of spaces or tabs between `#`,
// `mark`, and `:`, and any casing of the word (`# mark:`, `   #  MARK :`).
const MARK_LINE = /^[ \t]*#[ \t]*mark[ \t]*:/i;

// The line numbers (0-based) of every section head, for the folding
// provider and the bright decoration below. Every mark is a head, whether
// or not it has content under it to fold.
function markLineNumbers(text) {
  const lines = text.split("\n");
  const marks = [];
  for (let index = 0; index < lines.length; index += 1) {
    if (MARK_LINE.test(lines[index])) marks.push(index);
  }
  return marks;
}

function markFoldingRanges(text) {
  const lines = text.split("\n");
  const marks = markLineNumbers(text);
  const ranges = [];
  for (let mark = 0; mark < marks.length; mark += 1) {
    const start = marks[mark];
    const limit = mark + 1 < marks.length ? marks[mark + 1] : lines.length;
    let end = limit - 1;
    while (end > start && /^[ \t]*$/.test(lines[end])) end -= 1;
    if (end > start) ranges.push({ start, end });
  }
  return ranges;
}

function indentationCorrection(textThroughPreviousLine, previousLine, currentLine) {
  if (!/^[ \t]*$/.test(currentLine)) return null;
  if (!lineEndsWithColon(previousLine)) return null;
  if (layoutDepth(textThroughPreviousLine) === 0) return null;
  const wanted = previousLine.match(/^[ \t]*/)[0];
  return currentLine === wanted ? null : wanted;
}

function activate(context) {
  const vscode = require("vscode");
  require("./lsp.js").startClient(vscode, context);
  const provider = {
    provideOnTypeFormattingEdits(document, position, character) {
      if (character !== "\n" || position.line === 0) return [];
      const previous = document.lineAt(position.line - 1);
      const current = document.lineAt(position.line);
      const start = new vscode.Position(0, 0);
      const previousEnd = new vscode.Position(position.line - 1, previous.text.length);
      const throughPrevious = document.getText(new vscode.Range(start, previousEnd));
      const replacement = indentationCorrection(throughPrevious, previous.text, current.text);
      if (replacement === null) return [];
      return [
        vscode.TextEdit.replace(
          new vscode.Range(position.line, 0, position.line, current.text.length),
          replacement,
        ),
      ];
    },
  };
  context.subscriptions.push(
    vscode.languages.registerOnTypeFormattingEditProvider("luce", provider, "\n"),
  );
  context.subscriptions.push(
    vscode.languages.registerFoldingRangeProvider("luce", {
      provideFoldingRanges(document) {
        return markFoldingRanges(document.getText()).map(
          (range) =>
            new vscode.FoldingRange(
              range.start,
              range.end,
              vscode.FoldingRangeKind.Region,
            ),
        );
      },
    }),
  );

  // A `# mark:` head is a section title, not an aside, so it is painted
  // bright and bold — an accent that reads over the muted grey the theme
  // gives ordinary comments. Two variants keep it loud on either ground:
  // amber on a dark editor, a saturated magenta on a light one.
  const markDecoration = vscode.window.createTextEditorDecorationType({
    fontWeight: "bold",
    light: { color: "#C2185B" },
    dark: { color: "#FFC400" },
  });
  context.subscriptions.push(markDecoration);
  const paintMarks = (editor) => {
    if (!editor || editor.document.languageId !== "luce") return;
    const ranges = markLineNumbers(editor.document.getText()).map((line) => {
      const length = editor.document.lineAt(line).text.length;
      return new vscode.Range(line, 0, line, length);
    });
    editor.setDecorations(markDecoration, ranges);
  };
  const paintVisible = () => {
    for (const editor of vscode.window.visibleTextEditors) paintMarks(editor);
  };
  paintVisible();
  context.subscriptions.push(
    vscode.window.onDidChangeVisibleTextEditors(paintVisible),
    vscode.workspace.onDidChangeTextDocument((event) => {
      for (const editor of vscode.window.visibleTextEditors) {
        if (editor.document === event.document) paintMarks(editor);
      }
    }),
  );
}

function deactivate() {}

module.exports = {
  activate,
  deactivate,
  indentationCorrection,
  layoutDepth,
  lineEndsWithColon,
  markFoldingRanges,
  markLineNumbers,
};
