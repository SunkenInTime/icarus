import type { QueryCtx, MutationCtx } from "../_generated/server";
import type { Doc, Id } from "../_generated/dataModel";
import { notFoundError } from "./errors";

type AnyCtx = QueryCtx | MutationCtx;

export async function getStrategyByPublicId(
  ctx: AnyCtx,
  strategyPublicId: string,
): Promise<Doc<"strategies">> {
  const strategy = await ctx.db
    .query("strategies")
    .withIndex("by_publicId", (q) => q.eq("publicId", strategyPublicId))
    .first();

  if (strategy === null) {
    throw notFoundError("Strategy", strategyPublicId);
  }

  return strategy;
}

export async function getFolderByPublicId(
  ctx: AnyCtx,
  folderPublicId: string,
): Promise<Doc<"folders">> {
  const folder = await ctx.db
    .query("folders")
    .withIndex("by_publicId", (q) => q.eq("publicId", folderPublicId))
    .first();

  if (folder === null) {
    throw notFoundError("Folder", folderPublicId);
  }

  return folder;
}

/// A live page. One in the trash reads as not found, as it did when a
/// delete removed the row.
export async function getPageByPublicId(
  ctx: AnyCtx,
  pagePublicId: string,
): Promise<Doc<"pages">> {
  const page = await ctx.db
    .query("pages")
    .withIndex("by_publicId", (q) => q.eq("publicId", pagePublicId))
    .first();

  if (page === null || isTrashed(page)) {
    throw notFoundError("Page", pagePublicId);
  }

  return page;
}

/// How long a deleted page stays in the trash, restorable with everything on
/// it, before maintenance purges it for good (purgeTrashedPages).
export const PAGE_TRASH_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;

/// Whether [page] is in the trash: deleted, not purged yet.
export function isTrashed(page: Doc<"pages">): boolean {
  return page.deletedAt !== undefined;
}

/// Whether [page] has been in the trash for the whole retention: it is due
/// for purging, or partly purged already, so it can no longer be restored.
export function isPastTrashRetention(
  page: Doc<"pages">,
  now: number,
): boolean {
  return (
    page.deletedAt !== undefined &&
    page.deletedAt <= now - PAGE_TRASH_RETENTION_MS
  );
}

/// Whether the strategy has pages in the trash, restorable or not yet purged.
export async function hasTrashedPages(
  ctx: AnyCtx,
  strategyId: Id<"strategies">,
): Promise<boolean> {
  const trashed = await ctx.db
    .query("pages")
    .withIndex("by_strategyId_and_deletedAt", (q) =>
      q.eq("strategyId", strategyId).gt("deletedAt", undefined),
    )
    .first();
  return trashed !== null;
}

/// The strategy's pages in the trash that can still be restored, most
/// recently deleted first.
export async function listRestorablePages(
  ctx: AnyCtx,
  strategyId: Id<"strategies">,
  now: number,
): Promise<Doc<"pages">[]> {
  // Past the retention a page is due for purging (isPastTrashRetention).
  return await ctx.db
    .query("pages")
    .withIndex("by_strategyId_and_deletedAt", (q) =>
      q
        .eq("strategyId", strategyId)
        .gt("deletedAt", now - PAGE_TRASH_RETENTION_MS),
    )
    .order("desc")
    .collect();
}

/// The strategy's pages, leaving out those in the trash. Read through an
/// index, so pages in the trash cost nothing here.
export function livePagesQuery(ctx: AnyCtx, strategyId: Id<"strategies">) {
  return ctx.db
    .query("pages")
    .withIndex("by_strategyId_and_deletedAt", (q) =>
      q.eq("strategyId", strategyId).eq("deletedAt", undefined),
    );
}

export async function listLivePages(
  ctx: AnyCtx,
  strategyId: Id<"strategies">,
): Promise<Doc<"pages">[]> {
  return await livePagesQuery(ctx, strategyId).collect();
}

