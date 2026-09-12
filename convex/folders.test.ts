import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { expect, test } from "vitest";
import type { DataModel } from "./_generated/dataModel";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import schema from "./schema";
import { modules } from "./test.setup";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createFolder = makeFunctionReference<"mutation">("folders:create");
const moveFolder = makeFunctionReference<"mutation">("folders:move");

const identity = {
  issuer: "https://folders.test",
  subject: "owner",
  tokenIdentifier: "folders|owner",
  name: "Folder Owner",
};

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;

async function createHarness(): Promise<{
  t: RootHarness;
  owner: Harness;
}> {
  const t = convexTest(schema, modules);
  const owner = t.withIdentity(identity);
  await owner.mutation(ensureCurrentUser, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
  });
  return { t, owner };
}

async function seedFolder(
  owner: Harness,
  publicId: string,
  parentFolderPublicId?: string,
) {
  await owner.mutation(createFolder, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    publicId,
    name: publicId,
    parentFolderPublicId,
  });
}

async function parentPublicId(t: RootHarness, publicId: string) {
  return await t.run(async (ctx) => {
    const folder = await ctx.db
      .query("folders")
      .withIndex("by_publicId", (q) => q.eq("publicId", publicId))
      .unique();
    if (folder === null) {
      throw new Error(`Missing folder ${publicId}`);
    }
    if (folder.parentFolderId === undefined) {
      return null;
    }
    return (await ctx.db.get(folder.parentFolderId))?.publicId ?? null;
  });
}

test("folder move rejects self-parent without changing the folder", async () => {
  const { t, owner } = await createHarness();
  await seedFolder(owner, "root");

  await expect(
    owner.mutation(moveFolder, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      folderPublicId: "root",
      parentFolderPublicId: "root",
    }),
  ).rejects.toThrow("Folder move would create a cycle");

  await expect(parentPublicId(t, "root")).resolves.toBeNull();
});

test("folder move rejects a descendant parent without changing the tree", async () => {
  const { t, owner } = await createHarness();
  await seedFolder(owner, "root");
  await seedFolder(owner, "child", "root");
  await seedFolder(owner, "grandchild", "child");

  await expect(
    owner.mutation(moveFolder, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      folderPublicId: "root",
      parentFolderPublicId: "grandchild",
    }),
  ).rejects.toThrow("Folder move would create a cycle");

  await expect(parentPublicId(t, "root")).resolves.toBeNull();
  await expect(parentPublicId(t, "child")).resolves.toBe("root");
  await expect(parentPublicId(t, "grandchild")).resolves.toBe("child");
});

const listFolderTree = makeFunctionReference<"query">("folders:listTree");
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");
const deleteStrategy = makeFunctionReference<"mutation">("strategies:delete");

async function seedStrategy(
  owner: Harness,
  publicId: string,
  folderPublicId: string,
  mapData: string,
) {
  await owner.mutation(createStrategy, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    publicId,
    name: publicId,
    mapData,
    folderPublicId,
    initialPagePublicId: `${publicId}-page`,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
    initialPageSettings: {
      agentSize: 48,
      abilitySize: 32,
      useNeutralTeamColors: false,
    },
  });
}

async function placeAgent(
  owner: Harness,
  strategyPublicId: string,
  elementPublicId: string,
  agentType: string,
) {
  await owner.mutation(applyBatch, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    strategyPublicId,
    clientId: "client-a",
    ops: [
      {
        opId: `${elementPublicId}-add`,
        type: "element.add",
        elementPublicId,
        pagePublicId: `${strategyPublicId}-page`,
        payload: {
          kind: "agent",
          payloadVersion: 1,
          data: { type: agentType, position: { x: 0.5, y: 0.5 } },
        },
        sortIndex: 0,
      },
    ],
  });
}

test("folder tree summarises strategies, maps, and agents across the subtree", async () => {
  const { owner } = await createHarness();
  await seedFolder(owner, "root");
  await seedFolder(owner, "child", "root");
  await seedStrategy(owner, "s-root", "root", "ascent");
  await seedStrategy(owner, "s-child-1", "child", "haven");
  await seedStrategy(owner, "s-child-2", "child", "haven");
  await placeAgent(owner, "s-root", "e1", "jett");
  await placeAgent(owner, "s-child-1", "e2", "sova");
  await placeAgent(owner, "s-child-2", "e3", "sova");

  const tree = (await owner.query(listFolderTree, { scope: "owned" })) as Array<
    Record<string, unknown>
  >;
  const byId = new Map(tree.map((entry) => [entry.publicId, entry]));
  expect(byId.get("child")).toMatchObject({
    strategyCount: 2,
    mapPeeks: ["haven"],
    agentTypes: ["sova"],
  });
  expect(byId.get("root")).toMatchObject({
    strategyCount: 3,
    mapPeeks: ["haven", "ascent"],
    agentTypes: ["sova", "jett"],
  });
});

test("deleting a strategy drops it from the folder summary", async () => {
  const { owner } = await createHarness();
  await seedFolder(owner, "root");
  await seedStrategy(owner, "s-root", "root", "ascent");
  await placeAgent(owner, "s-root", "e1", "jett");
  await owner.mutation(deleteStrategy, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    strategyPublicId: "s-root",
    expectedRevision: 0,
  });

  const tree = (await owner.query(listFolderTree, { scope: "owned" })) as Array<
    Record<string, unknown>
  >;
  expect(tree[0]).toMatchObject({
    strategyCount: 0,
    mapPeeks: [],
    agentTypes: [],
  });
});
