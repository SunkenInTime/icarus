import { query } from "./_generated/server";
import { v } from "convex/values";
import { assertStrategyRole } from "./lib/auth";
import { getPageByPublicId, getStrategyByPublicId } from "./lib/entities";

export const listForPage = query({
  args: {
    strategyPublicId: v.string(),
    pagePublicId: v.string(),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "viewer");

    const page = await getPageByPublicId(ctx, args.pagePublicId);
    if (page.strategyId !== strategy._id) {
      throw new Error("Page strategy mismatch");
    }

    const lineups = await ctx.db
      .query("lineups")
      .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
      .collect();

    return lineups
      .sort((a, b) => a.sortIndex - b.sortIndex)
      .map((lineup) => ({
        publicId: lineup.publicId,
        strategyPublicId: strategy.publicId,
        pagePublicId: page.publicId,
        payload: lineup.payload,
        sortIndex: lineup.sortIndex,
        revision: lineup.revision,
        deleted: lineup.deleted,
        createdAt: lineup.createdAt,
        updatedAt: lineup.updatedAt,
      }));
  },
});
