import type { Doc, Id } from "./_generated/dataModel";
import type { QueryCtx, MutationCtx } from "./_generated/server";
import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import { deleteImageAssetsForStrategy } from "./images";
import {
  assertFolderRole,
  assertStrategyRole,
  getEffectiveStrategyRoleForUser,
  requireCurrentUser,
} from "./lib/auth";
import { getFolderByPublicId, getStrategyByPublicId } from "./lib/entities";

type AnyCtx = QueryCtx | MutationCtx;
type StrategyScope = "owned" | "shared";

const strategyScopeValidator = v.optional(
  v.union(v.literal("owned"), v.literal("shared")),
);

async function listAccessibleStrategiesForScope(
  ctx: AnyCtx,
  userId: Id<"users">,
  scope: StrategyScope,
): Promise<Array<{ strategy: Doc<"strategies">; role: "owner" | "editor" | "viewer" }>> {
  const strategies = await ctx.db.query("strategies").collect();
  const results: Array<{
    strategy: Doc<"strategies">;
    role: "owner" | "editor" | "viewer";
  }> = [];

  for (const strategy of strategies) {
    const role = await getEffectiveStrategyRoleForUser(ctx, strategy, userId);
    if (role === null) {
      continue;
    }
    if (scope === "owned" && strategy.ownerId !== userId) {
      continue;
    }
    if (scope === "shared" && strategy.ownerId === userId) {
      continue;
    }
    results.push({ strategy, role });
  }

  return results;
}

async function getAttackLabel(ctx: QueryCtx, strategyId: Id<"strategies">) {
  const pages = await ctx.db
    .query("pages")
    .withIndex("by_strategyId", (q) => q.eq("strategyId", strategyId))
    .collect();

  if (pages.length === 0) {
    return "Unknown";
  }

  const first = pages[0]!.isAttack;
  const mixed = pages.some((page) => page.isAttack !== first);
  return mixed ? "Mixed" : first ? "Attack" : "Defend";
}

export const listForFolder = query({
  args: {
    folderPublicId: v.optional(v.string()),
    scope: strategyScopeValidator,
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    const scope = args.scope ?? "owned";

    let folderId: Id<"folders"> | undefined;
    if (args.folderPublicId !== undefined) {
      const folder = await getFolderByPublicId(ctx, args.folderPublicId);
      await assertFolderRole(ctx, folder, "viewer");
      folderId = folder._id;
    }

    const accessible = await listAccessibleStrategiesForScope(ctx, user._id, scope);
    const folderLookup = new Map<Id<"folders">, string>();
    for (const { strategy } of accessible) {
      if (strategy.folderId === undefined || folderLookup.has(strategy.folderId)) {
        continue;
      }
      const folder = await ctx.db.get(strategy.folderId);
      if (folder !== null) {
        folderLookup.set(strategy.folderId, folder.publicId);
      }
    }

    return await Promise.all(
      accessible
        .filter(({ strategy }) => strategy.folderId === folderId)
        .sort((a, b) => b.strategy.updatedAt - a.strategy.updatedAt)
        .map(async ({ strategy, role }) => ({
          publicId: strategy.publicId,
          name: strategy.name,
          mapData: strategy.mapData,
          sequence: strategy.sequence,
          createdAt: strategy.createdAt,
          updatedAt: strategy.updatedAt,
          role,
          attackLabel: await getAttackLabel(ctx, strategy._id),
          folderPublicId:
            strategy.folderId === undefined
              ? null
              : folderLookup.get(strategy.folderId) ?? null,
          themeProfileId: strategy.themeProfileId ?? null,
          themeOverridePalette: strategy.themeOverridePalette ?? null,
        })),
    );
  },
});

export const listSharedWithMe = query({
  args: {},
  handler: async (ctx) => {
    const user = await requireCurrentUser(ctx);
    const sharedStrategies = await listAccessibleStrategiesForScope(
      ctx,
      user._id,
      "shared",
    );
    const folderLookup = new Map<Id<"folders">, string>();
    for (const { strategy } of sharedStrategies) {
      if (strategy.folderId === undefined || folderLookup.has(strategy.folderId)) {
        continue;
      }
      const folder = await ctx.db.get(strategy.folderId);
      if (folder !== null) {
        folderLookup.set(strategy.folderId, folder.publicId);
      }
    }

    return await Promise.all(
      sharedStrategies
        .sort((a, b) => b.strategy.updatedAt - a.strategy.updatedAt)
        .map(async ({ strategy, role }) => ({
          publicId: strategy.publicId,
          name: strategy.name,
          mapData: strategy.mapData,
          sequence: strategy.sequence,
          createdAt: strategy.createdAt,
          updatedAt: strategy.updatedAt,
          role,
          attackLabel: await getAttackLabel(ctx, strategy._id),
          folderPublicId:
            strategy.folderId === undefined
              ? null
              : folderLookup.get(strategy.folderId) ?? null,
          themeProfileId: strategy.themeProfileId ?? null,
          themeOverridePalette: strategy.themeOverridePalette ?? null,
        })),
    );
  },
});

