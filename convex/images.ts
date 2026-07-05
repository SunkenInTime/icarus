import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import {
  collectAssetIdFromElementPayload,
  collectAssetIdsFromLineupPayload,
  getActiveAssetForStrategy,
  inferFileExtension,
  getViewerAssetForStrategy,
  inferProvider,
  inferUploadStatus,
  isVisibleAsset,
  serializeAssetForViewer,
  type Provider,
  type UploadStatus,
} from "./lib/imageAssets";
import {
  action,
  internalMutation,
  internalQuery,
  query,
  type MutationCtx,
  type QueryCtx,
} from "./_generated/server";
import { v } from "convex/values";
import { assertStrategyRole } from "./lib/auth";
import { getStrategyByPublicId } from "./lib/entities";
import {
  createR2ObjectKey,
  deleteR2Object,
  expectedMimeTypeForExtension,
  getR2Config,
  headR2Object,
  normalizeImageExtension,
  presignR2PutUrl,
  publicR2UrlForObjectKey,
  validateImageUploadMetadata,
} from "./lib/r2";
import {
  conflictError,
  errorWithCode,
  internalError,
  invalidPayloadError,
  notFoundError,
} from "./lib/errors";

type AnyCtx = MutationCtx | QueryCtx;

type DeletionTarget = {
  assetId: Id<"imageAssets">;
  provider: Provider;
  objectKey: string | null;
};

const maxDeletionBatch = 100;

const providerValidator = v.union(v.literal("convex"), v.literal("r2"));

async function collectReferencedAssetIdsForStrategy(
  ctx: AnyCtx,
  strategyId: Doc<"strategies">["_id"],
): Promise<Set<string>> {
  const assetIds = new Set<string>();

  const elementQuery = ctx.db
    .query("elements")
    .withIndex("by_strategyId", (q) => q.eq("strategyId", strategyId));
  for await (const element of elementQuery) {
    if (element.deleted || element.elementType !== "image") {
      continue;
    }
    const assetId = collectAssetIdFromElementPayload(element.payload);
    if (assetId !== null) {
      assetIds.add(assetId);
    }
  }

  const lineupQuery = ctx.db
    .query("lineups")
    .withIndex("by_strategyId", (q) => q.eq("strategyId", strategyId));
  for await (const lineup of lineupQuery) {
    if (lineup.deleted) {
      continue;
    }
    for (const assetId of collectAssetIdsFromLineupPayload(lineup.payload)) {
      assetIds.add(assetId);
    }
  }

  return assetIds;
}

async function getDeletionCandidateForStrategy(
  ctx: AnyCtx,
  strategyId: Id<"strategies">,
  assetPublicId: string,
): Promise<Doc<"imageAssets"> | null> {
  const strategyCandidates = await ctx.db
    .query("imageAssets")
    .withIndex("by_strategyId_and_publicId", (q) =>
      q.eq("strategyId", strategyId).eq("publicId", assetPublicId),
    )
    .order("desc")
    .take(20);
  const ownedCandidate =
    strategyCandidates.find((asset) => inferUploadStatus(asset) !== "deleted") ??
    null;
  if (ownedCandidate !== null) {
    return ownedCandidate;
  }

  const legacyCandidates = await ctx.db
    .query("imageAssets")
    .withIndex("by_publicId", (q) => q.eq("publicId", assetPublicId))
    .order("desc")
    .take(20);
  return (
    legacyCandidates.find(
      (asset) => asset.strategyId === undefined && isVisibleAsset(asset),
    ) ?? null
  );
}

async function strategyReferencesAsset(
  ctx: AnyCtx,
  strategyId: Doc<"strategies">["_id"],
  assetPublicId: string,
): Promise<boolean> {
  const referencedAssetIds = await collectReferencedAssetIdsForStrategy(
    ctx,
    strategyId,
  );
  return referencedAssetIds.has(assetPublicId);
}

function deletionTargetForAsset(asset: Doc<"imageAssets">): DeletionTarget {
  return {
    assetId: asset._id,
    provider: inferProvider(asset),
    objectKey: asset.objectKey ?? null,
  };
}

async function markImageAssetDeleted(
  ctx: MutationCtx,
  asset: Doc<"imageAssets">,
  now: number,
): Promise<void> {
  if (asset.storageId !== undefined) {
    await ctx.storage.delete(asset.storageId);
  }
  await ctx.db.patch(asset._id, {
    uploadStatus: "deleted",
    deletedAt: now,
    updatedAt: now,
  });
}

