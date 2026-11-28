import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";

const root = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(root);

type Definition = { file: string; name: string; body: string };

const ALLOWED: Array<{ file: string; function: string; why: string }> = [
  {
    file: "convex/pages.ts",
    function: "listTrashed",
    why:
      "pages:listTrashed leaves out pages past their time in the trash, as shipped clients expect; " +
      "they only fetch it once (the Recently deleted dialog and the trashed-pages check), never subscribe",
  },
];

function sourceFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      return entry.name === "_generated" || entry.name === "node_modules"
        ? []
        : sourceFiles(path);
    }
    return /\.ts$/.test(entry.name) &&
      !/\.(test|setup|helpers)\.ts$/.test(entry.name)
      ? [path]
      : [];
  });
}

const withoutComments = (source: string) =>
  source.replace(/\/\*[\s\S]*?\*\/|\/\/.*$/gm, "");

const QUERY = /^(?:export )?const (\w+) = (?:internalQuery|query)\(/;
const FUNCTION =
  /^(?:export )?(?:async )?function\*? (\w+)|^(?:export )?const (\w+)(?::[^=]+)? = (?:async )?(?:\(|<|function\b|\w+ =>)/;

function definitionsIn(file: string, source: string) {
  const lines = withoutComments(source).split("\n");
  const queries: Definition[] = [];
  const functions: Definition[] = [];
  lines.forEach((line, start) => {
    const query = QUERY.exec(line);
    const fn = query === null ? FUNCTION.exec(line) : null;
    const name = query?.[1] ?? fn?.[1] ?? fn?.[2];
    if (name === undefined) return;
    let end = start + 1;
    while (end < lines.length && !/^[^\s})\]]/.test(lines[end]!)) end++;
    const body = lines.slice(start, end).join("\n");
    (query === null ? functions : queries).push({ file, name, body });
  });
  return { queries, functions };
}

function clockReadingQueries(sources: Array<[string, string]>) {
  const queries: Definition[] = [];
  const functions = new Map<string, Definition[]>();
  for (const [file, source] of sources) {
    const found = definitionsIn(file, source);
    queries.push(...found.queries);
    for (const fn of found.functions) {
      functions.set(fn.name, [...(functions.get(fn.name) ?? []), fn]);
    }
  }
  const readsClock = (body: string) =>
    /\bDate\.now\s*\(\s*\)|\bnew Date\s*(\(\s*\)|[^(\s])/.test(body);
  const calls = (body: string) =>
    [...new Set(body.match(/[A-Za-z_$][\w$]*/g) ?? [])].flatMap(
      (name) => functions.get(name) ?? [],
    );

  return queries.flatMap((query) => {
    const seen = new Set<Definition>([query]);
    const queue: Array<{ at: Definition; chain: Definition[] }> = [
      { at: query, chain: [query] },
    ];
    const readers: Definition[][] = [];
    while (queue.length > 0) {
      const { at, chain } = queue.shift()!;
      if (readsClock(at.body)) readers.push(chain);
      for (const next of calls(at.body)) {
        if (seen.has(next)) continue;
        seen.add(next);
        queue.push({ at: next, chain: [...chain, next] });
      }
    }
    return readers.length === 0 ? [] : [{ query, readers }];
  });
}

const where = ({ file, name }: Definition) => `${name} (${file})`;

describe("no query reads the clock", () => {
  const sources = sourceFiles(root).map(
    (path) =>
      [
        relative(repoRoot, path).split("\\").join("/"),
        readFileSync(path, "utf8"),
      ] as [string, string],
  );
  const found = clockReadingQueries(sources);

  test("except those allowed, each with its reason", () => {
    const allowed = (query: Definition) =>
      ALLOWED.some(
        (entry) => entry.file === query.file && entry.function === query.name,
      );
    const offenders = found
      .filter(({ query }) => !allowed(query))
      .map(
        ({ query, readers }) =>
          `query ${where(query)} reads Date.now() or new Date(), so its ` +
          "cache is dropped as time passes and it still isn't re-run when " +
          "time does: " +
          readers.map((chain) => chain.map(where).join(" -> ")).join("; "),
      );
    expect(offenders).toEqual([]);
  });

  test("every allowed use is still there", () => {
    const stale = ALLOWED.filter(
      (entry) =>
        !found.some(
          ({ query }) =>
            query.file === entry.file && query.name === entry.function,
        ),
    );
    expect(stale).toEqual([]);
  });
});
