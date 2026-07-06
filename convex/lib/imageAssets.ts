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
