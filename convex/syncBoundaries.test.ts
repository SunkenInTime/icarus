import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { beforeAll, describe, expect, test, vi } from "vitest";
import type { DataModel } from "./_generated/dataModel";
import schema from "./schema";
import { modules } from "./test.setup";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createStrategyWithInitialPage = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");
const getShell = makeFunctionReference<"query">("strategy:getShell");
const getPageSnapshot = makeFunctionReference<"query">("page:getSnapshot");
const getFullSnapshot = makeFunctionReference<"query">(
  "strategy:getFullSnapshot",
);
const addPage = makeFunctionReference<"mutation">("pages:add");
const deletePage = makeFunctionReference<"mutation">("pages:delete");

const identity = {
  issuer: "https://sync-boundaries.test",
  subject: "owner",
  tokenIdentifier: "sync-boundaries|owner",
  name: "Sync Owner",
};
const strategyPublicId = "strategy-sync-boundaries";
const pageA = "page-a";
const pageB = "page-b";
const settingsA = {
  agentSize: 48,
  abilitySize: 32,
  useNeutralTeamColors: false,
};
const settingsB = {
  agentSize: 52,
  abilitySize: 36,
  useNeutralTeamColors: true,
};

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;

function textPayload(text: string) {
  return {
    kind: "text" as const,
    payloadVersion: 1,
    data: { text, elementType: "text" },
  };
}

function imagePayload(assetPublicId: string) {
  return {
    kind: "image" as const,
    payloadVersion: 1,
    data: { id: assetPublicId, elementType: "image" },
  };
}

function lineupPayload(assetPublicId: string) {
  return {
    kind: "lineupGroup" as const,
    payloadVersion: 1,
    data: {
      name: "B lineup",
      items: [{ images: [{ id: assetPublicId }] }],
    },
  };
}

async function createHarness(): Promise<{
  t: RootHarness;
  owner: Harness;
}> {
  const t = convexTest(schema, modules);
  const owner = t.withIdentity(identity);
  await owner.mutation(ensureCurrentUser, {});
  return { t, owner };
}

async function createBaseStrategy(owner: Harness) {
  await owner.mutation(createStrategyWithInitialPage, {
    publicId: strategyPublicId,
    name: "Sync boundary strategy",
    mapData: "ascent",
    initialPagePublicId: pageA,
    initialPageName: "A active",
    initialPageIsAttack: true,
    initialPageSettings: settingsA,
  });
}

async function applyOps(
  owner: Harness,
  clientId: string,
  ops: Array<Record<string, unknown>>,
) {
  return (await owner.mutation(applyBatch, {
    strategyPublicId,
    clientId,
    clientProtocolVersion: 2,
    ops,
  })) as {
    strategyPublicId: string;
    results: Array<Record<string, unknown>>;
  };
}

async function getStrategyRow(t: Harness): Promise<Record<string, unknown>> {
  return await t.run(async (ctx) => {
    const row = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
      .first();
    if (row === null) throw new Error("Missing strategy test row");
    return row as unknown as Record<string, unknown>;
  });
}

async function deleteOperationEvents(t: Harness, opIds: string[]) {
  await t.run(async (ctx) => {
    const events = await ctx.db.query("operationEvents").collect();
    for (const event of events) {
      if (opIds.includes(event.opId)) {
        await ctx.db.delete(event._id);
      }
    }
  });
}

async function addPageB(owner: Harness, expectedRevision: number) {
  const response = await applyOps(owner, "fixture-pages", [
    {
      opId: "add-page-b",
      kind: "add",
      entityType: "page",
      pagePublicId: pageB,
      payload: { name: "B inactive", isAttack: false, settings: settingsB },
      sortIndex: 1,
      expectedRevision,
    },
  ]);
  expect(response.results[0]).toMatchObject({ status: "ack" });
}

