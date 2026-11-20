#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { extname } from "node:path";
import { fileURLToPath } from "node:url";

const BASELINE = "tool/comment_baseline.json";

const SLASH_LANGUAGES = {
  ".dart": "dart",
  ".ts": "js",
  ".tsx": "js",
  ".js": "js",
  ".mjs": "js",
  ".cjs": "js",
  ".rs": "rust",
  ".swift": "swift",
  ".kt": "c",
  ".c": "c",
  ".cc": "c",
  ".cpp": "c",
  ".h": "c",
  ".hpp": "c",
};

const HASH_LANGUAGES = {
  ".ps1": "powershell",
  ".psm1": "powershell",
  ".py": "python",
  ".sh": "shell",
};

const NOT_OURS = [
  /^third_party\//,
  /^packages\//,
  /^native\/[^/]+\/src\/vendor\//,
  /^web\/convex\.browser\.bundle\.js$/,
  /^convex\/_generated\//,
  /\/generated\//,
  /\.g\.dart$/,
  /\.freezed\.dart$/,
  /generated_plugin_registrant\.(cc|h)$/,
  /GeneratedPluginRegistrant\.swift$/,
  /^windows\/runner\/resource\.h$/,
];

const GENERATED_HEADER =
  /GENERATED CODE|@generated|Code generated|Do not edit|DO NOT EDIT|automatically generated/;

