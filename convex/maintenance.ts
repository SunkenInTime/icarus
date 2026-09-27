import { makeFunctionReference, paginationOptsValidator } from "convex/server";
import { internalMutation } from "./_generated/server";
import { v } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import {
  collectAssetIdFromElementPayload,
  collectAssetIdsFromLineupPayload,
} from "./lib/imageAssets";
import {
  syncElementAssetReferences,
  syncLineupAssetReferences,
} from "./lib/assetReferences";
import { queueAssetReclaim } from "./images";
import { refreshStrategyAgentSummary } from "./lib/strategyAgentSummary";

const MAINTENANCE_BATCH_SIZE = 200;
// Content rows can each hold up to ~900 KB (the op size cap), so passes
// that read content take only a few rows per transaction, well under
// Convex's 16 MiB read and write limits, and reschedule themselves.
const CONTENT_BATCH_SIZE = 8;
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

/// Hard-deletes content rows with their reference rows, and queues the
/// images they showed for reclaim, all in the caller's transaction: the
/// purge and the reclaim candidates land together or not at all.
async function purgeContentRows(
  ctx: Parameters<typeof syncElementAssetReferences>[0],
  elements: Doc<"elements">[],
  lineups: Doc<"lineups">[],
): Promise<void> {
  const assetIdsByStrategy = new Map<Id<"strategies">, Set<string>>();
  const note = (strategyId: Id<"strategies">, ids: Iterable<string>) => {
    let set = assetIdsByStrategy.get(strategyId);
    if (set === undefined) {
      assetIdsByStrategy.set(strategyId, (set = new Set()));
    }
    for (const id of ids) set.add(id);
  };
  for (const element of elements) {
    if (element.elementType === "image") {
      const assetId = collectAssetIdFromElementPayload(element.payload);
      if (assetId !== null) note(element.strategyId, [assetId]);
    }
    await ctx.db.delete(element._id);
    await syncElementAssetReferences(ctx, element._id, null);
  }
  for (const lineup of lineups) {
    note(lineup.strategyId, collectAssetIdsFromLineupPayload(lineup.payload));
    await ctx.db.delete(lineup._id);
    await syncLineupAssetReferences(ctx, lineup._id, null);
  }
  for (const [strategyId, assetPublicIds] of assetIdsByStrategy) {
    await queueAssetReclaim(ctx, strategyId, assetPublicIds);
  }
}

export const purgeDeletedPageOrphans = internalMutation({
  args: {
    pageId: v.id("pages"),
    strategyId: v.id("strategies"),
  },
  handler: async (ctx, args) => {
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

    await purgeContentRows(ctx, elements, lineups);

    const shouldContinue =
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

    await purgeContentRows(ctx, staleElements, staleLineups);

    const shouldContinue =
      staleElements.length === CONTENT_BATCH_SIZE ||
      (remainingSlots > 0 && staleLineups.length === remainingSlots);

    if (shouldContinue) {
      await ctx.scheduler.runAfter(0, purgeOldTombstonesRef, {});
    }
  },
});

/// One-off after the asset reference table shipped: gives every existing
/// element and lineup row its reference rows. Pages through elements, then
/// lineups, a few rows per run (rows can be large), rescheduling itself
/// until done. Safe to re-run: syncing a row is idempotent.
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
    }
    return { synced: page.page.length, isDone: page.isDone };
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
