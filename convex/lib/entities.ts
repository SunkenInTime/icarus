import type { QueryCtx, MutationCtx } from "../_generated/server";
import type { Doc } from "../_generated/dataModel";

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
    throw new Error(`Strategy not found: ${strategyPublicId}`);
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
    throw new Error(`Folder not found: ${folderPublicId}`);
  }

  return folder;
}

export async function getPageByPublicId(
  ctx: AnyCtx,
  pagePublicId: string,
): Promise<Doc<"pages">> {
  const page = await ctx.db
    .query("pages")
    .withIndex("by_publicId", (q) => q.eq("publicId", pagePublicId))
    .first();

  if (page === null) {
    throw new Error(`Page not found: ${pagePublicId}`);
  }

  return page;
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
    throw new Error(`Element not found: ${elementPublicId}`);
  }

  return element;
}

export async function getLineupByPublicId(
  ctx: AnyCtx,
  lineupPublicId: string,
): Promise<Doc<"lineups">> {
  const lineup = await ctx.db
    .query("lineups")
    .withIndex("by_publicId", (q) => q.eq("publicId", lineupPublicId))
    .first();

  if (lineup === null) {
    throw new Error(`Lineup not found: ${lineupPublicId}`);
  }

  return lineup;
}

export function sortByNumberField<T extends Record<string, unknown>>(
  input: T[],
  field: keyof T,
): T[] {
  return [...input].sort((a, b) => Number(a[field] ?? 0) - Number(b[field] ?? 0));
}
