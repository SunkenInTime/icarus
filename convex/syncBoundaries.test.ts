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
const reorderPages = makeFunctionReference<"mutation">("pages:reorder");

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
    clientProtocolVersion: 3,
    ops: ops.map(toProtocol3Op),
  })) as {
    strategyPublicId: string;
    results: Array<Record<string, unknown>>;
  };
}

function toProtocol3Op(op: Record<string, unknown>): Record<string, unknown> {
  if (typeof op.type === "string") return op;
  const opId = op.opId;
  const kind = op.kind;
  const entityType = op.entityType;
  const expectedRevision = op.expectedRevision;
  if (typeof opId !== "string" || typeof kind !== "string") {
    throw new Error("Invalid test op");
  }
  if (entityType === "strategy" && kind === "patch") {
    return {
      opId,
      type: "strategy.patch",
      payload: op.payload ?? {},
      expectedStrategyRevision: expectedRevision,
    };
  }
  if (entityType === "page") {
    const pagePublicId = op.entityPublicId ?? op.pagePublicId;
    if (kind === "add") {
      return {
        opId,
        type: "page.add",
        pagePublicId,
        payload: op.payload ?? {},
        sortIndex: op.sortIndex ?? 0,
        expectedStrategyRevision: expectedRevision,
      };
    }
    if (kind === "patch") {
      return {
        opId,
        type: "page.patch",
        pagePublicId,
        payload: op.payload ?? {},
        expectedPageRevision: expectedRevision,
      };
    }
    if (kind === "delete") {
      return {
        opId,
        type: "page.delete",
        pagePublicId,
        expectedStrategyRevision: expectedRevision,
      };
    }
    if (kind === "reorder") {
      return {
        opId,
        type: "page.reorder",
        pagePublicId,
        sortIndex: op.sortIndex,
        expectedStrategyRevision: expectedRevision,
      };
    }
  }
  if (entityType === "pageContent" && kind === "patch") {
    const payload = op.payload as { settings?: unknown } | undefined;
    return {
      opId,
      type: "pageContent.patch",
      pagePublicId: op.entityPublicId ?? op.pagePublicId,
      settings: payload?.settings,
      expectedPageContentRevision: expectedRevision,
    };
  }
  if (entityType === "element") {
    return toProtocol3ContentOp(op, opId, kind, "element");
  }
  if (entityType === "lineup") {
    return toProtocol3ContentOp(op, opId, kind, "lineup");
  }
  throw new Error(`Illegal test op pair: ${entityType}.${kind}`);
}

