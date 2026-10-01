import { makeFunctionReference, paginationOptsValidator } from "convex/server";
import {
  internalMutation,
  internalQuery,
  type MutationCtx,
} from "./_generated/server";
import { v } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import {
  assetIdsOfRow,
  assetReferencesReady,
  markContentTableBackfilled,
  syncElementAssetReferences,
  syncLineupAssetReferences,
} from "./lib/assetReferences";
import { inferUploadStatus } from "./lib/imageAssets";
import {
  processAssetReclaimCandidatesRef,
  queueAssetReclaim,
  sweepDeletedImageAssetsRef,
} from "./images";
import { refreshStrategyAgentSummary } from "./lib/strategyAgentSummary";
import { PAGE_TRASH_RETENTION_MS } from "./lib/entities";

const MAINTENANCE_BATCH_SIZE = 200;
// Content rows can each hold up to ~900 KB (the op size cap), so passes
// that read content take only a few rows per transaction, well under
// Convex's 16 MiB read and write limits, and reschedule themselves.
const CONTENT_BATCH_SIZE = 8;
// Reference rows a purge run turns into reclaim candidates. Each costs one
// indexed read and two writes, far under Convex's 4,096 index reads.
const PURGE_REFERENCE_BUDGET = 200;
// Reference rows the backfill writes per run, well under Convex's 8,192
// documents written per transaction.
const BACKFILL_WRITE_BUDGET = 2000;
// How long a deleted page's purge waits before checking again whether the
// reference backfill has finished.
const PURGE_WAIT_FOR_BACKFILL_MS = 10 * 60 * 1000;
const DAYS_30_MS = 30 * 24 * 60 * 60 * 1000;

// NOTE: replace these makeFunctionReference calls with internal.maintenance.* after
// Convex codegen is regenerated and exposes maintenance refs.
export const purgeDeletedPageOrphansRef = makeFunctionReference<"mutation">(
  "maintenance:purgeDeletedPageOrphans",
);
export const purgeOldOperationEventsRef = makeFunctionReference<"mutation">(
  "maintenance:purgeOldOperationEvents",
);
export const purgeOldTombstonesRef = makeFunctionReference<"mutation">(
  "maintenance:purgeOldTombstones",
);
export const backfillAssetReferencesRef = makeFunctionReference<"mutation">(
  "maintenance:backfillAssetReferences",
);
export const purgeTrashedPagesRef = makeFunctionReference<"mutation">(
  "maintenance:purgeTrashedPages",
);

/// Hard-deletes content rows, and queues the images they showed for
/// reclaim, in the caller's transaction: a purged row and its reclaim
/// candidates land together or not at all.
///
/// A row's reference rows are its purge progress. Each one is turned into a
/// reclaim candidate and deleted, at most PURGE_REFERENCE_BUDGET per run
/// (each costs one indexed read to skip a duplicate candidate); the row
/// itself goes once it has none left. A lineup showing hundreds of images
/// is purged across several runs, each committing its part, so a retry
/// resumes where the last run stopped. Returns whether every row was purged.
async function purgeContentRows(
  ctx: MutationCtx,
  elements: Doc<"elements">[],
  lineups: Doc<"lineups">[],
): Promise<boolean> {
  let budget = PURGE_REFERENCE_BUDGET;
  const rows: (
    | { strategyId: Id<"strategies">; elementId: Id<"elements"> }
    | { strategyId: Id<"strategies">; lineupId: Id<"lineups"> }
  )[] = [
    ...elements.map((row) => ({
      strategyId: row.strategyId,
      elementId: row._id,
    })),
    ...lineups.map((row) => ({
      strategyId: row.strategyId,
      lineupId: row._id,
    })),
  ];
  const assetIdsByStrategy = new Map<Id<"strategies">, string[]>();
  let purgedAll = true;
  for (const row of rows) {
    const references =
      "elementId" in row
        ? await ctx.db
            .query("assetReferences")
            .withIndex("by_elementId", (q) => q.eq("elementId", row.elementId))
            .take(budget + 1)
        : await ctx.db
            .query("assetReferences")
            .withIndex("by_lineupId", (q) => q.eq("lineupId", row.lineupId))
            .take(budget + 1);
    const handled = references.slice(0, budget);
    const assetIds = assetIdsByStrategy.get(row.strategyId) ?? [];
    assetIdsByStrategy.set(row.strategyId, assetIds);
    for (const reference of handled) {
      assetIds.push(reference.assetPublicId);
      await ctx.db.delete(reference._id);
    }
    budget -= handled.length;
    if (references.length > handled.length) {
      purgedAll = false;
      break;
    }
    await ctx.db.delete("elementId" in row ? row.elementId : row.lineupId);
  }
  for (const [strategyId, assetPublicIds] of assetIdsByStrategy) {
    await queueAssetReclaim(ctx, strategyId, assetPublicIds);
  }
  return purgedAll;
}

