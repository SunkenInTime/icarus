import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const toolDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(toolDirectory, "..");
const functionSpecPath = resolve(repositoryRoot, "convex/function_spec.json");
const errorCodesPath = resolve(repositoryRoot, "convex/error_codes.json");
const errorsSourcePath = resolve(repositoryRoot, "convex/lib/errors.ts");
const checkOnly = process.argv.includes("--check");

function sortObjectKeys(value) {
  if (Array.isArray(value)) {
    return value.map(sortObjectKeys);
  }
  if (value === null || typeof value !== "object") {
    return value;
  }
  return Object.fromEntries(
    Object.entries(value)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, child]) => [key, sortObjectKeys(child)]),
  );
}

function readFunctionSpec() {
  const executable = process.execPath;
  const args = [
    resolve(repositoryRoot, "node_modules", "convex", "bin", "main.js"),
    "function-spec",
  ];
  const previewName = process.env.CONVEX_PREVIEW_NAME;
  if (previewName) {
    args.push("--preview-name", previewName);
  }
  const raw = execFileSync(executable, args, {
    cwd: repositoryRoot,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    stdio: ["ignore", "pipe", "inherit"],
  });
  const liveSpec = JSON.parse(raw);
  return sortObjectKeys({
    functions: [...liveSpec.functions].sort((left, right) =>
      left.identifier.localeCompare(right.identifier),
    ),
  });
}

function readErrorCodes() {
  const source = readFileSync(errorsSourcePath, "utf8");
  const declaration = source.match(
    /export const errorCodes\s*=\s*\[([\s\S]*?)\]\s*as const/,
  );
  if (declaration === null) {
    throw new Error("convex/lib/errors.ts must export errorCodes as a const array");
  }
  const codes = [...declaration[1].matchAll(/"([A-Z][A-Z0-9_]*)"/g)].map(
    (match) => match[1],
  );
  if (codes.length === 0) {
    throw new Error("errorCodes must contain at least one code");
  }
  return [...new Set(codes)].sort();
}

function asJson(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

function writeOrCheck(path, contents) {
  if (!checkOnly) {
    writeFileSync(path, contents);
    return;
  }
  const committed = readFileSync(path, "utf8");
  if (committed.replaceAll("\r\n", "\n") !== contents) {
    throw new Error(`${path} is stale; run npm run snapshot:convex-contract`);
  }
}

writeOrCheck(functionSpecPath, asJson(readFunctionSpec()));
writeOrCheck(errorCodesPath, asJson(readErrorCodes()));

console.log(
  checkOnly
    ? "Convex contract snapshots are current."
    : "Wrote scrubbed Convex contract snapshots.",
);
