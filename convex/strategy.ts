import { query, type QueryCtx } from "./_generated/server";
import { v } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import { assertStrategyRole } from "./lib/auth";
import { getStrategyByPublicId, sortByNumberField } from "./lib/entities";
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
  serializeStrategyHeader,
} from "./lib/snapshotSerialization";
import { internalError } from "./lib/errors";

async function getPageContent(
  ctx: QueryCtx,
  pageId: Id<"pages">,
): Promise<Doc<"pageContents">> {
  const rows = await ctx.db
    .query("pageContents")
    .withIndex("by_pageId", (q) => q.eq("pageId", pageId))
    .take(2);
  if (rows.length !== 1) {
    throw internalError("Each page must have exactly one page content row.");
  }
  return rows[0]!;
}

export const getShell = query({
  args: {
    strategyPublicId: v.string(),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    const { role } = await assertStrategyRole(ctx, strategy, "viewer");
    const pages = await ctx.db
      .query("pages")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
      .collect();

    return {
      header: serializeStrategyHeader(strategy, role),
      pages: sortByNumberField(pages, "sortIndex").map((page) =>
        serializePageDescriptor(strategy.publicId, page),
      ),
    };
  },
});

export const getFullSnapshot = query({
  args: {
    strategyPublicId: v.string(),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    const { role } = await assertStrategyRole(ctx, strategy, "viewer");
    const [pages, elements, lineups] = await Promise.all([
      ctx.db
        .query("pages")
        .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
        .collect(),
      ctx.db
        .query("elements")
        .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
        .collect(),
      ctx.db
        .query("lineups")
        .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
        .collect(),
    ]);
    const orderedPages = sortByNumberField(pages, "sortIndex");
    const pagePublicIds = new Map(
      orderedPages.map((page) => [page._id, page.publicId]),
    );
    const pageContents = await Promise.all(
      orderedPages.map((page) => getPageContent(ctx, page._id)),
    );
    const visibleElements = elements.filter((element) =>
      pagePublicIds.has(element.pageId),
    );
    const visibleLineups = lineups.filter((lineup) =>
      pagePublicIds.has(lineup.pageId),
    );
    const referencedAssetIds = collectReferencedAssetIds(
      visibleElements,
      visibleLineups,
    );
    const assets = await Promise.all(
      [...referencedAssetIds].map((assetPublicId) =>
        getViewerAssetForStrategy(ctx, strategy._id, assetPublicId),
      ),
    );

    return {
      header: serializeStrategyHeader(strategy, role),
      pages: orderedPages.map((page, index) => {
        const content = serializePageContent(pageContents[index]!);
        return {
          ...serializePageDescriptor(strategy.publicId, page),
          settings: content.settings,
          contentRevision: content.revision,
          contentCreatedAt: content.createdAt,
          contentUpdatedAt: content.updatedAt,
        };
      }),
      elements: visibleElements
        .sort((left, right) => left.sortIndex - right.sortIndex)
        .map((element) =>
          serializeElement(
            strategy.publicId,
            pagePublicIds.get(element.pageId)!,
            element,
          ),
        ),
      lineups: visibleLineups
        .sort((left, right) => left.sortIndex - right.sortIndex)
        .map((lineup) =>
          serializeLineup(
            strategy.publicId,
            pagePublicIds.get(lineup.pageId)!,
            lineup,
          ),
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