/// Purges the content of a page whose row is gone: a page of a deleted
/// strategy, or one deleted before pages went to the trash. A page that
/// still has its row, in the trash or not, is left alone.
export const purgeDeletedPageOrphans = internalMutation({
  args: {
    pageId: v.id("pages"),
    strategyId: v.id("strategies"),
  },
  handler: async (ctx, args) => {
    if ((await ctx.db.get(args.pageId)) !== null) return;
    // A purge reclaims images through reference rows, which content from
    // before the reference table only has once the backfill has run.
    if (!(await assetReferencesReady(ctx))) {
      await ctx.scheduler.runAfter(
        PURGE_WAIT_FOR_BACKFILL_MS,
        purgeDeletedPageOrphansRef,
        args,
      );
      return;
    }
    const elements = await ctx.db
      .query("elements")
      .withIndex("by_pageId", (q) => q.eq("pageId", args.pageId))
      .take(CONTENT_BATCH_SIZE);
    const remainingSlots = CONTENT_BATCH_SIZE - elements.length;
    const lineups =
      remainingSlots > 0
        ? await ctx.db
            .query("lineups")
            .withIndex("by_pageId", (q) => q.eq("pageId", args.pageId))
            .take(remainingSlots)
        : [];

    const purgedAll = await purgeContentRows(ctx, elements, lineups);

    const shouldContinue =
      !purgedAll ||
      elements.length === CONTENT_BATCH_SIZE ||
      (remainingSlots > 0 && lineups.length === remainingSlots);

    if (shouldContinue) {
      await ctx.scheduler.runAfter(
        0,
        purgeDeletedPageOrphansRef,
        { pageId: args.pageId, strategyId: args.strategyId },
      );
    }
  },
});

/// Purges, for good, pages that have been in the trash for the whole
/// PAGE_TRASH_RETENTION_MS: first their elements and lineups, a few per run
/// (see purgeContentRows, which queues the images they showed for reclaim),
/// then the page and its settings once nothing is left on it. One page at a
/// time, rescheduling itself until no page is due. Restoring refuses a page
/// this old (isPastTrashRetention), so a purge never races a restore.
export const purgeTrashedPages = internalMutation({
  args: {},
  handler: async (ctx) => {
    // Waits for the reference backfill, like purgeOldTombstones.
    if (!(await assetReferencesReady(ctx))) return;
    const cutoff = Date.now() - PAGE_TRASH_RETENTION_MS;
    const page = await ctx.db
      .query("pages")
      .withIndex("by_deletedAt", (q) =>
        q.gt("deletedAt", 0).lt("deletedAt", cutoff),
      )
      .first();
    if (page === null) return;

    const elements = await ctx.db
      .query("elements")
      .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
      .take(CONTENT_BATCH_SIZE);
    const remainingSlots = CONTENT_BATCH_SIZE - elements.length;
    const lineups =
      remainingSlots > 0
        ? await ctx.db
            .query("lineups")
            .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
            .take(remainingSlots)
        : [];
    const purgedAll = await purgeContentRows(ctx, elements, lineups);
    if (purgedAll && elements.length + lineups.length < CONTENT_BATCH_SIZE) {
      const contents = await ctx.db
        .query("pageContents")
        .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
        .collect();
      for (const content of contents) await ctx.db.delete(content._id);
      await ctx.db.delete(page._id);
    }
    // The next run continues this page, or finds the next one due.
    await ctx.scheduler.runAfter(0, purgeTrashedPagesRef, {});
  },
});

