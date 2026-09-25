import type { Doc, Id } from "../_generated/dataModel";
import type { MutationCtx, QueryCtx } from "../_generated/server";
import { normalizeImageExtension, publicR2UrlForObjectKey } from "./r2";

type AnyCtx = MutationCtx | QueryCtx;

export type Provider = "convex" | "r2";
export type UploadStatus = "pending" | "active" | "failed" | "deleted";

export type SerializedAsset = {
  publicId: string;
  provider: Provider;
  uploadStatus: UploadStatus;
  fileExtension: string;
  mimeType: string | null;
  width: number | null;
  height: number | null;
  byteSize: number | null;
  uploadedAt: number | null;
  url: string | null;
  legacyStoragePath: string | null;
};

export function inferProvider(asset: Doc<"imageAssets">): Provider {
  return asset.provider ?? "convex";
}

export function inferUploadStatus(asset: Doc<"imageAssets">): UploadStatus {
  if (asset.uploadStatus !== undefined) {
    return asset.uploadStatus;
  }
  return asset.storageId !== undefined || asset.storagePath !== undefined
    ? "active"
    : "pending";
}

export function inferFileExtension(
  asset: Pick<Doc<"imageAssets">, "fileExtension" | "storagePath">,
): string {
  if (asset.fileExtension !== undefined && asset.fileExtension.length > 0) {
    return normalizeImageExtension(asset.fileExtension);
  }

  const legacyPath = asset.storagePath ?? "";
  const match = legacyPath.match(/(\.[A-Za-z0-9]+)(?:$|[?#])/);
  return match?.[1]?.toLowerCase() ?? "";
}

export function collectAssetIdFromElementPayload(
  payload: Doc<"elements">["payload"],
): string | null {
  return typeof payload.data.id === "string" ? payload.data.id : null;
}

export function collectAssetIdsFromLineupPayload(
  payload: Doc<"lineups">["payload"],
): Set<string> {
  const assetIds = new Set<string>();

  const addImages = (rawImages: unknown) => {
    if (!Array.isArray(rawImages)) {
      return;
    }
    for (const image of rawImages) {
      if (
        typeof image === "object" &&
        image !== null &&
        typeof (image as { id?: unknown }).id === "string"
      ) {
        assetIds.add((image as { id: string }).id);
      }
    }
  };

  // Legacy lineup payloads stored images at the top level.
  addImages(payload.data.images);

  // Grouped lineup payloads (LineUpGroup) nest them per item:
  // data.items[*].images[*].id
  const rawItems = payload.data.items;
  if (Array.isArray(rawItems)) {
    for (const item of rawItems) {
      if (typeof item === "object" && item !== null) {
        addImages((item as { images?: unknown }).images);
      }
    }
  }

  return assetIds;
}

export function collectReferencedAssetIds(
  elements: Doc<"elements">[],
  lineups: Doc<"lineups">[],
): Set<string> {
  const assetIds = new Set<string>();

  for (const element of elements) {
    if (element.deleted || element.elementType !== "image") {
      continue;
    }

    const assetId = collectAssetIdFromElementPayload(element.payload);
    if (assetId !== null) {
      assetIds.add(assetId);
    }
  }

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

/// How long a pending upload may wait before the stale-upload sweep removes
/// it.
export const staleUploadAgeMs = 24 * 60 * 60 * 1000;

/// Every image id the strategy's live elements and lineups show, optionally
/// leaving out one page's content.
export async function collectReferencedAssetIdsForStrategy(
  ctx: AnyCtx,
  strategyId: Id<"strategies">,
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

export function isVisibleAsset(asset: Doc<"imageAssets">): boolean {
  if (inferUploadStatus(asset) !== "active") {
    return false;
  }
  if (inferProvider(asset) === "r2") {
    return asset.objectKey !== undefined && asset.objectKey.length > 0;
  }
  return asset.storageId !== undefined;
}

export async function getActiveAssetForStrategy(
  ctx: AnyCtx,
  strategyId: Id<"strategies">,
  assetPublicId: string,
): Promise<Doc<"imageAssets"> | null> {
  const strategyAsset = await ctx.db
    .query("imageAssets")
    .withIndex("by_strategyId_and_publicId_and_uploadStatus", (q) =>
      q
        .eq("strategyId", strategyId)
        .eq("publicId", assetPublicId)
        .eq("uploadStatus", "active"),
    )
    .order("desc")
    .first();

  if (strategyAsset !== null && isVisibleAsset(strategyAsset)) {
    return strategyAsset;
  }

  const legacyCandidates = await ctx.db
    .query("imageAssets")
    .withIndex("by_publicId", (q) => q.eq("publicId", assetPublicId))
    .order("desc")
    .take(20);
  return (
    legacyCandidates.find(
      (asset) =>
        (asset.strategyId === undefined || asset.strategyId === strategyId) &&
        isVisibleAsset(asset),
    ) ?? null
  );
}

/// A row recording that a strategy's content shows an image whose upload has
/// not started: pending, with no bytes anywhere yet. The upload intent adopts
/// it; the stale-upload sweep removes it if the upload never comes.
export function isUploadPlaceholder(asset: Doc<"imageAssets">): boolean {
  return (
    inferUploadStatus(asset) === "pending" &&
    asset.objectKey === undefined &&
    asset.storageId === undefined
  );
}

/// The image ids a live element or lineup row shows.
export function referencedAssetIds(
  row: Doc<"elements"> | Doc<"lineups"> | null,
): Set<string> {
  if (row === null || row.deleted) return new Set();
  if ("elementType" in row) {
    if (row.elementType !== "image") return new Set();
    const assetId = collectAssetIdFromElementPayload(row.payload);
    return new Set(assetId === null ? [] : [assetId]);
  }
  return collectAssetIdsFromLineupPayload(row.payload);
}

/// Records that the strategy's content now shows these images. Content and
/// its upload reach the server independently, so an image can be referenced
/// before its upload intent exists; without a row, readers could not tell an
/// image that is on its way from one that will never come.
export async function expectAssets(
  ctx: MutationCtx,
  strategyId: Id<"strategies">,
  assetPublicIds: Iterable<string>,
  now: number,
): Promise<void> {
  for (const publicId of assetPublicIds) {
    if (
      (await getViewerAssetForStrategy(ctx, strategyId, publicId)) !== null
    ) {
      continue;
    }
    await ctx.db.insert("imageAssets", {
      publicId,
      strategyId,
      uploadStatus: "pending",
      createdAt: now,
      updatedAt: now,
    });
  }
}

/// Drops the placeholders for images that no live element or lineup in the
/// strategy shows any more. Rows holding bytes are left to the normal asset
/// lifecycle.
export async function removeUploadPlaceholders(
  ctx: MutationCtx,
  strategyId: Id<"strategies">,
  assetPublicIds: Iterable<string>,
): Promise<void> {
  // Read the strategy's references only when a placeholder is at stake.
  let stillShown: Set<string> | null = null;
  for (const publicId of assetPublicIds) {
    const placeholders = (
      await ctx.db
        .query("imageAssets")
        .withIndex("by_strategyId_and_publicId_and_uploadStatus", (q) =>
          q
            .eq("strategyId", strategyId)
            .eq("publicId", publicId)
            .eq("uploadStatus", "pending"),
        )
        .take(20)
    ).filter(isUploadPlaceholder);
    if (placeholders.length === 0) continue;
    stillShown ??= await collectReferencedAssetIdsForStrategy(ctx, strategyId);
    if (stillShown.has(publicId)) continue;
    for (const row of placeholders) await ctx.db.delete(row._id);
  }
}

/// Gives `targetStrategyId` its own active row for the image the source
/// strategy shows under `sourceAssetPublicId`, stored as `targetAssetPublicId`.
/// The row points at the same R2 object or Convex storage file: physical
/// cleanup only deletes bytes once no row points at them
/// (`hasSharedDeletionTarget` in images.ts), so each row is one reference.
/// Only an active source row is copied; a deleted one may already be mid-sweep.
/// "uploading" means the source's image has not finished uploading, so there
/// is nothing to copy yet; "unavailable" means the source cannot show it either.
export async function copyActiveAssetToStrategy(
  ctx: MutationCtx,
  args: {
    sourceStrategyId: Id<"strategies">;
    sourceAssetPublicId: string;
    targetStrategyId: Id<"strategies">;
    targetAssetPublicId: string;
    userId: Id<"users">;
    now: number;
  },
): Promise<"copied" | "uploading" | "unavailable"> {
  const source = await getActiveAssetForStrategy(
    ctx,
    args.sourceStrategyId,
    args.sourceAssetPublicId,
  );
  if (source === null) {
    const pending = await ctx.db
      .query("imageAssets")
      .withIndex("by_strategyId_and_publicId_and_uploadStatus", (q) =>
        q
          .eq("strategyId", args.sourceStrategyId)
          .eq("publicId", args.sourceAssetPublicId)
          .eq("uploadStatus", "pending"),
      )
      .first();
    return pending === null ? "unavailable" : "uploading";
  }
  await ctx.db.insert("imageAssets", {
    publicId: args.targetAssetPublicId,
    provider: inferProvider(source),
    strategyId: args.targetStrategyId,
    createdByUserId: args.userId,
    storageId: source.storageId,
    objectKey: source.objectKey,
    uploadStatus: "active",
    fileExtension: source.fileExtension,
    mimeType: source.mimeType,
    width: source.width,
    height: source.height,
    byteSize: source.byteSize,
    etag: source.etag,
    uploadedAt: source.uploadedAt,
    storagePath: source.storagePath,
    createdAt: args.now,
    updatedAt: args.now,
  });
  return "copied";
}

export async function getViewerAssetForStrategy(
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
  const strategyAsset =
    strategyCandidates.find(
      (asset) => inferUploadStatus(asset) !== "deleted",
    ) ?? null;
  if (strategyAsset !== null) {
    return strategyAsset;
  }

  return await getActiveAssetForStrategy(ctx, strategyId, assetPublicId);
}

export async function serializeAssetForViewer(
  ctx: QueryCtx,
  asset: Doc<"imageAssets">,
): Promise<SerializedAsset> {
  const provider = inferProvider(asset);
  const uploadStatus = inferUploadStatus(asset);
  const url =
    provider === "r2"
      ? asset.objectKey === undefined || uploadStatus !== "active"
        ? null
        : publicR2UrlForObjectKey(asset.objectKey)
      : asset.storageId === undefined || uploadStatus !== "active"
        ? null
        : await ctx.storage.getUrl(asset.storageId);

  return {
    publicId: asset.publicId,
    provider,
    uploadStatus,
    fileExtension: inferFileExtension(asset),
    mimeType: asset.mimeType ?? null,
    width: asset.width ?? null,
    height: asset.height ?? null,
    byteSize: asset.byteSize ?? null,
    uploadedAt: asset.uploadedAt ?? null,
    url,
    legacyStoragePath: asset.storagePath ?? null,
  };
}
