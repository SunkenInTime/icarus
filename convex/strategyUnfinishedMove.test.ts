import {
  convexTest,
  type TestConvexForDataModel,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { describe, expect, test } from "vitest";
import type { DataModel } from "./_generated/dataModel";
import { markAssetReferencesReady } from "./lib/assetReferences";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import schema from "./schema";
import { modules } from "./test.setup";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createFolder = makeFunctionReference<"mutation">("folders:create");
const listTree = makeFunctionReference<"query">("folders:listTree");
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const finishMove = makeFunctionReference<"mutation">("strategies:finishMove");
const listStrategies = makeFunctionReference<"query">(
  "strategies:listForFolder",
);
const getShell = makeFunctionReference<"query">("strategy:getShell");

type Harness = TestConvexForDataModel<DataModel>;

const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };

function identity(subject: string) {
  return {
    issuer: "https://unfinished-move.test",
    subject,
    tokenIdentifier: `unfinished-move|${subject}`,
    name: `User ${subject}`,
  };
}

async function createHarness(): Promise<{ owner: Harness; other: Harness }> {
  const t = convexTest(schema, modules);
  await t.run(markAssetReferencesReady);
  const owner = t.withIdentity(identity("owner"));
  const other = t.withIdentity(identity("other"));
  await owner.mutation(ensureCurrentUser, protocol);
  await other.mutation(ensureCurrentUser, protocol);
  return { owner, other };
}

async function create(
  t: Harness,
  publicId: string,
  extra: { folderPublicId?: string; unfinishedMove?: boolean } = {},
) {
  await t.mutation(createStrategy, {
    ...protocol,
    publicId,
    name: publicId,
    mapData: "ascent",
    initialPagePublicId: `${publicId}-page`,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
    ...extra,
  });
}

async function listedIds(t: Harness, folderPublicId?: string) {
  const strategies = (await t.query(listStrategies, {
    ...(folderPublicId === undefined ? {} : { folderPublicId }),
    scope: "owned",
  })) as Array<{ publicId: string }>;
  return strategies.map((strategy) => strategy.publicId).sort();
}

async function folderCount(t: Harness, folderPublicId: string) {
  const tree = (await t.query(listTree, { scope: "all" })) as Array<{
    publicId: string;
    strategyCount: number;
  }>;
  return tree.find((folder) => folder.publicId === folderPublicId)!
    .strategyCount;
}

describe("a strategy moving in from a device", () => {
  test("stays out of the library until the move finishes", async () => {
    const { owner } = await createHarness();
    await owner.mutation(createFolder, {
      ...protocol,
      publicId: "plays",
      name: "Plays",
    });
    await create(owner, "made-here");
    await create(owner, "moving-root", { unfinishedMove: true });
    await create(owner, "moving-in-folder", {
      folderPublicId: "plays",
      unfinishedMove: true,
    });

    expect(await listedIds(owner)).toEqual(["made-here"]);
    expect(await listedIds(owner, "plays")).toEqual([]);
    expect(await folderCount(owner, "plays")).toBe(0);
    // The moving device still reads it whole, to check it landed.
    const shell = (await owner.query(getShell, {
      ...protocol,
      strategyPublicId: "moving-root",
    })) as { header: { publicId: string } };
    expect(shell.header.publicId).toBe("moving-root");

    await owner.mutation(finishMove, {
      ...protocol,
      strategyPublicId: "moving-root",
    });
    await owner.mutation(finishMove, {
      ...protocol,
      strategyPublicId: "moving-in-folder",
    });
    expect(await listedIds(owner)).toEqual(["made-here", "moving-root"]);
    expect(await listedIds(owner, "plays")).toEqual(["moving-in-folder"]);
    expect(await folderCount(owner, "plays")).toBe(1);

    // Finishing twice changes nothing.
    await owner.mutation(finishMove, {
      ...protocol,
      strategyPublicId: "moving-root",
    });
    expect(await listedIds(owner)).toEqual(["made-here", "moving-root"]);
  });

  test("only its owner can finish the move", async () => {
    const { owner, other } = await createHarness();
    await create(owner, "moving", { unfinishedMove: true });

    await expect(
      other.mutation(finishMove, { ...protocol, strategyPublicId: "moving" }),
    ).rejects.toThrow();
    expect(await listedIds(owner)).toEqual([]);
  });

  test("a create without the flag is listed at once, as before", async () => {
    const { owner } = await createHarness();
    await create(owner, "plain", { unfinishedMove: false });

    expect(await listedIds(owner)).toEqual(["plain"]);
  });
});