export const generateUploadUrl = action({
  args: {
    strategyPublicId: v.string(),
    assetPublicId: v.string(),
    mimeType: v.string(),
    fileExtension: v.string(),
    byteSize: v.optional(v.number()),
    width: v.optional(v.number()),
    height: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const config = getR2Config();
    const validated = validateImageUploadMetadata({
      fileExtension: args.fileExtension,
      mimeType: args.mimeType,
      byteSize: args.byteSize,
      maxImageBytes: config.maxImageBytes,
    });
    const objectKey = createR2ObjectKey({
      strategyPublicId: args.strategyPublicId,
      assetPublicId: args.assetPublicId,
      fileExtension: validated.fileExtension,
    });

    const intent: { uploadId: Id<"imageAssets">; objectKey: string } =
      await ctx.runMutation(internal.images.createR2UploadIntent, {
        strategyPublicId: args.strategyPublicId,
        assetPublicId: args.assetPublicId,
        objectKey,
        mimeType: validated.mimeType,
        fileExtension: validated.fileExtension,
        byteSize: args.byteSize,
        width: args.width,
        height: args.height,
      });
    const signed = await presignR2PutUrl({
      config,
      objectKey: intent.objectKey,
      mimeType: validated.mimeType,
    });

    return {
      provider: "r2" as const,
      uploadId: intent.uploadId,
      objectKey: intent.objectKey,
      uploadUrl: signed.uploadUrl,
      requiredHeaders: signed.requiredHeaders,
      expiresAt: signed.expiresAt,
      maxBytes: config.maxImageBytes,
    };
  },
});

export const createR2UploadIntent = internalMutation({
  args: {
    strategyPublicId: v.string(),
    assetPublicId: v.string(),
    objectKey: v.string(),
    mimeType: v.string(),
    fileExtension: v.string(),
    byteSize: v.optional(v.number()),
    width: v.optional(v.number()),
    height: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    const { user } = await assertStrategyRole(ctx, strategy, "editor");

    const existingObject = await ctx.db
      .query("imageAssets")
      .withIndex("by_objectKey", (q) => q.eq("objectKey", args.objectKey))
      .first();
    if (existingObject !== null) {
      throw conflictError("R2 object key collision. Retry the upload.");
    }

    const now = Date.now();
    const uploadId = await ctx.db.insert("imageAssets", {
      publicId: args.assetPublicId,
      provider: "r2",
      strategyId: strategy._id,
      createdByUserId: user._id,
      objectKey: args.objectKey,
      uploadStatus: "pending",
      fileExtension: args.fileExtension,
      mimeType: args.mimeType,
      width: args.width,
      height: args.height,
      byteSize: args.byteSize,
      createdAt: now,
      updatedAt: now,
    });

    return { uploadId, objectKey: args.objectKey };
  },
});

