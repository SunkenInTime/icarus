import { makeFunctionReference } from "convex/server";
import { getConvexSize } from "convex/values";
import type { Doc, Id } from "../_generated/dataModel";
import type { MutationCtx } from "../_generated/server";
import { ContentCopy, CopyBudget, createPublicId } from "./contentCopy";
import { livePagesQuery } from "./entities";
import {
  agentTypesOf,
  deleteStrategyAgentSummary,
  storeStrategyAgentSummary,
} from "./strategyAgentSummary";

const purgeDeletedPageOrphansRef = makeFunctionReference<"mutation">(
  "maintenance:purgeDeletedPageOrphans",
);
const markDeletedStrategyImageAssetsRef = makeFunctionReference<"mutation">(
  "images:markDeletedStrategyImageAssets",
);

/// Copies [source] into a new strategy in one transaction: pages, page
/// settings, live elements and lineups under fresh publicIds, and an image
/// asset row per image the copy shows. The rows share the source's stored
/// bytes, so deleting either strategy leaves the other's images alone.
///
/// Past the copy budget the whole copy is refused with [tooLarge]: the
/// transaction rolls back, so no part of a copy is ever left behind.
export async function copyStrategy(
  ctx: MutationCtx,
  source: Doc<"strategies">,
  target: {
    publicId: string;
    ownerId: Id<"users">;
    folderId: Id<"folders"> | undefined;
    name: string;
    /// Who the copied image rows are recorded as made by.
    userId: Id<"users">;
  },
  tooLarge: () => Error,
): Promise<{
  strategyId: Id<"strategies">;
  agentTypes: string[];
  /// Each copied page's side, in page order.
  pageIsAttack: boolean[];
  lineupCount: number;
}> {
  const now = Date.now();
  const strategyId = await ctx.db.insert("strategies", {
    publicId: target.publicId,
    ownerId: target.ownerId,
    folderId: target.folderId,
    name: target.name,
    mapData: source.mapData,
    revision: 0,
    themeProfileId: source.themeProfileId,
    themeOverridePalette: source.themeOverridePalette,
    createdAt: now,
    updatedAt: now,
  });

  const budget = new CopyBudget(tooLarge);
  const copy = new ContentCopy(ctx, {
    sourceStrategyId: source._id,
    targetStrategyId: strategyId,
    userId: target.userId,
    now,
    budget,
  });
  // Pages in the trash are not copied, nor read, so content on them
  // cannot push the copy over its budget.
  const sourcePages = await budget.read(livePagesQuery(ctx, source._id));
  for (const page of sourcePages) {
    const content = await ctx.db
      .query("pageContents")
      .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
      .first();
    // The settings read, and the two rows this page's copy writes.
    budget.spend({
      bytes: content === null ? 0 : getConvexSize(content),
      documents: 2,
    });
    const pageToCopy = await copy.read(page._id);
    const pageId = await ctx.db.insert("pages", {
      publicId: createPublicId(),
      strategyId,
      name: page.name,
      ...(page.isAutoNamed === undefined
        ? {}
        : { isAutoNamed: page.isAutoNamed }),
      sortIndex: page.sortIndex,
      isAttack: page.isAttack,
      revision: 1,
      createdAt: now,
      updatedAt: now,
    });
    await ctx.db.insert("pageContents", {
      pageId,
      settings: content?.settings,
      revision: 1,
      createdAt: now,
      updatedAt: now,
    });
    await copy.write(pageToCopy, pageId);
  }

  // The copy's summary comes from the rows just copied: reading them back
  // would read the strategy's agents a second time.
  const agentTypes = agentTypesOf(copy.elements, copy.lineupAgents);
  await storeStrategyAgentSummary(ctx, strategyId, agentTypes);
  return {
    strategyId,
    agentTypes,
    pageIsAttack: [...sourcePages]
      .sort((a, b) => a.sortIndex - b.sortIndex)
      .map((page) => page.isAttack),
    lineupCount: copy.lineupAgents.length,
  };
}

export async function deleteStrategyRecord(
  ctx: MutationCtx,
  strategy: Doc<"strategies">,
) {
  // Pages in the trash are left to their purge (purgeTrashedPages), which
  // needs no strategy: one purge scheduled per page must stay within
  // Convex's scheduling limit however many pages the trash holds. Nothing
  // can reach or restore them once the strategy is gone.
  const pages = await livePagesQuery(ctx, strategy._id).collect();

  for (const page of pages) {
    const pageContents = await ctx.db
      .query("pageContents")
      .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
      .collect();
    for (const pageContent of pageContents) {
      await ctx.db.delete(pageContent._id);
    }
    await ctx.db.delete(page._id);
    await ctx.scheduler.runAfter(0, purgeDeletedPageOrphansRef, {
      pageId: page._id,
      strategyId: strategy._id,
    });
  }

  const collaborators = await ctx.db
    .query("strategyCollaborators")
    .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
    .collect();
  for (const collaborator of collaborators) {
    await ctx.db.delete(collaborator._id);
  }

  const invites = await ctx.db
    .query("inviteTokens")
    .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
    .collect();
  for (const invite of invites) {
    await ctx.db.delete(invite._id);
  }

  const shareLinks = await ctx.db
    .query("shareLinks")
    .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
    .collect();
  for (const shareLink of shareLinks) {
    await ctx.db.delete(shareLink._id);
  }

  await ctx.scheduler.runAfter(0, markDeletedStrategyImageAssetsRef, {
    strategyId: strategy._id,
  });
  await deleteStrategyAgentSummary(ctx, strategy._id);
  await ctx.db.delete(strategy._id);
}