async function seedTwoPageContent(t: Harness, owner: Harness) {
  await createBaseStrategy(owner);
  await addPageB(owner, 0);

  const strategy = await t.run(async (ctx) => {
    return await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
      .first();
  });
  if (strategy === null) throw new Error("Missing strategy test row");
  const pages = await t.run(async (ctx) => {
    return await ctx.db
      .query("pages")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
      .collect();
  });
  const pageAId = pages.find((page) => page.publicId === pageA)?._id;
  const pageBId = pages.find((page) => page.publicId === pageB)?._id;
  if (pageAId === undefined || pageBId === undefined) {
    throw new Error("Missing test pages");
  }

  await t.run(async (ctx) => {
    const now = Date.now();
    const assetA = "asset-a";
    const assetB = "asset-b";
    await ctx.db.insert("imageAssets", {
      publicId: assetA,
      provider: "r2",
      strategyId: strategy._id,
      objectKey: "tests/asset-a.png",
      uploadStatus: "active",
      fileExtension: ".png",
      createdAt: now,
      updatedAt: now,
    });
    await ctx.db.insert("imageAssets", {
      publicId: assetB,
      provider: "r2",
      strategyId: strategy._id,
      objectKey: "tests/asset-b.png",
      uploadStatus: "active",
      fileExtension: ".png",
      createdAt: now,
      updatedAt: now,
    });
    await ctx.db.insert("elements", {
      publicId: "element-a",
      strategyId: strategy._id,
      pageId: pageAId,
      elementType: "image",
      payloadKind: "image",
      payloadVersion: 1,
      payload: imagePayload(assetA),
      sortIndex: 0,
      revision: 1,
      deleted: false,
      createdAt: now,
      updatedAt: now,
    });
    await ctx.db.insert("elements", {
      publicId: "element-b",
      strategyId: strategy._id,
      pageId: pageBId,
      elementType: "text",
      payloadKind: "text",
      payloadVersion: 1,
      payload: textPayload("B only"),
      sortIndex: 0,
      revision: 1,
      deleted: false,
      createdAt: now,
      updatedAt: now,
    });
    await ctx.db.insert("lineups", {
      publicId: "lineup-b",
      strategyId: strategy._id,
      pageId: pageBId,
      payloadKind: "lineupGroup",
      payloadVersion: 1,
      payload: lineupPayload(assetB),
      sortIndex: 0,
      revision: 1,
      deleted: false,
      createdAt: now,
      updatedAt: now,
    });
  });
}

beforeAll(() => {
  process.env.R2_PUBLIC_BASE_URL = "https://assets.sync-boundaries.test";
});

describe("page-scoped read contract", () => {
  test("strategy shell contains metadata and descriptors but no page content", async () => {
    const { t, owner } = await createHarness();
    await seedTwoPageContent(t, owner);

    const shell = (await owner.query(getShell, {
      strategyPublicId,
    })) as Record<string, unknown>;
    expect(shell).toHaveProperty("header");
    expect(shell).toHaveProperty("pages");
    expect(shell).not.toHaveProperty("elements");
    expect(shell).not.toHaveProperty("lineups");
    expect(shell).not.toHaveProperty("assets");
    for (const page of shell.pages as Array<Record<string, unknown>>) {
      expect(page).not.toHaveProperty("settings");
    }
  });

  test("one page snapshot excludes records and assets from other pages", async () => {
    const { t, owner } = await createHarness();
    await seedTwoPageContent(t, owner);

    const snapshot = (await owner.query(getPageSnapshot, {
      strategyPublicId,
      pagePublicId: pageA,
    })) as {
      page: { publicId: string };
      content: { settings: unknown };
      elements: Array<{ publicId: string }>;
      lineups: Array<{ publicId: string }>;
      assets: Array<{ publicId: string }>;
    };
    expect(snapshot.page).toMatchObject({ publicId: pageA });
    expect(snapshot.content).toMatchObject({ settings: settingsA });
    expect(snapshot.elements.map((item) => item.publicId)).toEqual([
      "element-a",
    ]);
    expect(snapshot.lineups).toEqual([]);
    expect(snapshot.assets.map((item) => item.publicId)).toEqual(["asset-a"]);
  });

  test("full snapshot reconstructs every page and referenced asset", async () => {
    const { t, owner } = await createHarness();
    await seedTwoPageContent(t, owner);

    const snapshot = (await owner.query(getFullSnapshot, {
      strategyPublicId,
    })) as {
      pages: Array<{ publicId: string; settings: unknown }>;
      elements: Array<{ publicId: string }>;
      lineups: Array<{ publicId: string }>;
      assets: Array<{ publicId: string }>;
    };
    expect(snapshot.pages).toMatchObject([
      { publicId: pageA, settings: settingsA },
      { publicId: pageB, settings: settingsB },
    ]);
    expect(snapshot.elements.map((item) => item.publicId)).toEqual([
      "element-a",
      "element-b",
    ]);
    expect(snapshot.lineups.map((item) => item.publicId)).toEqual(["lineup-b"]);
    expect(snapshot.assets.map((item) => item.publicId).sort()).toEqual([
      "asset-a",
      "asset-b",
    ]);
  });

  test("page creation always creates one page content row", async () => {
    const { t, owner } = await createHarness();
    await createBaseStrategy(owner);
    await addPageB(owner, 0);

    const counts = await t.run(async (ctx) => {
      const db = ctx.db as unknown as {
        query(table: string): { collect(): Promise<Array<unknown>> };
      };
      return {
        pages: (await db.query("pages").collect()).length,
        pageContents: (await db.query("pageContents").collect()).length,
      };
    });
    expect(counts).toEqual({ pages: 2, pageContents: 2 });
  });
});

