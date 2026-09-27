import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import type { DataModel, Id } from "./_generated/dataModel";
import type { MutationCtx } from "./_generated/server";
import { processAssetReclaimBatch } from "./images";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import schema from "./schema";
import { modules } from "./test.setup";
import { insertElement } from "./testContent.helpers";

const ensureCurrentUser = makeFunctionReference<"mutation">(
  "users:ensureCurrentUser",
);
const createStrategy = makeFunctionReference<"mutation">(
  "strategies:createWithInitialPage",
);
const duplicateStrategy = makeFunctionReference<"mutation">(
  "strategies:duplicate",
);
const applyBatch = makeFunctionReference<"mutation">("ops:applyBatch");
const purgeOldTombstones = makeFunctionReference<"mutation">(
  "maintenance:purgeOldTombstones",
);
const backfillAssetReferences = makeFunctionReference<"mutation">(
  "maintenance:backfillAssetReferences",
);

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;

const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };
const strategyPublicId = "media-limits";
const pagePublicId = "media-limits-page";
const day = 24 * 60 * 60 * 1000;
// Rows as large as the op size cap allows, the way Codex's replay built them.
const largeText = "x".repeat(700 * 1024);

async function createHarness(): Promise<{ t: RootHarness; owner: Harness }> {
  const t = convexTest(schema, modules);
  const owner = t.withIdentity({
    issuer: "https://media-limits.test",
    subject: "owner",
    tokenIdentifier: "media-limits|owner",
    name: "Owner",
  });
  await owner.mutation(ensureCurrentUser, protocol);
  await owner.mutation(createStrategy, {
    ...protocol,
    publicId: strategyPublicId,
    name: "Big",
    mapData: "ascent",
    initialPagePublicId: pagePublicId,
    initialPageName: "Page 1",
    initialPageIsAttack: true,
  });
  return { t, owner };
}

async function ids(t: RootHarness) {
  return await t.run(async (ctx) => {
    const strategy = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
      .unique();
    const page = await ctx.db
      .query("pages")
      .withIndex("by_publicId", (q) => q.eq("publicId", pagePublicId))
      .unique();
    return { strategyId: strategy!._id, pageId: page!._id };
  });
}

/// [rows] large text elements, and (optionally) an image element deleted
/// 40 days ago whose asset is still active.
async function seedLargeStrategy(
  t: RootHarness,
  rows: number,
  { oldImageTombstone }: { oldImageTombstone: boolean },
) {
  const { strategyId, pageId } = await ids(t);
  await t.run(async (ctx) => {
    const now = Date.now();
    for (let index = 0; index < rows; index++) {
      await insertElement(ctx, {
        publicId: `text-${index}`,
        strategyId,
        pageId,
        elementType: "text",
        payloadKind: "text",
        payloadVersion: 1,
        payload: {
          kind: "text",
          payloadVersion: 1,
          data: { id: `text-${index}`, elementType: "text", text: largeText },
        },
        sortIndex: index,
        revision: 1,
        deleted: false,
        createdAt: now,
        updatedAt: now,
      });
    }
    if (!oldImageTombstone) return;
    const longAgo = now - 40 * day;
    await ctx.db.insert("imageAssets", {
      publicId: "old-image",
      provider: "r2",
      strategyId,
      objectKey: "tests/old-image.png",
      uploadStatus: "active",
      fileExtension: ".png",
      createdAt: longAgo,
      updatedAt: longAgo,
    });
    await insertElement(ctx, {
      publicId: "old-image",
      strategyId,
      pageId,
      elementType: "image",
      payloadKind: "image",
      payloadVersion: 1,
      payload: {
        kind: "image",
        payloadVersion: 1,
        data: { id: "old-image", elementType: "image" },
      },
      sortIndex: 999,
      revision: 2,
      deleted: true,
      createdAt: longAgo,
      updatedAt: longAgo,
    });
  });
  return { strategyId, pageId };
}