export const completeUpload = action({
  args: {
    strategyPublicId: v.string(),
    assetPublicId: v.string(),
    provider: v.optional(providerValidator),
    uploadId: v.optional(v.id("imageAssets")),
    objectKey: v.optional(v.string()),
    storageId: v.optional(v.id("_storage")),
    etag: v.optional(v.string()),
    mimeType: v.optional(v.string()),
    fileExtension: v.optional(v.string()),
    byteSize: v.optional(v.number()),
    width: v.optional(v.number()),
    height: v.optional(v.number()),
  },
  handler: async (
    ctx,
    args,
  ): Promise<{
    ok: true;
    provider: Provider;
    url?: string | null;
  }> => {
    if (args.storageId !== undefined || args.provider === "convex") {
      await ctx.runMutation(internal.images.completeLegacyUpload, {
        strategyPublicId: args.strategyPublicId,
        assetPublicId: args.assetPublicId,
        storageId: args.storageId,
        mimeType: args.mimeType,
        fileExtension: args.fileExtension,
        width: args.width,
        height: args.height,
      });
      return { ok: true, provider: "convex" };
    }

    if (args.uploadId === undefined) {
      throw invalidPayloadError("Missing R2 uploadId for image completion.");
    }

    const intent: {
      uploadId: Id<"imageAssets">;
      objectKey: string;
      uploadStatus: UploadStatus;
      fileExtension: string;
      mimeType: string;
      byteSize: number | null;
    } = await ctx.runQuery(internal.images.getR2UploadIntentForCompletion, {
      strategyPublicId: args.strategyPublicId,
      assetPublicId: args.assetPublicId,
      uploadId: args.uploadId,
    });

    if (args.objectKey !== undefined && args.objectKey !== intent.objectKey) {
      throw errorWithCode(
        "R2_OBJECT_KEY_MISMATCH",
        "R2 object key does not match upload intent.",
      );
    }
    if (intent.uploadStatus === "active") {
      return {
        ok: true,
        provider: "r2" as const,
        url: publicR2UrlForObjectKey(intent.objectKey),
      };
    }

    const config = getR2Config();
    const metadata = await headR2Object(config, intent.objectKey);
    if (metadata === null) {
      await ctx.runMutation(internal.images.markR2UploadFailed, {
        uploadId: intent.uploadId,
        reason: "R2 object was not found during completion.",
      });
      throw notFoundError("Uploaded image", intent.objectKey);
    }

    const expectedMimeType =
      args.mimeType ??
      intent.mimeType ??
      expectedMimeTypeForExtension(intent.fileExtension);
    const actualMimeType =
      metadata.mimeType?.split(";")[0]?.trim().toLowerCase() ?? null;
    const actualByteSize = metadata.byteSize;
    if (
      actualByteSize === null ||
      actualByteSize <= 0 ||
      actualByteSize > config.maxImageBytes ||
      expectedMimeType === null ||
      actualMimeType !== expectedMimeType
    ) {
      await deleteR2Object(config, intent.objectKey);
      await ctx.runMutation(internal.images.markR2UploadFailed, {
        uploadId: intent.uploadId,
        reason: "Uploaded R2 object failed size or MIME validation.",
      });
      throw invalidPayloadError("Uploaded image failed size or MIME validation.");
    }

    const result: { ok: true; replaced: DeletionTarget[] } =
      await ctx.runMutation(internal.images.markR2UploadActive, {
        strategyPublicId: args.strategyPublicId,
        assetPublicId: args.assetPublicId,
        uploadId: intent.uploadId,
        byteSize: actualByteSize,
        etag: metadata.etag ?? args.etag,
        mimeType: actualMimeType,
        fileExtension: args.fileExtension ?? intent.fileExtension,
        width: args.width,
        height: args.height,
      });

    for (const target of result.replaced) {
      if (target.provider === "r2" && target.objectKey !== null) {
        await deleteR2Object(config, target.objectKey);
      }
    }

    return {
      ok: true,
      provider: "r2" as const,
      url: publicR2UrlForObjectKey(intent.objectKey),
    };
  },
});

export const getR2UploadIntentForCompletion = internalQuery({
  args: {
    strategyPublicId: v.string(),
    assetPublicId: v.string(),
    uploadId: v.id("imageAssets"),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");

    const asset = await ctx.db.get(args.uploadId);
    if (
      asset === null ||
      asset.strategyId !== strategy._id ||
      asset.publicId !== args.assetPublicId ||
      inferProvider(asset) !== "r2" ||
      asset.objectKey === undefined
    ) {
      throw errorWithCode("UPLOAD_INTENT_NOT_FOUND", "Upload intent not found.");
    }

    const fileExtension = inferFileExtension(asset);
    const expectedMimeType = expectedMimeTypeForExtension(fileExtension);
    if (expectedMimeType === null || asset.mimeType === undefined) {
      throw invalidPayloadError("Upload intent has invalid image metadata.");
    }

    return {
      uploadId: asset._id,
      objectKey: asset.objectKey,
      uploadStatus: inferUploadStatus(asset),
      fileExtension,
      mimeType: asset.mimeType,
      byteSize: asset.byteSize ?? null,
    };
  },
});

export const markR2UploadActive = internalMutation({
  args: {
    strategyPublicId: v.string(),
    assetPublicId: v.string(),
    uploadId: v.id("imageAssets"),
    byteSize: v.number(),
    etag: v.optional(v.string()),
    mimeType: v.string(),
    fileExtension: v.string(),
    width: v.optional(v.number()),
    height: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");

    const asset = await ctx.db.get(args.uploadId);
    if (
      asset === null ||
      asset.strategyId !== strategy._id ||
      asset.publicId !== args.assetPublicId ||
      inferProvider(asset) !== "r2" ||
      asset.objectKey === undefined
    ) {
      throw errorWithCode("UPLOAD_INTENT_NOT_FOUND", "Upload intent not found.");
    }

    const now = Date.now();
    await ctx.db.patch(asset._id, {
      uploadStatus: "active",
      fileExtension: normalizeImageExtension(args.fileExtension),
      mimeType: args.mimeType,
      width: args.width ?? asset.width,
      height: args.height ?? asset.height,
      byteSize: args.byteSize,
      etag: args.etag,
      uploadedAt: now,
      updatedAt: now,
    });

    const olderActiveAssets = await ctx.db
      .query("imageAssets")
      .withIndex("by_strategyId_and_publicId_and_uploadStatus", (q) =>
        q
          .eq("strategyId", strategy._id)
          .eq("publicId", args.assetPublicId)
          .eq("uploadStatus", "active"),
      )
      .take(20);
    const replaced: DeletionTarget[] = [];
    for (const olderAsset of olderActiveAssets) {
      if (olderAsset._id === asset._id) {
        continue;
      }
      replaced.push(deletionTargetForAsset(olderAsset));
      await markImageAssetDeleted(ctx, olderAsset, now);
    }

    return { ok: true as const, replaced };
  },
});

