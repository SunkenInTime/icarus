import { query } from "./_generated/server";
import { v } from "convex/values";
import { assertStrategyRole } from "./lib/auth";
import {
  contentOnPages,
  getPageByPublicId,
  getStrategyByPublicId,
  listLivePages,
} from "./lib/entities";
import { errorWithCode } from "./lib/errors";
import { elementValidator } from "./lib/publicValidators";

export const listForPage = query({
  args: {
    strategyPublicId: v.string(),
    pagePublicId: v.string(),
  },
  returns: v.array(elementValidator),
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "viewer");

    const page = await getPageByPublicId(ctx, args.pagePublicId);
    if (page.strategyId !== strategy._id) {
      throw errorWithCode("PAGE_STRATEGY_MISMATCH", "Page strategy mismatch");
    }

    const elements = await ctx.db
      .query("elements")
      .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
      .collect();

    return elements
      .sort((a, b) => a.sortIndex - b.sortIndex)
      .map((element) => ({
        publicId: element.publicId,
        strategyPublicId: strategy.publicId,
        pagePublicId: page.publicId,
        elementType: element.elementType,
        payload: element.payload,
        sortIndex: element.sortIndex,
        revision: element.revision,
        deleted: element.deleted,
        createdAt: element.createdAt,
        updatedAt: element.updatedAt,
      }));
  },
});

export const listForStrategy = query({
  args: {
    strategyPublicId: v.string(),
  },
  returns: v.array(elementValidator),
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "viewer");

    const pages = await listLivePages(ctx, strategy._id);
    const pagePublicIds = new Map(
      pages.map((page) => [page._id, page.publicId]),
    );

    // Page by page: content in the trash is never read.
    const { elements } = await contentOnPages(ctx, pages);

    return elements
      .sort((a, b) => a.sortIndex - b.sortIndex)
      .filter((element) => pagePublicIds.has(element.pageId))
      .map((element) => ({
        publicId: element.publicId,
        strategyPublicId: strategy.publicId,
        pagePublicId: pagePublicIds.get(element.pageId)!,
        elementType: element.elementType,
        payload: element.payload,
        sortIndex: element.sortIndex,
        revision: element.revision,
        deleted: element.deleted,
        createdAt: element.createdAt,
        updatedAt: element.updatedAt,
      }));
  },
});
