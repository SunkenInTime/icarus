import {
  convexTest,
  type TestConvexForDataModel,
  type TestConvexForDataModelAndIdentity,
} from "convex-test";
import { makeFunctionReference } from "convex/server";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { getConvexSize } from "convex/values";
import type { DataModel, Id } from "./_generated/dataModel";
import type { MutationCtx } from "./_generated/server";
import * as images from "./images";
import { processAssetReclaimBatch } from "./images";
import { markAssetReferencesReady } from "./lib/assetReferences";
import { CURRENT_CLOUD_PROTOCOL_VERSION } from "./lib/cloudProtocol";
import * as maintenance from "./maintenance";
import schema from "./schema";
import * as strategies from "./strategies";
import { modules } from "./test.setup";
import { insertElement, insertLineup } from "./testContent.helpers";

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
const checkAssetReferences = makeFunctionReference<"query">(
  "maintenance:checkAssetReferences",
);
const findShownUnavailableAssets = makeFunctionReference<"query">(
  "maintenance:findShownUnavailableAssets",
);
const claimDeletedImageAssets = makeFunctionReference<"mutation">(
  "images:claimDeletedImageAssets",
);
const completeLegacyUpload = makeFunctionReference<"mutation">(
  "images:completeLegacyUpload",
);
const sweepDeletedImageAssets = makeFunctionReference<"action">(
  "images:sweepDeletedImageAssets",
);
const processAssetReclaimCandidates = makeFunctionReference<"mutation">(
  "images:processAssetReclaimCandidates",
);
const markPurgedTombstoneImageAssets = makeFunctionReference<"mutation">(
  "images:markPurgedTombstoneImageAssets",
);
const deleteAssetRef = makeFunctionReference<"action">("images:deleteAssetRef");

type Harness = TestConvexForDataModel<DataModel>;
type RootHarness = TestConvexForDataModelAndIdentity<DataModel>;

const protocol = { clientProtocolVersion: CURRENT_CLOUD_PROTOCOL_VERSION };
const strategyPublicId = "media-limits";
const pagePublicId = "media-limits-page";
const day = 24 * 60 * 60 * 1000;
// Rows as large as the op size cap allows, the way Codex's replay built them.
const largeText = "x".repeat(700 * 1024);