export const markR2UploadFailed = internalMutation({
  args: {
    uploadId: v.id("imageAssets"),
    reason: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const asset = await ctx.db.get(args.uploadId);
    if (asset === null || inferUploadStatus(asset) === "deleted") {
      return { ok: true };
    }
    await ctx.db.patch(asset._id, {
      uploadStatus: "failed",
      updatedAt: Date.now(),
    });
    return { ok: true };
  },
});

export const completeLegacyUpload = internalMutation({
  args: {
    strategyPublicId: v.string(),
    assetPublicId: v.string(),
    storageId: v.optional(v.id("_storage")),
    mimeType: v.optional(v.string()),
    fileExtension: v.optional(v.string()),
    width: v.optional(v.number()),
    height: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    if (args.storageId === undefined) {
      throw internalError("Missing Convex storageId for legacy image completion.");
    }

    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    const { user } = await assertStrategyRole(ctx, strategy, "editor");
    const now = Date.now();
    const metadata = await ctx.db.system.get("_storage", args.storageId);
    const existing = await getDeletionCandidateForStrategy(
      ctx,
      strategy._id,
      args.assetPublicId,
    );

    if (
      existing !== null &&
      (existing.strategyId === undefined || existing.strategyId === strategy._id) &&
      inferProvider(existing) === "convex"
    ) {
      const previousStorageId = existing.storageId;
      await ctx.db.patch(existing._id, {
        provider: "convex",
        strategyId: strategy._id,
        createdByUserId: existing.createdByUserId ?? user._id,
        storageId: args.storageId,
        uploadStatus: "active",
        fileExtension: args.fileExtension,
        mimeType: args.mimeType ?? metadata?.contentType,
        width: args.width,
        height: args.height,
        byteSize: metadata?.size,
        uploadedAt: now,
        updatedAt: now,
      });
      if (
        previousStorageId !== undefined &&
        previousStorageId !== args.storageId
      ) {
        await ctx.storage.delete(previousStorageId);
      }
    } else {
      await ctx.db.insert("imageAssets", {
        publicId: args.assetPublicId,
        provider: "convex",
        strategyId: strategy._id,
        createdByUserId: user._id,
        storageId: args.storageId,
        uploadStatus: "active",
        fileExtension: args.fileExtension,
        mimeType: args.mimeType ?? metadata?.contentType,
        width: args.width,
        height: args.height,
        byteSize: metadata?.size,
        uploadedAt: now,
        createdAt: now,
        updatedAt: now,
      });
    }

    return { ok: true, provider: "convex" as const };
  },
});

export const listForStrategy = query({
  args: {
    strategyPublicId: v.string(),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "viewer");

    const referencedAssetIds = await collectReferencedAssetIdsForStrategy(
      ctx,
      strategy._id,
    );
    const assets = await Promise.all(
      [...referencedAssetIds].map((assetPublicId) =>
        getViewerAssetForStrategy(ctx, strategy._id, assetPublicId),
      ),
    );

    return await Promise.all(
      assets
        .filter((asset): asset is Doc<"imageAssets"> => asset !== null)
        .map((asset) => serializeAssetForViewer(ctx, asset)),
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

    if (
      !(await strategyReferencesAsset(ctx, strategy._id, args.assetPublicId))
    ) {
      throw notFoundError("Asset", args.assetPublicId);
    }

    const asset = await getActiveAssetForStrategy(
      ctx,
      strategy._id,
      args.assetPublicId,
    );
    if (asset === null) {
      throw notFoundError("Asset", args.assetPublicId);
    }

    return {
      url:
        inferProvider(asset) === "r2"
          ? asset.objectKey === undefined
            ? null
            : publicR2UrlForObjectKey(asset.objectKey)
          : asset.storageId === undefined
            ? null
            : await ctx.storage.getUrl(asset.storageId),
    };
  },
});

