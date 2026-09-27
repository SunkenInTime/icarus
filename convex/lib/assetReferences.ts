import type { Doc, Id } from "../_generated/dataModel";
import type { MutationCtx, QueryCtx } from "../_generated/server";
import {
  collectAssetIdFromElementPayload,
  collectAssetIdsFromLineupPayload,
  isUploadPlaceholder,
} from "./imageAssets";

type AnyCtx = MutationCtx | QueryCtx;

/// The fields of a content row its image references depend on, so a row
/// just written can be synced without reading it back.
export type ReferencingElement = Pick<
  Doc<"elements">,
  "strategyId" | "pageId" | "deleted" | "elementType" | "payload"
>;
export type ReferencingLineup = Pick<
  Doc<"lineups">,
  "strategyId" | "pageId" | "deleted" | "payload"
>;

/// The image ids a content row shows, whether or not it is deleted: a
/// tombstone keeps referencing its image until it is purged.
function assetIdsOfRow(
  row: ReferencingElement | ReferencingLineup,
): Set<string> {
  if ("elementType" in row) {
    if (row.elementType !== "image") return new Set();
    const assetId = collectAssetIdFromElementPayload(row.payload);
    return new Set(assetId === null ? [] : [assetId]);
  }
  return collectAssetIdsFromLineupPayload(row.payload);
}

/// Brings the reference rows of one element in step with it. Call after
/// every write to the element; pass the id with `null` after hard-deleting
/// it. Touches only this element's reference rows.
export async function syncElementAssetReferences(
  ctx: MutationCtx,
  elementId: Id<"elements">,
  element: ReferencingElement | null,
): Promise<void> {
  const existing = await ctx.db
    .query("assetReferences")
    .withIndex("by_elementId", (q) => q.eq("elementId", elementId))
    .collect();
  await syncRows(ctx, existing, element, { elementId });
}

/// Brings the reference rows of one lineup row in step with it. Call after
/// every write to the row; pass the id with `null` after hard-deleting it.
export async function syncLineupAssetReferences(
  ctx: MutationCtx,
  lineupId: Id<"lineups">,
  lineup: ReferencingLineup | null,
): Promise<void> {
  const existing = await ctx.db
    .query("assetReferences")
    .withIndex("by_lineupId", (q) => q.eq("lineupId", lineupId))
    .collect();
  await syncRows(ctx, existing, lineup, { lineupId });
}

async function syncRows(
  ctx: MutationCtx,
  existing: Doc<"assetReferences">[],
  row: ReferencingElement | ReferencingLineup | null,
  source: { elementId?: Id<"elements">; lineupId?: Id<"lineups"> },
): Promise<void> {
  const wanted = row === null ? new Set<string>() : assetIdsOfRow(row);
  const kept = new Set<string>();
  for (const reference of existing) {
    if (row === null || !wanted.has(reference.assetPublicId) ||
        kept.has(reference.assetPublicId)) {
      await ctx.db.delete(reference._id);
      continue;
    }
    kept.add(reference.assetPublicId);
    if (reference.deleted !== row.deleted || reference.pageId !== row.pageId) {
      await ctx.db.patch(reference._id, {
        deleted: row.deleted,
        pageId: row.pageId,
      });
    }
  }
  if (row === null) return;
  for (const assetPublicId of wanted) {
    if (kept.has(assetPublicId)) continue;
    await ctx.db.insert("assetReferences", {
      strategyId: row.strategyId,
      assetPublicId,
      pageId: row.pageId,
      ...source,
      deleted: row.deleted,
    });
  }
}

/// Whether any content of the strategy shows the image: a live element or
/// lineup row, and, with [includeTombstones], a deleted one still inside
/// its retention window. One indexed read, whatever the strategy's size.
export async function isAssetReferenced(
  ctx: AnyCtx,
  strategyId: Id<"strategies">,
  assetPublicId: string,
  { includeTombstones }: { includeTombstones: boolean },
): Promise<boolean> {
  const reference = includeTombstones
    ? await ctx.db
        .query("assetReferences")
        .withIndex("by_strategyId_and_assetPublicId", (q) =>
          q.eq("strategyId", strategyId).eq("assetPublicId", assetPublicId),
        )
        .first()
    : await ctx.db
        .query("assetReferences")
        .withIndex("by_strategyId_and_assetPublicId_and_deleted", (q) =>
          q
            .eq("strategyId", strategyId)
            .eq("assetPublicId", assetPublicId)
            .eq("deleted", false),
        )
        .first();
  return reference !== null;
}

/// Every image id the strategy's live content shows. Reads reference rows
/// only (one per image reference), never the content itself.
export async function collectLiveAssetIds(
  ctx: AnyCtx,
  strategyId: Id<"strategies">,
): Promise<Set<string>> {
  const assetIds = new Set<string>();
  const references = ctx.db
    .query("assetReferences")
    .withIndex("by_strategyId_and_deleted", (q) =>
      q.eq("strategyId", strategyId).eq("deleted", false),
    );
  for await (const reference of references) {
    assetIds.add(reference.assetPublicId);
  }
  return assetIds;
}

/// Records images whose content was just purged, to be checked by the
/// reclaim worker (images.processAssetReclaimCandidates). Written in the
/// purge's own transaction, so the purge and the candidate land together.
export async function addAssetReclaimCandidates(
  ctx: MutationCtx,
  strategyId: Id<"strategies">,
  assetPublicIds: Iterable<string>,
  now: number,
): Promise<number> {
  let added = 0;
  for (const assetPublicId of new Set(assetPublicIds)) {
    const existing = await ctx.db
      .query("assetReclaimCandidates")
      .withIndex("by_strategyId_and_assetPublicId", (q) =>
        q.eq("strategyId", strategyId).eq("assetPublicId", assetPublicId),
      )
      .first();
    if (existing !== null) continue;
    await ctx.db.insert("assetReclaimCandidates", {
      strategyId,
      assetPublicId,
      createdAt: now,
    });
    added += 1;
  }
  return added;
}

/// Drops the upload placeholders among [assetPublicIds] (images deleted
/// elements showed) that no live content of the strategy shows any more.
/// Rows holding bytes are left to the normal asset lifecycle.
///
/// Called once, after every op of a batch has applied (and synced its
/// reference rows), so the check sees the batch's final state: a lineup
/// added later in the same batch keeps the placeholder of the image it
/// shows. Each check is one indexed read.
export async function removeUploadPlaceholders(
  ctx: MutationCtx,
  strategyId: Id<"strategies">,
  assetPublicIds: Iterable<string>,
): Promise<void> {
  for (const publicId of new Set(assetPublicIds)) {
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
    if (
      await isAssetReferenced(ctx, strategyId, publicId, {
        includeTombstones: false,
      })
    ) {
      continue;
    }
    for (const row of placeholders) await ctx.db.delete(row._id);
  }
}