export const purgeOldOperationEvents = internalMutation({
  args: {},
  handler: async (ctx) => {
    const cutoff = Date.now() - DAYS_30_MS;
    const staleEvents = await ctx.db
      .query("operationEvents")
      .withIndex("by_createdAt", (q) => q.lt("createdAt", cutoff))
      .take(MAINTENANCE_BATCH_SIZE);

    for (const event of staleEvents) {
      await ctx.db.delete(event._id);
    }

    if (staleEvents.length === MAINTENANCE_BATCH_SIZE) {
      await ctx.scheduler.runAfter(0, purgeOldOperationEventsRef, {});
    }
  },
});

/// Purges tombstones past their 30-day retention. A tombstone is the last
/// record that its content showed an image, so the images go to the reclaim
/// queue in the same transaction (see purgeContentRows).
export const purgeOldTombstones = internalMutation({
  args: {},
  handler: async (ctx) => {
    // Waits for the reference backfill (see purgeDeletedPageOrphans), which
    // starts this purge when it finishes.
    if (!(await assetReferencesReady(ctx))) return;
    const cutoff = Date.now() - DAYS_30_MS;
    const staleElements = await ctx.db
      .query("elements")
      .withIndex("by_deleted_and_updatedAt", (q) =>
        q.eq("deleted", true).lt("updatedAt", cutoff),
      )
      .take(CONTENT_BATCH_SIZE);

    const remainingSlots = CONTENT_BATCH_SIZE - staleElements.length;
    const staleLineups =
      remainingSlots > 0
        ? await ctx.db
            .query("lineups")
            .withIndex("by_deleted_and_updatedAt", (q) =>
              q.eq("deleted", true).lt("updatedAt", cutoff),
            )
            .take(remainingSlots)
        : [];

    const purgedAll = await purgeContentRows(ctx, staleElements, staleLineups);

    const shouldContinue =
      !purgedAll ||
      staleElements.length === CONTENT_BATCH_SIZE ||
      (remainingSlots > 0 && staleLineups.length === remainingSlots);

    if (shouldContinue) {
      await ctx.scheduler.runAfter(0, purgeOldTombstonesRef, {});
    }
  },
});

/// One-off after the asset reference table shipped: gives every existing
/// element and lineup row, tombstones included, its reference rows. Pages
/// through elements, then lineups, a few rows per run (rows can be large),
/// rescheduling itself until done. Rows written meanwhile get theirs from
/// the writer itself. When a table's last page is done it records that
/// table as backfilled. Once both are, every reference-dependent deletion
/// opens (see assetReferencesReady), and the lineups run starts the purge,
/// reclaim, and physical sweep that were waiting. Safe to re-run: syncing a
/// row is idempotent.
export const backfillAssetReferences = internalMutation({
  args: {
    table: v.union(v.literal("elements"), v.literal("lineups")),
    paginationOpts: paginationOptsValidator,
  },
  handler: async (ctx, args) => {
    const page =
      args.table === "elements"
        ? await ctx.db.query("elements").paginate(args.paginationOpts)
        : await ctx.db.query("lineups").paginate(args.paginationOpts);
    // A row can show thousands of images, so writes are budgeted, not rows.
    // A run that spends its budget mid-page runs the same page again: rows
    // already in step cost no writes, and the row it stopped in continues.
    let writesLeft = BACKFILL_WRITE_BUDGET;
    for (const row of page.page) {
      const result =
        "elementType" in row
          ? await syncElementAssetReferences(ctx, row._id, row, writesLeft)
          : await syncLineupAssetReferences(ctx, row._id, row, writesLeft);
      writesLeft -= result.writes;
      if (!result.complete) {
        await ctx.scheduler.runAfter(0, backfillAssetReferencesRef, args);
        return { synced: page.page.length, isDone: false };
      }
    }
    if (!page.isDone) {
      await ctx.scheduler.runAfter(0, backfillAssetReferencesRef, {
        table: args.table,
        paginationOpts: {
          numItems: args.paginationOpts.numItems,
          cursor: page.continueCursor,
        },
      });
      return { synced: page.page.length, isDone: false };
    }
    await markContentTableBackfilled(ctx, args.table);
    if (args.table === "elements") {
      await ctx.scheduler.runAfter(0, backfillAssetReferencesRef, {
        table: "lineups",
        paginationOpts: { numItems: args.paginationOpts.numItems, cursor: null },
      });
    } else if (await assetReferencesReady(ctx)) {
      await ctx.scheduler.runAfter(0, purgeOldTombstonesRef, {});
      await ctx.scheduler.runAfter(0, processAssetReclaimCandidatesRef, {});
      await ctx.scheduler.runAfter(0, sweepDeletedImageAssetsRef, {});
    }
    return { synced: page.page.length, isDone: true };
  },
});