/// A deployment with one strategy. By default its reference backfill has
/// run, as every deployment's will have; [backfilled] false is the window
/// between deploying this version and running the backfill.
async function createHarness(
  { backfilled }: { backfilled: boolean } = { backfilled: true },
): Promise<{ t: RootHarness; owner: Harness }> {
  const t = convexTest(schema, modules);
  if (backfilled) await t.run(markAssetReferencesReady);
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
  {
    oldImageTombstone,
    text = largeText,
  }: { oldImageTombstone: boolean; text?: string },
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
          data: { id: `text-${index}`, elementType: "text", text },
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

/// [ctx] with every document its queries and gets return counted, in
/// stored bytes, and every query run counted as one index range read: a
/// stand-in for Convex's per-transaction read accounting (convex-test does
/// not enforce the limits).
function countReads<Ctx extends MutationCtx>(ctx: Ctx) {
  let bytes = 0;
  let rangeReads = 0;
  let writes = 0;
  const count = <T>(doc: T): T => {
    if (doc !== null && doc !== undefined) bytes += getConvexSize(doc as any);
    return doc;
  };
  const wrapQuery = (query: any): any =>
    new Proxy(query, {
      get(target, prop) {
        if (prop === Symbol.asyncIterator) {
          return async function* () {
            rangeReads += 1;
            for await (const doc of target) yield count(doc);
          };
        }
        const value = Reflect.get(target, prop, target);
        if (typeof value !== "function") return value;
        return (...args: unknown[]) => {
          const result = value.apply(target, args);
          if (prop === "first" || prop === "unique") {
            rangeReads += 1;
            return result.then(count);
          }
          if (prop === "take" || prop === "collect") {
            rangeReads += 1;
            return result.then((docs: unknown[]) => docs.map(count));
          }
          if (prop === "paginate") {
            rangeReads += 1;
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
      if (prop === "insert" || prop === "patch" || prop === "delete") {
        return (...args: unknown[]) => {
          writes += 1;
          return (target as any)[prop](...args);
        };
      }
      const value = Reflect.get(target, prop, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  return {
    ctx: { ...ctx, db } as Ctx,
    bytesRead: () => bytes,
    rangeReads: () => rangeReads,
    writes: () => writes,
  };
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

  test("the backfill gives existing content its references, then opens the gate", async () => {
    const { t } = await createHarness({ backfilled: false });
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

    const mismatched = async () => [
      ...(
        await t.query(checkAssetReferences, {
          table: "elements",
          paginationOpts: { numItems: 100, cursor: null },
        })
      ).mismatched,
      ...(
        await t.query(checkAssetReferences, {
          table: "lineups",
          paginationOpts: { numItems: 100, cursor: null },
        })
      ).mismatched,
    ];
    expect((await mismatched()).sort()).toEqual([
      "before-image",
      "lineupLink:before-0",
      "lineupLink:before-1",
      "lineupLink:before-2",
    ]);

    await t.mutation(backfillAssetReferences, {
      table: "elements",
      paginationOpts: { numItems: 1, cursor: null },
    });
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(await mismatched()).toEqual([]);

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
    const completed = await t.run(
      async (ctx) => await ctx.db.query("completedBackfills").collect(),
    );
    expect(completed.map((row) => row.name).sort()).toEqual([
      "assetReferences:elements",
      "assetReferences:lineups",
    ]);
  });
});

describe("before the reference backfill", () => {
  test("nothing is deleted on the say-so of missing references", async () => {
    const { t, owner } = await createHarness({ backfilled: false });
    const { strategyId, pageId } = await ids(t);
    const longAgo = Date.now() - 40 * day;
    // Written by the previous version: an image only an old tombstone
    // shows, and one a live lineup also shows. No reference rows.
    await t.run(async (ctx) => {
      for (const publicId of ["tombstone-only", "lineup-shown"]) {
        await ctx.db.insert("imageAssets", {
          publicId,
          provider: "r2",
          strategyId,
          objectKey: `tests/${publicId}.png`,
          uploadStatus: "active",
          fileExtension: ".png",
          createdAt: longAgo,
          updatedAt: longAgo,
        });
        await ctx.db.insert("elements", {
          publicId,
          strategyId,
          pageId,
          elementType: "image",
          payloadKind: "image",
          payloadVersion: 1,
          payload: {
            kind: "image",
            payloadVersion: 1,
            data: { id: publicId, elementType: "image" },
          },
          sortIndex: 0,
          revision: 2,
          deleted: true,
          createdAt: longAgo,
          updatedAt: longAgo,
        });
      }
      await ctx.db.insert("lineups", {
        publicId: "lineupLink:live",
        strategyId,
        pageId,
        payloadKind: "lineupLink",
        payloadVersion: 1,
        payload: {
          kind: "lineupLink",
          payloadVersion: 1,
          data: {
            id: "live",
            originId: "o",
            landingId: "l",
            images: [{ id: "lineup-shown" }],
          },
        },
        sortIndex: 0,
        revision: 1,
        deleted: false,
        createdAt: longAgo,
        updatedAt: longAgo,
      });
    });

    // Everything that deletes on a reference check, before the backfill:
    // the tombstone purge, a cleanup the previous version scheduled, the
    // reclaim worker, and a user deleting an image.
    await t.mutation(purgeOldTombstones, {});
    await t.mutation(markPurgedTombstoneImageAssets, {
      strategyId,
      assetPublicIds: ["tombstone-only", "lineup-shown"],
    });
    await t.mutation(processAssetReclaimCandidates, {});
    await expect(
      owner.action(deleteAssetRef, {
        ...protocol,
        strategyPublicId,
        assetPublicId: "lineup-shown",
      }),
    ).rejects.toThrow("still referenced");
    await t.finishAllScheduledFunctions(vi.runAllTimers);

    expect(await assetStatus(t, "tombstone-only")).toEqual(["active"]);
    expect(await assetStatus(t, "lineup-shown")).toEqual(["active"]);
    const tombstones = await t.run(async (ctx) =>
      (await ctx.db.query("elements").collect()).filter((row) => row.deleted),
    );
    expect(tombstones).toHaveLength(2);
    // The old run's images wait in the queue for the backfill.
    expect((await candidates(t)).map((row) => row.assetPublicId).sort()).toEqual(
      ["lineup-shown", "tombstone-only"],
    );

    // The backfill opens the gate, then the purge and reclaim it starts run.
    // (Run by hand: the physical sweep after them needs R2.)
    await t.mutation(backfillAssetReferences, {
      table: "elements",
      paginationOpts: { numItems: 8, cursor: null },
    });
    expect(
      await t.mutation(backfillAssetReferences, {
        table: "lineups",
        paginationOpts: { numItems: 8, cursor: null },
      }),
    ).toEqual({ synced: 1, isDone: true });
    await t.mutation(purgeOldTombstones, {});
    await t.mutation(processAssetReclaimCandidates, {});

    expect(await assetStatus(t, "tombstone-only")).toEqual(["deleted"]);
    expect(await assetStatus(t, "lineup-shown")).toEqual(["active"]);
    const remaining = await t.run(
      async (ctx) => await ctx.db.query("elements").collect(),
    );
    expect(remaining.filter((row) => row.deleted)).toEqual([]);
    expect(await candidates(t)).toEqual([]);
  });
});

describe("the backfill and its gate", () => {
  /// A lineup link showing [images] images, inserted without reference
  /// rows, as the previous version wrote it.
  async function insertOldLineup(
    t: RootHarness,
    linkId: string,
    images: number,
  ) {
    const { strategyId, pageId } = await ids(t);
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("lineups", {
        publicId: `lineupLink:${linkId}`,
        strategyId,
        pageId,
        payloadKind: "lineupLink",
        payloadVersion: 1,
        payload: {
          kind: "lineupLink",
          payloadVersion: 1,
          data: {
            id: linkId,
            originId: "o",
            landingId: "l",
            images: Array.from({ length: images }, (_, index) => ({
              id: `${linkId}-${index}`,
            })),
          },
        },
        sortIndex: 0,
        revision: 1,
        deleted: false,
        createdAt: now,
        updatedAt: now,
      });
    });
  }

  test("image-heavy lineups are backfilled across runs, each within its write budget", async () => {
    const { t } = await createHarness({ backfilled: false });
    // Codex's replay: 8 lineups x 2,100 images, 16,800 reference rows in one
    // run before, past Convex's 8,192 writes.
    for (let index = 0; index < 8; index++) {
      await insertOldLineup(t, `heavy-${index}`, 2100);
    }
    const args = {
      table: "lineups" as const,
      paginationOpts: { numItems: 8, cursor: null },
    };

    const firstRun = await t.run(async (ctx) => {
      const counted = countReads(ctx);
      const result = await (maintenance.backfillAssetReferences as any)
        ._handler(counted.ctx, args);
      return { result, writes: counted.writes() };
    });
    expect(firstRun.result.isDone).toBe(false);
    expect(firstRun.writes).toBeLessThanOrEqual(2000);

    // Each run commits its writes; the same page runs again and continues.
    await t.mutation(backfillAssetReferences, args);
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    const state = await t.run(async (ctx) => ({
      references: (await ctx.db.query("assetReferences").collect()).length,
      completed: (await ctx.db.query("completedBackfills").collect()).map(
        (row) => row.name,
      ),
    }));
    expect(state.references).toBe(16800);
    // Lineups are done, but elements have not been backfilled: still gated.
    expect(state.completed).toEqual(["assetReferences:lineups"]);
  });

  test("the gate opens only once both tables are backfilled, in either order", async () => {
    const { t } = await createHarness({ backfilled: false });
    const { strategyId, pageId } = await ids(t);
    // A live placed image from the previous version: no reference row.
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("imageAssets", {
        publicId: "live-image",
        provider: "r2",
        strategyId,
        objectKey: "tests/live-image.png",
        uploadStatus: "active",
        fileExtension: ".png",
        createdAt: now,
        updatedAt: now,
      });
      await ctx.db.insert("elements", {
        publicId: "live-image",
        strategyId,
        pageId,
        elementType: "image",
        payloadKind: "image",
        payloadVersion: 1,
        payload: {
          kind: "image",
          payloadVersion: 1,
          data: { id: "live-image", elementType: "image" },
        },
        sortIndex: 0,
        revision: 1,
        deleted: false,
        createdAt: now,
        updatedAt: now,
      });
    });
    await t.mutation(markPurgedTombstoneImageAssets, {
      strategyId,
      assetPublicIds: ["live-image"],
    });

    // Codex's replay: the lineups backfill first, on an empty table.
    await t.mutation(backfillAssetReferences, {
      table: "lineups",
      paginationOpts: { numItems: 8, cursor: null },
    });
    await t.mutation(processAssetReclaimCandidates, {});
    expect(await assetStatus(t, "live-image")).toEqual(["active"]);
    expect((await candidates(t)).map((row) => row.assetPublicId)).toEqual([
      "live-image",
    ]);

    // Elements finish too: the gate opens and the element keeps its image.
    await t.mutation(backfillAssetReferences, {
      table: "elements",
      paginationOpts: { numItems: 8, cursor: null },
    });
    await t.mutation(backfillAssetReferences, {
      table: "lineups",
      paginationOpts: { numItems: 8, cursor: null },
    });
    await t.mutation(processAssetReclaimCandidates, {});
    expect(await assetStatus(t, "live-image")).toEqual(["active"]);
    expect(await candidates(t)).toEqual([]);
  });

  test("an old cleanup job with thousands of images queues them in bounded runs", async () => {
    const { t } = await createHarness({ backfilled: false });
    const { strategyId } = await ids(t);
    const assetPublicIds = Array.from(
      { length: 4250 },
      (_, index) => `old-${index}`,
    );

    const firstRun = await t.run(async (ctx) => {
      const counted = countReads(ctx);
      await (images.markPurgedTombstoneImageAssets as any)._handler(
        counted.ctx,
        { strategyId, assetPublicIds },
      );
      return counted.rangeReads();
    });
    // Before: 4,250 index reads in one run, past Convex's 4,096.
    expect(firstRun).toBeLessThanOrEqual(110);
    expect(await candidates(t)).toHaveLength(100);

    // The rest was scheduled in the same transaction, never lost.
    await t.finishAllScheduledFunctions(vi.runAllTimers);
    expect(await candidates(t)).toHaveLength(4250);
  });

  test("stored bytes are not removed before the backfill", async () => {
    const { t } = await createHarness({ backfilled: false });
    const { strategyId } = await ids(t);
    // Marked deleted, and waiting for the physical sweep.
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("imageAssets", {
        publicId: "marked",
        provider: "r2",
        strategyId,
        objectKey: "tests/marked.png",
        uploadStatus: "deleted",
        deletedAt: now,
        fileExtension: ".png",
        createdAt: now,
        updatedAt: now,
      });
    });

    expect(await t.mutation(claimDeletedImageAssets, {})).toEqual([]);
    expect(await assetStatus(t, "marked")).toEqual(["deleted"]);

    await t.run(markAssetReferencesReady);
    expect(await t.mutation(claimDeletedImageAssets, {})).toHaveLength(1);
  });

  test("a replaced legacy blob waits for the backfill, then the sweep removes it", async () => {
    const { t, owner } = await createHarness({ backfilled: false });
    const { strategyId } = await ids(t);
    const { oldBlob, newBlob } = await t.run(async (ctx) => {
      const oldBlob = await ctx.storage.store(new Blob(["old"]));
      const newBlob = await ctx.storage.store(new Blob(["new"]));
      const now = Date.now();
      await ctx.db.insert("imageAssets", {
        publicId: "legacy-image",
        provider: "convex",
        strategyId,
        storageId: oldBlob,
        uploadStatus: "active",
        fileExtension: ".png",
        createdAt: now,
        updatedAt: now,
      });
      return { oldBlob, newBlob };
    });

    await owner.mutation(completeLegacyUpload, {
      strategyPublicId,
      assetPublicId: "legacy-image",
      storageId: newBlob,
      fileExtension: ".png",
    });
    await t.action(sweepDeletedImageAssets, {});
    const blobExists = async (id: typeof oldBlob) =>
      await t.run(async (ctx) => (await ctx.storage.get(id)) !== null);
    expect(await blobExists(oldBlob)).toBe(true);
    expect((await assetStatus(t, "legacy-image")).sort()).toEqual([
      "active",
      "deleted",
    ]);

    await t.run(markAssetReferencesReady);
    await t.action(sweepDeletedImageAssets, {});
    expect(await blobExists(oldBlob)).toBe(false);
    expect(await blobExists(newBlob)).toBe(true);
    expect(await assetStatus(t, "legacy-image")).toEqual(["active"]);
  });

  test("the safety check lists shown images whose assets are not active", async () => {
    const { t } = await createHarness({ backfilled: false });
    const { strategyId } = await ids(t);
    await insertOldLineup(t, "shown", 3);
    await t.run(async (ctx) => {
      const now = Date.now();
      const statuses = ["active", "deleted", "pending"] as const;
      for (let index = 0; index < 3; index++) {
        await ctx.db.insert("imageAssets", {
          publicId: `shown-${index}`,
          provider: "r2",
          strategyId,
          objectKey: `tests/shown-${index}.png`,
          uploadStatus: statuses[index],
          fileExtension: ".png",
          createdAt: now,
          updatedAt: now,
        });
      }
    });

    const result = await t.query(findShownUnavailableAssets, {
      table: "lineups",
      paginationOpts: { numItems: 100, cursor: null },
    });
    expect(result.unavailable).toEqual([
      {
        content: "lineupLink:shown",
        assetPublicId: "shown-1",
        statuses: ["deleted"],
      },
      {
        content: "lineupLink:shown",
        assetPublicId: "shown-2",
        statuses: ["pending"],
      },
    ]);
  });
});

