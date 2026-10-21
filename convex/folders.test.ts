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

const listStrategiesForFolder = makeFunctionReference<"query">(
  "strategies:listForFolder",
);

test("strategy lists carry each strategy's agents only when asked", async () => {
  const { owner } = await createHarness();
  await seedFolder(owner, "root");
  await seedStrategy(owner, "s-agents", "root", "ascent");
  await seedStrategy(owner, "s-empty", "root", "haven");
  await placeAgent(owner, "s-agents", "e1", "jett");
  await placeAgent(owner, "s-agents", "e2", "sova");
  await placeAgent(owner, "s-agents", "e3", "sova");

  const asked = (await owner.query(listStrategiesForFolder, {
    folderPublicId: "root",
    includeAgentTypes: true,
  })) as Array<Record<string, unknown>>;
  const byId = new Map(asked.map((entry) => [entry.publicId, entry]));
  expect(byId.get("s-agents")?.agentTypes).toEqual(["sova", "jett"]);
  expect(byId.get("s-empty")?.agentTypes).toEqual([]);

  // Builds that predate the field reject any field they don't know, so a
  // caller that doesn't ask gets the answer it always got.
  const unasked = (await owner.query(listStrategiesForFolder, {
    folderPublicId: "root",
  })) as Array<Record<string, unknown>>;
  expect(unasked).toHaveLength(2);
  for (const entry of unasked) {
    expect(entry).not.toHaveProperty("agentTypes");
  }
});

test("a strategy's agents follow moves, swaps and deletes", async () => {
  const { owner } = await createHarness();
  await seedFolder(owner, "root");
  await seedStrategy(owner, "s", "root", "ascent");
  await placeAgent(owner, "s", "e1", "jett");
  await placeAgent(owner, "s", "e2", "sova");
  const agentsOf = async () => {
    const listed = (await owner.query(listStrategiesForFolder, {
      folderPublicId: "root",
      includeAgentTypes: true,
    })) as Array<Record<string, unknown>>;
    return listed[0]?.agentTypes;
  };
  const patch = (opId: string, agentType: string, x: number, revision: number) =>
    owner.mutation(applyBatch, {
      clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
      strategyPublicId: "s",
      clientId: "client-a",
      ops: [
        {
          opId,
          type: "element.patch",
          elementPublicId: "e1",
          payload: {
            kind: "agent",
            payloadVersion: 1,
            data: { type: agentType, position: { x, y: 0.5 } },
          },
          expectedElementRevision: revision,
        },
      ],
    });
  expect(await agentsOf()).toEqual(["jett", "sova"]);

  await patch("move", "jett", 0.25, 1);
  expect(await agentsOf()).toEqual(["jett", "sova"]);

  await patch("swap", "omen", 0.25, 2);
  expect(await agentsOf()).toEqual(["omen", "sova"]);

  await owner.mutation(applyBatch, {
    clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION,
    strategyPublicId: "s",
    clientId: "client-a",
    ops: [
      {
        opId: "delete",
        type: "element.delete",
        elementPublicId: "e2",
        pagePublicId: "s-page",
        expectedElementRevision: 1,
      },
    ],
  });
  expect(await agentsOf()).toEqual(["omen"]);
});

test("summaries keep only agent-shaped names, however a peer wrote them", async () => {
  const { t, owner } = await createHarness();
  await seedFolder(owner, "root");
  await seedFolder(owner, "child", "root");
  await seedStrategy(owner, "s", "child", "ascent");
  await placeAgent(owner, "s", "e1", "jett");
  // An editor can write any data for an agent: these are not agent names.
  await placeAgent(owner, "s", "e2", "x".repeat(100_000));
  await placeAgent(owner, "s", "e3", "jett ");
  await placeAgent(owner, "s", "e4", "a".repeat(33));
  // A summary stored before names were checked.
  await seedStrategy(owner, "old", "child", "ascent");
  await t.run(async (ctx) => {
    const old = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", "old"))
      .unique();
    await ctx.db.insert("strategyAgentSummaries", {
      strategyId: old!._id,
      agentTypes: ["y".repeat(100_000), "sova"],
      updatedAt: 0,
    });
  });

  const stored = await t.run(async (ctx) => {
    const s = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", "s"))
      .unique();
    return await ctx.db
      .query("strategyAgentSummaries")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", s!._id))
      .unique();
  });
  expect(stored?.agentTypes).toEqual(["jett"]);

  const listed = (await owner.query(listStrategiesForFolder, {
    folderPublicId: "child",
    includeAgentTypes: true,
  })) as Array<Record<string, unknown>>;
  expect(
    Object.fromEntries(listed.map((entry) => [entry.publicId, entry.agentTypes])),
  ).toEqual({ s: ["jett"], old: ["sova"] });

  const tree = (await owner.query(listFolderTree, { scope: "owned" })) as Array<
    Record<string, unknown>
  >;
  for (const folder of tree) {
    expect(folder.agentTypes).toEqual(["jett", "sova"]);
  }
});

test("a folder lists at most 32 agents", async () => {
  const { owner } = await createHarness();
  await seedFolder(owner, "root");
  // Agent-shaped names an editor made up, one strategy at a time.
  const names = Array.from({ length: 40 }, (_, index) =>
    `agent${String.fromCharCode(97 + Math.floor(index / 26))}${String.fromCharCode(97 + (index % 26))}`,
  );
  await seedStrategy(owner, "s", "root", "ascent");
  for (const [index, name] of names.entries()) {
    await placeAgent(owner, "s", `e${index}`, name);
  }
  await seedStrategy(owner, "s2", "root", "ascent");
  await placeAgent(owner, "s2", "jett-1", "jett");

  const tree = (await owner.query(listFolderTree, { scope: "owned" })) as Array<
    Record<string, unknown>
  >;
  const agents = tree[0]!.agentTypes as string[];
  expect(agents).toHaveLength(32);
  const listed = (await owner.query(listStrategiesForFolder, {
    folderPublicId: "root",
    includeAgentTypes: true,
  })) as Array<Record<string, unknown>>;
  for (const entry of listed) {
    expect((entry.agentTypes as string[]).length).toBeLessThanOrEqual(32);
  }
});


test("folder previews skip a stored map no build knows", async () => {
  const { t, owner } = await createHarness();
  await seedFolder(owner, "root");
  await seedFolder(owner, "child", "root");
  await seedStrategy(owner, "s-junk", "child", "ascent");
  await seedStrategy(owner, "s-haven", "child", "haven");
  // Written before maps were checked.
  await t.run(async (ctx) => {
    const strategy = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", "s-junk"))
      .unique();
    await ctx.db.patch(strategy!._id, { mapData: "x".repeat(100_000) });
  });

  const tree = (await owner.query(listFolderTree, { scope: "owned" })) as Array<
    Record<string, unknown>
  >;
  for (const folder of tree) {
    expect(folder).toMatchObject({ strategyCount: 2, mapPeeks: ["haven"] });
  }
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
