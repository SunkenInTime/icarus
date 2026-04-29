import type { Doc } from "./_generated/dataModel";
import { mutation, query, type MutationCtx, type QueryCtx } from "./_generated/server";
import { v } from "convex/values";
import { assertStrategyRole } from "./lib/auth";
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

function decodeObject(payload: string): Record<string, unknown> | null {
  try {
    const decoded = JSON.parse(payload);
    if (typeof decoded === "object" && decoded !== null) {
      return decoded as Record<string, unknown>;
    }
  } catch (_) {
    // Ignore malformed payloads while gathering asset references.
  }
  return null;
}

function collectAssetIdFromElementPayload(payload: string): string | null {
  const decoded = decodeObject(payload);
  if (decoded === null) {
    return null;
  }
  return typeof decoded.id === "string" ? decoded.id : null;
}

function collectAssetIdsFromLineupPayload(payload: string): Set<string> {
  const assetIds = new Set<string>();
  const decoded = decodeObject(payload);
  if (decoded === null) {
    return assetIds;
  }

  const rawImages = decoded.images;
  if (!Array.isArray(rawImages)) {
    return assetIds;
  }

  for (const image of rawImages) {
    if (typeof image === "object" && image !== null && typeof image.id === "string") {
      assetIds.add(image.id);
    }
  }
  return assetIds;
}

async function collectReferencedAssetIdsForStrategy(
  ctx: AnyCtx,
  strategyId: Doc<"strategies">["_id"],
): Promise<Set<string>> {
  const assetIds = new Set<string>();

  const elements = await ctx.db
    .query("elements")
    .withIndex("by_strategyId", (q) => q.eq("strategyId", strategyId))
    .collect();
  for (const element of elements) {
    if (element.deleted || element.elementType !== "image") {
      continue;
    }

    const assetId = collectAssetIdFromElementPayload(element.payload);
    if (assetId !== null) {
      assetIds.add(assetId);
    }
  }

  const lineups = await ctx.db
    .query("lineups")
    .withIndex("by_strategyId", (q) => q.eq("strategyId", strategyId))
    .collect();
  for (const lineup of lineups) {
    if (lineup.deleted) {
      continue;
    }

    for (const assetId of collectAssetIdsFromLineupPayload(lineup.payload)) {
      assetIds.add(assetId);
    }
  }

  return assetIds;
}

async function strategyReferencesAsset(
  ctx: AnyCtx,
  strategyId: Doc<"strategies">["_id"],
  assetPublicId: string,
): Promise<boolean> {
  const referencedAssetIds = await collectReferencedAssetIdsForStrategy(ctx, strategyId);
  return referencedAssetIds.has(assetPublicId);
}

async function serializeAssetForViewer(
  ctx: QueryCtx,
  asset: Doc<"imageAssets">,
): Promise<{
  publicId: string;
  fileExtension: string;
  mimeType: string | null;
  width: number | null;
  height: number | null;
  url: string | null;
  legacyStoragePath: string | null;
}> {
  return {
    publicId: asset.publicId,
    fileExtension: inferFileExtension(asset),
    mimeType: asset.mimeType ?? null,
    width: asset.width ?? null,
    height: asset.height ?? null,
    url:
      asset.storageId === undefined ? null : await ctx.storage.getUrl(asset.storageId),
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
    mimeType: v.optional(v.string()),
    fileExtension: v.optional(v.string()),
    width: v.optional(v.number()),
    height: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");

    const existing = await getImageAssetByPublicId(ctx, args.assetPublicId);
    const now = Date.now();

    if (existing === null) {
      await ctx.db.insert("imageAssets", {
        publicId: args.assetPublicId,
        storageId: args.storageId,
        fileExtension: args.fileExtension,
        mimeType: args.mimeType,
        width: args.width,
        height: args.height,
        createdAt: now,
        updatedAt: now,
      });
    } else {
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

    const referencedAssetIds = await collectReferencedAssetIdsForStrategy(ctx, strategy._id);
    const assets = await Promise.all(
      [...referencedAssetIds].map((assetPublicId) =>
        getImageAssetByPublicId(ctx, assetPublicId),
      ),
    );

    const serialized = await Promise.all(
      assets
        .filter((asset): asset is Doc<"imageAssets"> => asset !== null)
        .map((asset) => serializeAssetForViewer(ctx, asset)),
    );

    return serialized;
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
    if (
      asset === null ||
      !(await strategyReferencesAsset(ctx, strategy._id, args.assetPublicId))
    ) {
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
    if (
      asset === null ||
      !(await strategyReferencesAsset(ctx, strategy._id, args.assetPublicId))
    ) {
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
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");
    return [];
  },
});
