import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { afterEach, beforeAll, describe, expect, test, vi } from "vitest";
import type { DataModel } from "./_generated/dataModel";
import cronDefinitions from "./crons";
import schema from "./schema";
import { modules } from "./test.setup";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const addPage = makeFunctionReference<"mutation">("pages:add");
const deletePage = makeFunctionReference<"mutation">("pages:delete");
const deleteStrategy = makeFunctionReference<"mutation">("strategies:delete");
const markStaleImageUploadsDeleted = makeFunctionReference<"mutation">(
  "images:markStaleImageUploadsDeleted",
);
const sweepDeletedImageAssets = makeFunctionReference<"action">(
  "images:sweepDeletedImageAssets",
);
const completeUpload = makeFunctionReference<"action">("images:completeUpload");
const getAssetUrl = makeFunctionReference<"query">("images:getAssetUrl");

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;

const strategyPublicId = "asset-lifecycle-strategy";
const pageA = "asset-page-a";
const pageB = "asset-page-b";

function identity() {
  return {
    issuer: "https://asset-lifecycle.test",
    subject: "owner",
    tokenIdentifier: "asset-lifecycle|owner",
    name: "Asset Owner",
  };
}

async function createHarness(): Promise<{
  t: RootHarness;
  owner: Harness;
}> {
  const t = convexTest(schema, modules);
  const owner = t.withIdentity(identity());
  await owner.mutation(ensureCurrentUser, {});
  return { t, owner };
}

