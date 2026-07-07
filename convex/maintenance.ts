import { makeFunctionReference } from "convex/server";
import { internalMutation } from "./_generated/server";
import { v } from "convex/values";

const MAINTENANCE_BATCH_SIZE = 200;
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

export const purgeDeletedPageOrphans = internalMutation({
  args: {
    pageId: v.id("pages"),
  },
  handler: async (ctx, args) => {
    const elements = await ctx.db
      .query("elements")
      .withIndex("by_pageId", (q) => q.eq("pageId", args.pageId))
      .take(MAINTENANCE_BATCH_SIZE);
    for (const element of elements) {
      await ctx.db.delete(element._id);
    }

    const remainingSlots = MAINTENANCE_BATCH_SIZE - elements.length;
    const lineups =
      remainingSlots > 0
        ? await ctx.db
            .query("lineups")
            .withIndex("by_pageId", (q) => q.eq("pageId", args.pageId))
            .take(remainingSlots)
        : [];
    for (const lineup of lineups) {
      await ctx.db.delete(lineup._id);
    }

    const shouldContinue =
      elements.length === MAINTENANCE_BATCH_SIZE ||
      (remainingSlots > 0 && lineups.length === remainingSlots);

    if (shouldContinue) {
      await ctx.scheduler.runAfter(
        0,
        purgeDeletedPageOrphansRef,
        { pageId: args.pageId },
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

export const purgeOldTombstones = internalMutation({
  args: {},
  handler: async (ctx) => {
    const cutoff = Date.now() - DAYS_30_MS;
    const staleElements = await ctx.db
      .query("elements")
      .withIndex("by_deleted_and_updatedAt", (q) =>
        q.eq("deleted", true).lt("updatedAt", cutoff),
      )
      .take(MAINTENANCE_BATCH_SIZE);

    for (const element of staleElements) {
      await ctx.db.delete(element._id);
    }

    const remainingSlots = MAINTENANCE_BATCH_SIZE - staleElements.length;
    const staleLineups =
      remainingSlots > 0
        ? await ctx.db
            .query("lineups")
            .withIndex("by_deleted_and_updatedAt", (q) =>
              q.eq("deleted", true).lt("updatedAt", cutoff),
            )
            .take(remainingSlots)
        : [];

    for (const lineup of staleLineups) {
      await ctx.db.delete(lineup._id);
    }

    const shouldContinue =
      staleElements.length === MAINTENANCE_BATCH_SIZE ||
      (remainingSlots > 0 && staleLineups.length === remainingSlots);

    if (shouldContinue) {
      await ctx.scheduler.runAfter(0, purgeOldTombstonesRef, {});
    }
  },
});
