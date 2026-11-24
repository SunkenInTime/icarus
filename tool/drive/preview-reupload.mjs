import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const [preview, strategyName, mode] = process.argv.slice(2);
if (!preview || !strategyName) {
  console.error("usage: preview-reupload.mjs <preview name> <strategy name>");
  process.exit(2);
}
const protocol = 6;

const cli = fileURLToPath(
  new URL("../../node_modules/convex/bin/main.js", import.meta.url),
);

function convex(args) {
  return execFileSync(
    process.execPath,
    [cli, ...args, "--preview-name", preview],
    { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] },
  );
}

function table(name) {
  return convex(["data", name, "--limit", "10000", "--format", "jsonLines"])
    .split("\n")
    .filter((line) => line.trim().startsWith("{"))
    .map((line) => JSON.parse(line));
}

function run(fn, args, identity) {
  return convex([
    "run",
    fn,
    JSON.stringify(args),
    "--identity",
    JSON.stringify(identity),
  ]);
}

function rowsOf(strategy) {
  const pages = table("pages").filter((p) => p.strategyId === strategy._id);
  const elements = table("elements").filter(
    (e) => e.strategyId === strategy._id,
  );
  return { strategy, pages, elements };
}

const strategy = table("strategies").find((s) => s.name === strategyName);
if (!strategy) throw new Error(`no strategy named ${strategyName}`);
const before = rowsOf(strategy);
if (mode === "show") {
  console.log(JSON.stringify({ now: before }));
  process.exit(0);
}
console.log(JSON.stringify({ before }));
const owner = table("users").find((u) => u._id === strategy.ownerId);
const [issuer, subject] = owner.externalId.split("|");
const identity = { tokenIdentifier: owner.externalId, issuer, subject };

const live = before.pages
  .filter((p) => p.deletedAt === undefined)
  .sort((a, b) => a.sortIndex - b.sortIndex);
if (live.length !== 1) throw new Error("expected a strategy of one page");
const page = live[0];

run(
  "strategies:delete",
  {
    clientProtocolVersion: protocol,
    strategyPublicId: strategy.publicId,
    expectedRevision: strategy.revision,
  },
  identity,
);
run(
  "strategies:createWithInitialPage",
  {
    clientProtocolVersion: protocol,
    publicId: strategy.publicId,
    name: strategy.name,
    mapData: strategy.mapData,
    initialPagePublicId: page.publicId,
    initialPageName: page.name,
    initialPageIsAttack: page.isAttack,
    ...(page.isAutoNamed === undefined
      ? {}
      : { initialPageIsAutoNamed: page.isAutoNamed }),
  },
  identity,
);
const again = table("strategies").find(
  (s) => s.publicId === strategy.publicId,
);
console.log(JSON.stringify({ after: rowsOf(again) }));
