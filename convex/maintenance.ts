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
  markAssetReferencesReady,
  syncElementAssetReferences,
  syncLineupAssetReferences,
} from "./lib/assetReferences";
import { processAssetReclaimCandidatesRef, queueAssetReclaim } from "./images";
import { refreshStrategyAgentSummary } from "./lib/strategyAgentSummary";

const MAINTENANCE_BATCH_SIZE = 200;
// Content rows can each hold up to ~900 KB (the op size cap), so passes
// that read content take only a few rows per transaction, well under
// Convex's 16 MiB read and write limits, and reschedule themselves.
const CONTENT_BATCH_SIZE = 8;
// Reference rows a purge run turns into reclaim candidates. Each costs one
// indexed read and two writes, far under Convex's 4,096 index reads.
const PURGE_REFERENCE_BUDGET = 200;
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

export const purgeDeletedPageOrphans = internalMutation({
  args: {
    pageId: v.id("pages"),
    strategyId: v.id("strategies"),
  },
  handler: async (ctx, args) => {
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
/// the writer itself. When the last page is done it records the backfill
/// as complete, which opens every reference-dependent deletion (see
/// assetReferencesReady), and starts the purge and reclaim work that was
/// waiting for it. Safe to re-run: syncing a row is idempotent.
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
    for (const row of page.page) {
      if ("elementType" in row) {
        await syncElementAssetReferences(ctx, row._id, row);
      } else {
        await syncLineupAssetReferences(ctx, row._id, row);
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
    } else if (args.table === "elements") {
      await ctx.scheduler.runAfter(0, backfillAssetReferencesRef, {
        table: "lineups",
        paginationOpts: { numItems: args.paginationOpts.numItems, cursor: null },
      });
    } else {
      await markAssetReferencesReady(ctx);
      await ctx.scheduler.runAfter(0, purgeOldTombstonesRef, {});
      await ctx.scheduler.runAfter(0, processAssetReclaimCandidatesRef, {});
    }
    return { synced: page.page.length, isDone: page.isDone };
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