describe("record-scoped write contract", () => {
  test("content operations leave the strategy row unchanged", async () => {
    const { t, owner } = await createHarness();
    await createBaseStrategy(owner);
    await applyOps(owner, "content-write", [
      {
        opId: "add-element",
        kind: "add",
        entityType: "element",
        entityPublicId: "element-a",
        pagePublicId: pageA,
        payload: textPayload("before"),
        sortIndex: 0,
      },
    ]);
    const before = await getStrategyRow(t);

    const response = await applyOps(owner, "content-write", [
      {
        opId: "patch-element",
        kind: "patch",
        entityType: "element",
        entityPublicId: "element-a",
        pagePublicId: pageA,
        payload: textPayload("after"),
        expectedRevision: 1,
      },
    ]);
    expect(response.results[0]).toMatchObject({
      status: "ack",
      appliedRevision: 2,
    });
    expect(await getStrategyRow(t)).toEqual(before);
  });

  test("page settings update only their page content revision", async () => {
    const { t, owner } = await createHarness();
    await createBaseStrategy(owner);
    const beforeStrategy = await getStrategyRow(t);
    const beforePage = (await owner.query(getPageSnapshot, {
      strategyPublicId,
      pagePublicId: pageA,
    })) as { page: { revision: number }; content: { revision: number } };

    const response = await applyOps(owner, "page-content-write", [
      {
        opId: "patch-page-content",
        kind: "patch",
        entityType: "pageContent",
        entityPublicId: pageA,
        payload: { settings: settingsB },
        expectedRevision: beforePage.content.revision,
      },
    ]);
    expect(response.results[0]).toMatchObject({
      status: "ack",
      appliedRevision: beforePage.content.revision + 1,
    });
    const afterPage = (await owner.query(getPageSnapshot, {
      strategyPublicId,
      pagePublicId: pageA,
    })) as {
      page: { revision: number };
      content: { revision: number; settings: unknown };
    };
    expect(afterPage.page.revision).toBe(beforePage.page.revision);
    expect(afterPage.content).toMatchObject({
      revision: beforePage.content.revision + 1,
      settings: settingsB,
    });
    expect(await getStrategyRow(t)).toEqual(beforeStrategy);
  });

  test("different entities and pages update from the same strategy revision", async () => {
    const { t, owner } = await createHarness();
    await createBaseStrategy(owner);
    await addPageB(owner, 0);
    await applyOps(owner, "parallel-adds", [
      {
        opId: "add-a",
        kind: "add",
        entityType: "element",
        entityPublicId: "element-a",
        pagePublicId: pageA,
        payload: textPayload("A"),
      },
      {
        opId: "add-b",
        kind: "add",
        entityType: "element",
        entityPublicId: "element-b",
        pagePublicId: pageB,
        payload: textPayload("B"),
      },
    ]);

    const response = await applyOps(owner, "parallel-patches", [
      {
        opId: "patch-a",
        kind: "patch",
        entityType: "element",
        entityPublicId: "element-a",
        payload: textPayload("A2"),
        expectedRevision: 1,
      },
      {
        opId: "patch-b",
        kind: "patch",
        entityType: "element",
        entityPublicId: "element-b",
        payload: textPayload("B2"),
        expectedRevision: 1,
      },
    ]);
    expect(response.results.map((result) => result.status)).toEqual([
      "ack",
      "ack",
    ]);
  });

  test("one batch commits accepted ops and visibly rejects stale ops", async () => {
    const { owner } = await createHarness();
    await createBaseStrategy(owner);
    await applyOps(owner, "same-entity", [
      {
        opId: "add",
        kind: "add",
        entityType: "element",
        entityPublicId: "element-a",
        pagePublicId: pageA,
        payload: textPayload("base"),
      },
    ]);

    const response = await applyOps(owner, "same-entity", [
      {
        opId: "first",
        kind: "patch",
        entityType: "element",
        entityPublicId: "element-a",
        payload: textPayload("first"),
        expectedRevision: 1,
      },
      {
        opId: "second",
        kind: "patch",
        entityType: "element",
        entityPublicId: "element-a",
        payload: textPayload("second"),
        expectedRevision: 1,
      },
    ]);
    expect(response.results).toMatchObject([
      { status: "ack", appliedRevision: 2 },
      {
        status: "reject",
        reason: "revision_mismatch",
        latestRevision: 2,
      },
    ]);
    const snapshot = (await owner.query(getPageSnapshot, {
      strategyPublicId,
      pagePublicId: pageA,
    })) as {
      elements: Array<{
        publicId: string;
        revision: number;
        payload: { data: { text: string } };
      }>;
    };
    expect(snapshot.elements).toMatchObject([
      {
        publicId: "element-a",
        revision: 2,
        payload: { data: { text: "first" } },
      },
    ]);
  });

  test("page membership changes use the strategy revision", async () => {
    const { t, owner } = await createHarness();
    await createBaseStrategy(owner);
    const strategy = await getStrategyRow(t);
    expect(strategy.revision).toBe(0);

    const accepted = await applyOps(owner, "page-membership", [
      {
        opId: "add-page-b",
        kind: "add",
        entityType: "page",
        pagePublicId: pageB,
        payload: { name: "B", isAttack: false, settings: settingsB },
        sortIndex: 1,
        expectedRevision: 0,
      },
    ]);
    expect(accepted.results[0]).toMatchObject({
      status: "ack",
      appliedRevision: 1,
    });

    const rejected = await applyOps(owner, "page-membership", [
      {
        opId: "add-stale-page",
        kind: "add",
        entityType: "page",
        pagePublicId: "page-stale",
        payload: { name: "stale", isAttack: true },
        sortIndex: 2,
        expectedRevision: 0,
      },
    ]);
    expect(rejected.results[0]).toMatchObject({
      status: "reject",
      reason: "revision_mismatch",
      latestRevision: 1,
    });
  });

  test("page reorder uses the strategy revision", async () => {
    const { owner } = await createHarness();
    await createBaseStrategy(owner);
    await addPageB(owner, 0);

    const accepted = await applyOps(owner, "page-reorder", [
      {
        opId: "move-page-b",
        kind: "reorder",
        entityType: "page",
        entityPublicId: pageB,
        sortIndex: 0,
        expectedRevision: 1,
      },
    ]);
    expect(accepted.results[0]).toMatchObject({
      status: "ack",
      appliedRevision: 2,
    });
    const shell = (await owner.query(getShell, {
      strategyPublicId,
    })) as {
      pages: Array<{ publicId: string; sortIndex: number; revision: number }>;
    };
    expect(shell.pages).toMatchObject([
      { publicId: pageB, sortIndex: 0, revision: 2 },
      { publicId: pageA, sortIndex: 1, revision: 2 },
    ]);

    const rejected = await applyOps(owner, "page-reorder", [
      {
        opId: "stale-page-a",
        kind: "reorder",
        entityType: "page",
        entityPublicId: pageA,
        sortIndex: 0,
        expectedRevision: 1,
      },
    ]);
    expect(rejected.results[0]).toMatchObject({
      status: "reject",
      reason: "revision_mismatch",
      latestRevision: 2,
    });
  });

  test("page add at an occupied position shifts siblings", async () => {
    const { owner } = await createHarness();
    await createBaseStrategy(owner);

    const response = await applyOps(owner, "page-insert", [
      {
        opId: "insert-page-b-first",
        kind: "add",
        entityType: "page",
        pagePublicId: pageB,
        payload: { name: "B inactive", isAttack: false, settings: settingsB },
        sortIndex: 0,
        expectedRevision: 0,
      },
    ]);
    expect(response.results[0]).toMatchObject({
      status: "ack",
      appliedRevision: 1,
    });

    const shell = (await owner.query(getShell, {
      strategyPublicId,
    })) as {
      pages: Array<{ publicId: string; sortIndex: number; revision: number }>;
    };
    expect(shell.pages).toMatchObject([
      { publicId: pageB, sortIndex: 0, revision: 1 },
      { publicId: pageA, sortIndex: 1, revision: 2 },
    ]);
  });

  test("soft-deleted elements and lineups can be restored with their ids", async () => {
    const elementId = "restorable-element";
    const lineupId = "restorable-lineup";
    const restoredText = "restored";
    const restoredAsset = "restored-asset";
    const { owner } = await createHarness();
    await createBaseStrategy(owner);
    await applyOps(owner, "undo-restore", [
      {
        opId: "add-element",
        kind: "add",
        entityType: "element",
        entityPublicId: elementId,
        pagePublicId: pageA,
        payload: textPayload("before delete"),
      },
      {
        opId: "add-lineup",
        kind: "add",
        entityType: "lineup",
        entityPublicId: lineupId,
        pagePublicId: pageA,
        payload: lineupPayload("before-delete-asset"),
      },
    ]);
    await applyOps(owner, "undo-restore", [
      {
        opId: "delete-element",
        kind: "delete",
        entityType: "element",
        entityPublicId: elementId,
        expectedRevision: 1,
      },
      {
        opId: "delete-lineup",
        kind: "delete",
        entityType: "lineup",
        entityPublicId: lineupId,
        expectedRevision: 1,
      },
    ]);

    const restored = await applyOps(owner, "undo-restore", [
      {
        opId: "restore-element",
        kind: "add",
        entityType: "element",
        entityPublicId: elementId,
        pagePublicId: pageA,
        payload: textPayload(restoredText),
      },
      {
        opId: "restore-lineup",
        kind: "add",
        entityType: "lineup",
        entityPublicId: lineupId,
        pagePublicId: pageA,
        payload: lineupPayload(restoredAsset),
      },
    ]);
    expect(restored.results).toMatchObject([
      { status: "ack", appliedRevision: 3 },
      { status: "ack", appliedRevision: 3 },
    ]);

    const snapshot = (await owner.query(getPageSnapshot, {
      strategyPublicId,
      pagePublicId: pageA,
    })) as {
      elements: Array<{
        publicId: string;
        revision: number;
        deleted: boolean;
        payload: { data: { text: string } };
      }>;
      lineups: Array<{
        publicId: string;
        revision: number;
        deleted: boolean;
        payload: { data: { items: Array<{ images: Array<{ id: string }> }> } };
      }>;
    };
    expect(snapshot.elements).toMatchObject([
      {
        publicId: elementId,
        revision: 3,
        deleted: false,
        payload: { data: { text: restoredText } },
      },
    ]);
    expect(snapshot.lineups).toMatchObject([
      {
        publicId: lineupId,
        revision: 3,
        deleted: false,
        payload: {
          data: { items: [{ images: [{ id: restoredAsset }] }] },
        },
      },
    ]);
  });

  test("direct page delete replay is idempotent after one page remains", async () => {
    vi.useFakeTimers();
    try {
      const { t, owner } = await createHarness();
      await createBaseStrategy(owner);
      const added = (await owner.mutation(addPage, {
        strategyPublicId,
        expectedRevision: 0,
        pagePublicId: pageB,
        name: "B inactive",
        sortIndex: 1,
        isAttack: false,
        settings: settingsB,
      })) as { revision: number };
      expect(added.revision).toBe(1);

      const deleted = (await owner.mutation(deletePage, {
        strategyPublicId,
        pagePublicId: pageB,
        expectedRevision: 1,
      })) as { revision: number; reused?: boolean };
      expect(deleted).toMatchObject({ revision: 2 });

      const replayed = (await owner.mutation(deletePage, {
        strategyPublicId,
        pagePublicId: pageB,
        expectedRevision: 1,
      })) as { revision: number; reused?: boolean };
      expect(replayed).toMatchObject({ revision: 2, reused: true });
      await t.finishAllScheduledFunctions(vi.runAllTimers);
    } finally {
      vi.useRealTimers();
    }
  });

  test("direct page add replay ignores settings key order", async () => {
    const { owner } = await createHarness();
    await createBaseStrategy(owner);
    await owner.mutation(addPage, {
      strategyPublicId,
      expectedRevision: 0,
      pagePublicId: pageB,
      name: "B inactive",
      sortIndex: 1,
      isAttack: false,
      settings: settingsB,
    });

    const replayed = (await owner.mutation(addPage, {
      strategyPublicId,
      expectedRevision: 0,
      pagePublicId: pageB,
      name: "B inactive",
      sortIndex: 1,
      isAttack: false,
      settings: {
        useNeutralTeamColors: true,
        abilitySize: 36,
        agentSize: 52,
      },
    })) as { revision: number; reused?: boolean };
    expect(replayed).toMatchObject({ revision: 1, reused: true });
  });
});

