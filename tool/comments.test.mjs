import assert from "node:assert/strict";
import { test } from "node:test";

import { ContinuedLineComment, MidLineComment, blocks, codeOnly, commentLineCount, isOurs, removeBlocks, scan } from "./comments.mjs";

const texts = (source, language) => scan(source, language).map((comment) => comment.text);

test("dart strings and interpolation hide comment markers", () => {
  const source = [
    `final a = '// not a comment';`,
    `final b = "\${'/* nor this */'} // but this";`,
    `final c = r'\\// raw';`,
    `final d = '''`,
    `// inside a triple-quoted string`,
    `''';`,
    `final e = "\${{'k': "\${'//'}"}}"; // after nested interpolation`,
  ].join("\n");
  assert.deepEqual(texts(source, "dart"), [`// after nested interpolation`]);
});

test("dart block comments nest", () => {
  const source = `/* outer /* inner */ still outer */ final x = 1; /// doc`;
  assert.deepEqual(texts(source, "dart"), ["/* outer /* inner */ still outer */", "/// doc"]);
});

test("tool directives and formatter guards are not counted", () => {
  const source = [
    `// ignore_for_file: avoid_print`,
    `// ignore: unused_local_variable`,
    `final m = [`,
    `  1, 0, //`,
    `  0, 1, //`,
    `];`,
    `// A real comment.`,
  ].join("\n");
  assert.equal(commentLineCount(source, "dart"), 1);
});

test("javascript regexes and templates hide comment markers", () => {
  const source = [
    "const url = /https?:\\/\\//;",
    "const t = `${'//'} and ${`/* */`}`;",
    "const ratio = a / b; // half",
    "function f(y) { return /[/]/.test(y); }",
    "if (ok) /[//]/.test(s);",
    "i++ / 2; // after a postfix",
    'console.log(+ +/[//]/.test("/"));',
    "obj.if(true) / 2; // after a method named if",
  ].join("\n");
  assert.deepEqual(texts(source, "js"), ["// half", "// after a postfix", "// after a method named if"]);
});

test("rust lifetimes, chars and raw strings", () => {
  const source = [
    `fn f<'a>(s: &'a str) -> char { '"' }`,
    `let r = r#"// not "a" comment"#;`,
    `let c = cr#"inside " // literal"#;`,
    `let q = '\\''; // quote`,
    `/* a /* nested */ block */`,
  ].join("\n");
  assert.deepEqual(texts(source, "rust"), ["// quote", "/* a /* nested */ block */"]);
});

test("powershell strings and block comments", () => {
  const source = [`$a = "# not a comment"`, `<# help`, `text #>`, `Write-Host $a # trailing`].join("\n");
  assert.deepEqual(texts(source, "powershell"), ["<# help\ntext #>", "# trailing"]);
});

test("consecutive own-line comments form one block, trailing ones stand alone", () => {
  const source = [`// one`, `// two`, `final x = 1; // three`, `/// four`].join("\n");
  assert.deepEqual(
    blocks(source, "dart").map((block) => [block.startLine + 1, block.lines, block.ownLine]),
    [
      [1, 2, true],
      [3, 1, false],
      [4, 1, true],
    ],
  );
});

test("removing blocks keeps the code and one blank line", () => {
  const source = [`final a = 1;`, ``, `// gone`, ``, `final b = 2; // gone too`, ``].join("\n");
  const removed = removeBlocks(source, blocks(source, "dart"));
  assert.equal(removed, [`final a = 1;`, ``, `final b = 2;`, ``].join("\n"));
  assert.equal(codeOnly(removed, "dart"), codeOnly(source, "dart"));
});

test("shell heredocs and powershell here-strings are data", () => {
  const shell = [
    "cat <<'EOF'", "# delivered literally", "EOF",
    "cat <<\\END", "# also literal", "END",
    "cat <<123", "# numbered", "123",
    "cat <<< hello", "# after a here-string",
    "((x = 1<<2))", "# after a shift",
    "echo done # trailing",
  ].join("\n");
  assert.deepEqual(texts(shell, "shell"), ["# after a here-string", "# after a shift", "# trailing"]);
  assert.deepEqual(texts(`value = 'it\\'s # literal'\n# real`, "python"), ["# real"]);
  const powershell = ["$t = @'\r", "This is Icarus's template\r", "# part of the emitted script\r", "'@\r", "$a = 'ends in `' # real\r", ""].join("\n");
  assert.deepEqual(texts(powershell, "powershell"), ["# real"]);
});

test("a generated marker counts only inside a header comment", () => {
  assert.equal(isOurs("tool/x.ts", `export const labels = ["Do not edit"];\n`), true);
  assert.equal(isOurs("tool/x.ts", `// Do not edit: generated.\nexport const x = 1;\n`), false);
});

test("a comment with code on both sides is left for a person", () => {
  for (const [source, language] of [
    ["const n = 1/**/.toString();", "js"],
    ["const t = typeof/**/x;", "js"],
    ["#define F/**/(x) x", "c"],
    ["return /* note\n*/ (7);", "js"],
  ]) {
    assert.throws(() => removeBlocks(source, blocks(source, language)), MidLineComment, source);
  }
  const opening = "  /* gone */ run();\n";
  assert.equal(removeBlocks(opening, blocks(opening, "js")), "  run();\n");
  assert.notEqual(codeOnly("a+++b", "js"), codeOnly("a+ ++b", "js"));
});

test("a comment inside a backslash-continued line is left for a person", () => {
  for (const [source, language] of [
    ['puts("before"); // note \\\nputs("after");', "c"],
    ["#define F \\\n/* note */(x)", "c"],
    ["x = 1 \\\n# note\n+ 2", "python"],
  ]) {
    assert.throws(() => removeBlocks(source, blocks(source, language)), ContinuedLineComment, source);
  }
});

test("u+2028 ends a js line comment, and c++ raw strings are data", () => {
  assert.deepEqual(texts('a(); // note\u2028b();', "js"), ["// note"]);
  assert.deepEqual(texts('auto s = R"x(one\n// literal\n)x"; // real', "c"), ["// real"]);
});

test("removing a trailing comment keeps CRLF line endings", () => {
  const source = "final a = 1; // gone\r\nfinal b = 2;\r\n";
  assert.equal(removeBlocks(source, blocks(source, "dart")), "final a = 1;\r\nfinal b = 2;\r\n");
});

test("code equality keeps whitespace inside strings and drops it elsewhere", () => {
  assert.equal(codeOnly("f( 'a b' ,\n  x )", "dart"), codeOnly("f('a b', x)", "dart"));
  assert.notEqual(codeOnly("f('a b')", "dart"), codeOnly("f('ab')", "dart"));
  assert.notEqual(codeOnly("return x", "js"), codeOnly("returnx", "js"));
});
