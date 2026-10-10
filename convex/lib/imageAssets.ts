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

/// The picture an image element shows: its `assetId` when it has one, else
/// its own id. A copy of an image is a new element showing its original's
/// picture, so it needs no picture of its own, and is never waiting on an
/// upload its original is still making. Only images have an `assetId`.
export function collectAssetIdFromElementPayload(
  payload: Doc<"elements">["payload"],
): string | null {
  const { assetId, id } = payload.data;
  if (typeof assetId === "string" && assetId.length > 0) return assetId;
  return typeof id === "string" ? id : null;
}

/// [next] keeping the picture [current] shows, when it leaves the picture
/// out. An image never changes picture, and builds from before pictures had
/// their own id write an image's whole payload without the field: moving a
/// copy there must not cut it off from its picture.
export function keepPictureId(
  current: Doc<"elements">["payload"],
  next: Doc<"elements">["payload"],
): Doc<"elements">["payload"] {
  const assetId = current.data.assetId;
  if (typeof assetId !== "string" || "assetId" in next.data) return next;
  return { ...next, data: { ...next.data, assetId } };
}

/// [assets] as builds from before pictures had their own id can read them:
/// they look an image's picture up under the image's own id. Each live image
/// showing another id's picture gets that picture under its own id too.
export function withPictureAliases<T extends { publicId: string }>(
  assets: T[],
  elements: Doc<"elements">[],
): T[] {
  const byId = new Map(assets.map((asset) => [asset.publicId, asset]));
  const aliases: T[] = [];
  for (const element of elements) {
    if (element.deleted || element.elementType !== "image") continue;
    const id = element.payload.data.id;
    const pictureId = collectAssetIdFromElementPayload(element.payload);
    if (typeof id !== "string" || pictureId === null || pictureId === id) {
      continue;
    }
    const picture = byId.get(pictureId);
    if (picture === undefined || byId.has(id)) continue;
    const alias = { ...picture, publicId: id };
    byId.set(id, alias);
    aliases.push(alias);
  }
  return [...assets, ...aliases];
}

/// The images a lineup group shows: links[*].images[*].id, across every
/// lineup in it. Its origins and landings hold none.
export function collectAssetIdsFromLineupPayload(
  payload: Doc<"lineups">["payload"],
): Set<string> {
  const assetIds = new Set<string>();
  const links = payload.data.links;
  if (!Array.isArray(links)) return assetIds;
  for (const link of links) {
    const images = isObject(link) ? link.images : undefined;
    if (!Array.isArray(images)) continue;
    for (const image of images) {
      if (isObject(image) && typeof image.id === "string") {
        assetIds.add(image.id);
      }
    }
  }
  return assetIds;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
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

  // Rows from before upload statuses, this strategy's then those of no
  // strategy. Each is read on its own: copies into other strategies keep
  // their pictures' ids, so a read of every strategy's rows could fill its
  // limit with theirs. Ten each keeps the whole lookup to 22 rows, as a
  // copy's budget counts it (convex/lib/contentCopy.ts).
  for (const owner of [strategyId, undefined]) {
    const legacyCandidates = await ctx.db
      .query("imageAssets")
      .withIndex("by_strategyId_and_publicId", (q) =>
        q.eq("strategyId", owner).eq("publicId", assetPublicId),
      )
      .order("desc")
      .take(10);
    const visible = legacyCandidates.find(isVisibleAsset);
    if (visible !== undefined) return visible;
  }
  return null;
}

/// The picture image [itemPublicId] of the strategy shows, when the image
/// shows another's (see collectAssetIdFromElementPayload): builds from
/// before pictures had their own id ask for a picture by the image's id.
export async function pictureShownByImage(
  ctx: AnyCtx,
  strategyId: Id<"strategies">,
  itemPublicId: string,
): Promise<string | null> {
  const element = await ctx.db
    .query("elements")
    .withIndex("by_publicId", (q) => q.eq("publicId", itemPublicId))
    .first();
  if (
    element === null ||
    element.deleted ||
    element.strategyId !== strategyId ||
    element.elementType !== "image"
  ) {
    return null;
  }
  const pictureId = collectAssetIdFromElementPayload(element.payload);
  return pictureId === itemPublicId ? null : pictureId;
}

/// [payload] as builds from before pictures had their own id hold it: they
/// keep no `assetId`, so one sent to them reads as a change they made.
/// They find the picture by the image's own id (withPictureAliases), and a
/// write of theirs keeps the stored picture (keepPictureId).
export function withoutPictureId(
  payload: Doc<"elements">["payload"],
): Doc<"elements">["payload"] {
  if (!("assetId" in payload.data)) return payload;
  const { assetId: _assetId, ...data } = payload.data;
  return { ...payload, data };
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
