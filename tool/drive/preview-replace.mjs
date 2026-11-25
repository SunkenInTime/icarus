import { execFileSync, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { fileURLToPath } from "node:url";

const [strategyName, teammateSubject, mode] = process.argv.slice(2);
if (strategyName === "logs") {
  const seconds = Number(teammateSubject);
  const cliPath = fileURLToPath(
    new URL("../../node_modules/convex/bin/main.js", import.meta.url),
  );
  const child = spawn(
    process.execPath,
    [
      cliPath,
      "logs",
      "--jsonl",
      "--preview-name",
      process.env.ICARUS_PREVIEW_NAME,
    ],
    {
      env: process.env,
      stdio: ["ignore", "pipe", "ignore"],
    },
  );
  child.stdout.on("data", (chunk) => process.stdout.write(chunk));
  setTimeout(() => {
    child.kill();
    process.exit(0);
  }, seconds * 1000);
} else if (!strategyName || !teammateSubject) {
  console.error(
    "usage: dev-replace.mjs <strategy name> <teammate subject> [show|logs]",
  );
  process.exit(2);
}
const protocol = 6;
const cli = fileURLToPath(
  new URL("../../node_modules/convex/bin/main.js", import.meta.url),
);
const preview = process.env.ICARUS_PREVIEW_NAME;
if (!preview || !process.env.CONVEX_DEPLOY_KEY?.startsWith("preview:")) {
  console.error(
    "run this through preview-replace.ps1, which gives it a preview",
  );
  process.exit(2);
}
const env = process.env;

function convex(args) {
  return execFileSync(
    process.execPath,
    [cli, ...args, "--preview-name", preview],
    {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "inherit"],
      env,
    },
  );
}

function table(name) {
  return convex(["data", name, "--limit", "10000", "--format", "jsonLines"])
    .split("\n")
    .filter((line) => line.trim().startsWith("{"))
    .map((line) => JSON.parse(line));
}

function identityOf(user) {
  const [issuer, subject] = user.externalId.split("|");
  return { tokenIdentifier: user.externalId, issuer, subject };
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

if (strategyName !== "logs") await replace();

async function replace() {
  const strategy = table("strategies").find((s) => s.name === strategyName);
  if (!strategy) throw new Error(`no strategy named ${strategyName}`);
  const shape = (row) => ({
    publicId: row.publicId,
    revision: row.revision,
    createdAt: row.createdAt,
  });
  const users = table("users");
  const owner = users.find((u) => u._id === strategy.ownerId);
  const teammate = users.find(
    (u) =>
      u.externalId === teammateSubject ||
      u.externalId.endsWith(`|${teammateSubject}`),
  );
  if (!teammate) throw new Error(`no user for ${teammateSubject}`);
  const pagesOf = (id) =>
    table("pages").filter(
      (p) => p.strategyId === id && p.deletedAt === undefined,
    );
  const elementsOf = (id) =>
    table("elements")
      .filter((e) => e.strategyId === id)
      .map(shape);
  console.log(
    JSON.stringify({
      before: {
        strategy: shape(strategy),
        pages: pagesOf(strategy._id).map(shape),
        elements: elementsOf(strategy._id),
      },
    }),
  );
  if (mode === "show") return;

  const page = pagesOf(strategy._id).sort(
    (a, b) => a.sortIndex - b.sortIndex,
  )[0];
  run(
    "strategies:delete",
    {
      clientProtocolVersion: protocol,
      strategyPublicId: strategy.publicId,
      expectedRevision: strategy.revision,
    },
    identityOf(owner),
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
    },
    identityOf(owner),
  );
  const token = randomBytes(12).toString("hex");
  run(
    "shares:create",
    {
      clientProtocolVersion: protocol,
      targetType: "strategy",
      targetPublicId: strategy.publicId,
      token,
      role: "editor",
    },
    identityOf(owner),
  );
  run(
    "shares:redeem",
    { clientProtocolVersion: protocol, token },
    identityOf(teammate),
  );
  const again = table("strategies").find(
    (s) => s.publicId === strategy.publicId,
  );
  console.log(
    JSON.stringify({
      replacedAt: Date.now(),
      after: {
        strategy: shape(again),
        pages: pagesOf(again._id).map(shape),
        elements: elementsOf(again._id),
      },
    }),
  );
}