/// The element rows, tombstones included, on [pages]. Read page by page,
/// so content in the trash is never read, however much of it the strategy
/// keeps.
export async function elementsOnPages(
  ctx: AnyCtx,
  pages: Doc<"pages">[],
): Promise<Doc<"elements">[]> {
  const byPage = await Promise.all(
    pages.map((page) =>
      ctx.db
        .query("elements")
        .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
        .collect(),
    ),
  );
  return byPage.flat();
}

/// The lineup rows on [pages]; see [elementsOnPages].
export async function lineupsOnPages(
  ctx: AnyCtx,
  pages: Doc<"pages">[],
): Promise<Doc<"lineups">[]> {
  const byPage = await Promise.all(
    pages.map((page) =>
      ctx.db
        .query("lineups")
        .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
        .collect(),
    ),
  );
  return byPage.flat();
}

/// Stores [ordered] as the strategy's page order: each page's sortIndex
/// becomes its position, and an auto-named page is named for it. Only pages
/// that change are written, each with a new revision.
export async function writePageOrder(
  ctx: MutationCtx,
  ordered: Doc<"pages">[],
  now: number,
): Promise<void> {
  for (let index = 0; index < ordered.length; index += 1) {
    const page = ordered[index]!;
    const name = page.isAutoNamed === true ? `Page ${index + 1}` : page.name;
    if (page.sortIndex !== index || page.name !== name) {
      await ctx.db.patch(page._id, {
        name,
        sortIndex: index,
        revision: page.revision + 1,
        updatedAt: now,
      });
    }
  }
}

/// Moves [page] to the trash, deleted by [deletedBy]. Its rows stay, so it
/// can be restored with everything on it; it keeps its sortIndex, the place
/// it goes back to. The live pages left close the gap. [livePages] includes
/// [page].
export async function trashPage(
  ctx: MutationCtx,
  page: Doc<"pages">,
  livePages: Doc<"pages">[],
  deletedBy: Id<"users">,
  now: number,
): Promise<void> {
  await ctx.db.patch(page._id, { deletedAt: now, deletedBy });
  await writePageOrder(
    ctx,
    sortByNumberField(
      livePages.filter((candidate) => candidate._id !== page._id),
      "sortIndex",
    ),
    now,
  );
}

/// Takes [page] out of the trash, back at the place it was deleted from, or
/// last if fewer pages are left than that.
export async function restoreTrashedPage(
  ctx: MutationCtx,
  page: Doc<"pages">,
  livePages: Doc<"pages">[],
  now: number,
): Promise<void> {
  const ordered = sortByNumberField(livePages, "sortIndex");
  ordered.splice(clampPageIndex(page.sortIndex, ordered.length), 0, page);
  await ctx.db.patch(page._id, { deletedAt: undefined, deletedBy: undefined });
  await writePageOrder(ctx, ordered, now);
}

export async function getElementByPublicId(
  ctx: AnyCtx,
  elementPublicId: string,
): Promise<Doc<"elements">> {
  const element = await ctx.db
    .query("elements")
    .withIndex("by_publicId", (q) => q.eq("publicId", elementPublicId))
    .first();

  if (element === null) {
    throw notFoundError("Element", elementPublicId);
  }

  return element;
}

export function sortByNumberField<T extends Record<string, unknown>>(
  input: T[],
  field: keyof T,
): T[] {
  return [...input].sort((a, b) => {
    const fieldDifference = Number(a[field] ?? 0) - Number(b[field] ?? 0);
    if (fieldDifference !== 0) return fieldDifference;

    const leftPublicId = typeof a.publicId === "string" ? a.publicId : "";
    const rightPublicId = typeof b.publicId === "string" ? b.publicId : "";
    return leftPublicId.localeCompare(rightPublicId);
  });
}

export function clampPageIndex(index: number, maximum: number): number {
  return Math.max(0, Math.min(Math.trunc(index), maximum));
}
