import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { afterEach, expect, test, vi } from "vitest";
import type { DataModel } from "./_generated/dataModel";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import schema from "./schema";
import { modules } from "./test.setup";

// A client deleting a folder deletes what it listed in it, one call at a
// time. What someone moves out meanwhile must survive.

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createFolder = makeFunctionReference<"mutation">("folders:create");
const moveFolder = makeFunctionReference<"mutation">("folders:move");
const deleteFolder = makeFunctionReference<"mutation">("folders:delete");
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const moveStrategy = makeFunctionReference<"mutation">("strategies:move");
const deleteStrategy = makeFunctionReference<"mutation">("strategies:delete");

const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;

afterEach(() => {
  vi.useRealTimers();
});

/// maps > ascent > retakes, with a strategy in retakes, and bind beside.
async function library(): Promise<{ t: RootHarness; owner: Harness }> {
  vi.useFakeTimers();
  const t = convexTest(schema, modules);
  const owner = t.withIdentity({
    issuer: "https://tree-delete.test",
    subject: "owner",
    tokenIdentifier: "tree-delete|owner",
    name: "Owner",
  });
  await owner.mutation(ensureCurrentUser, protocol);
  for (const [publicId, parent] of [
    ["maps", undefined],
    ["ascent", "maps"],
    ["retakes", "ascent"],
    ["bind", undefined],
  ] as const) {
    await owner.mutation(createFolder, {
      ...protocol,
      publicId,
      name: publicId,
      parentFolderPublicId: parent,
    });
  }
  await owner.mutation(createStrategy, {
    ...protocol,
    publicId: "b-retake",
    name: "B retake",
    mapData: "ascent",
    folderPublicId: "retakes",
    initialPagePublicId: "b-retake-page",
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
  return { t, owner };
}

async function revisionOf(t: RootHarness, publicId: string) {
  return await t.run(async (ctx) => {
    const strategy = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", publicId))
      .unique();
    return strategy?.revision ?? null;
  });
}

async function folderExists(t: RootHarness, publicId: string) {
  return await t.run(
    async (ctx) =>
      (await ctx.db
        .query("folders")
        .withIndex("by_publicId", (q) => q.eq("publicId", publicId))
        .unique()) !== null,
  );
}

test("a strategy anywhere below the folder being deleted is deleted", async () => {
  const { t, owner } = await library();

  await owner.mutation(deleteStrategy, {
    ...protocol,
    strategyPublicId: "b-retake",
    expectedRevision: (await revisionOf(t, "b-retake"))!,
    withinFolderPublicId: "maps",
  });

  expect(await revisionOf(t, "b-retake")).toBeNull();
});

test("a strategy moved out of the folder being deleted is kept", async () => {
  const { t, owner } = await library();
  await owner.mutation(moveStrategy, {
    ...protocol,
    strategyPublicId: "b-retake",
    expectedRevision: (await revisionOf(t, "b-retake"))!,
    folderPublicId: "bind",
  });

  await expect(
    owner.mutation(deleteStrategy, {
      ...protocol,
      strategyPublicId: "b-retake",
      expectedRevision: (await revisionOf(t, "b-retake"))!,
      withinFolderPublicId: "maps",
    }),
  ).rejects.toThrow("Not inside the folder being deleted");

  expect(await revisionOf(t, "b-retake")).not.toBeNull();
});

test("a subfolder moved out keeps itself and what is in it", async () => {
  const { t, owner } = await library();
  await owner.mutation(createFolder, {
    ...protocol,
    publicId: "empty",
    name: "empty",
    parentFolderPublicId: "ascent",
  });
  await owner.mutation(moveFolder, {
    ...protocol,
    folderPublicId: "ascent",
    parentFolderPublicId: "bind",
  });

  // The folder move left the strategy's revision as it was, so only the
  // folder check can tell.
  await expect(
    owner.mutation(deleteStrategy, {
      ...protocol,
      strategyPublicId: "b-retake",
      expectedRevision: (await revisionOf(t, "b-retake"))!,
      withinFolderPublicId: "maps",
    }),
  ).rejects.toThrow("Not inside the folder being deleted");
  await expect(
    owner.mutation(deleteFolder, {
      ...protocol,
      folderPublicId: "empty",
      withinFolderPublicId: "maps",
    }),
  ).rejects.toThrow("Not inside the folder being deleted");

  expect(await revisionOf(t, "b-retake")).not.toBeNull();
  expect(await folderExists(t, "empty")).toBe(true);
});

test("an empty folder anywhere below the folder being deleted is deleted", async () => {
  const { t, owner } = await library();
  await owner.mutation(createFolder, {
    ...protocol,
    publicId: "empty",
    name: "empty",
    parentFolderPublicId: "retakes",
  });

  await owner.mutation(deleteFolder, {
    ...protocol,
    folderPublicId: "empty",
    withinFolderPublicId: "maps",
  });

  expect(await folderExists(t, "empty")).toBe(false);
});

test("the folder being deleted is within itself", async () => {
  const { t, owner } = await library();
  await owner.mutation(deleteFolder, {
    ...protocol,
    folderPublicId: "bind",
    withinFolderPublicId: "bind",
  });

  expect(await folderExists(t, "bind")).toBe(false);
});

test("without the folder, deletes work as before for clients that never send it", async () => {
  const { t, owner } = await library();
  await owner.mutation(moveStrategy, {
    ...protocol,
    strategyPublicId: "b-retake",
    expectedRevision: (await revisionOf(t, "b-retake"))!,
    folderPublicId: "bind",
  });

  await owner.mutation(deleteStrategy, {
    ...protocol,
    strategyPublicId: "b-retake",
    expectedRevision: (await revisionOf(t, "b-retake"))!,
  });
  await owner.mutation(deleteFolder, { ...protocol, folderPublicId: "bind" });

  expect(await revisionOf(t, "b-retake")).toBeNull();
  expect(await folderExists(t, "bind")).toBe(false);
});
