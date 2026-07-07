import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import { assertStrategyRole } from "./lib/auth";
import { purgeDeletedPageOrphansRef } from "./maintenance";
import {
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
} from "./lib/errors";

function settingsEqual(left: unknown, right: unknown): boolean {
  return JSON.stringify(left ?? null) === JSON.stringify(right ?? null);
}

export const listForStrategy = query({
  args: {
    strategyPublicId: v.string(),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "viewer");

    const pages = await ctx.db
      .query("pages")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
      .collect();

    return sortByNumberField(pages, "sortIndex").map((page) => ({
      publicId: page.publicId,
      strategyPublicId: strategy.publicId,
      name: page.name,
      sortIndex: page.sortIndex,
      isAttack: page.isAttack,
      settings: page.settings ?? null,
      revision: page.revision,
      createdAt: page.createdAt,
      updatedAt: page.updatedAt,
    }));
  },
});

export const add = mutation({
  args: {
    strategyPublicId: v.string(),
    pagePublicId: v.string(),
    name: v.string(),
    sortIndex: v.number(),
    isAttack: v.boolean(),
    settings: v.optional(strategySettingsValidator),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");

    const now = Date.now();
    const existingPage = await ctx.db
      .query("pages")
      .withIndex("by_publicId", (q) => q.eq("publicId", args.pagePublicId))
      .first();
    if (existingPage !== null) {
      if (existingPage.strategyId !== strategy._id) {
        throw conflictError(`Page publicId already exists: ${args.pagePublicId}`);
      }

      const settingsChanged = !settingsEqual(existingPage.settings, args.settings);
      const hasChanges =
        existingPage.name !== args.name ||
        existingPage.sortIndex !== args.sortIndex ||
        existingPage.isAttack !== args.isAttack ||
        settingsChanged;
      if (!hasChanges) {
        return { ok: true, reused: true };
      }

      await ctx.db.patch(existingPage._id, {
        name: args.name,
        sortIndex: args.sortIndex,
        isAttack: args.isAttack,
        settings: args.settings,
        revision: existingPage.revision + 1,
        updatedAt: now,
      });

      await ctx.db.patch(strategy._id, {
        sequence: strategy.sequence + 1,
        updatedAt: now,
      });
      return { ok: true, reused: true };
    }

    await ctx.db.insert("pages", {
      publicId: args.pagePublicId,
      strategyId: strategy._id,
      name: args.name,
      sortIndex: args.sortIndex,
      isAttack: args.isAttack,
      settings: args.settings,
      revision: 1,
      createdAt: now,
      updatedAt: now,
    });

    await ctx.db.patch(strategy._id, {
      sequence: strategy.sequence + 1,
      updatedAt: now,
    });

    return { ok: true };
  },
});

export const rename = mutation({
  args: {
    strategyPublicId: v.string(),
    pagePublicId: v.string(),
    name: v.string(),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");

    const page = await getPageByPublicId(ctx, args.pagePublicId);
    if (page.strategyId !== strategy._id) {
      throw errorWithCode("PAGE_STRATEGY_MISMATCH", "Page strategy mismatch");
    }

    const now = Date.now();
    await ctx.db.patch(page._id, {
      name: args.name,
      revision: page.revision + 1,
      updatedAt: now,
    });

    await ctx.db.patch(strategy._id, {
      sequence: strategy.sequence + 1,
      updatedAt: now,
    });

    return { ok: true };
  },
});

export const deletePage = mutation({
  args: {
    strategyPublicId: v.string(),
    pagePublicId: v.string(),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");

    const pages = await ctx.db
      .query("pages")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
      .collect();

    if (pages.length <= 1) {
      throw invalidOpError("Cannot delete last page");
    }

    const page = await getPageByPublicId(ctx, args.pagePublicId);
    if (page.strategyId !== strategy._id) {
      throw errorWithCode("PAGE_STRATEGY_MISMATCH", "Page strategy mismatch");
    }

    await ctx.db.delete(page._id);

    await ctx.scheduler.runAfter(0, purgeDeletedPageOrphansRef, {
      pageId: page._id,
    });

    const ordered = sortByNumberField(
      pages.filter((p) => p._id !== page._id),
      "sortIndex",
    );
    for (let i = 0; i < ordered.length; i += 1) {
      const current = ordered[i]!;
      if (current.sortIndex !== i) {
        await ctx.db.patch(current._id, {
          sortIndex: i,
          revision: current.revision + 1,
          updatedAt: Date.now(),
        });
      }
    }

    await ctx.db.patch(strategy._id, {
      sequence: strategy.sequence + 1,
      updatedAt: Date.now(),
    });

    return { ok: true };
  },
});

export const reorder = mutation({
  args: {
    strategyPublicId: v.string(),
    orderedPagePublicIds: v.array(v.string()),
  },
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

    const pageByPublicId = new Map(pages.map((p) => [p.publicId, p]));
    const now = Date.now();

    for (let i = 0; i < args.orderedPagePublicIds.length; i += 1) {
      const publicId = args.orderedPagePublicIds[i]!;
      const page = pageByPublicId.get(publicId);
      if (!page) {
        throw notFoundError("Page", publicId);
      }
      if (page.sortIndex !== i) {
        await ctx.db.patch(page._id, {
          sortIndex: i,
          revision: page.revision + 1,
          updatedAt: now,
        });
      }
    }

    await ctx.db.patch(strategy._id, {
      sequence: strategy.sequence + 1,
      updatedAt: now,
    });

    return { ok: true };
  },
});

export { deletePage as delete };