const DIRECTIVES = {
  dart: /^(ignore(_for_file)?:|coverage:|@dart\s*=|dart format (off|on)\b)/,
  js: /^(eslint-|@ts-(check|nocheck|ignore|expect-error)|prettier-ignore|biome-ignore|@vite-ignore|[#@]?__PURE__|@vitest-environment|istanbul ignore|[cv]8 ignore|reference )/,
  rust: /^$/,
  swift: /^swiftlint:/,
  c: /^(NOLINT|clang-format (off|on))/,
  powershell: /^Requires /,
  python: /^(noqa|type: ignore|pragma|-\*-)/,
  shell: /^(shellcheck )/,
};

export function languageOf(path) {
  const ext = extname(path).toLowerCase();
  return SLASH_LANGUAGES[ext] ?? HASH_LANGUAGES[ext] ?? null;
}

export function isOurs(path, text) {
  if (!languageOf(path)) return false;
  if (NOT_OURS.some((pattern) => pattern.test(path))) return false;
  const head = text.split("\n", 5).join("\n");
  return !GENERATED_HEADER.test(head);
}

export function scan(text, language) {
  const hash = ["powershell", "python", "shell"].includes(language);
  const comments = hash ? scanHash(text, language) : scanSlash(text, language);
  return comments.map((comment) => ({
    ...comment,
    directive: DIRECTIVES[language].test(comment.text.replace(/^[/*#!<\s]+/, "")),
  }));
}

function scanSlash(text, language) {
  const comments = [];
  const nests = language === "dart" || language === "rust" || language === "swift";
  const stack = [{ kind: "code", depth: 0 }];
  let i = 0;
  let lastSignificant = "";

  const top = () => stack[stack.length - 1];

  while (i < text.length) {
    const mode = top();
    const c = text[i];
    const next = text[i + 1];

    if (mode.kind === "string") {
      if (c === "\\" && !mode.raw) {
        if (language === "swift" && next === "(") {
          stack.push({ kind: "code", depth: 1, closer: ")" });
          i += 2;
          continue;
        }
        i += 2;
        continue;
      }
      if (!mode.raw && mode.interpolates && c === "$" && next === "{") {
        stack.push({ kind: "code", depth: 1, closer: "}" });
        i += 2;
        continue;
      }
      if (text.startsWith(mode.end, i)) {
        stack.pop();
        i += mode.end.length;
        lastSignificant = "a";
        continue;
      }
      if (mode.end.length === 1 && mode.end !== "`" && c === "\n" && language !== "rust") {
        stack.pop();
      }
      i += 1;
      continue;
    }

    if (mode.kind === "regex") {
      if (c === "\\") {
        i += 2;
        continue;
      }
      if (c === "[") mode.inClass = true;
      else if (c === "]") mode.inClass = false;
      else if (c === "/" && !mode.inClass) {
        stack.pop();
        lastSignificant = "a";
      } else if (c === "\n") stack.pop();
      i += 1;
      continue;
    }

    if (c === "/" && next === "/") {
      const end = text.indexOf("\n", i);
      const stop = end === -1 ? text.length : end;
      comments.push({ start: i, end: stop, text: text.slice(i, stop), block: false });
      i = stop;
      continue;
    }

    if (c === "/" && next === "*") {
      let depth = 1;
      let j = i + 2;
      while (j < text.length && depth > 0) {
        if (nests && text[j] === "/" && text[j + 1] === "*") {
          depth += 1;
          j += 2;
        } else if (text[j] === "*" && text[j + 1] === "/") {
          depth -= 1;
          j += 2;
        } else {
          j += 1;
        }
      }
      comments.push({ start: i, end: j, text: text.slice(i, j), block: true });
      i = j;
      continue;
    }

    if (mode.closer) {
      const opener = mode.closer === "}" ? "{" : "(";
      if (c === opener) mode.depth += 1;
      if (c === mode.closer) {
        mode.depth -= 1;
        if (mode.depth === 0) {
          stack.pop();
          i += 1;
          continue;
        }
      }
    }

    const string = openString(text, i, language);
    if (string) {
      stack.push(string.mode);
      i += string.length;
      continue;
    }

    if (language === "rust" && c === "'") {
      i += rustQuote(text, i);
      lastSignificant = "a";
      continue;
    }

    if (language === "js" && c === "/" && regexCanStart(text, i, lastSignificant)) {
      stack.push({ kind: "regex", inClass: false });
      i += 1;
      continue;
    }

    if (!/\s/.test(c)) lastSignificant = c;
    i += 1;
  }
  return comments;
}

function openString(text, i, language) {
  const c = text[i];
  if (language === "dart") {
    let raw = false;
    let at = i;
    if (c === "r" && (text[i + 1] === "'" || text[i + 1] === '"') && !/[\w$]/.test(text[i - 1] ?? "")) {
      raw = true;
      at = i + 1;
    }
    const q = text[at];
    if (q !== "'" && q !== '"') return null;
    const triple = text.startsWith(q.repeat(3), at);
    const end = triple ? q.repeat(3) : q;
    return {
      length: at - i + end.length,
      mode: { kind: "string", end, raw, interpolates: true },
    };
  }
  if (language === "js") {
    if (c === "'" || c === '"') return { length: 1, mode: { kind: "string", end: c, raw: false } };
    if (c === "`") return { length: 1, mode: { kind: "string", end: "`", raw: false, interpolates: true } };
    return null;
  }
  if (language === "rust") {
    const prefix = /^(b?r(#*)")|^(b?")/.exec(text.slice(i, i + 260));
    if (!prefix || /[\w]/.test(text[i - 1] ?? "")) return null;
    if (prefix[1]) {
      return { length: prefix[1].length, mode: { kind: "string", end: `"${prefix[2]}`, raw: true } };
    }
    return { length: prefix[3].length, mode: { kind: "string", end: '"', raw: false } };
  }
  if (language === "swift") {
    const prefix = /^(#*)("""|")/.exec(text.slice(i, i + 40));
    if (!prefix || (prefix[1] === "" && c !== '"')) return null;
    const hashes = prefix[1];
    return {
      length: prefix[0].length,
      mode: { kind: "string", end: `${prefix[2]}${hashes}`, raw: hashes.length > 0 },
    };
  }
  if (c === '"') return { length: 1, mode: { kind: "string", end: '"', raw: false } };
  if (c === "'") return { length: 1, mode: { kind: "string", end: "'", raw: false } };
  return null;
}

function rustQuote(text, i) {
  if (text[i + 1] === "\\") {
    const close = text.indexOf("'", i + 3);
    return close === -1 ? 1 : close - i + 1;
  }
  const codePoint = text.codePointAt(i + 1);
  const width = codePoint > 0xffff ? 2 : 1;
  if (text[i + 1 + width] === "'") return width + 2;
  return 1;
}

const REGEX_AFTER_WORD = new Set([
  "return", "typeof", "instanceof", "in", "of", "new", "delete", "void",
  "throw", "case", "do", "else", "yield", "await",
]);

function regexCanStart(text, i, lastSignificant) {
  if (lastSignificant === "" || "(,=:[!&|?{};+-*%<>~^".includes(lastSignificant)) return true;
  if (/[\w$]/.test(lastSignificant)) {
    const word = /([\w$]+)\s*$/.exec(text.slice(Math.max(0, i - 40), i));
    return Boolean(word && REGEX_AFTER_WORD.has(word[1]));
  }
  return false;
}

function scanHash(text, language) {
  const comments = [];
  let i = 0;
  let quote = null;
  let lastChar = "\n";
  while (i < text.length) {
    const c = text[i];
    if (quote) {
      if (c === "\\" && language !== "powershell") {
        i += 2;
        continue;
      }
      if (language === "powershell" && c === "`") {
        i += 2;
        continue;
      }
      if (text.startsWith(quote, i)) {
        i += quote.length;
        quote = null;
        lastChar = "a";
        continue;
      }
      i += 1;
      continue;
    }
    if (language === "powershell" && c === "<" && text[i + 1] === "#") {
      const close = text.indexOf("#>", i + 2);
      const stop = close === -1 ? text.length : close + 2;
      comments.push({ start: i, end: stop, text: text.slice(i, stop), block: true });
      i = stop;
      continue;
    }
    if (c === "#" && /\s|^$/.test(lastChar) && !(i === 0 && text[1] === "!")) {
      const end = text.indexOf("\n", i);
      const stop = end === -1 ? text.length : end;
      comments.push({ start: i, end: stop, text: text.slice(i, stop), block: false });
      i = stop;
      continue;
    }
    if (language === "powershell" && c === "@" && (text[i + 1] === '"' || text[i + 1] === "'") && text[i + 2] === "\n") {
      quote = `\n${text[i + 1]}@`;
      i += 2;
      continue;
    }
    if (language === "python" && (text.startsWith('"""', i) || text.startsWith("'''", i))) {
      quote = text.slice(i, i + 3);
      i += 3;
      continue;
    }
    if (c === '"' || c === "'") {
      quote = c;
      i += 1;
      continue;
    }
    lastChar = c;
    i += 1;
  }
  return comments;
}

export function blocks(text, language) {
  const lineStarts = [0];
  for (let i = 0; i < text.length; i += 1) if (text[i] === "\n") lineStarts.push(i + 1);
  const lineOf = (offset) => {
    let lo = 0;
    let hi = lineStarts.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (lineStarts[mid] <= offset) lo = mid;
      else hi = mid - 1;
    }
    return lo;
  };
  const lineText = (line) => text.slice(lineStarts[line], (lineStarts[line + 1] ?? text.length + 1) - 1);

  const result = [];
  for (const comment of scan(text, language)) {
    const startLine = lineOf(comment.start);
    const endLine = lineOf(Math.max(comment.start, comment.end - 1));
    const before = text.slice(lineStarts[startLine], comment.start);
    const after = text.slice(comment.end, (lineStarts[endLine + 1] ?? text.length + 1) - 1);
    const ownLine = before.trim() === "" && after.trim() === "";
    const previous = result[result.length - 1];
    if (
      previous &&
      ownLine &&
      previous.ownLine &&
      !comment.block &&
      !previous.block &&
      previous.directive === comment.directive &&
      previous.endLine + 1 === startLine
    ) {
      previous.endLine = endLine;
      previous.end = comment.end;
      previous.text += `\n${comment.text}`;
      continue;
    }
    const formatterGuard = !ownLine && !comment.block && comment.text.trim() === "//";
    result.push({ ...comment, startLine, endLine, ownLine, directive: comment.directive || formatterGuard });
  }
  for (const block of result) {
    block.lines = block.endLine - block.startLine + 1;
    block.lineText = lineText;
  }
  return result;
}

export function commentLineCount(text, language) {
  const lines = new Set();
  for (const block of blocks(text, language)) {
    if (block.directive) continue;
    for (let line = block.startLine; line <= block.endLine; line += 1) lines.add(line);
  }
  return lines.size;
}

export function removeBlocks(text, removed) {
  const lines = text.split("\n");
  const drop = new Set();
  const edits = [];
  for (const block of removed) {
    if (block.ownLine) {
      for (let line = block.startLine; line <= block.endLine; line += 1) drop.add(line);
    } else {
      edits.push(block);
    }
  }
  let out = text;
  for (const block of [...edits].sort((a, b) => b.start - a.start)) {
    let start = block.start;
    let end = block.end;
    while (start > 0 && (out[start - 1] === " " || out[start - 1] === "\t")) start -= 1;
    const lineEnds = out[end] === "\n" || end === out.length;
    if (!lineEnds && start !== block.start) start += 1;
    if (!lineEnds) while (out[end] === " " || out[end] === "\t") end += 1;
    out = out.slice(0, start) + out.slice(end);
  }
  if (drop.size === 0) return out;
  const kept = [];
  const outLines = out.split("\n");
  const shift = outLines.length - lines.length;
  if (shift !== 0) throw new Error("A trailing-comment edit changed the line count");
  for (let line = 0; line < outLines.length; line += 1) {
    if (drop.has(line)) continue;
    const blank = outLines[line].trim() === "";
    const previousBlank = kept.length > 0 && kept[kept.length - 1].trim() === "";
    const droppedJustBefore = drop.has(line - 1);
    if (blank && previousBlank && droppedJustBefore) continue;
    if (blank && kept.length === 0 && droppedJustBefore) continue;
    kept.push(outLines[line]);
  }
  return kept.join("\n");
}

export function codeOnly(text, language) {
  let out = "";
  let at = 0;
  for (const comment of scan(text, language)) {
    out += text.slice(at, comment.start);
    at = comment.end;
  }
  out += text.slice(at);
  return out.replace(/\s+/g, "");
}

function git(...args) {
  return execFileSync("git", args, { encoding: "utf8", maxBuffer: 1 << 28 });
}

function trackedFiles() {
  return git("ls-files", "-z").split("\0").filter(Boolean);
}

export function inventory(paths = trackedFiles()) {
  const files = [];
  for (const path of paths) {
    if (!languageOf(path) || !existsSync(path)) continue;
    const text = readFileSync(path, "utf8");
    if (!isOurs(path, text)) continue;
    files.push({ path, text, language: languageOf(path) });
  }
  return files;
}

function counts() {
  const result = {};
  for (const file of inventory()) {
    const count = commentLineCount(file.text, file.language);
    if (count > 0) result[file.path] = count;
  }
  return Object.fromEntries(Object.entries(result).sort(([a], [b]) => (a < b ? -1 : 1)));
}

function readBaseline() {
  return existsSync(BASELINE) ? JSON.parse(readFileSync(BASELINE, "utf8")) : {};
}

function writeBaseline(next) {
  writeFileSync(BASELINE, `${JSON.stringify(next, null, 2)}\n`);
}

function check() {
  const baseline = readBaseline();
  const current = counts();
  const grew = [];
  const shrank = [];
  for (const [path, count] of Object.entries(current)) {
    const allowed = baseline[path] ?? 0;
    if (count > allowed) grew.push({ path, count, allowed });
    else if (count < allowed) shrank.push(path);
  }
  for (const path of Object.keys(baseline)) if (!(path in current)) shrank.push(path);

  for (const { path, count, allowed } of grew) {
    console.error(`${path}: ${count} comment lines, ${allowed} allowed.`);
  }
  if (grew.length > 0) {
    console.error(
      "\nNew comments are not allowed. Say it in the code: a name, a type, a test.\n" +
        "A decision that needs its reasons kept goes in docs/adr/.\n" +
        "List a file's comments with: node tool/comments.mjs list <path>",
    );
  }
  if (shrank.length > 0) {
    console.error(
      `\n${shrank.length} file(s) have fewer comments than ${BASELINE} allows. ` +
        "Lock that in with: node tool/comments.mjs baseline",
    );
  }
  if (grew.length > 0 || shrank.length > 0) process.exit(1);
  const total = Object.values(current).reduce((sum, n) => sum + n, 0);
  console.log(`Comments: ${total} lines in ${Object.keys(current).length} files, none above the baseline.`);
}

function baseline() {
  const old = readBaseline();
  const current = counts();
  const raised = Object.entries(current).filter(([path, count]) => count > (old[path] ?? 0));
  if (existsSync(BASELINE) && raised.length > 0) {
    for (const [path, count] of raised) console.error(`${path}: ${count} > ${old[path] ?? 0}`);
    console.error("\nThe baseline only goes down. Remove the new comments first.");
    process.exit(1);
  }
  writeBaseline(current);
  const total = Object.values(current).reduce((sum, n) => sum + n, 0);
  console.log(`Wrote ${BASELINE}: ${total} comment lines in ${Object.keys(current).length} files.`);
}

function list(paths) {
  const files = inventory(paths.length > 0 ? expand(paths) : undefined);
  for (const file of files) {
    for (const block of blocks(file.text, file.language)) {
      if (block.directive) continue;
      const line = block.startLine + 1;
      console.log(
        JSON.stringify({
          id: `${file.path}:${line}`,
          path: file.path,
          line,
          lines: block.lines,
          ownLine: block.ownLine,
          text: block.text,
        }),
      );
    }
  }
}

function expand(paths) {
  const tracked = trackedFiles();
  return tracked.filter((file) =>
    paths.some((path) => file === path || file.startsWith(path.endsWith("/") ? path : `${path}/`)),
  );
}

function remove(idsFile) {
  const wanted = new Map();
  for (const id of readFileSync(idsFile, "utf8").split("\n").map((s) => s.trim()).filter(Boolean)) {
    const at = id.lastIndexOf(":");
    const path = id.slice(0, at);
    if (!wanted.has(path)) wanted.set(path, new Set());
    wanted.get(path).add(Number(id.slice(at + 1)));
  }
  let removedCount = 0;
  for (const [path, lines] of wanted) {
    const language = languageOf(path);
    const text = readFileSync(path, "utf8");
    const found = blocks(text, language).filter((block) => lines.has(block.startLine + 1) && !block.directive);
    const missing = [...lines].filter((line) => !found.some((block) => block.startLine + 1 === line));
    if (missing.length > 0) throw new Error(`${path}: no comment block starts on line(s) ${missing.join(", ")}`);
    const next = removeBlocks(text, found);
    if (codeOnly(next, language) !== codeOnly(text, language)) {
      throw new Error(`${path}: removing comments would change the code; nothing written`);
    }
    if (next.trim() === "") unlinkSync(path);
    else writeFileSync(path, next);
    removedCount += found.length;
  }
  console.log(`Removed ${removedCount} comment blocks from ${wanted.size} files.`);
}

const DART_IMPORT = /^import\s+'[^']+'[^;]*;/gm;

export function sameCodeBesidesImports(before, after, language) {
  if (codeOnly(before, language) === codeOnly(after, language)) return true;
  if (language !== "dart") return false;
  const importsOf = (text) => new Set(text.match(DART_IMPORT) ?? []);
  const kept = importsOf(after);
  if ([...kept].some((line) => !importsOf(before).has(line))) return false;
  const strip = (text) => codeOnly(text.replace(DART_IMPORT, ""), language);
  return strip(before) === strip(after);
}

function sameCode(ref) {
  const changed = git("diff", "--name-only", "-z", ref, "--").split("\0").filter(Boolean);
  const differs = [];
  for (const path of changed) {
    const language = languageOf(path);
    if (!language) continue;
    let before;
    try {
      before = git("show", `${ref}:${path}`);
    } catch {
      continue;
    }
    const after = existsSync(path) ? readFileSync(path, "utf8") : "";
    if (!sameCodeBesidesImports(before, after, language)) differs.push(path);
  }
  if (differs.length > 0) {
    console.error(`Code changed, not only comments, in:\n${differs.join("\n")}`);
    process.exit(1);
  }
  console.log(`Only comments, whitespace and unused Dart imports differ from ${ref} in the changed source files.`);
}

function stats(paths) {
  const files = inventory(paths.length > 0 ? expand(paths) : undefined);
  let blockCount = 0;
  let commentLines = 0;
  let ownLines = 0;
  let trailing = 0;
  let directives = 0;
  const byArea = {};
  for (const file of files) {
    const area = file.path.split("/").slice(0, 2).join("/");
    for (const block of blocks(file.text, file.language)) {
      if (block.directive) {
        directives += 1;
        continue;
      }
      blockCount += 1;
      commentLines += block.lines;
      if (block.ownLine) ownLines += block.lines;
      else trailing += 1;
      byArea[area] = (byArea[area] ?? 0) + block.lines;
    }
  }
  console.log(JSON.stringify({ files: files.length, blocks: blockCount, commentLines, ownLines, trailing, directives, byArea }, null, 2));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [command, ...rest] = process.argv.slice(2);
  const commands = {
    check: () => check(),
    baseline: () => baseline(),
    list: () => list(rest),
    remove: () => remove(rest[0]),
    "same-code": () => sameCode(rest[0] ?? "origin/main"),
    stats: () => stats(rest),
  };
  if (!commands[command]) {
    console.error("usage: node tool/comments.mjs check | baseline | list [paths] | remove <ids-file> | same-code [ref] | stats [paths]");
    process.exit(2);
  }
  commands[command]();
}
