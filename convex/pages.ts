import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import { assertStrategyRole } from "./lib/auth";
import { purgeDeletedPageOrphansRef } from "./maintenance";
import {
  clampPageIndex,
  getPageByPublicId,
  getStrategyByPublicId,
  sortByNumberField,
} from "./lib/entities";
import { strategySettingsValidator } from "./lib/payloadValidators";
import {
  conflictError,
  invalidOpError,
  notFoundError,
  errorWithCode,
  internalError,
} from "./lib/errors";
import { serializePageDescriptor } from "./lib/snapshotSerialization";
import { valuesEqual } from "./lib/canonicalValues";
import {
  pageDescriptorValidator,
  revisionResultValidator,
} from "./lib/publicValidators";

export const listForStrategy = query({
  args: { strategyPublicId: v.string() },
  returns: v.array(pageDescriptorValidator),
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "viewer");
    const pages = await ctx.db
      .query("pages")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
      .collect();
    return sortByNumberField(pages, "sortIndex").map((page) =>
      serializePageDescriptor(strategy.publicId, page),
    );
  },
});

export const add = mutation({
  args: {
    strategyPublicId: v.string(),
    expectedRevision: v.number(),
    pagePublicId: v.string(),
    name: v.string(),
    sortIndex: v.number(),
    isAttack: v.boolean(),
    settings: v.optional(strategySettingsValidator),
  },
  returns: revisionResultValidator,
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");
    const existingPage = await ctx.db
      .query("pages")
      .withIndex("by_publicId", (q) => q.eq("publicId", args.pagePublicId))
      .first();
    const pages = await ctx.db
      .query("pages")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
      .collect();

    if (existingPage !== null) {
      if (existingPage.strategyId !== strategy._id) {
        throw conflictError(
          `Page publicId already exists: ${args.pagePublicId}`,
        );
      }
      const pageContents = await ctx.db
        .query("pageContents")
        .withIndex("by_pageId", (q) => q.eq("pageId", existingPage._id))
        .take(2);
      if (pageContents.length !== 1) {
        throw internalError(
          "Each page must have exactly one page content row.",
        );
      }
      const desiredSortIndex = clampPageIndex(
        args.sortIndex,
        Math.max(0, pages.length - 1),
      );
      const identical =
        existingPage.name === args.name &&
        existingPage.sortIndex === desiredSortIndex &&
        existingPage.isAttack === args.isAttack &&
        valuesEqual(pageContents[0]!.settings, args.settings);
      if (identical) {
        return { ok: true, reused: true, revision: strategy.revision } as const;
      }
      throw conflictError(`Page publicId already exists: ${args.pagePublicId}`);
    }
    if (args.expectedRevision !== strategy.revision) {
      throw conflictError("Strategy revision mismatch");
    }

    const now = Date.now();
    const orderedPages = sortByNumberField(pages, "sortIndex");
    const desiredSortIndex = clampPageIndex(args.sortIndex, orderedPages.length);
    for (let index = 0; index < orderedPages.length; index += 1) {
      const page = orderedPages[index]!;
      const normalizedIndex = index >= desiredSortIndex ? index + 1 : index;
      if (page.sortIndex !== normalizedIndex) {
        await ctx.db.patch(page._id, {
          sortIndex: normalizedIndex,
          revision: page.revision + 1,
          updatedAt: now,
        });
      }
    }
    const pageId = await ctx.db.insert("pages", {
      publicId: args.pagePublicId,
      strategyId: strategy._id,
      name: args.name,
      sortIndex: desiredSortIndex,
      isAttack: args.isAttack,
      revision: 1,
      createdAt: now,
      updatedAt: now,
    });
    await ctx.db.insert("pageContents", {
      pageId,
      settings: args.settings,
      revision: 1,
      createdAt: now,
      updatedAt: now,
    });
    const revision = strategy.revision + 1;
    await ctx.db.patch(strategy._id, { revision, updatedAt: now });
    return { ok: true, revision } as const;
  },
});

export const rename = mutation({
  args: {
    strategyPublicId: v.string(),
    pagePublicId: v.string(),
    name: v.string(),
    expectedRevision: v.number(),
  },
  returns: revisionResultValidator,
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");
    const page = await getPageByPublicId(ctx, args.pagePublicId);
    if (page.strategyId !== strategy._id) {
      throw errorWithCode("PAGE_STRATEGY_MISMATCH", "Page strategy mismatch");
    }
    if (page.name === args.name) {
      return { ok: true, reused: true, revision: page.revision } as const;
    }
    if (args.expectedRevision !== page.revision) {
      throw conflictError("Page revision mismatch");
    }

    const revision = page.revision + 1;
    await ctx.db.patch(page._id, {
      name: args.name,
      revision,
      updatedAt: Date.now(),
    });
    return { ok: true, revision } as const;
  },
});

const deletePage = mutation({
  args: {
    strategyPublicId: v.string(),
    pagePublicId: v.string(),
    expectedRevision: v.number(),
  },
  returns: revisionResultValidator,
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");
    const pages = await ctx.db
      .query("pages")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
      .collect();
    const page = pages.find(
      (candidate) => candidate.publicId === args.pagePublicId,
    );
    if (page === undefined) {
      return { ok: true, reused: true, revision: strategy.revision } as const;
    }
    if (pages.length <= 1) {
      throw invalidOpError("Cannot delete last page");
    }
    if (args.expectedRevision !== strategy.revision) {
      throw conflictError("Strategy revision mismatch");
    }

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
    });

    const ordered = sortByNumberField(
      pages.filter((candidate) => candidate._id !== page._id),
      "sortIndex",
    );
    const now = Date.now();
    for (let index = 0; index < ordered.length; index += 1) {
      const current = ordered[index]!;
      if (current.sortIndex !== index) {
        await ctx.db.patch(current._id, {
          sortIndex: index,
          revision: current.revision + 1,
          updatedAt: now,
        });
      }
    }

    const revision = strategy.revision + 1;
    await ctx.db.patch(strategy._id, { revision, updatedAt: now });
    return { ok: true, revision } as const;
  },
});

export const reorder = mutation({
  args: {
    strategyPublicId: v.string(),
    orderedPagePublicIds: v.array(v.string()),
    expectedRevision: v.number(),
  },
  returns: revisionResultValidator,
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");
    const pages = await ctx.db
      .query("pages")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
      .collect();
    if (pages.length !== args.orderedPagePublicIds.length) {
      throw invalidOpError("Page count mismatch");
    }
    if (new Set(args.orderedPagePublicIds).size !== pages.length) {
      throw invalidOpError("Page order must include each page exactly once");
    }
    const pageByPublicId = new Map(pages.map((page) => [page.publicId, page]));
    const ordered = args.orderedPagePublicIds.map((publicId) => {
      const page = pageByPublicId.get(publicId);
      if (page === undefined) throw notFoundError("Page", publicId);
      return page;
    });
    if (ordered.every((page, index) => page.sortIndex === index)) {
      return { ok: true, reused: true, revision: strategy.revision } as const;
    }
    if (args.expectedRevision !== strategy.revision) {
      throw conflictError("Strategy revision mismatch");
    }

    const now = Date.now();
    for (let index = 0; index < ordered.length; index += 1) {
      const page = ordered[index]!;
      if (page.sortIndex !== index) {
        await ctx.db.patch(page._id, {
          sortIndex: index,
          revision: page.revision + 1,
          updatedAt: now,
        });
      }
    }
    const revision = strategy.revision + 1;
    await ctx.db.patch(strategy._id, { revision, updatedAt: now });
    return { ok: true, revision } as const;
  },
});

export { deletePage as delete };
