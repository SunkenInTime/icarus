import type { Doc, Id } from "./_generated/dataModel";
import { mutation, query, type MutationCtx, type QueryCtx } from "./_generated/server";
import { ConvexError, v } from "convex/values";
import { assertStrategyRole, requireCurrentUser } from "./lib/auth";
import {
  getElementByPublicId,
  getLineupByPublicId,
  getPageByPublicId,
  getStrategyByPublicId,
} from "./lib/entities";

type AnyCtx = MutationCtx | QueryCtx;
type ImageAssetOwnerType = "element" | "lineup";

function normalizeOwnerType(
  asset: Pick<Doc<"imageAssets">, "ownerType">,
): ImageAssetOwnerType {
  return asset.ownerType ?? "element";
}

function ownerNotFoundError(
  ownerType: ImageAssetOwnerType,
  ownerPublicId: string,
): ConvexError<{
  code: "OWNER_NOT_FOUND";
  message: "owner_not_found";
  ownerType: ImageAssetOwnerType;
  ownerPublicId: string;
}> {
  return new ConvexError({
    code: "OWNER_NOT_FOUND",
    message: "owner_not_found",
    ownerType,
    ownerPublicId,
  });
}

async function getImageAssetByPublicId(
  ctx: AnyCtx,
  assetPublicId: string,
): Promise<Doc<"imageAssets"> | null> {
  return await ctx.db
    .query("imageAssets")
    .withIndex("by_publicId", (q) => q.eq("publicId", assetPublicId))
    .unique();
}

function inferFileExtension(
  asset: Pick<Doc<"imageAssets">, "fileExtension" | "storagePath">,
): string {
  if (asset.fileExtension !== undefined && asset.fileExtension.length > 0) {
    return asset.fileExtension;
  }

  const legacyPath = asset.storagePath ?? "";
  const match = legacyPath.match(/(\.[A-Za-z0-9]+)(?:$|[?#])/);
  return match?.[1]?.toLowerCase() ?? "";
}

async function resolveOwnerAttachment(
  ctx: MutationCtx,
  args: {
    strategyId: Id<"strategies">;
    pageId: Id<"pages">;
    ownerType: ImageAssetOwnerType;
    ownerPublicId: string;
  },
): Promise<{
  elementId: Id<"elements"> | undefined;
  lineupId: Id<"lineups"> | undefined;
}> {
  if (args.ownerType === "element") {
    try {
      const element = await getElementByPublicId(ctx, args.ownerPublicId);
      if (element.strategyId !== args.strategyId || element.pageId !== args.pageId) {
        throw new Error("Element context mismatch");
      }
      return {
        elementId: element._id,
        lineupId: undefined,
      };
    } catch (error) {
      if (error instanceof Error && error.message.startsWith("Element not found:")) {
        throw ownerNotFoundError(args.ownerType, args.ownerPublicId);
      }
      throw error;
    }
  }

  try {
    const lineup = await getLineupByPublicId(ctx, args.ownerPublicId);
    if (lineup.strategyId !== args.strategyId || lineup.pageId !== args.pageId) {
      throw new Error("Lineup context mismatch");
    }
    return {
      elementId: undefined,
      lineupId: lineup._id,
    };
  } catch (error) {
    if (error instanceof Error && error.message.startsWith("Lineup not found:")) {
      throw ownerNotFoundError(args.ownerType, args.ownerPublicId);
    }
    throw error;
  }
}

async function serializeAssetForViewer(
  ctx: QueryCtx,
  strategyPublicId: string,
  asset: Doc<"imageAssets">,
): Promise<{
  publicId: string;
  strategyPublicId: string;
  pagePublicId: string;
  ownerType: ImageAssetOwnerType;
  ownerPublicId: string;
  fileExtension: string;
  mimeType: string;
  width: number | null;
  height: number | null;
  url: string | null;
  legacyStoragePath: string | null;
} | null> {
  const page = await ctx.db.get(asset.pageId);
  if (page === null) {
    return null;
  }

  const ownerType = normalizeOwnerType(asset);
  const ownerDoc = ownerType === "lineup"
    ? asset.lineupId === undefined
      ? null
      : await ctx.db.get(asset.lineupId)
    : asset.elementId === undefined
      ? null
      : await ctx.db.get(asset.elementId);

  if (ownerDoc === null) {
    return null;
  }

  const url = asset.storageId === undefined
    ? null
    : await ctx.storage.getUrl(asset.storageId);

  return {
    publicId: asset.publicId,
    strategyPublicId,
    pagePublicId: page.publicId,
    ownerType,
    ownerPublicId: ownerDoc.publicId,
    fileExtension: inferFileExtension(asset),
    mimeType: asset.mimeType,
    width: asset.width ?? null,
    height: asset.height ?? null,
    url,
    legacyStoragePath: asset.storagePath ?? null,
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

export async function deleteImageAssetsForPage(
  ctx: MutationCtx,
  pageId: Id<"pages">,
): Promise<void> {
  const assets = await ctx.db
    .query("imageAssets")
    .withIndex("by_pageId", (q) => q.eq("pageId", pageId))
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
    pagePublicId: v.string(),
    assetPublicId: v.string(),
    ownerType: v.union(v.literal("element"), v.literal("lineup")),
    ownerPublicId: v.string(),
    storageId: v.id("_storage"),
    mimeType: v.string(),
    fileExtension: v.string(),
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

    const { elementId, lineupId } = await resolveOwnerAttachment(ctx, {
      strategyId: strategy._id,
      pageId: page._id,
      ownerType: args.ownerType,
      ownerPublicId: args.ownerPublicId,
    });
    const existing = await getImageAssetByPublicId(ctx, args.assetPublicId);
    const now = Date.now();

    if (existing === null) {
      await ctx.db.insert("imageAssets", {
        publicId: args.assetPublicId,
        strategyId: strategy._id,
        pageId: page._id,
        ownerType: args.ownerType,
        elementId,
        lineupId,
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
        strategyId: strategy._id,
        pageId: page._id,
        ownerType: args.ownerType,
        elementId,
        lineupId,
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

    const serialized = await Promise.all(
      assets.map((asset) => serializeAssetForViewer(ctx, strategy.publicId, asset)),
    );

    return serialized.filter((asset) => asset !== null);
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

    const serialized = await Promise.all(
      assets
        .filter((asset) => asset.createdByUserId === user._id)
        .map((asset) => serializeAssetForViewer(ctx, strategy.publicId, asset)),
    );

    return serialized.filter((asset) => asset !== null);
  },
});