/// [ctx] with every document its queries and gets return counted, as a
/// stand-in for Convex's per-transaction read accounting (convex-test does
/// not enforce the limits).
function countReads(ctx: MutationCtx) {
  let bytes = 0;
  const count = <T>(doc: T): T => {
    if (doc !== null && doc !== undefined) bytes += JSON.stringify(doc).length;
    return doc;
  };
  const wrapQuery = (query: any): any =>
    new Proxy(query, {
      get(target, prop) {
        if (prop === Symbol.asyncIterator) {
          return async function* () {
            for await (const doc of target) yield count(doc);
          };
        }
        const value = Reflect.get(target, prop, target);
        if (typeof value !== "function") return value;
        return (...args: unknown[]) => {
          const result = value.apply(target, args);
          if (prop === "first" || prop === "unique") return result.then(count);
          if (prop === "take" || prop === "collect") {
            return result.then((docs: unknown[]) => docs.map(count));
          }
          if (prop === "paginate") {
            return result.then((page: { page: unknown[] }) => {
              page.page.forEach(count);
              return page;
            });
          }
          return wrapQuery(result);
        };
      },
    });
  const db = new Proxy(ctx.db, {
    get(target, prop) {
      if (prop === "query") {
        return (table: string) => wrapQuery((target as any).query(table));
      }
      if (prop === "get") {
        return (id: any) => (target as any).get(id).then(count);
      }
      const value = Reflect.get(target, prop, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  return { ctx: { ...ctx, db } as MutationCtx, bytesRead: () => bytes };
}

async function candidates(t: RootHarness) {
  return await t.run(
    async (ctx) => await ctx.db.query("assetReclaimCandidates").collect(),
  );
}

async function assetStatus(t: RootHarness, publicId: string) {
  return await t.run(async (ctx) =>
    (await ctx.db.query("imageAssets").collect())
      .filter((asset) => asset.publicId === publicId)
      .map((asset) => asset.uploadStatus),
  );
}

/** A ConvexError's code (convex-test passes its data as JSON text). */
function errorCode(error: unknown): unknown {
  const data = (error as { data?: unknown }).data;
  return (typeof data === "string" ? JSON.parse(data) : data)?.code;
}

beforeEach(() => {
  // Scheduled work (the reclaim a purge starts) runs only when a test asks.
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
});

describe("media cleanup stays within transaction limits", () => {
  test("reclaiming an image reads its references, not the strategy's content", async () => {
    const { t } = await createHarness();
    // Codex's replay: thirteen 700 KiB rows, 18.6 MB read to reclaim one
    // image before, over Convex's 16 MiB transaction read limit.
    await seedLargeStrategy(t, 13, { oldImageTombstone: true });

    await t.mutation(purgeOldTombstones, {});
    expect((await candidates(t)).map((row) => row.assetPublicId)).toEqual([
      "old-image",
    ]);

    const result = await t.run(async (ctx) => {
      const counted = countReads(ctx);
      const outcome = await processAssetReclaimBatch(counted.ctx);
      return { outcome, bytesRead: counted.bytesRead() };
    });

    expect(result.outcome).toEqual({ checked: 1, marked: 1 });
    // A few small index rows, nowhere near the 9 MiB of text on the page.
    expect(result.bytesRead).toBeLessThan(16 * 1024);
    expect(await assetStatus(t, "old-image")).toEqual(["deleted"]);
    expect(await candidates(t)).toEqual([]);
  });

  test("the purge queues its images in the transaction that removes the tombstones", async () => {
    const { t } = await createHarness();
    await seedLargeStrategy(t, 1, { oldImageTombstone: true });

    await t.mutation(purgeOldTombstones, {});

    // Before any reclaim runs: the tombstone and its reference are gone and
    // the candidate is already recorded, so no window loses the image.
    const state = await t.run(async (ctx) => ({
      tombstone: await ctx.db
        .query("elements")
        .withIndex("by_publicId", (q) => q.eq("publicId", "old-image"))
        .first(),
      references: await ctx.db.query("assetReferences").collect(),
    }));
    expect(state.tombstone).toBeNull();
    expect(
      state.references.filter((row) => row.assetPublicId === "old-image"),
    ).toEqual([]);
    expect((await candidates(t)).map((row) => row.assetPublicId)).toEqual([
      "old-image",
    ]);
  });

  test("a reclaim run that fails leaves its candidates queued", async () => {
    const { t } = await createHarness();
    await seedLargeStrategy(t, 1, { oldImageTombstone: true });
    await t.mutation(purgeOldTombstones, {});

    await expect(
      t.run(async (ctx) => {
        await processAssetReclaimBatch(ctx);
        throw new Error("simulated failure after the batch ran");
      }),
    ).rejects.toThrow("simulated failure");

    // Rolled back: still queued, image untouched.
    expect((await candidates(t)).map((row) => row.assetPublicId)).toEqual([
      "old-image",
    ]);
    expect(await assetStatus(t, "old-image")).toEqual(["active"]);

    // The next run reclaims it.
    await t.run(async (ctx) => {
      await processAssetReclaimBatch(ctx);
    });
    expect(await assetStatus(t, "old-image")).toEqual(["deleted"]);
    expect(await candidates(t)).toEqual([]);
  });

  test("an image a live lineup still shows is kept", async () => {
    const { t, owner } = await createHarness();
    await seedLargeStrategy(t, 1, { oldImageTombstone: true });
    await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId,
      clientId: "editor",
      ops: [
        {
          opId: "link-shows-old-image",
          type: "lineup.add",
          lineupPublicId: "lineupLink:link",
          pagePublicId,
          payload: {
            kind: "lineupLink",
            payloadVersion: 1,
            data: {
              id: "link",
              originId: "o",
              landingId: "l",
              images: [{ id: "old-image" }],
            },
          },
          sortIndex: 0,
        },
      ],
    });
    await t.mutation(purgeOldTombstones, {});
    await t.run(async (ctx) => {
      await processAssetReclaimBatch(ctx);
    });
    expect(await assetStatus(t, "old-image")).toEqual(["active"]);
    expect(await candidates(t)).toEqual([]);
  });
});

describe("asset references follow their content", () => {
  test("ops keep an image's reference in step: add, delete, restore", async () => {
    const { t, owner } = await createHarness();
    const references = async () =>
      await t.run(async (ctx) =>
        (await ctx.db.query("assetReferences").collect()).map((row) => ({
          assetPublicId: row.assetPublicId,
          deleted: row.deleted,
          source: row.elementId !== undefined ? "element" : "lineup",
        })),
      );
    const image = (id: string) => ({
      kind: "image",
      payloadVersion: 1,
      data: { id, elementType: "image" },
    });
    await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId,
      clientId: "editor",
      ops: [
        {
          opId: "add-image",
          type: "element.add",
          elementPublicId: "placed",
          pagePublicId,
          payload: image("placed"),
          sortIndex: 0,
        },
        {
          opId: "add-link",
          type: "lineup.add",
          lineupPublicId: "lineupLink:k",
          pagePublicId,
          payload: {
            kind: "lineupLink",
            payloadVersion: 1,
            data: { id: "k", originId: "o", landingId: "l", images: [{ id: "a" }, { id: "b" }] },
          },
          sortIndex: 0,
        },
      ],
    });
    expect(await references()).toEqual(
      expect.arrayContaining([
        { assetPublicId: "placed", deleted: false, source: "element" },
        { assetPublicId: "a", deleted: false, source: "lineup" },
        { assetPublicId: "b", deleted: false, source: "lineup" },
      ]),
    );

    await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId,
      clientId: "editor",
      ops: [
        {
          opId: "delete-image",
          type: "element.delete",
          elementPublicId: "placed",
          pagePublicId,
          expectedElementRevision: 1,
        },
        {
          opId: "drop-b",
          type: "lineup.patch",
          lineupPublicId: "lineupLink:k",
          pagePublicId,
          payload: {
            kind: "lineupLink",
            payloadVersion: 1,
            data: { id: "k", originId: "o", landingId: "l", images: [{ id: "a" }] },
          },
          expectedLineupRevision: 1,
        },
      ],
    });
    const afterDelete = await references();
    expect(afterDelete).toHaveLength(2);
    expect(afterDelete).toEqual(
      expect.arrayContaining([
        { assetPublicId: "placed", deleted: true, source: "element" },
        { assetPublicId: "a", deleted: false, source: "lineup" },
      ]),
    );

    await owner.mutation(applyBatch, {
      ...protocol,
      strategyPublicId,
      clientId: "editor",
      ops: [
        {
          opId: "restore-image",
          type: "element.add",
          elementPublicId: "placed",
          pagePublicId,
          payload: image("placed"),
          sortIndex: 0,
          expectedElementRevision: 2,
        },
      ],
    });
    expect(await references()).toEqual(
      expect.arrayContaining([
        { assetPublicId: "placed", deleted: false, source: "element" },
      ]),
    );
  });

  test("the backfill gives existing content its references", async () => {
    const { t } = await createHarness();
    const { strategyId, pageId } = await ids(t);
    await t.run(async (ctx) => {
      const now = Date.now();
      // Written before the reference table existed: no reference rows.
      await ctx.db.insert("elements", {
        publicId: "before-image",
        strategyId,
        pageId,
        elementType: "image",
        payloadKind: "image",
        payloadVersion: 1,
        payload: {
          kind: "image",
          payloadVersion: 1,
          data: { id: "before-image", elementType: "image" },
        },
        sortIndex: 0,
        revision: 1,
        deleted: false,
        createdAt: now,
        updatedAt: now,
      });
      for (let index = 0; index < 3; index++) {
        await ctx.db.insert("lineups", {
          publicId: `lineupLink:before-${index}`,
          strategyId,
          pageId,
          payloadKind: "lineupLink",
          payloadVersion: 1,
          payload: {
            kind: "lineupLink",
            payloadVersion: 1,
            data: {
              id: `before-${index}`,
              originId: "o",
              landingId: "l",
              images: [{ id: `link-image-${index}` }],
            },
          },
          sortIndex: index,
          revision: 1,
          deleted: index === 2,
          createdAt: now,
          updatedAt: now,
        });
      }
    });

    await t.mutation(backfillAssetReferences, {
      table: "elements",
      paginationOpts: { numItems: 1, cursor: null },
    });
    await t.finishAllScheduledFunctions(vi.runAllTimers);

    const references = await t.run(async (ctx) =>
      (await ctx.db.query("assetReferences").collect())
        .map((row) => `${row.assetPublicId}:${row.deleted}`)
        .sort(),
    );
    expect(references).toEqual([
      "before-image:false",
      "link-image-0:false",
      "link-image-1:false",
      "link-image-2:true",
    ]);
  });
});

