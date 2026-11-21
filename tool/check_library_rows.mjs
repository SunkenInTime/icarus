import { spawnSync } from "node:child_process";
import { existsSync, statSync } from "node:fs";
import { resolve } from "node:path";

const args = process.argv.slice(2);
const detail = args.includes("--detail");
const folders = args.filter((arg) => arg !== "--detail");

if (folders.length !== 1) {
  console.error(
    "usage: node tool/check_library_rows.mjs <folder of Hive stores and .ica files> [--detail]",
  );
  process.exit(2);
}

const folder = resolve(folders[0]);
if (!existsSync(folder) || !statSync(folder).isDirectory()) {
  console.error(`not a folder: ${folder}`);
  process.exit(2);
}

const result = spawnSync(
  "flutter",
  [
    "test",
    "--no-pub",
    "--reporter",
    "silent",
    "--plain-name",
    "corpus",
    "test/library_rows/library_corpus_test.dart",
    "test/library_rows/strategy_diff_test.dart",
  ],
  {
    stdio: "inherit",
    shell: process.platform === "win32",
    env: {
      ...process.env,
      ICARUS_LIBRARY_CORPUS: folder,
      ICARUS_LIBRARY_DETAIL: detail ? "1" : "0",
    },
  },
);
process.exit(result.status ?? 1);
