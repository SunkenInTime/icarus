import { query } from "./_generated/server";
import { v } from "convex/values";
import type { Doc } from "./_generated/dataModel";
import { assertStrategyRole } from "./lib/auth";
import { getStrategyByPublicId, sortByNumberField } from "./lib/entities";
import {
  collectReferencedAssetIds,
  getViewerAssetForStrategy,
  serializeAssetForViewer,
} from "./lib/imageAssets";

export const get = query({
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
    const pagePublicIds = new Map(
      pages.map((page) => [page._id, page.publicId]),
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
      header: {
        publicId: strategy.publicId,
        name: strategy.name,
        mapData: strategy.mapData,
        sequence: strategy.sequence,
        createdAt: strategy.createdAt,
        updatedAt: strategy.updatedAt,
        themeProfileId: strategy.themeProfileId ?? null,
        themeOverridePalette: strategy.themeOverridePalette ?? null,
        role,
      },
      pages: sortByNumberField(pages, "sortIndex").map((page) => ({
        publicId: page.publicId,
        strategyPublicId: strategy.publicId,
        name: page.name,
        sortIndex: page.sortIndex,
        isAttack: page.isAttack,
        settings: page.settings ?? null,
        revision: page.revision,
        createdAt: page.createdAt,
        updatedAt: page.updatedAt,
      })),
      elements: visibleElements
        .sort((a, b) => a.sortIndex - b.sortIndex)
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
        })),
      lineups: visibleLineups
        .sort((a, b) => a.sortIndex - b.sortIndex)
        .map((lineup) => ({
          publicId: lineup.publicId,
          strategyPublicId: strategy.publicId,
          pagePublicId: pagePublicIds.get(lineup.pageId)!,
          payload: lineup.payload,
          sortIndex: lineup.sortIndex,
          revision: lineup.revision,
          deleted: lineup.deleted,
          createdAt: lineup.createdAt,
          updatedAt: lineup.updatedAt,
        })),
      assets: await Promise.all(
        assets
          .filter((asset): asset is Doc<"imageAssets"> => asset !== null)
          .map((asset) => serializeAssetForViewer(ctx, asset)),
      ),
    };
  },
});