describe("purges stay within transaction limits", () => {
  test("lineups showing hundreds of images are purged across runs, each bounded", async () => {
    const { t } = await createHarness();
    const { strategyId, pageId } = await ids(t);
    const longAgo = Date.now() - 40 * day;
    // Codex's replay: five tombstoned lineups showing 850 images each.
    await t.run(async (ctx) => {
      for (let lineup = 0; lineup < 5; lineup++) {
        await insertLineup(ctx, {
          publicId: `lineupLink:many-${lineup}`,
          strategyId,
          pageId,
          payloadKind: "lineupLink",
          payloadVersion: 1,
          payload: {
            kind: "lineupLink",
            payloadVersion: 1,
            data: {
              id: `many-${lineup}`,
              originId: "o",
              landingId: "l",
              images: Array.from({ length: 850 }, (_, image) => ({
                id: `image-${lineup}-${image}`,
              })),
            },
          },
          sortIndex: lineup,
          revision: 2,
          deleted: true,
          createdAt: longAgo,
          updatedAt: longAgo,
        });
      }
    });
    const state = async () =>
      await t.run(async (ctx) => ({
        lineups: (await ctx.db.query("lineups").collect()).length,
        references: (await ctx.db.query("assetReferences").collect()).length,
        candidates: (await ctx.db.query("assetReclaimCandidates").collect())
          .length,
      }));

    const firstRun = await t.run(async (ctx) => {
      const counted = countReads(ctx);
      await (maintenance.purgeOldTombstones as any)._handler(counted.ctx, {});
      return counted.rangeReads();
    });
    // Before: one run, 4,257 index reads, past Convex's 4,096.
    expect(firstRun).toBeLessThan(300);
    expect(await state()).toEqual({
      lineups: 5,
      references: 4250 - 200,
      candidates: 200,
    });

    // Each run commits its part, so the next resumes where it stopped.
    let runs = 1;
    while ((await state()).lineups > 0) {
      await t.mutation(purgeOldTombstones, {});
      runs += 1;
      expect(runs).toBeLessThanOrEqual(22);
    }
    expect(await state()).toEqual({
      lineups: 0,
      references: 0,
      candidates: 4250,
    });
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

  test("the size limit counts stored bytes, not characters", async () => {
    const { t, owner } = await createHarness();
    // 界 is three bytes stored. 15 rows of 290K characters are 4.5 M
    // characters, but 13 MB stored, past the 12 MiB budget.
    await seedLargeStrategy(t, 15, {
      oldImageTombstone: false,
      text: "界".repeat(290 * 1024),
    });

    const error = await owner
      .mutation(duplicateStrategy, {
        ...protocol,
        sourceStrategyPublicId: strategyPublicId,
        publicId: "wide-copy",
        name: "Copy",
      })
      .then(
        () => null,
        (caught: unknown) => caught,
      );
    expect(errorCode(error)).toBe("STRATEGY_TOO_LARGE_TO_DUPLICATE");
    expect(await strategyExists(t, "wide-copy")).toBe(false);
  });

  test("a duplicate reads its source once: no reread for the summary or references", async () => {
    const { t, owner } = await createHarness();
    const { strategyId, pageId } = await ids(t);
    // Codex's replay: thirteen 700 KiB agents read 18.6 MB before.
    await t.run(async (ctx) => {
      const now = Date.now();
      for (let index = 0; index < 13; index++) {
        await insertElement(ctx, {
          publicId: `agent-${index}`,
          strategyId,
          pageId,
          elementType: "agent",
          payloadKind: "agent",
          payloadVersion: 1,
          payload: {
            kind: "agent",
            payloadVersion: 1,
            data: {
              id: `agent-${index}`,
              elementType: "agent",
              type: "jett",
              note: largeText,
            },
          },
          sortIndex: index,
          revision: 1,
          deleted: false,
          createdAt: now,
          updatedAt: now,
        });
      }
    });
    const sourceBytes = await t.run(async (ctx) =>
      (await ctx.db.query("elements").collect())
        .map((row) => getConvexSize(row as any))
        .reduce((a, b) => a + b, 0),
    );

    const bytesRead = await owner.run(async (ctx) => {
      const counted = countReads(ctx);
      await (strategies.duplicate as any)._handler(counted.ctx, {
        ...protocol,
        sourceStrategyPublicId: strategyPublicId,
        publicId: "agents-copy",
        name: "Copy",
      });
      return counted.bytesRead();
    });

    expect(bytesRead).toBeGreaterThanOrEqual(sourceBytes);
    expect(bytesRead).toBeLessThan(sourceBytes + 64 * 1024);
    const summary = await t.run(async (ctx) => {
      const copy = await ctx.db
        .query("strategies")
        .withIndex("by_publicId", (q) => q.eq("publicId", "agents-copy"))
        .unique();
      return await ctx.db
        .query("strategyAgentSummaries")
        .withIndex("by_strategyId", (q) => q.eq("strategyId", copy!._id))
        .unique();
    });
    expect(summary?.agentTypes).toEqual(["jett"]);
  });

  async function seedLinkImages(t: RootHarness, count: number) {
    const { strategyId, pageId } = await ids(t);
    await t.run(async (ctx) => {
      const now = Date.now();
      await insertLineup(ctx, {
        publicId: "lineupLink:gallery",
        strategyId,
        pageId,
        payloadKind: "lineupLink",
        payloadVersion: 1,
        payload: {
          kind: "lineupLink",
          payloadVersion: 1,
          data: {
            id: "gallery",
            originId: "o",
            landingId: "l",
            images: Array.from({ length: count }, (_, index) => ({
              id: `gallery-${index}`,
            })),
          },
        },
        sortIndex: 0,
        revision: 1,
        deleted: false,
        createdAt: now,
        updatedAt: now,
      });
    });
  }

  test("a strategy showing too many images is refused whole", async () => {
    const { t, owner } = await createHarness();
    // Codex's replay copied 2,100 images with 4,210 index reads, past
    // Convex's 4,096.
    await seedLinkImages(t, 2100);

    const error = await owner
      .mutation(duplicateStrategy, {
        ...protocol,
        sourceStrategyPublicId: strategyPublicId,
        publicId: "gallery-copy",
        name: "Copy",
      })
      .then(
        () => null,
        (caught: unknown) => caught,
      );
    expect(errorCode(error)).toBe("STRATEGY_TOO_LARGE_TO_DUPLICATE");
    expect(await strategyExists(t, "gallery-copy")).toBe(false);
  });

  test("a strategy showing hundreds of images copies within the index read limit", async () => {
    const { t, owner } = await createHarness();
    await seedLinkImages(t, 500);

    const rangeReads = await owner.run(async (ctx) => {
      const counted = countReads(ctx);
      await (strategies.duplicate as any)._handler(counted.ctx, {
        ...protocol,
        sourceStrategyPublicId: strategyPublicId,
        publicId: "gallery-copy",
        name: "Copy",
      });
      return counted.rangeReads();
    });

    expect(rangeReads).toBeLessThan(4096);
    const copyReferences = await t.run(async (ctx) => {
      const copy = await ctx.db
        .query("strategies")
        .withIndex("by_publicId", (q) => q.eq("publicId", "gallery-copy"))
        .unique();
      return await ctx.db
        .query("assetReferences")
        .withIndex("by_strategyId_and_deleted", (q) =>
          q.eq("strategyId", copy!._id).eq("deleted", false),
        )
        .collect();
    });
    expect(copyReferences).toHaveLength(500);
  });

  test("a strategy with thousands of pages is refused whole", async () => {
    const { t, owner } = await createHarness();
    const { strategyId } = await ids(t);
    // Codex's replay: 4,251 small pages blew the limits before the budget
    // existed.
    await t.run(async (ctx) => {
      const now = Date.now();
      for (let index = 0; index < 4251; index++) {
        await ctx.db.insert("pages", {
          publicId: `extra-page-${index}`,
          strategyId,
          name: `Page ${index}`,
          sortIndex: index + 1,
          isAttack: true,
          revision: 1,
          createdAt: now,
          updatedAt: now,
        });
      }
    });

    const error = await owner
      .mutation(duplicateStrategy, {
        ...protocol,
        sourceStrategyPublicId: strategyPublicId,
        publicId: "pages-copy",
        name: "Copy",
      })
      .then(
        () => null,
        (caught: unknown) => caught,
      );
    expect(errorCode(error)).toBe("STRATEGY_TOO_LARGE_TO_DUPLICATE");
    expect(await strategyExists(t, "pages-copy")).toBe(false);
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