describe("duplicate stays within transaction limits", () => {
  async function strategyExists(t: RootHarness, publicId: string) {
    return await t.run(
      async (ctx) =>
        (await ctx.db
          .query("strategies")
          .withIndex("by_publicId", (q) => q.eq("publicId", publicId))
          .first()) !== null,
    );
  }

  test("a strategy over the size limit is refused whole, with a clear error", async () => {
    const { t, owner } = await createHarness();
    // 18 x 700 KiB = 12.3 MiB, past the 12 MiB duplicate budget.
    await seedLargeStrategy(t, 18, { oldImageTombstone: false });

    const error = await owner
      .mutation(duplicateStrategy, {
        ...protocol,
        sourceStrategyPublicId: strategyPublicId,
        publicId: "too-big-copy",
        name: "Copy",
      })
      .then(
        () => null,
        (caught: unknown) => caught,
      );

    expect(errorCode(error)).toBe("STRATEGY_TOO_LARGE_TO_DUPLICATE");
    expect(await strategyExists(t, "too-big-copy")).toBe(false);
  });

  test("a strategy just under the limit duplicates, with its references", async () => {
    const { t, owner } = await createHarness();
    await seedLargeStrategy(t, 17, { oldImageTombstone: false });
    const { strategyId, pageId } = await ids(t);
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("imageAssets", {
        publicId: "placed",
        provider: "r2",
        strategyId,
        objectKey: "tests/placed.png",
        uploadStatus: "active",
        fileExtension: ".png",
        createdAt: now,
        updatedAt: now,
      });
      await insertElement(ctx, {
        publicId: "placed",
        strategyId,
        pageId,
        elementType: "image",
        payloadKind: "image",
        payloadVersion: 1,
        payload: {
          kind: "image",
          payloadVersion: 1,
          data: { id: "placed", elementType: "image" },
        },
        sortIndex: 99,
        revision: 1,
        deleted: false,
        createdAt: now,
        updatedAt: now,
      });
    });

    await expect(
      owner.mutation(duplicateStrategy, {
        ...protocol,
        sourceStrategyPublicId: strategyPublicId,
        publicId: "copy",
        name: "Copy",
      }),
    ).resolves.toEqual({ ok: true });

    // The copy's image element got a reference row of its own.
    const copyReferences = await t.run(async (ctx) => {
      const copy = await ctx.db
        .query("strategies")
        .withIndex("by_publicId", (q) => q.eq("publicId", "copy"))
        .unique();
      return await ctx.db
        .query("assetReferences")
        .withIndex("by_strategyId_and_deleted", (q) =>
          q.eq("strategyId", copy!._id as Id<"strategies">).eq("deleted", false),
        )
        .collect();
    });
    expect(copyReferences).toHaveLength(1);
  });

  test("a strategy over the row limit is refused whole", async () => {
    const { t, owner } = await createHarness();
    const { strategyId, pageId } = await ids(t);
    await t.run(async (ctx) => {
      const now = Date.now();
      for (let index = 0; index < 4001; index++) {
        await ctx.db.insert("elements", {
          publicId: `tiny-${index}`,
          strategyId,
          pageId,
          elementType: "text",
          payloadKind: "text",
          payloadVersion: 1,
          payload: {
            kind: "text",
            payloadVersion: 1,
            data: { id: `tiny-${index}`, elementType: "text", text: "" },
          },
          sortIndex: index,
          revision: 1,
          deleted: false,
          createdAt: now,
          updatedAt: now,
        });
      }
    });

    const error = await owner
      .mutation(duplicateStrategy, {
        ...protocol,
        sourceStrategyPublicId: strategyPublicId,
        publicId: "too-many-copy",
        name: "Copy",
      })
      .then(
        () => null,
        (caught: unknown) => caught,
      );
    expect(errorCode(error)).toBe("STRATEGY_TOO_LARGE_TO_DUPLICATE");
    expect(await strategyExists(t, "too-many-copy")).toBe(false);
  });
});
