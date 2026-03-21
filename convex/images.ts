import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import { assertStrategyRole, requireCurrentUser } from "./lib/auth";
import {
  getElementByPublicId,
  getPageByPublicId,
  getStrategyByPublicId,
} from "./lib/entities";

export const registerAssetRef = mutation({
  args: {
    strategyPublicId: v.string(),
    pagePublicId: v.string(),
    assetPublicId: v.string(),
    elementPublicId: v.optional(v.string()),
    storagePath: v.string(),
    mimeType: v.string(),
    width: v.optional(v.number()),
    height: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    const { user } = await assertStrategyRole(ctx, strategy, "editor");
    const page = await getPageByPublicId(ctx, args.pagePublicId);

    if (page.strategyId !== strategy._id) {
      throw new Error("Page strategy mismatch");
    }

    let elementId;
    if (args.elementPublicId !== undefined) {
      const element = await getElementByPublicId(ctx, args.elementPublicId);
      if (element.strategyId !== strategy._id || element.pageId !== page._id) {
        throw new Error("Element context mismatch");
      }
      elementId = element._id;
    }

    const existing = await ctx.db
      .query("imageAssets")
      .withIndex("by_publicId", (q) => q.eq("publicId", args.assetPublicId))
      .first();

    if (existing === null) {
      await ctx.db.insert("imageAssets", {
        publicId: args.assetPublicId,
        strategyId: strategy._id,
        pageId: page._id,
        elementId,
        storagePath: args.storagePath,
        mimeType: args.mimeType,
        width: args.width,
        height: args.height,
        createdByUserId: user._id,
        createdAt: Date.now(),
        updatedAt: Date.now(),
      });
    } else {
      await ctx.db.patch(existing._id, {
        strategyId: strategy._id,
        pageId: page._id,
        elementId,
        storagePath: args.storagePath,
        mimeType: args.mimeType,
        width: args.width,
        height: args.height,
        updatedAt: Date.now(),
      });
    }

    return { ok: true };
  },
});

export const listForStrategy = query({
  args: {
    strategyPublicId: v.string(),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "viewer");

    const assets = await ctx.db
      .query("imageAssets")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
      .collect();

    return assets.map((asset) => ({
      publicId: asset.publicId,
      storagePath: asset.storagePath,
      mimeType: asset.mimeType,
      width: asset.width ?? null,
      height: asset.height ?? null,
      pageId: asset.pageId,
      elementId: asset.elementId ?? null,
      createdAt: asset.createdAt,
      updatedAt: asset.updatedAt,
    }));
  },
});

export const deleteAssetRef = mutation({
  args: {
    strategyPublicId: v.string(),
    assetPublicId: v.string(),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");

    const asset = await ctx.db
      .query("imageAssets")
      .withIndex("by_publicId", (q) => q.eq("publicId", args.assetPublicId))
      .first();

    if (asset === null || asset.strategyId !== strategy._id) {
      throw new Error("Asset not found");
    }

    await ctx.db.delete(asset._id);
    return { ok: true };
  },
});

export const listPotentiallyStale = query({
  args: {
    strategyPublicId: v.string(),
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");

    const assets = await ctx.db
      .query("imageAssets")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
      .collect();

    return assets.filter((asset) => asset.createdByUserId === user._id);
  },
});