/// Verifies the reference backfill, one page of rows at a time: returns
/// the rows whose reference rows do not match the images they show (the
/// set of images, deleted flag, and page). Page with continueCursor until
/// isDone; every page should report no mismatched rows.
export const checkAssetReferences = internalQuery({
  args: {
    table: v.union(v.literal("elements"), v.literal("lineups")),
    paginationOpts: paginationOptsValidator,
  },
  handler: async (ctx, args) => {
    const page =
      args.table === "elements"
        ? await ctx.db.query("elements").paginate(args.paginationOpts)
        : await ctx.db.query("lineups").paginate(args.paginationOpts);
    const mismatched: string[] = [];
    for (const row of page.page) {
      const references =
        "elementType" in row
          ? await ctx.db
              .query("assetReferences")
              .withIndex("by_elementId", (q) => q.eq("elementId", row._id))
              .collect()
          : await ctx.db
              .query("assetReferences")
              .withIndex("by_lineupId", (q) => q.eq("lineupId", row._id))
              .collect();
      const expected = assetIdsOfRow(row);
      const matches =
        references.length === expected.size &&
        references.every(
          (reference) =>
            expected.has(reference.assetPublicId) &&
            reference.deleted === row.deleted &&
            reference.pageId === row.pageId,
        );
      if (!matches) mismatched.push(row.publicId);
    }
    return {
      checked: page.page.length,
      mismatched,
      isDone: page.isDone,
      continueCursor: page.continueCursor,
    };
  },
});

/// Read-only safety check, usable before and after the reference backfill:
/// reads live content itself (not reference rows) and lists every image it
/// shows that has no active asset, with the statuses of that image's asset
/// rows (deleted, pending, failed; none at all if the rows are gone). An
/// image mid-upload shows as pending; a shown image marked deleted is the
/// case cleanup must never cause. Page with continueCursor until isDone;
/// its cost is one indexed read per image shown, so keep pages small.
export const findShownUnavailableAssets = internalQuery({
  args: {
    table: v.union(v.literal("elements"), v.literal("lineups")),
    paginationOpts: paginationOptsValidator,
  },
  handler: async (ctx, args) => {
    const page =
      args.table === "elements"
        ? await ctx.db.query("elements").paginate(args.paginationOpts)
        : await ctx.db.query("lineups").paginate(args.paginationOpts);
    const unavailable: {
      content: string;
      assetPublicId: string;
      statuses: string[];
    }[] = [];
    for (const row of page.page) {
      if (row.deleted) continue;
      for (const assetPublicId of assetIdsOfRow(row)) {
        // One indexed read per image, so a page's cost is its images.
        const rows = await ctx.db
          .query("imageAssets")
          .withIndex("by_strategyId_and_publicId", (q) =>
            q.eq("strategyId", row.strategyId).eq("publicId", assetPublicId),
          )
          .take(20);
        if (rows.some((asset) => inferUploadStatus(asset) === "active")) {
          continue;
        }
        unavailable.push({
          content: row.publicId,
          assetPublicId,
          statuses: rows.map((asset) => inferUploadStatus(asset)),
        });
      }
    }
    return {
      checked: page.page.length,
      unavailable,
      isDone: page.isDone,
      continueCursor: page.continueCursor,
    };
  },
});

/// One-off after the agent summary table shipped: every strategy written
/// before it needs its summary computed once. Safe to re-run.
export const backfillStrategyAgentSummaries = internalMutation({
  args: {},
  returns: v.number(),
  handler: async (ctx) => {
    const strategies = await ctx.db.query("strategies").collect();
    for (const strategy of strategies) {
      await refreshStrategyAgentSummary(ctx, strategy._id);
    }
    return strategies.length;
  },
});