export const deleteAssetRef = action({
  args: {
    strategyPublicId: v.string(),
    assetPublicId: v.string(),
  },
  handler: async (ctx, args) => {
    const target: DeletionTarget = await ctx.runQuery(
      internal.images.getAssetDeletionTarget,
      args,
    );

    if (target.provider === "r2" && target.objectKey !== null) {
      await deleteR2Object(getR2Config(), target.objectKey);
    }

    await ctx.runMutation(internal.images.markDeletedAssetRefsForStrategy, {
      strategyPublicId: args.strategyPublicId,
      assetIds: [target.assetId],
    });
    return { ok: true };
  },
});

export const getAssetDeletionTarget = internalQuery({
  args: {
    strategyPublicId: v.string(),
    assetPublicId: v.string(),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");

    const asset = await getDeletionCandidateForStrategy(
      ctx,
      strategy._id,
      args.assetPublicId,
    );
    if (asset === null) {
      throw notFoundError("Asset", args.assetPublicId);
    }

    if (
      asset.strategyId === undefined &&
      !(await strategyReferencesAsset(ctx, strategy._id, args.assetPublicId))
    ) {
      throw notFoundError("Asset", args.assetPublicId);
    }

    return deletionTargetForAsset(asset);
  },
});

export const markDeletedAssetRefsForStrategy = internalMutation({
  args: {
    strategyPublicId: v.string(),
    assetIds: v.array(v.id("imageAssets")),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");

    const now = Date.now();
    let deleted = 0;
    for (const assetId of args.assetIds.slice(0, maxDeletionBatch)) {
      const asset = await ctx.db.get(assetId);
      if (asset === null || inferUploadStatus(asset) === "deleted") {
        continue;
      }
      if (asset.strategyId !== undefined && asset.strategyId !== strategy._id) {
        continue;
      }
      await markImageAssetDeleted(ctx, asset, now);
      deleted += 1;
    }
    return { ok: true, deleted };
  },
});

export const listPotentiallyStale = query({
  args: {
    strategyPublicId: v.string(),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");
    const limit = Math.max(1, Math.min(args.limit ?? 200, 500));

    const referencedAssetIds = await collectReferencedAssetIdsForStrategy(
      ctx,
      strategy._id,
    );
    const assets = await ctx.db
      .query("imageAssets")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
      .order("desc")
      .take(limit);

    const candidates = assets.filter((asset) => {
      const status = inferUploadStatus(asset);
      if (status === "deleted") {
        return false;
      }
      if (status === "pending" || status === "failed") {
        return true;
      }
      return !referencedAssetIds.has(asset.publicId);
    });

    return await Promise.all(
      candidates.map((asset) => serializeAssetForViewer(ctx, asset)),
    );
  },
});

export const sweepStaleUploadsForStrategy = action({
  args: {
    strategyPublicId: v.string(),
    staleBefore: v.number(),
    limit: v.optional(v.number()),
  },
  handler: async (
    ctx,
    args,
  ): Promise<{
    ok: true;
    deleted: number;
  }> => {
    const targets: DeletionTarget[] = await ctx.runQuery(
      internal.images.listStaleUploadDeletionTargets,
      args,
    );
    const config = targets.some(
      (target) => target.provider === "r2" && target.objectKey !== null,
    )
      ? getR2Config()
      : null;

    for (const target of targets) {
      if (
        config !== null &&
        target.provider === "r2" &&
        target.objectKey !== null
      ) {
        await deleteR2Object(config, target.objectKey);
      }
    }

    const result: { ok: boolean; deleted: number } = await ctx.runMutation(
      internal.images.markDeletedAssetRefsForStrategy,
      {
        strategyPublicId: args.strategyPublicId,
        assetIds: targets.map((target) => target.assetId),
      },
    );
    return { ok: true, deleted: result.deleted };
  },
});

export const listStaleUploadDeletionTargets = internalQuery({
  args: {
    strategyPublicId: v.string(),
    staleBefore: v.number(),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");
    const limit = Math.max(1, Math.min(args.limit ?? 50, maxDeletionBatch));

    const targets: DeletionTarget[] = [];
    for (const status of ["pending", "failed"] as UploadStatus[]) {
      const candidates = await ctx.db
        .query("imageAssets")
        .withIndex("by_strategyId_and_uploadStatus_and_updatedAt", (q) =>
          q
            .eq("strategyId", strategy._id)
            .eq("uploadStatus", status)
            .lte("updatedAt", args.staleBefore),
        )
        .take(limit - targets.length);
      for (const asset of candidates) {
        targets.push(deletionTargetForAsset(asset));
      }
      if (targets.length >= limit) {
        break;
      }
    }

    return targets;
  },
});