describe("replay safety after operation event expiry", () => {
  test("identical add acknowledges and different add rejects", async () => {
    const { t, owner } = await createHarness();
    await createBaseStrategy(owner);
    const original = {
      opId: "replayed-add",
      kind: "add",
      entityType: "element",
      entityPublicId: "element-a",
      pagePublicId: pageA,
      payload: textPayload("original"),
      sortIndex: 0,
    };
    await applyOps(owner, "replay-add", [original]);
    await deleteOperationEvents(t, ["replayed-add"]);

    const identical = await applyOps(owner, "replay-add", [original]);
    expect(identical.results[0]).toMatchObject({
      status: "ack",
      reason: "noop",
    });

    const different = await applyOps(owner, "replay-add-different", [
      { ...original, opId: "different-add", payload: textPayload("different") },
    ]);
    expect(different.results[0]).toMatchObject({
      status: "reject",
      reason: "already_exists",
    });
  });

  test("matching stale patch acknowledges before revision rejection", async () => {
    const { t, owner } = await createHarness();
    await createBaseStrategy(owner);
    await applyOps(owner, "replay-patch", [
      {
        opId: "add",
        kind: "add",
        entityType: "element",
        entityPublicId: "element-a",
        pagePublicId: pageA,
        payload: textPayload("base"),
      },
      {
        opId: "patch",
        kind: "patch",
        entityType: "element",
        entityPublicId: "element-a",
        payload: textPayload("desired"),
        expectedRevision: 1,
      },
    ]);
    await deleteOperationEvents(t, ["patch"]);

    const response = await applyOps(owner, "replay-patch", [
      {
        opId: "patch",
        kind: "patch",
        entityType: "element",
        entityPublicId: "element-a",
        payload: textPayload("desired"),
        expectedRevision: 1,
      },
    ]);
    expect(response.results[0]).toMatchObject({
      status: "ack",
      reason: "noop",
      appliedRevision: 2,
    });
  });

  test("different stale patch rejects with the current entity", async () => {
    const { owner } = await createHarness();
    await createBaseStrategy(owner);
    await applyOps(owner, "replay-patch-different", [
      {
        opId: "add",
        kind: "add",
        entityType: "element",
        entityPublicId: "element-a",
        pagePublicId: pageA,
        payload: textPayload("base"),
      },
      {
        opId: "advance",
        kind: "patch",
        entityType: "element",
        entityPublicId: "element-a",
        payload: textPayload("newer"),
        expectedRevision: 1,
      },
    ]);
    const response = await applyOps(owner, "replay-patch-different", [
      {
        opId: "stale",
        kind: "patch",
        entityType: "element",
        entityPublicId: "element-a",
        payload: textPayload("different"),
        expectedRevision: 1,
      },
    ]);
    expect(response.results[0]).toMatchObject({
      status: "reject",
      reason: "revision_mismatch",
      latestRevision: 2,
      latestPayload: textPayload("newer"),
    });
  });

  test("delete against a missing row acknowledges as a no-op", async () => {
    const { owner } = await createHarness();
    await createBaseStrategy(owner);
    const response = await applyOps(owner, "replay-delete", [
      {
        opId: "missing-delete",
        kind: "delete",
        entityType: "element",
        entityPublicId: "missing-element",
        expectedRevision: 4,
      },
    ]);
    expect(response.results[0]).toMatchObject({
      status: "ack",
      reason: "noop",
    });
  });

  test("reorder already at the desired position acknowledges before revision rejection", async () => {
    const { t, owner } = await createHarness();
    await createBaseStrategy(owner);
    await applyOps(owner, "replay-reorder", [
      {
        opId: "add",
        kind: "add",
        entityType: "element",
        entityPublicId: "element-a",
        pagePublicId: pageA,
        payload: textPayload("base"),
        sortIndex: 0,
      },
      {
        opId: "advance",
        kind: "patch",
        entityType: "element",
        entityPublicId: "element-a",
        payload: textPayload("newer"),
        expectedRevision: 1,
      },
    ]);
    await deleteOperationEvents(t, ["advance"]);

    const response = await applyOps(owner, "replay-reorder", [
      {
        opId: "reorder",
        kind: "reorder",
        entityType: "element",
        entityPublicId: "element-a",
        sortIndex: 0,
        expectedRevision: 1,
      },
    ]);
    expect(response.results[0]).toMatchObject({
      status: "ack",
      reason: "noop",
      appliedRevision: 2,
    });
  });
});
