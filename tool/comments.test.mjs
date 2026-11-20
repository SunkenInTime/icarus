import assert from "node:assert/strict";
import { test } from "node:test";

import { blocks, codeOnly, commentLineCount, removeBlocks, sameCodeBesidesImports, scan } from "./comments.mjs";

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
    "if (x) return /[/]/.test(y);",
  ].join("\n");
  assert.deepEqual(texts(source, "js"), ["// half"]);
});

test("rust lifetimes, chars and raw strings", () => {
  const source = [
    `fn f<'a>(s: &'a str) -> char { '"' }`,
    `let r = r#"// not "a" comment"#;`,
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

test("same-code accepts dropped imports and refuses code changes", () => {
  const before = `import 'a.dart';\nimport 'b.dart';\n/// See [B].\nfinal x = 1;\n`;
  assert.ok(sameCodeBesidesImports(before, `import 'a.dart';\nfinal x = 1;\n`, "dart"));
  assert.ok(!sameCodeBesidesImports(before, `import 'a.dart';\nimport 'c.dart';\nfinal x = 1;\n`, "dart"));
  assert.ok(!sameCodeBesidesImports(before, `import 'a.dart';\nimport 'b.dart';\nfinal x = 2;\n`, "dart"));
});