export const getHeader = query({
  args: {
    strategyPublicId: v.string(),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    const { role } = await assertStrategyRole(ctx, strategy, "viewer");

    return {
      publicId: strategy.publicId,
      name: strategy.name,
      mapData: strategy.mapData,
      sequence: strategy.sequence,
      createdAt: strategy.createdAt,
      updatedAt: strategy.updatedAt,
      themeProfileId: strategy.themeProfileId ?? null,
      themeOverridePalette: strategy.themeOverridePalette ?? null,
      role,
    };
  },
});

export const create = mutation({
  args: {
    publicId: v.string(),
    name: v.string(),
    mapData: v.string(),
    folderPublicId: v.optional(v.string()),
    themeProfileId: v.optional(v.string()),
    themeOverridePalette: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    const now = Date.now();

    let folderId: Id<"folders"> | undefined;
    if (args.folderPublicId !== undefined) {
      const folder = await getFolderByPublicId(ctx, args.folderPublicId);
      const { role } = await assertFolderRole(ctx, folder, "owner");
      if (role !== "owner") {
        throw new Error("Forbidden");
      }
      folderId = folder._id;
    }

    const existing = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", args.publicId))
      .collect();
    const existingOwned = existing.find((item) => item.ownerId === user._id);
    if (existingOwned !== undefined) {
      return { ok: true, reused: true };
    }
    if (existing.length > 0) {
      throw new Error(`Strategy publicId already exists: ${args.publicId}`);
    }

    await ctx.db.insert("strategies", {
      publicId: args.publicId,
      ownerId: user._id,
      folderId,
      name: args.name,
      mapData: args.mapData,
      sequence: 0,
      themeProfileId: args.themeProfileId,
      themeOverridePalette: args.themeOverridePalette,
      createdAt: now,
      updatedAt: now,
    });

    return { ok: true };
  },
});

export const update = mutation({
  args: {
    strategyPublicId: v.string(),
    name: v.optional(v.string()),
    mapData: v.optional(v.string()),
    themeProfileId: v.optional(v.string()),
    clearThemeProfileId: v.optional(v.boolean()),
    themeOverridePalette: v.optional(v.string()),
    clearThemeOverridePalette: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");

    const patch: Record<string, unknown> = {
      updatedAt: Date.now(),
      sequence: strategy.sequence + 1,
    };

    if (args.name !== undefined) patch.name = args.name;
    if (args.mapData !== undefined) patch.mapData = args.mapData;

    if (args.clearThemeProfileId === true) {
      patch.themeProfileId = undefined;
    } else if (args.themeProfileId !== undefined) {
      patch.themeProfileId = args.themeProfileId;
    }

    if (args.clearThemeOverridePalette === true) {
      patch.themeOverridePalette = undefined;
    } else if (args.themeOverridePalette !== undefined) {
      patch.themeOverridePalette = args.themeOverridePalette;
    }

    await ctx.db.patch(strategy._id, patch);
    return { ok: true };
  },
});

export const move = mutation({
  args: {
    strategyPublicId: v.string(),
    folderPublicId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");

    let folderId: Id<"folders"> | undefined;
    if (args.folderPublicId !== undefined) {
      const folder = await getFolderByPublicId(ctx, args.folderPublicId);
      const parentAccess = await assertFolderRole(ctx, folder, "owner");
      if (parentAccess.role !== "owner" || folder.ownerId !== strategy.ownerId) {
        throw new Error("Forbidden");
      }
      folderId = folder._id;
    }

    await ctx.db.patch(strategy._id, {
      folderId,
      sequence: strategy.sequence + 1,
      updatedAt: Date.now(),
    });

    return { ok: true };
  },
});

export const deleteStrategy = mutation({
  args: {
    strategyPublicId: v.string(),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    const { role } = await assertStrategyRole(ctx, strategy, "owner");

    if (role !== "owner") {
      throw new Error("Forbidden");
    }

    const pages = await ctx.db
      .query("pages")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
      .collect();

    for (const page of pages) {
      const pageElements = await ctx.db
        .query("elements")
        .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
        .collect();
      for (const element of pageElements) {
        await ctx.db.delete(element._id);
      }

      const pageLineups = await ctx.db
        .query("lineups")
        .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
        .collect();
      for (const lineup of pageLineups) {
        await ctx.db.delete(lineup._id);
      }

      await ctx.db.delete(page._id);
    }

    await deleteImageAssetsForStrategy(ctx, strategy._id);

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
    for (const link of shareLinks) {
      await ctx.db.delete(link._id);
    }

    await ctx.db.delete(strategy._id);
    return { ok: true };
  },
});

export { deleteStrategy as delete };
