import { query } from "./_generated/server";
import { v } from "convex/values";
import type { Doc } from "./_generated/dataModel";
import { assertStrategyRole } from "./lib/auth";
import { getPageByPublicId, getStrategyByPublicId } from "./lib/entities";
import { errorWithCode, internalError } from "./lib/errors";
import {
  collectReferencedAssetIds,
  getViewerAssetForStrategy,
  serializeAssetForViewer,
} from "./lib/imageAssets";
import {
  serializeElement,
  serializeLineup,
  serializePageContent,
  serializePageDescriptor,
} from "./lib/snapshotSerialization";

export const getSnapshot = query({
  args: {
    strategyPublicId: v.string(),
    pagePublicId: v.string(),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "viewer");
    const page = await getPageByPublicId(ctx, args.pagePublicId);
    if (page.strategyId !== strategy._id) {
      throw errorWithCode("PAGE_STRATEGY_MISMATCH", "Page strategy mismatch");
    }

    const [pageContents, elements, lineups] = await Promise.all([
      ctx.db
        .query("pageContents")
        .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
        .take(2),
      ctx.db
        .query("elements")
        .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
        .collect(),
      ctx.db
        .query("lineups")
        .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
        .collect(),
    ]);
    if (pageContents.length !== 1) {
      throw internalError("Each page must have exactly one page content row.");
    }

    const referencedAssetIds = collectReferencedAssetIds(elements, lineups);
    const assets = await Promise.all(
      [...referencedAssetIds].map((assetPublicId) =>
        getViewerAssetForStrategy(ctx, strategy._id, assetPublicId),
      ),
    );

    return {
      page: serializePageDescriptor(strategy.publicId, page),
      content: serializePageContent(pageContents[0]!),
      elements: elements
        .sort((left, right) => left.sortIndex - right.sortIndex)
        .map((element) =>
          serializeElement(strategy.publicId, page.publicId, element),
        ),
      lineups: lineups
        .sort((left, right) => left.sortIndex - right.sortIndex)
        .map((lineup) =>
          serializeLineup(strategy.publicId, page.publicId, lineup),
        ),
      assets: (
        await Promise.all(
          assets
            .filter((asset): asset is Doc<"imageAssets"> => asset !== null)
            .map((asset) => serializeAssetForViewer(ctx, asset)),
        )
      ).sort((left, right) => left.publicId.localeCompare(right.publicId)),
    };
  },
});