function toProtocol3ContentOp(
  op: Record<string, unknown>,
  opId: string,
  kind: string,
  entity: "element" | "lineup",
): Record<string, unknown> {
  const capitalized = entity === "element" ? "Element" : "Lineup";
  const idKey = `${entity}PublicId`;
  const expectedKey = `expected${capitalized}Revision`;
  return {
    opId,
    type: `${entity}.${kind}`,
    [idKey]: op.entityPublicId,
    ...({ pagePublicId: op.pagePublicId ?? pageA }),
    ...(op.payload === undefined ? {} : { payload: op.payload }),
    ...((kind === "add" || kind === "reorder") && op.sortIndex === undefined
      ? { sortIndex: 0 }
      : op.sortIndex === undefined
        ? {}
        : { sortIndex: op.sortIndex }),
    ...(op.expectedRevision === undefined
      ? {}
      : { [expectedKey]: op.expectedRevision }),
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
  expect(response.results[0]).toMatchObject({ status: "applied" });
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

  test("structural page ops rename only auto-named pages", async () => {
    vi.useFakeTimers();
    try {
      const { t, owner } = await createHarness();
      await owner.mutation(createStrategyWithInitialPage, {
        publicId: strategyPublicId,
        name: "Page names",
        mapData: "ascent",
        initialPagePublicId: pageA,
        initialPageName: "Page 1",
        initialPageIsAutoNamed: true,
        initialPageIsAttack: true,
        initialPageSettings: settingsA,
      });

      expect(
        await applyOps(owner, "page-name-provenance", [
          {
            opId: "insert-page-before-a",
            type: "page.add",
            pagePublicId: pageB,
            payload: {
              name: "Page 1",
              isAutoNamed: true,
              isAttack: false,
              settings: settingsB,
            },
            sortIndex: 0,
            expectedStrategyRevision: 0,
          },
        ]),
      ).toMatchObject({ results: [{ status: "applied" }] });

      let shell = (await owner.query(getShell, {
        strategyPublicId,
      })) as {
        pages: Array<{
          publicId: string;
          name: string;
          isAutoNamed?: boolean;
          revision: number;
        }>;
      };
      expect(shell.pages).toMatchObject([
        { publicId: pageB, name: "Page 1", isAutoNamed: true },
        { publicId: pageA, name: "Page 2", isAutoNamed: true },
      ]);

      expect(
        await applyOps(owner, "page-name-provenance", [
          {
            opId: "rename-page-a",
            type: "page.patch",
            pagePublicId: pageA,
            payload: { name: "Anchor", isAutoNamed: false },
            expectedPageRevision: shell.pages[1]!.revision,
          },
          {
            opId: "move-page-a-first",
            type: "page.reorder",
            pagePublicId: pageA,
            sortIndex: 0,
            expectedStrategyRevision: 1,
          },
        ]),
      ).toMatchObject({
        results: [{ status: "applied" }, { status: "applied" }],
      });

      shell = (await owner.query(getShell, {
        strategyPublicId,
      })) as typeof shell;
      expect(shell.pages).toMatchObject([
        { publicId: pageA, name: "Anchor", isAutoNamed: false },
        { publicId: pageB, name: "Page 2", isAutoNamed: true },
      ]);

      expect(
        await applyOps(owner, "page-name-provenance", [
          {
            opId: "delete-page-a",
            type: "page.delete",
            pagePublicId: pageA,
            expectedStrategyRevision: 2,
          },
        ]),
      ).toMatchObject({ results: [{ status: "applied" }] });

      shell = (await owner.query(getShell, {
        strategyPublicId,
      })) as typeof shell;
      expect(shell.pages).toMatchObject([
        { publicId: pageB, name: "Page 1", isAutoNamed: true },
      ]);
      await t.finishAllScheduledFunctions(vi.runAllTimers);
    } finally {
      vi.useRealTimers();
    }
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
      status: "applied",
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
      status: "applied",
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
      "applied",
      "applied",
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
      { status: "applied", appliedRevision: 2 },
      {
        status: "rejected",
        reason: "revision_mismatch",
        current: { type: "element", revision: 2 },
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
      status: "applied",
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
      status: "rejected",
      reason: "revision_mismatch",
      current: { type: "strategy", revision: 1 },
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
      status: "applied",
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
      status: "rejected",
      reason: "revision_mismatch",
      current: { type: "strategy", revision: 2 },
    });
  });

  test("same-base page structure ops advance together in one batch", async () => {
    const { owner } = await createHarness();
    await createBaseStrategy(owner);

    const result = await applyOps(owner, "offline-page-batch", [
      {
        opId: "add-page-b-offline",
        kind: "add",
        entityType: "page",
        entityPublicId: pageB,
        payload: { name: "B", isAttack: false, settings: settingsB },
        sortIndex: 1,
        expectedRevision: 0,
      },
      {
        opId: "add-page-c-offline",
        kind: "add",
        entityType: "page",
        entityPublicId: "page-c",
        payload: { name: "C", isAttack: true, settings: settingsA },
        sortIndex: 2,
        expectedRevision: 0,
      },
    ]);

    expect(result.results).toMatchObject([
      { status: "applied", appliedRevision: 1 },
      { status: "applied", appliedRevision: 2 },
    ]);
    const shell = (await owner.query(getShell, {
      strategyPublicId,
    })) as { pages: Array<{ publicId: string; sortIndex: number }> };
    expect(shell.pages).toMatchObject([
      { publicId: pageA, sortIndex: 0 },
      { publicId: pageB, sortIndex: 1 },
      { publicId: "page-c", sortIndex: 2 },
    ]);
  });

  test("a stale first page op does not open same-batch revision chaining", async () => {
    const { owner } = await createHarness();
    await createBaseStrategy(owner);
    await addPageB(owner, 0);

    const result = await applyOps(owner, "stale-offline-page-batch", [
      {
        opId: "stale-add-page-c",
        kind: "add",
        entityType: "page",
        entityPublicId: "page-c",
        payload: { name: "C", isAttack: true, settings: settingsA },
        sortIndex: 2,
        expectedRevision: 0,
      },
      {
        opId: "stale-add-page-d",
        kind: "add",
        entityType: "page",
        entityPublicId: "page-d",
        payload: { name: "D", isAttack: false, settings: settingsB },
        sortIndex: 3,
        expectedRevision: 0,
      },
    ]);

    expect(result.results).toMatchObject([
      { status: "rejected", reason: "revision_mismatch" },
      { status: "rejected", reason: "revision_mismatch" },
    ]);
  });

  test("page descriptor operations all apply through the durable batch protocol", async () => {
    vi.useFakeTimers();
    try {
      const { t, owner } = await createHarness();
      await createBaseStrategy(owner);

      const renamed = await applyOps(owner, "page-descriptors", [
        {
          opId: "rename-page-a",
          kind: "patch",
          entityType: "page",
          entityPublicId: pageA,
          payload: { name: "A renamed" },
          expectedRevision: 1,
        },
      ]);
      expect(renamed.results[0]).toMatchObject({
        status: "applied",
        appliedRevision: 2,
      });

      const added = await applyOps(owner, "page-descriptors", [
        {
          opId: "add-page-b",
          kind: "add",
          entityType: "page",
          entityPublicId: pageB,
          payload: { name: "B", isAttack: false, settings: settingsB },
          sortIndex: 1,
          expectedRevision: 0,
        },
      ]);
      expect(added.results[0]).toMatchObject({
        status: "applied",
        appliedRevision: 1,
      });

      const reordered = await applyOps(owner, "page-descriptors", [
        {
          opId: "reorder-page-b",
          kind: "reorder",
          entityType: "page",
          entityPublicId: pageB,
          sortIndex: 0,
          expectedRevision: 1,
        },
      ]);
      expect(reordered.results[0]).toMatchObject({
        status: "applied",
        appliedRevision: 2,
      });

      const deleted = await applyOps(owner, "page-descriptors", [
        {
          opId: "delete-page-b",
          kind: "delete",
          entityType: "page",
          entityPublicId: pageB,
          expectedRevision: 2,
        },
      ]);
      expect(deleted.results[0]).toMatchObject({
        status: "applied",
        appliedRevision: 3,
      });

      const shell = (await owner.query(getShell, {
        strategyPublicId,
      })) as {
        header: { revision: number };
        pages: Array<{ publicId: string; name: string; sortIndex: number }>;
      };
      expect(shell.header.revision).toBe(3);
      expect(shell.pages).toMatchObject([
        { publicId: pageA, name: "A renamed", sortIndex: 0 },
      ]);
      await t.finishAllScheduledFunctions(vi.runAllTimers);
    } finally {
      vi.useRealTimers();
    }
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
      status: "applied",
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

    const missingRevision = await applyOps(owner, "undo-restore-missing", [
      {
        opId: "restore-element-missing",
        kind: "add",
        entityType: "element",
        entityPublicId: elementId,
        pagePublicId: pageA,
        payload: textPayload(restoredText),
      },
      {
        opId: "restore-lineup-missing",
        kind: "add",
        entityType: "lineup",
        entityPublicId: lineupId,
        pagePublicId: pageA,
        payload: lineupPayload(restoredAsset),
      },
    ]);
    expect(missingRevision.results).toMatchObject([
      {
        status: "rejected",
        reason: "missing_expected_revision",
        current: { type: "element", revision: 2 },
      },
      {
        status: "rejected",
        reason: "missing_expected_revision",
        current: { type: "lineup", revision: 2 },
      },
    ]);

    const staleRevision = await applyOps(owner, "undo-restore-stale", [
      {
        opId: "restore-element-stale",
        kind: "add",
        entityType: "element",
        entityPublicId: elementId,
        pagePublicId: pageA,
        payload: textPayload(restoredText),
        expectedRevision: 1,
      },
      {
        opId: "restore-lineup-stale",
        kind: "add",
        entityType: "lineup",
        entityPublicId: lineupId,
        pagePublicId: pageA,
        payload: lineupPayload(restoredAsset),
        expectedRevision: 1,
      },
    ]);
    expect(staleRevision.results).toMatchObject([
      {
        status: "rejected",
        reason: "revision_mismatch",
        current: { type: "element", revision: 2 },
      },
      {
        status: "rejected",
        reason: "revision_mismatch",
        current: { type: "lineup", revision: 2 },
      },
    ]);

    const misclassifiedPatch = await applyOps(owner, "undo-restore-patch", [
      {
        opId: "restore-element-patch",
        kind: "patch",
        entityType: "element",
        entityPublicId: elementId,
        pagePublicId: pageA,
        payload: textPayload("before delete"),
        sortIndex: 0,
        expectedRevision: 2,
      },
      {
        opId: "restore-lineup-patch",
        kind: "patch",
        entityType: "lineup",
        entityPublicId: lineupId,
        pagePublicId: pageA,
        payload: lineupPayload("before-delete-asset"),
        sortIndex: 0,
        expectedRevision: 2,
      },
    ]);
    expect(misclassifiedPatch.results).toMatchObject([
      { status: "noop", currentRevision: 2 },
      { status: "noop", currentRevision: 2 },
    ]);
    const stillDeleted = (await owner.query(getPageSnapshot, {
      strategyPublicId,
      pagePublicId: pageA,
    })) as {
      elements: Array<{ publicId: string; deleted: boolean }>;
      lineups: Array<{ publicId: string; deleted: boolean }>;
    };
    expect(stillDeleted.elements).toMatchObject([
      { publicId: elementId, deleted: true },
    ]);
    expect(stillDeleted.lineups).toMatchObject([
      { publicId: lineupId, deleted: true },
    ]);

    const restored = await applyOps(owner, "undo-restore-current", [
      {
        opId: "restore-element-current",
        kind: "add",
        entityType: "element",
        entityPublicId: elementId,
        pagePublicId: pageA,
        payload: textPayload(restoredText),
        expectedRevision: 2,
      },
      {
        opId: "restore-lineup-current",
        kind: "add",
        entityType: "lineup",
        entityPublicId: lineupId,
        pagePublicId: pageA,
        payload: lineupPayload(restoredAsset),
        expectedRevision: 2,
      },
    ]);
    expect(restored.results).toMatchObject([
      { status: "applied", appliedRevision: 3 },
      { status: "applied", appliedRevision: 3 },
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

  test("direct page add normalizes occupied and out-of-range positions", async () => {
    const { owner } = await createHarness();
    await createBaseStrategy(owner);

    await owner.mutation(addPage, {
      strategyPublicId,
      expectedRevision: 0,
      pagePublicId: pageB,
      name: "B inactive",
      sortIndex: 0,
      isAttack: false,
      settings: settingsB,
    });
    await owner.mutation(addPage, {
      strategyPublicId,
      expectedRevision: 1,
      pagePublicId: "page-c",
      name: "C",
      sortIndex: 99,
      isAttack: true,
    });

    const shell = (await owner.query(getShell, {
      strategyPublicId,
    })) as {
      pages: Array<{ publicId: string; sortIndex: number; revision: number }>;
    };
    expect(shell.pages).toMatchObject([
      { publicId: pageB, sortIndex: 0, revision: 1 },
      { publicId: pageA, sortIndex: 1, revision: 2 },
      { publicId: "page-c", sortIndex: 2, revision: 1 },
    ]);

    const replayed = (await owner.mutation(addPage, {
      strategyPublicId,
      expectedRevision: 1,
      pagePublicId: "page-c",
      name: "C",
      sortIndex: 99,
      isAttack: true,
    })) as { revision: number; reused?: boolean };
    expect(replayed).toMatchObject({ revision: 2, reused: true });
  });

  test("direct page reorder rejects duplicate page ids", async () => {
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

    await expect(
      owner.mutation(reorderPages, {
        strategyPublicId,
        orderedPagePublicIds: [pageA, pageA],
        expectedRevision: 1,
      }),
    ).rejects.toThrow("Page order must include each page exactly once");

    const shell = (await owner.query(getShell, {
      strategyPublicId,
    })) as {
      header: { revision: number };
      pages: Array<{ publicId: string; sortIndex: number; revision: number }>;
    };
    expect(shell.header.revision).toBe(1);
    expect(shell.pages).toMatchObject([
      { publicId: pageA, sortIndex: 0, revision: 1 },
      { publicId: pageB, sortIndex: 1, revision: 1 },
    ]);
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
      status: "noop",
    });

    const different = await applyOps(owner, "replay-add-different", [
      { ...original, opId: "different-add", payload: textPayload("different") },
    ]);
    expect(different.results[0]).toMatchObject({
      status: "rejected",
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
      status: "noop",
      currentRevision: 2,
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
      status: "rejected",
      reason: "revision_mismatch",
      current: {
        type: "element",
        revision: 2,
        value: textPayload("newer"),
      },
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
      status: "noop",
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
      status: "noop",
      currentRevision: 2,
    });
  });
});

describe("cloud protocol v3 boundary", () => {
  test("old clients receive a structured upgrade error", async () => {
    const { owner } = await createHarness();

    const error = await owner
      .mutation(applyBatch, {
        strategyPublicId,
        clientId: "old-client",
        clientProtocolVersion: 2,
        ops: [],
      })
      .then(
        () => null,
        (caught: unknown) => caught as { data?: unknown },
      );
    expect(error).not.toBeNull();
    expect(typeof error?.data).toBe("string");
    expect(JSON.parse(error?.data as string)).toEqual({
      code: "CLIENT_UPGRADE_REQUIRED",
      message: "Client upgrade required",
    });
  });

  test("the wire validator rejects an illegal operation discriminator", async () => {
    const { owner } = await createHarness();

    await expect(
      owner.mutation(applyBatch, {
        strategyPublicId,
        clientId: "illegal-op",
        clientProtocolVersion: 3,
        ops: [
          {
            opId: "illegal-page-delete",
            type: "page.delete",
            elementPublicId: "element-a",
            expectedStrategyRevision: 0,
          },
        ],
      }),
    ).rejects.toThrow();
  });

  test("function errors become closed failed outcomes", async () => {
    const { owner } = await createHarness();
    await createBaseStrategy(owner);

    const response = await applyOps(owner, "failed-outcome", [
      {
        opId: "page-settings-on-descriptor",
        type: "page.patch",
        pagePublicId: pageA,
        payload: { settings: settingsB },
        expectedPageRevision: 1,
      },
    ]);

    expect(response.results[0]).toEqual({
      opId: "page-settings-on-descriptor",
      status: "failed",
      code: "PAGE_SETTINGS_REQUIRE_PAGE_CONTENT",
      rawCode: "PAGE_SETTINGS_REQUIRE_PAGE_CONTENT",
      message: "Page settings require a pageContent operation",
    });
  });
});