async function seedStrategy(owner: Harness): Promise<void> {
  await owner.mutation(createStrategy, {
    publicId: strategyPublicId,
    name: "Asset lifecycle",
    mapData: "ascent",
    initialPagePublicId: pageA,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
}

async function getStrategyAndPages(t: RootHarness) {
  return await t.run(async (ctx) => {
    const strategy = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
      .unique();
    if (strategy === null) {
      throw new Error("Missing Strategy test row");
    }
    const pages = await ctx.db
      .query("pages")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
      .collect();
    return { strategy, pages };
  });
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
    data: { items: [{ images: [{ id: assetPublicId }] }] },
  };
}

function mockR2Deletes(statuses: number[] = [204]) {
  let callIndex = 0;
  const fetchMock = vi.fn(
    async (_input: RequestInfo | URL, _init?: RequestInit) => {
      const status = statuses[Math.min(callIndex, statuses.length - 1)]!;
      callIndex += 1;
      return new Response(null, { status });
    },
  );
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

async function allAssets(t: RootHarness) {
  return await t.run(
    async (ctx) => await ctx.db.query("imageAssets").collect(),
  );
}

beforeAll(() => {
  process.env.R2_ACCOUNT_ID = "asset-lifecycle-account";
  process.env.R2_BUCKET = "asset-lifecycle-bucket";
  process.env.R2_ACCESS_KEY_ID = "asset-lifecycle-access-key";
  process.env.R2_SECRET_ACCESS_KEY = "asset-lifecycle-secret";
  process.env.R2_PUBLIC_BASE_URL = "https://assets.asset-lifecycle.test";
  process.env.R2_S3_ENDPOINT = "https://asset-lifecycle.r2.test";
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("image asset lifecycle", () => {
  test("page deletion removes only assets unreferenced by remaining Pages and Lineups", async () => {
    vi.useFakeTimers();
    const fetchMock = mockR2Deletes();
    const { t, owner } = await createHarness();
    await seedStrategy(owner);
    await owner.mutation(addPage, {
      strategyPublicId,
      expectedRevision: 0,
      pagePublicId: pageB,
      name: "Page 2",
      sortIndex: 1,
      isAttack: false,
    });
    const { strategy, pages } = await getStrategyAndPages(t);
    const pageAId = pages.find((page) => page.publicId === pageA)?._id;
    const pageBId = pages.find((page) => page.publicId === pageB)?._id;
    if (pageAId === undefined || pageBId === undefined) {
      throw new Error("Missing Page test rows");
    }

    await t.run(async (ctx) => {
      const now = Date.now();
      for (const [publicId, objectKey] of [
        ["page-only", "pages/page-only.png"],
        ["tombstoned-page-only", "pages/tombstoned-page-only.png"],
        ["still-used", "pages/still-used.png"],
        ["still-used-by-element", "pages/still-used-by-element.png"],
      ] as const) {
        await ctx.db.insert("imageAssets", {
          publicId,
          provider: "r2",
          strategyId: strategy._id,
          objectKey,
          uploadStatus: "active",
          createdAt: now,
          updatedAt: now,
        });
      }
      for (const [publicId, assetPublicId] of [
        ["page-only-element", "page-only"],
        ["tombstoned-element", "tombstoned-page-only"],
        ["shared-element", "still-used"],
        ["shared-page-element", "still-used-by-element"],
      ] as const) {
        await ctx.db.insert("elements", {
          publicId,
          strategyId: strategy._id,
          pageId: pageAId,
          elementType: "image",
          payloadKind: "image",
          payloadVersion: 1,
          payload: imagePayload(assetPublicId),
          sortIndex: 0,
          revision: 1,
          deleted: publicId === "tombstoned-element",
          createdAt: now,
          updatedAt: now,
        });
      }
      await ctx.db.insert("lineups", {
        publicId: "remaining-lineup",
        strategyId: strategy._id,
        pageId: pageBId,
        payloadKind: "lineupGroup",
        payloadVersion: 1,
        payload: lineupPayload("still-used"),
        sortIndex: 0,
        revision: 1,
        deleted: false,
        createdAt: now,
        updatedAt: now,
      });
      await ctx.db.insert("elements", {
        publicId: "remaining-image-element",
        strategyId: strategy._id,
        pageId: pageBId,
        elementType: "image",
        payloadKind: "image",
        payloadVersion: 1,
        payload: imagePayload("still-used-by-element"),
        sortIndex: 1,
        revision: 1,
        deleted: false,
        createdAt: now,
        updatedAt: now,
      });
    });

    await owner.mutation(deletePage, {
      strategyPublicId,
      pagePublicId: pageA,
      expectedRevision: 1,
    });
    await t.finishAllScheduledFunctions(vi.runAllTimers);

    const assets = await allAssets(t);
    expect(assets).toMatchObject([
      { publicId: "still-used", uploadStatus: "active" },
      { publicId: "still-used-by-element", uploadStatus: "active" },
    ]);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(fetchMock.mock.calls[0]?.[1]).toMatchObject({ method: "DELETE" });
    expect(fetchMock.mock.calls.map((call) => String(call[0])).sort()).toEqual(
      expect.arrayContaining([
        expect.stringContaining("page-only.png"),
        expect.stringContaining("tombstoned-page-only.png"),
      ]),
    );
  });

  test("Strategy deletion reclaims exact-owned R2 and Convex assets but preserves ambiguous shared legacy rows", async () => {
    vi.useFakeTimers();
    const fetchMock = mockR2Deletes();
    const { t, owner } = await createHarness();
    await seedStrategy(owner);
    const { strategy } = await getStrategyAndPages(t);
    const { uniqueStorageId, sharedStorageId } = await t.run(async (ctx) => ({
      uniqueStorageId: await ctx.storage.store(new Blob(["unique"])),
      sharedStorageId: await ctx.storage.store(new Blob(["shared"])),
    }));

    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("imageAssets", {
        publicId: "owned-r2",
        provider: "r2",
        strategyId: strategy._id,
        objectKey: "strategies/owned/delete.png",
        uploadStatus: "active",
        createdAt: now,
        updatedAt: now,
      });
      await ctx.db.insert("imageAssets", {
        publicId: "owned-shared-r2",
        provider: "r2",
        strategyId: strategy._id,
        objectKey: "legacy/shared.png",
        uploadStatus: "active",
        createdAt: now,
        updatedAt: now,
      });
      await ctx.db.insert("imageAssets", {
        publicId: "legacy-shared-r2",
        provider: "r2",
        objectKey: "legacy/shared.png",
        uploadStatus: "active",
        createdAt: now,
        updatedAt: now,
      });
      await ctx.db.insert("imageAssets", {
        publicId: "legacy-deleted-r2",
        provider: "r2",
        objectKey: "legacy/ambiguous-deleted.png",
        uploadStatus: "deleted",
        deletedAt: now,
        createdAt: now,
        updatedAt: now,
      });
      await ctx.db.insert("imageAssets", {
        publicId: "owned-convex",
        provider: "convex",
        strategyId: strategy._id,
        storageId: uniqueStorageId,
        uploadStatus: "active",
        createdAt: now,
        updatedAt: now,
      });
      await ctx.db.insert("imageAssets", {
        publicId: "owned-shared-convex",
        provider: "convex",
        strategyId: strategy._id,
        storageId: sharedStorageId,
        uploadStatus: "active",
        createdAt: now,
        updatedAt: now,
      });
      await ctx.db.insert("imageAssets", {
        publicId: "legacy-shared-convex",
        provider: "convex",
        storageId: sharedStorageId,
        uploadStatus: "active",
        createdAt: now,
        updatedAt: now,
      });
    });

    await owner.mutation(deleteStrategy, {
      strategyPublicId,
      expectedRevision: 0,
    });
    await t.finishAllScheduledFunctions(vi.runAllTimers);

    expect(await allAssets(t)).toMatchObject([
      { publicId: "legacy-shared-r2", objectKey: "legacy/shared.png" },
      {
        publicId: "legacy-deleted-r2",
        objectKey: "legacy/ambiguous-deleted.png",
      },
      { publicId: "legacy-shared-convex", storageId: sharedStorageId },
    ]);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(String(fetchMock.mock.calls[0]?.[0])).toContain("delete.png");
    await expect(
      t.run(async (ctx) => (await ctx.storage.get(uniqueStorageId)) === null),
    ).resolves.toBe(true);
    await expect(
      t.run(async (ctx) => (await ctx.storage.get(sharedStorageId)) !== null),
    ).resolves.toBe(true);
  });

  test("R2 failure keeps the tombstone target for an idempotent retry", async () => {
    vi.useFakeTimers();
    const fetchMock = mockR2Deletes([500, 404]);
    const { t, owner } = await createHarness();
    await seedStrategy(owner);
    const { strategy } = await getStrategyAndPages(t);
    const assetId = await t.run(async (ctx) => {
      const now = Date.now();
      return await ctx.db.insert("imageAssets", {
        publicId: "retry-r2",
        provider: "r2",
        strategyId: strategy._id,
        objectKey: "retry/keep-target.png",
        uploadStatus: "deleted",
        deletedAt: now,
        createdAt: now,
        updatedAt: now,
      });
    });

    await expect(
      t.action(sweepDeletedImageAssets, { limit: 1 }),
    ).resolves.toMatchObject({ deleted: 0, failed: 1 });
    await expect(
      t.run(async (ctx) => await ctx.db.get(assetId)),
    ).resolves.toMatchObject({
      uploadStatus: "deleted",
      objectKey: "retry/keep-target.png",
    });

    await expect(
      t.action(sweepDeletedImageAssets, { limit: 1 }),
    ).resolves.toMatchObject({ deleted: 1, failed: 0 });
    await expect(
      t.run(async (ctx) => await ctx.db.get(assetId)),
    ).resolves.toBeNull();
    expect(fetchMock).toHaveBeenCalledTimes(2);
    await t.finishAllScheduledFunctions(vi.runAllTimers);
  });

  test("the last deleted row sharing an R2 key removes the object", async () => {
    vi.useFakeTimers();
    const fetchMock = mockR2Deletes();
    const { t, owner } = await createHarness();
    await seedStrategy(owner);
    const { strategy } = await getStrategyAndPages(t);
    await t.run(async (ctx) => {
      const now = Date.now();
      for (const publicId of ["duplicate-a", "duplicate-b"]) {
        await ctx.db.insert("imageAssets", {
          publicId,
          provider: "r2",
          strategyId: strategy._id,
          objectKey: "duplicates/shared-deleted.png",
          uploadStatus: "deleted",
          deletedAt: now,
          createdAt: now,
          updatedAt: now,
        });
      }
    });

    await expect(
      t.action(sweepDeletedImageAssets, { limit: 2 }),
    ).resolves.toMatchObject({ deleted: 2, failed: 0 });
    expect(await allAssets(t)).toEqual([]);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(String(fetchMock.mock.calls[0]?.[0])).toContain(
      "shared-deleted.png",
    );
    await t.finishAllScheduledFunctions(vi.runAllTimers);
  });

  test("overlapping cleanup actions claim one R2 tombstone once", async () => {
    vi.useFakeTimers();
    const fetchMock = mockR2Deletes();
    const { t, owner } = await createHarness();
    await seedStrategy(owner);
    const { strategy } = await getStrategyAndPages(t);
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("imageAssets", {
        publicId: "single-claim",
        provider: "r2",
        strategyId: strategy._id,
        objectKey: "claims/single.png",
        uploadStatus: "deleted",
        deletedAt: now,
        createdAt: now,
        updatedAt: now,
      });
    });

    const results = (await Promise.all([
      t.action(sweepDeletedImageAssets, { limit: 1 }),
      t.action(sweepDeletedImageAssets, { limit: 1 }),
    ])) as Array<{ deleted: number; failed: number }>;

    expect(results.reduce((total, result) => total + result.deleted, 0)).toBe(
      1,
    );
    expect(results.reduce((total, result) => total + result.failed, 0)).toBe(0);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(await allAssets(t)).toEqual([]);
    await t.finishAllScheduledFunctions(vi.runAllTimers);
  });

  test("the hourly path releases a stranded claim and completes its deletion", async () => {
    vi.useFakeTimers();
    const fetchMock = mockR2Deletes();
    const { t, owner } = await createHarness();
    await seedStrategy(owner);
    const { strategy } = await getStrategyAndPages(t);
    const now = Date.now();
    await t.run(async (ctx) => {
      await ctx.db.insert("imageAssets", {
        publicId: "stranded-claim",
        provider: "r2",
        strategyId: strategy._id,
        objectKey: "claims/stranded.png",
        uploadStatus: "deleted",
        deletedAt: now - 60 * 60 * 1000,
        cleanupClaimedAt: now - 16 * 60 * 1000,
        createdAt: now - 60 * 60 * 1000,
        updatedAt: now - 60 * 60 * 1000,
      });
    });

    await expect(
      t.mutation(markStaleImageUploadsDeleted, {}),
    ).resolves.toMatchObject({ deleted: 0, released: 1 });
    await t.finishAllScheduledFunctions(vi.runAllTimers);

    expect(await allAssets(t)).toEqual([]);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test("legacy reads survive while completion inserts an exact-owned replacement", async () => {
    const { t, owner } = await createHarness();
    await seedStrategy(owner);
    const { strategy, pages } = await getStrategyAndPages(t);
    const pageId = pages.find((page) => page.publicId === pageA)?._id;
    if (pageId === undefined) {
      throw new Error("Missing Page test row");
    }
    const { legacyStorageId, replacementStorageId } = await t.run(
      async (ctx) => ({
        legacyStorageId: await ctx.storage.store(new Blob(["legacy"])),
        replacementStorageId: await ctx.storage.store(
          new Blob(["replacement"]),
        ),
      }),
    );
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("imageAssets", {
        publicId: "legacy-readable",
        provider: "convex",
        storageId: legacyStorageId,
        uploadStatus: "active",
        createdAt: now,
        updatedAt: now,
      });
      await ctx.db.insert("elements", {
        publicId: "legacy-image-element",
        strategyId: strategy._id,
        pageId,
        elementType: "image",
        payloadKind: "image",
        payloadVersion: 1,
        payload: imagePayload("legacy-readable"),
        sortIndex: 0,
        revision: 1,
        deleted: false,
        createdAt: now,
        updatedAt: now,
      });
    });

    const legacyResult = (await owner.query(getAssetUrl, {
      strategyPublicId,
      assetPublicId: "legacy-readable",
    })) as { url: string | null };
    expect(legacyResult.url).toMatch(
      /^https:\/\/some-deployment\.convex\.cloud\//,
    );
    await owner.action(completeUpload, {
      strategyPublicId,
      assetPublicId: "legacy-readable",
      provider: "convex",
      storageId: replacementStorageId,
      fileExtension: ".png",
      mimeType: "image/png",
    });

    const assets = await allAssets(t);
    expect(
      assets.find((asset) => asset.strategyId === undefined),
    ).toMatchObject({
      publicId: "legacy-readable",
      storageId: legacyStorageId,
    });
    expect(
      assets.find((asset) => asset.strategyId === strategy._id),
    ).toMatchObject({
      publicId: "legacy-readable",
      storageId: replacementStorageId,
    });
    const replacementResult = (await owner.query(getAssetUrl, {
      strategyPublicId,
      assetPublicId: "legacy-readable",
    })) as { url: string | null };
    expect(replacementResult.url).toMatch(
      /^https:\/\/some-deployment\.convex\.cloud\//,
    );
    expect(replacementResult.url).not.toBe(legacyResult.url);
  });

  test("the cron path marks stale owned uploads without user auth and leaves ambiguous legacy rows", async () => {
    vi.useFakeTimers();
    const fetchMock = mockR2Deletes();
    const { t, owner } = await createHarness();
    await seedStrategy(owner);
    const { strategy } = await getStrategyAndPages(t);
    const staleAt = Date.now() - 48 * 60 * 60 * 1000;
    await t.run(async (ctx) => {
      await ctx.db.insert("imageAssets", {
        publicId: "stale-owned",
        provider: "r2",
        strategyId: strategy._id,
        objectKey: "stale/owned.png",
        uploadStatus: "pending",
        createdAt: staleAt,
        updatedAt: staleAt,
      });
      await ctx.db.insert("imageAssets", {
        publicId: "stale-legacy",
        provider: "r2",
        objectKey: "stale/legacy.png",
        uploadStatus: "failed",
        createdAt: staleAt,
        updatedAt: staleAt,
      });
    });

    expect(
      cronDefinitions.crons["mark-stale-image-uploads-deleted"],
    ).toMatchObject({
      name: "images:markStaleImageUploadsDeleted",
      schedule: { hours: 1, type: "interval" },
    });
    await expect(
      t.mutation(markStaleImageUploadsDeleted, {
        staleBefore: Date.now() - 24 * 60 * 60 * 1000,
      }),
    ).resolves.toMatchObject({ deleted: 1 });
    await t.finishAllScheduledFunctions(vi.runAllTimers);

    expect(await allAssets(t)).toMatchObject([
      { publicId: "stale-legacy", uploadStatus: "failed" },
    ]);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test("Strategy cleanup continues through bounded database and external deletion batches", async () => {
    vi.useFakeTimers();
    const fetchMock = mockR2Deletes();
    const { t, owner } = await createHarness();
    await seedStrategy(owner);
    const { strategy } = await getStrategyAndPages(t);
    await t.run(async (ctx) => {
      const now = Date.now();
      for (let index = 0; index < 126; index += 1) {
        await ctx.db.insert("imageAssets", {
          publicId: `bounded-${index}`,
          provider: "r2",
          strategyId: strategy._id,
          objectKey: `bounded/${index}.png`,
          uploadStatus: "active",
          createdAt: now,
          updatedAt: now,
        });
      }
    });

    await owner.mutation(deleteStrategy, {
      strategyPublicId,
      expectedRevision: 0,
    });
    await t.finishAllScheduledFunctions(vi.runAllTimers);

    expect(await allAssets(t)).toEqual([]);
    expect(fetchMock).toHaveBeenCalledTimes(126);
  }, 30_000);
});
