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

/// The backfill that gives content written before the reference table its
/// reference rows runs once per content table; each finished table is
/// recorded under its own name.
export type ContentTable = "elements" | "lineups";
const backfillName = (table: ContentTable) => `assetReferences:${table}`;

async function isBackfilled(ctx: AnyCtx, table: ContentTable) {
  const row = await ctx.db
    .query("completedBackfills")
    .withIndex("by_name", (q) => q.eq("name", backfillName(table)))
    .first();
  return row !== null;
}

/// Whether every content row has its reference rows: true once
/// maintenance.backfillAssetReferences has finished both elements and
/// lineups, in either order. Until then a missing reference row proves
/// nothing, so nothing may be deleted on its say-so: no asset marked
/// deleted, and no stored bytes removed.
export async function assetReferencesReady(ctx: AnyCtx): Promise<boolean> {
  return (
    (await isBackfilled(ctx, "elements")) &&
    (await isBackfilled(ctx, "lineups"))
  );
}

/// Records that the backfill of [table] has finished. Idempotent.
export async function markContentTableBackfilled(
  ctx: MutationCtx,
  table: ContentTable,
): Promise<void> {
  if (await isBackfilled(ctx, table)) return;
  await ctx.db.insert("completedBackfills", {
    name: backfillName(table),
    completedAt: Date.now(),
  });
}

/// Records both tables as backfilled (tests, and a fresh deployment).
export async function markAssetReferencesReady(
  ctx: MutationCtx,
): Promise<void> {
  await markContentTableBackfilled(ctx, "elements");
  await markContentTableBackfilled(ctx, "lineups");
}

/// The image ids a content row shows, whether or not it is deleted: a
/// tombstone keeps referencing its image until it is purged.
export function assetIdsOfRow(
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
/// it. Touches only this element's reference rows. With [maxWrites] it
/// stops after that many writes and reports whether the rows are fully in
/// step; syncing again continues (see syncRows).
export async function syncElementAssetReferences(
  ctx: MutationCtx,
  elementId: Id<"elements">,
  element: ReferencingElement | null,
  maxWrites = Infinity,
): Promise<SyncResult> {
  const existing = await ctx.db
    .query("assetReferences")
    .withIndex("by_elementId", (q) => q.eq("elementId", elementId))
    .collect();
  return await syncRows(ctx, existing, element, { elementId }, maxWrites);
}

/// Brings the reference rows of one lineup row in step with it. Call after
/// every write to the row; pass the id with `null` after hard-deleting it.
/// [maxWrites] as for syncElementAssetReferences.
export async function syncLineupAssetReferences(
  ctx: MutationCtx,
  lineupId: Id<"lineups">,
  lineup: ReferencingLineup | null,
  maxWrites = Infinity,
): Promise<SyncResult> {
  const existing = await ctx.db
    .query("assetReferences")
    .withIndex("by_lineupId", (q) => q.eq("lineupId", lineupId))
    .collect();
  return await syncRows(ctx, existing, lineup, { lineupId }, maxWrites);
}

export type SyncResult = { writes: number; complete: boolean };

/// Writes the reference rows of a content row inserted in this same
/// transaction, which has none yet, so nothing is read.
export async function insertAssetReferences(
  ctx: MutationCtx,
  source: { elementId: Id<"elements"> } | { lineupId: Id<"lineups"> },
  row: ReferencingElement | ReferencingLineup,
): Promise<void> {
  for (const assetPublicId of assetIdsOfRow(row)) {
    await ctx.db.insert("assetReferences", {
      strategyId: row.strategyId,
      assetPublicId,
      pageId: row.pageId,
      ...source,
      deleted: row.deleted,
    });
  }
}

/// Diffs a row's reference rows against the images it shows and writes the
/// difference, at most [maxWrites] writes. Every write moves the rows closer
/// to the wanted set, so a sync cut short is finished by syncing again.
async function syncRows(
  ctx: MutationCtx,
  existing: Doc<"assetReferences">[],
  row: ReferencingElement | ReferencingLineup | null,
  source: { elementId?: Id<"elements">; lineupId?: Id<"lineups"> },
  maxWrites: number,
): Promise<SyncResult> {
  const wanted = row === null ? new Set<string>() : assetIdsOfRow(row);
  const kept = new Set<string>();
  let writes = 0;
  const outOfWrites = () => writes++ >= maxWrites;
  for (const reference of existing) {
    if (row === null || !wanted.has(reference.assetPublicId) ||
        kept.has(reference.assetPublicId)) {
      if (outOfWrites()) return { writes: maxWrites, complete: false };
      await ctx.db.delete(reference._id);
      continue;
    }
    kept.add(reference.assetPublicId);
    if (reference.deleted !== row.deleted || reference.pageId !== row.pageId) {
      if (outOfWrites()) return { writes: maxWrites, complete: false };
      await ctx.db.patch(reference._id, {
        deleted: row.deleted,
        pageId: row.pageId,
      });
    }
  }
  if (row === null) return { writes, complete: true };
  for (const assetPublicId of wanted) {
    if (kept.has(assetPublicId)) continue;
    if (outOfWrites()) return { writes: maxWrites, complete: false };
    await ctx.db.insert("assetReferences", {
      strategyId: row.strategyId,
      assetPublicId,
      pageId: row.pageId,
      ...source,
      deleted: row.deleted,
    });
  }
  return { writes, complete: true };
}

/// Whether any content of the strategy shows the image: a live element or
/// lineup row, and, with [includeTombstones], a deleted one still inside
/// its retention window. One indexed read, whatever the strategy's size.
///
/// Until the reference backfill has finished, every image counts as
/// referenced: content written before the table existed has no reference
/// rows yet, and keeping an image is always safe where deleting it is not.
export async function isAssetReferenced(
  ctx: AnyCtx,
  strategyId: Id<"strategies">,
  assetPublicId: string,
  { includeTombstones }: { includeTombstones: boolean },
): Promise<boolean> {
  if (!(await assetReferencesReady(ctx))) return true;
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
