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
  serializeAssetForViewer,
  type Provider,
  type UploadStatus,
} from "./lib/imageAssets";
import {
  action,
  internalAction,
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
import {
  imageAssetValidator,
  imageProviderValidator,
  okResultValidator,
} from "./lib/publicValidators";
import {
  assertSupportedCloudProtocol,
  cloudProtocolArgs,
} from "./lib/cloudProtocol";
import { makeFunctionReference } from "convex/server";

type AnyCtx = MutationCtx | QueryCtx;

type DeletionTarget = {
  assetId: Id<"imageAssets">;
  provider: Provider;
  objectKey: string | null;
  sharedTarget: boolean;
};

const maxDeletionBatch = 100;
const physicalDeletionBatch = 25;
const pageAssetIdBatch = 50;
const staleUploadAgeMs = 24 * 60 * 60 * 1000;
const staleDeletionClaimAgeMs = 15 * 60 * 1000;
const deletionRetryDelayMs = 60 * 1000;

export const markDeletedPageImageAssetsRef = makeFunctionReference<"mutation">(
  "images:markDeletedPageImageAssets",
);
export const markDeletedStrategyImageAssetsRef =
  makeFunctionReference<"mutation">("images:markDeletedStrategyImageAssets");
export const markStaleImageUploadsDeletedRef =
  makeFunctionReference<"mutation">("images:markStaleImageUploadsDeleted");
export const sweepDeletedImageAssetsRef = makeFunctionReference<"action">(
  "images:sweepDeletedImageAssets",
);
const claimDeletedImageAssetsRef = makeFunctionReference<"mutation">(
  "images:claimDeletedImageAssets",
);
const getDeletedImageAssetTargetRef = makeFunctionReference<"query">(
  "images:getDeletedImageAssetTarget",
);
const finalizeDeletedImageAssetRef = makeFunctionReference<"mutation">(
  "images:finalizeDeletedImageAsset",
);
const scheduleDeletedImageAssetSweepRef = makeFunctionReference<"mutation">(
  "images:scheduleDeletedImageAssetSweep",
);
const releaseImageAssetDeletionClaimsRef = makeFunctionReference<"mutation">(
  "images:releaseImageAssetDeletionClaims",
);

function createUploadAttemptPublicId(): string {
  return crypto.randomUUID();
}

async function collectReferencedAssetIdsForStrategy(
  ctx: AnyCtx,
  strategyId: Doc<"strategies">["_id"],
  excludedPageId?: Id<"pages">,
): Promise<Set<string>> {
  const assetIds = new Set<string>();

  const elementQuery = ctx.db
    .query("elements")
    .withIndex("by_strategyId", (q) => q.eq("strategyId", strategyId));
  for await (const element of elementQuery) {
    if (
      element.deleted ||
      element.pageId === excludedPageId ||
      element.elementType !== "image"
    ) {
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
    if (lineup.deleted || lineup.pageId === excludedPageId) {
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
  return ownedCandidate;
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

async function markImageAssetDeleted(
  ctx: MutationCtx,
  asset: Doc<"imageAssets">,
  now: number,
): Promise<void> {
  await ctx.db.patch(asset._id, {
    uploadStatus: "deleted",
    deletedAt: now,
    cleanupClaimedAt: undefined,
    updatedAt: now,
  });
}

async function schedulePhysicalDeletion(
  ctx: MutationCtx,
  delayMs = 0,
): Promise<void> {
  await ctx.scheduler.runAfter(delayMs, sweepDeletedImageAssetsRef, {});
}

function chunks<T>(values: T[], size: number): T[][] {
  const result: T[][] = [];
  for (let index = 0; index < values.length; index += size) {
    result.push(values.slice(index, index + size));
  }
  return result;
}

export async function captureDeletedPageImageAssets(
  ctx: MutationCtx,
  args: {
    strategyId: Id<"strategies">;
    pageId: Id<"pages">;
    assetPublicIds: Iterable<string>;
  },
): Promise<void> {
  const assetPublicIds = [...new Set(args.assetPublicIds)];
  for (const assetIdChunk of chunks(assetPublicIds, pageAssetIdBatch)) {
    await ctx.scheduler.runAfter(0, markDeletedPageImageAssetsRef, {
      strategyId: args.strategyId,
      pageId: args.pageId,
      assetPublicIds: assetIdChunk,
    });
  }
}

export const generateUploadUrl = action({
  args: {
    ...cloudProtocolArgs,
    strategyPublicId: v.string(),
    assetPublicId: v.string(),
    mimeType: v.string(),
    fileExtension: v.string(),
    byteSize: v.optional(v.number()),
    width: v.optional(v.number()),
    height: v.optional(v.number()),
  },
  returns: v.object({
    provider: v.literal("r2"),
    uploadId: v.string(),
    objectKey: v.string(),
    uploadUrl: v.string(),
    requiredHeaders: v.record(v.string(), v.string()),
    expiresAt: v.number(),
    maxBytes: v.number(),
  }),
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
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

    const uploadAttemptPublicId = createUploadAttemptPublicId();
    const intent: {
      uploadId: Id<"imageAssets">;
      uploadAttemptPublicId: string;
      objectKey: string;
    } =
      await ctx.runMutation(internal.images.createR2UploadIntent, {
        strategyPublicId: args.strategyPublicId,
        assetPublicId: args.assetPublicId,
        objectKey,
        uploadAttemptPublicId,
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
      uploadId: intent.uploadAttemptPublicId,
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
    uploadAttemptPublicId: v.string(),
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
      uploadAttemptPublicId: args.uploadAttemptPublicId,
      uploadStatus: "pending",
      fileExtension: args.fileExtension,
      mimeType: args.mimeType,
      width: args.width,
      height: args.height,
      byteSize: args.byteSize,
      createdAt: now,
      updatedAt: now,
    });

    return {
      uploadId,
      uploadAttemptPublicId: args.uploadAttemptPublicId,
      objectKey: args.objectKey,
    };
  },
});

export const completeUpload = action({
  args: {
    ...cloudProtocolArgs,
    strategyPublicId: v.string(),
    assetPublicId: v.string(),
    provider: v.optional(imageProviderValidator),
    uploadId: v.optional(v.string()),
    objectKey: v.optional(v.string()),
    storageId: v.optional(v.id("_storage")),
    etag: v.optional(v.string()),
    mimeType: v.optional(v.string()),
    fileExtension: v.optional(v.string()),
    byteSize: v.optional(v.number()),
    width: v.optional(v.number()),
    height: v.optional(v.number()),
  },
  returns: v.union(
    v.object({ ok: v.literal(true), provider: v.literal("convex") }),
    v.object({
      ok: v.literal(true),
      provider: v.literal("r2"),
      url: v.string(),
    }),
  ),
  handler: async (
    ctx,
    args,
  ) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
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
      return { ok: true, provider: "convex" } as const;
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
      uploadAttemptPublicId: args.uploadId,
    });

    if (args.objectKey !== undefined && args.objectKey !== intent.objectKey) {
      throw errorWithCode(
        "R2_OBJECT_KEY_MISMATCH",
        "R2 object key does not match upload intent.",
      );
    }
    if (intent.uploadStatus === "active") {
      return {
        ok: true as const,
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

    return {
      ok: true as const,
      provider: "r2" as const,
      url: publicR2UrlForObjectKey(intent.objectKey),
    };
  },
});

export const getR2UploadIntentForCompletion = internalQuery({
  args: {
    strategyPublicId: v.string(),
    assetPublicId: v.string(),
    uploadAttemptPublicId: v.string(),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");

    const asset = await ctx.db
      .query("imageAssets")
      .withIndex("by_uploadAttemptPublicId", (q) =>
        q.eq("uploadAttemptPublicId", args.uploadAttemptPublicId),
      )
      .unique();
    if (
      asset === null ||
      asset.strategyId !== strategy._id ||
      asset.publicId !== args.assetPublicId ||
      inferProvider(asset) !== "r2" ||
      asset.objectKey === undefined ||
      inferUploadStatus(asset) === "deleted"
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
      asset.objectKey === undefined ||
      inferUploadStatus(asset) === "deleted"
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
    let replaced = 0;
    for (const olderAsset of olderActiveAssets) {
      if (olderAsset._id === asset._id) {
        continue;
      }
      await markImageAssetDeleted(ctx, olderAsset, now);
      replaced += 1;
    }

    if (replaced > 0) {
      await schedulePhysicalDeletion(ctx);
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
    return { ok: true } as const;
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
        previousStorageId !== args.storageId &&
        !(await hasSharedDeletionTarget(ctx, existing))
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
  returns: v.array(imageAssetValidator),
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
  returns: v.object({ url: v.union(v.string(), v.null()) }),
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
    ...cloudProtocolArgs,
    strategyPublicId: v.string(),
    assetPublicId: v.string(),
  },
  returns: okResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const target: { assetId: Id<"imageAssets"> } = await ctx.runQuery(
      internal.images.getAssetDeletionTarget,
      args,
    );

    await ctx.runMutation(internal.images.markDeletedAssetRefsForStrategy, {
      strategyPublicId: args.strategyPublicId,
      assetIds: [target.assetId],
    });
    return { ok: true } as const;
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

    if (await strategyReferencesAsset(ctx, strategy._id, args.assetPublicId)) {
      throw conflictError("Asset is still referenced by this Strategy.");
    }

    return { assetId: asset._id };
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
    let shouldSweep = false;
    const referencedAssetIds = await collectReferencedAssetIdsForStrategy(
      ctx,
      strategy._id,
    );
    for (const assetId of args.assetIds.slice(0, maxDeletionBatch)) {
      const asset = await ctx.db.get(assetId);
      if (asset === null) {
        continue;
      }
      if (
        asset.strategyId !== strategy._id ||
        referencedAssetIds.has(asset.publicId)
      ) {
        continue;
      }
      shouldSweep = true;
      if (inferUploadStatus(asset) !== "deleted") {
        await markImageAssetDeleted(ctx, asset, now);
        deleted += 1;
      }
    }
    if (shouldSweep) {
      await schedulePhysicalDeletion(ctx);
    }
    return { ok: true, deleted };
  },
});

export const markDeletedPageImageAssets = internalMutation({
  args: {
    strategyId: v.id("strategies"),
    pageId: v.id("pages"),
    assetPublicIds: v.array(v.string()),
  },
  handler: async (ctx, args) => {
    const candidateIds = new Set(
      args.assetPublicIds.slice(0, pageAssetIdBatch),
    );
    const remainingReferences = await collectReferencedAssetIdsForStrategy(
      ctx,
      args.strategyId,
      args.pageId,
    );
    for (const referencedId of remainingReferences) {
      candidateIds.delete(referencedId);
    }

    const assets: Doc<"imageAssets">[] = [];
    for (const assetPublicId of candidateIds) {
      const remainingSlots = maxDeletionBatch - assets.length;
      if (remainingSlots <= 0) {
        break;
      }
      const matches = await ctx.db
        .query("imageAssets")
        .withIndex("by_strategyId_and_publicId", (q) =>
          q.eq("strategyId", args.strategyId).eq("publicId", assetPublicId),
        )
        .filter((q) => q.neq(q.field("uploadStatus"), "deleted"))
        .take(remainingSlots);
      assets.push(...matches);
    }

    const now = Date.now();
    for (const asset of assets) {
      await markImageAssetDeleted(ctx, asset, now);
    }
    if (assets.length > 0) {
      await schedulePhysicalDeletion(ctx);
    }
    if (assets.length === maxDeletionBatch) {
      await ctx.scheduler.runAfter(0, markDeletedPageImageAssetsRef, args);
    }
    return { ok: true as const, deleted: assets.length };
  },
});

export const markDeletedStrategyImageAssets = internalMutation({
  args: {
    strategyId: v.id("strategies"),
  },
  handler: async (ctx, args) => {
    const assets = await ctx.db
      .query("imageAssets")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", args.strategyId))
      .filter((q) => q.neq(q.field("uploadStatus"), "deleted"))
      .take(maxDeletionBatch);
    const now = Date.now();
    for (const asset of assets) {
      await markImageAssetDeleted(ctx, asset, now);
    }
    if (assets.length > 0) {
      await schedulePhysicalDeletion(ctx);
    }
    if (assets.length === maxDeletionBatch) {
      await ctx.scheduler.runAfter(0, markDeletedStrategyImageAssetsRef, args);
    }
    return { ok: true as const, deleted: assets.length };
  },
});

export const markStaleImageUploadsDeleted = internalMutation({
  args: {
    staleBefore: v.optional(v.number()),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const staleBefore = args.staleBefore ?? Date.now() - staleUploadAgeMs;
    const limit = Math.max(
      1,
      Math.min(args.limit ?? maxDeletionBatch, maxDeletionBatch),
    );
    const stuckClaims = await ctx.db
      .query("imageAssets")
      .withIndex("by_uploadStatus_and_updatedAt", (q) =>
        q.eq("uploadStatus", "deleted"),
      )
      .filter((q) =>
        q.and(
          q.neq(q.field("strategyId"), undefined),
          q.neq(q.field("cleanupClaimedAt"), undefined),
          q.lte(
            q.field("cleanupClaimedAt"),
            Date.now() - staleDeletionClaimAgeMs,
          ),
        ),
      )
      .take(limit);
    for (const asset of stuckClaims) {
      await ctx.db.patch(asset._id, { cleanupClaimedAt: undefined });
    }

    const assets: Doc<"imageAssets">[] = [];
    for (const status of ["pending", "failed"] as UploadStatus[]) {
      const remainingSlots = limit - stuckClaims.length - assets.length;
      if (remainingSlots <= 0) {
        break;
      }
      const matches = await ctx.db
        .query("imageAssets")
        .withIndex("by_uploadStatus_and_updatedAt", (q) =>
          q.eq("uploadStatus", status).lte("updatedAt", staleBefore),
        )
        .filter((q) => q.neq(q.field("strategyId"), undefined))
        .take(remainingSlots);
      assets.push(...matches);
      }

    const now = Date.now();
    for (const asset of assets) {
      await markImageAssetDeleted(ctx, asset, now);
    }
    if (assets.length > 0 || stuckClaims.length > 0) {
      await schedulePhysicalDeletion(ctx);
    }
    if (assets.length + stuckClaims.length === limit) {
      await ctx.scheduler.runAfter(0, markStaleImageUploadsDeletedRef, {
        staleBefore,
        limit,
      });
    }
    return {
      ok: true as const,
      deleted: assets.length,
      released: stuckClaims.length,
    };
  },
    });

async function hasSharedDeletionTarget(
  ctx: QueryCtx | MutationCtx,
  asset: Doc<"imageAssets">,
): Promise<boolean> {
  if (inferProvider(asset) === "r2") {
    if (asset.objectKey === undefined) {
      return false;
    }
    const matches = await ctx.db
      .query("imageAssets")
      .withIndex("by_objectKey", (q) => q.eq("objectKey", asset.objectKey))
      .take(2);
    return matches.some((candidate) => candidate._id !== asset._id);
  }
  if (asset.storageId === undefined) {
    return false;
  }
  const matches = await ctx.db
    .query("imageAssets")
    .withIndex("by_storageId", (q) => q.eq("storageId", asset.storageId))
    .take(2);
  return matches.some((candidate) => candidate._id !== asset._id);
}

export const claimDeletedImageAssets = internalMutation({
  args: {
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const limit = Math.max(
      1,
      Math.min(args.limit ?? physicalDeletionBatch, physicalDeletionBatch),
    );
    const assets = await ctx.db
      .query("imageAssets")
      .withIndex("by_uploadStatus_and_updatedAt", (q) =>
        q.eq("uploadStatus", "deleted"),
      )
      .filter((q) =>
        q.and(
          q.neq(q.field("strategyId"), undefined),
          q.eq(q.field("cleanupClaimedAt"), undefined),
        ),
      )
      .take(limit);
    const now = Date.now();
    for (const asset of assets) {
      await ctx.db.patch(asset._id, { cleanupClaimedAt: now });
    }
    return assets.map((asset) => asset._id);
  },
});

export const getDeletedImageAssetTarget = internalQuery({
  args: {
    assetId: v.id("imageAssets"),
  },
  handler: async (ctx, args): Promise<DeletionTarget | null> => {
    const asset = await ctx.db.get(args.assetId);
    if (
      asset === null ||
      inferUploadStatus(asset) !== "deleted" ||
      asset.cleanupClaimedAt === undefined
    ) {
      return null;
    }
    return {
      assetId: asset._id,
      provider: inferProvider(asset),
      objectKey: asset.objectKey ?? null,
      sharedTarget: await hasSharedDeletionTarget(ctx, asset),
    };
  },
});

export const finalizeDeletedImageAsset = internalMutation({
  args: {
    assetId: v.id("imageAssets"),
    r2ObjectDeleted: v.boolean(),
  },
  handler: async (ctx, args) => {
    const asset = await ctx.db.get(args.assetId);
    if (asset === null) {
      return { ok: true as const, finalized: true };
    }
    if (inferUploadStatus(asset) !== "deleted") {
      return { ok: true as const, finalized: false };
    }

    const sharedTarget = await hasSharedDeletionTarget(ctx, asset);
    if (inferProvider(asset) === "r2") {
      if (
        asset.objectKey !== undefined &&
        !sharedTarget &&
        !args.r2ObjectDeleted
      ) {
        return { ok: true as const, finalized: false };
      }
    } else if (asset.storageId !== undefined && !sharedTarget) {
      await ctx.storage.delete(asset.storageId);
    }
    await ctx.db.delete(asset._id);
    return { ok: true as const, finalized: true };
  },
});

export const scheduleDeletedImageAssetSweep = internalMutation({
  args: {
    delayMs: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const delayMs = Math.max(0, Math.min(args.delayMs ?? 0, 60 * 60 * 1000));
    await schedulePhysicalDeletion(ctx, delayMs);
    return { ok: true as const };
  },
});

export const releaseImageAssetDeletionClaims = internalMutation({
  args: {
    assetIds: v.array(v.id("imageAssets")),
    retryAfterMs: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    for (const assetId of args.assetIds.slice(0, physicalDeletionBatch)) {
      const asset = await ctx.db.get(assetId);
      if (
        asset !== null &&
        inferUploadStatus(asset) === "deleted" &&
        asset.cleanupClaimedAt !== undefined
      ) {
        await ctx.db.patch(asset._id, { cleanupClaimedAt: undefined });
      }
    }
    await schedulePhysicalDeletion(
    ctx,
      Math.max(0, args.retryAfterMs ?? deletionRetryDelayMs),
    );
    return { ok: true as const };
  },
});

export const sweepDeletedImageAssets = internalAction({
  args: {
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const limit = Math.max(
      1,
      Math.min(args.limit ?? physicalDeletionBatch, physicalDeletionBatch),
    );
    const assetIds: Id<"imageAssets">[] = await ctx.runMutation(
      claimDeletedImageAssetsRef,
      { limit },
    );
    let deleted = 0;
    let failed = 0;
    const failedAssetIds: Id<"imageAssets">[] = [];
    let config: ReturnType<typeof getR2Config> | null = null;

    for (const assetId of assetIds) {
      try {
        const target: DeletionTarget | null = await ctx.runQuery(
          getDeletedImageAssetTargetRef,
          { assetId },
        );
        if (target === null) {
          continue;
        }
        let r2ObjectDeleted = false;
      if (
        target.provider === "r2" &&
          target.objectKey !== null &&
          !target.sharedTarget
      ) {
          config ??= getR2Config();
        await deleteR2Object(config, target.objectKey);
          r2ObjectDeleted = true;
        }
        const result: { finalized: boolean } = await ctx.runMutation(
          finalizeDeletedImageAssetRef,
          { assetId, r2ObjectDeleted },
        );
        if (result.finalized) {
          deleted += 1;
        } else {
          failed += 1;
          failedAssetIds.push(assetId);
        }
      } catch {
        failed += 1;
        failedAssetIds.push(assetId);
      }
    }

    if (failedAssetIds.length > 0) {
      await ctx.runMutation(releaseImageAssetDeletionClaimsRef, {
        assetIds: failedAssetIds,
        retryAfterMs: deletionRetryDelayMs,
      });
    } else if (assetIds.length === limit) {
      await ctx.runMutation(scheduleDeletedImageAssetSweepRef, {
        delayMs: 0,
      });
    }
    return { ok: true as const, deleted, failed };
  },
});

export const listPotentiallyStale = internalQuery({
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
