import type { Doc, Id } from "./_generated/dataModel";
import { mutation, query, type MutationCtx, type QueryCtx } from "./_generated/server";
import { v } from "convex/values";
import { assertStrategyRole, requireCurrentUser } from "./lib/auth";
import { getStrategyByPublicId } from "./lib/entities";

type AnyCtx = MutationCtx | QueryCtx;

async function getImageAssetByPublicId(
  ctx: AnyCtx,
  assetPublicId: string,
): Promise<Doc<"imageAssets"> | null> {
  return await ctx.db
    .query("imageAssets")
    .withIndex("by_publicId", (q) => q.eq("publicId", assetPublicId))
    .unique();
}

async function serializeAssetForViewer(
  ctx: QueryCtx,
  strategyPublicId: string,
  asset: Doc<"imageAssets">,
): Promise<{
  publicId: string;
  strategyPublicId: string;
  fileExtension: string;
  mimeType: string;
  width: number | null;
  height: number | null;
  url: string | null;
}> {
  const url = asset.storageId === undefined
    ? null
    : await ctx.storage.getUrl(asset.storageId);

  return {
    publicId: asset.publicId,
    strategyPublicId,
    fileExtension: asset.fileExtension ?? "",
    mimeType: asset.mimeType,
    width: asset.width ?? null,
    height: asset.height ?? null,
    url,
  };
}

export async function deleteImageAsset(
  ctx: MutationCtx,
  asset: Doc<"imageAssets">,
): Promise<void> {
  if (asset.storageId !== undefined) {
    await ctx.storage.delete(asset.storageId);
  }
  await ctx.db.delete(asset._id);
}

export async function deleteImageAssetsForStrategy(
  ctx: MutationCtx,
  strategyId: Id<"strategies">,
): Promise<void> {
  const assets = await ctx.db
    .query("imageAssets")
    .withIndex("by_strategyId", (q) => q.eq("strategyId", strategyId))
    .collect();

  for (const asset of assets) {
    await deleteImageAsset(ctx, asset);
  }
}

export const generateUploadUrl = mutation({
  args: {
    strategyPublicId: v.string(),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");

    return {
      uploadUrl: await ctx.storage.generateUploadUrl(),
    };
  },
});

export const completeUpload = mutation({
  args: {
    strategyPublicId: v.string(),
    assetPublicId: v.string(),
    storageId: v.id("_storage"),
    mimeType: v.string(),
    fileExtension: v.string(),
    width: v.optional(v.number()),
    height: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    const { user } = await assertStrategyRole(ctx, strategy, "editor");
    const existing = await getImageAssetByPublicId(ctx, args.assetPublicId);
    const now = Date.now();

    if (existing === null) {
      await ctx.db.insert("imageAssets", {
        publicId: args.assetPublicId,
        strategyId: strategy._id,
        storageId: args.storageId,
        fileExtension: args.fileExtension,
        mimeType: args.mimeType,
        width: args.width,
        height: args.height,
        createdByUserId: user._id,
        createdAt: now,
        updatedAt: now,
      });
    } else {
      if (existing.strategyId !== strategy._id) {
        throw new Error("Asset strategy mismatch");
      }

      await ctx.db.patch(existing._id, {
        storageId: args.storageId,
        fileExtension: args.fileExtension,
        mimeType: args.mimeType,
        width: args.width,
        height: args.height,
        updatedAt: now,
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

    return await Promise.all(
      assets.map((asset) => serializeAssetForViewer(ctx, strategy.publicId, asset)),
    );
  },
});

export const getAssetUrl = query({
  args: {
    strategyPublicId: v.string(),
    assetPublicId: v.string(),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "viewer");

    const asset = await getImageAssetByPublicId(ctx, args.assetPublicId);
    if (asset === null || asset.strategyId !== strategy._id) {
      throw new Error("Asset not found");
    }

    return {
      url:
        asset.storageId === undefined ? null : await ctx.storage.getUrl(asset.storageId),
    };
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

    const asset = await getImageAssetByPublicId(ctx, args.assetPublicId);

    if (asset === null || asset.strategyId !== strategy._id) {
      throw new Error("Asset not found");
    }

    await deleteImageAsset(ctx, asset);
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

    return await Promise.all(
      assets
        .filter((asset) => asset.createdByUserId === user._id)
        .map((asset) => serializeAssetForViewer(ctx, strategy.publicId, asset)),
    );
  },
});
