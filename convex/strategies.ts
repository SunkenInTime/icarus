import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import {
  assertStrategyRole,
  getStrategyRoleForUser,
  requireCurrentUser,
} from "./lib/auth";
import { getFolderByPublicId, getStrategyByPublicId } from "./lib/entities";

async function listAccessibleStrategies(ctx: any, userId: any) {
  const owned = await ctx.db
    .query("strategies")
    .withIndex("by_ownerId", (q: any) => q.eq("ownerId", userId))
    .collect();

  const memberships = await ctx.db
    .query("strategyCollaborators")
    .withIndex("by_userId", (q: any) => q.eq("userId", userId))
    .collect();

  const fromMembership = await Promise.all(
    memberships.map((m: any) => ctx.db.get(m.strategyId)),
  );

  const dedup = new Map<any, any>();
  for (const strategy of [...owned, ...fromMembership]) {
    if (strategy !== null) {
      dedup.set(strategy._id, strategy);
    }
  }

  return Array.from(dedup.values());
}

export const listForFolder = query({
  args: {
    folderPublicId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    const all = await listAccessibleStrategies(ctx as any, user._id);

    let folderId;
    if (args.folderPublicId !== undefined) {
      const folder = await getFolderByPublicId(ctx, args.folderPublicId);
      if (folder.ownerId !== user._id) {
        throw new Error("Forbidden");
      }
      folderId = folder._id;
    }

    const folderIdToPublicId = new Map<any, string>();
    for (const strategy of all) {
      if (
        strategy.folderId !== undefined &&
        !folderIdToPublicId.has(strategy.folderId)
      ) {
        const strategyFolder = await ctx.db.get(strategy.folderId);
        if (strategyFolder !== null) {
          folderIdToPublicId.set(strategy.folderId, strategyFolder.publicId);
        }
      }
    }

    const filtered = all
      .filter((s) => s.folderId === folderId)
      .sort((a, b) => b.updatedAt - a.updatedAt);

    return Promise.all(
      filtered.map(async (s) => ({
        publicId: s.publicId,
        name: s.name,
        mapData: s.mapData,
        sequence: s.sequence,
        createdAt: s.createdAt,
        updatedAt: s.updatedAt,
        folderPublicId:
          s.folderId === undefined
            ? null
            : folderIdToPublicId.get(s.folderId) ?? null,
        themeProfileId: s.themeProfileId ?? null,
        themeOverridePalette: s.themeOverridePalette ?? null,
        role: await getStrategyRoleForUser(ctx, s, user._id),
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

    let folderId;
    if (args.folderPublicId !== undefined) {
      const folder = await getFolderByPublicId(ctx, args.folderPublicId);
      if (folder.ownerId !== user._id) {
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

    let folderId;
    if (args.folderPublicId !== undefined) {
      const folder = await getFolderByPublicId(ctx, args.folderPublicId);
      if (folder.ownerId !== strategy.ownerId) {
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

      const assets = await ctx.db
        .query("imageAssets")
        .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
        .collect();
      for (const asset of assets) {
        await ctx.db.delete(asset._id);
      }

      await ctx.db.delete(page._id);
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

    await ctx.db.delete(strategy._id);
    return { ok: true };
  },
});

export { deleteStrategy as delete };



