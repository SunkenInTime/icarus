import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import type { MutationCtx, QueryCtx } from "./_generated/server";
import {
  assertFolderRole,
  assertStrategyRole,
  getEffectiveStrategyRoleForUser,
  requireCurrentUser,
} from "./lib/auth";
import { getFolderByPublicId, getStrategyByPublicId } from "./lib/entities";
import {
  mapThemePaletteValidator,
  strategySettingsValidator,
} from "./lib/payloadValidators";

type StrategyScope = "owned" | "shared" | "all";

type StrategyCreateInput = {
  publicId: string;
  name: string;
  mapData: string;
  folderPublicId?: string;
  themeProfileId?: string;
  themeOverridePalette?: Doc<"strategies">["themeOverridePalette"];
};

type InitialPageInput = {
  publicId: string;
  name: string;
  isAttack: boolean;
  settings?: Doc<"pages">["settings"];
};

function createPublicId(): string {
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (char) => {
    const random = Math.floor(Math.random() * 16);
    const value = char === "x" ? random : (random & 0x3) | 0x8;
    return value.toString(16);
  });
}

const strategyScopeValidator = v.optional(
  v.union(v.literal("owned"), v.literal("shared"), v.literal("all")),
);

function matchesScope(
  ownerId: Id<"users">,
  userId: Id<"users">,
  scope: StrategyScope,
): boolean {
  if (scope === "all") {
    return true;
  }
  if (scope === "owned") {
    return ownerId === userId;
  }
  return ownerId !== userId;
}

async function summarizeStrategies(
  ctx: QueryCtx,
  strategies: Doc<"strategies">[],
  userId: Id<"users">,
) {
  const memberships = await ctx.db
    .query("strategyCollaborators")
    .withIndex("by_userId", (q) => q.eq("userId", userId))
    .collect();

  const folderIdToPublicId = new Map<Id<"folders">, string>();
  for (const strategy of strategies) {
    if (
      strategy.folderId !== undefined &&
      !folderIdToPublicId.has(strategy.folderId)
    ) {
      const folder = await ctx.db.get(strategy.folderId);
      if (folder !== null) {
        folderIdToPublicId.set(strategy.folderId, folder.publicId);
      }
    }
  }

  return await Promise.all(
    strategies
      .sort((a, b) => b.updatedAt - a.updatedAt)
      .map(async (s) => {
        const pages = await ctx.db
          .query("pages")
          .withIndex("by_strategyId", (q) => q.eq("strategyId", s._id))
          .collect();
        let attackLabel = "Unknown";
        if (pages.length > 0) {
          const first = pages[0]!.isAttack;
          const mixed = pages.some((page) => page.isAttack !== first);
          attackLabel = mixed ? "Mixed" : first ? "Attack" : "Defend";
        }
        const role =
          s.ownerId === userId
            ? "owner"
            : ((await getEffectiveStrategyRoleForUser(ctx, s, userId)) ??
              memberships.find((m: any) => m.strategyId === s._id)?.role ??
              "viewer");

        return {
          publicId: s.publicId,
          name: s.name,
          mapData: s.mapData,
          sequence: s.sequence,
          createdAt: s.createdAt,
          updatedAt: s.updatedAt,
          role,
          attackLabel,
          folderPublicId:
            s.folderId === undefined
              ? null
              : (folderIdToPublicId.get(s.folderId) ?? null),
          themeProfileId: s.themeProfileId ?? null,
          themeOverridePalette: s.themeOverridePalette ?? null,
        };
      }),
  );
}

async function listStrategiesInFolder(
  ctx: QueryCtx,
  folderId: Id<"folders"> | undefined,
  userId: Id<"users">,
  scope: StrategyScope,
) {
  let candidates: Doc<"strategies">[];
  if (folderId !== undefined) {
    candidates = await ctx.db
      .query("strategies")
      .withIndex("by_folderId", (q) => q.eq("folderId", folderId))
      .collect();
  } else if (scope === "shared") {
    const memberships = await ctx.db
      .query("strategyCollaborators")
      .withIndex("by_userId", (q) => q.eq("userId", userId))
      .collect();
    const shared = await Promise.all(
      memberships.map((membership) => ctx.db.get(membership.strategyId)),
    );
    candidates = shared.filter(
      (strategy): strategy is Doc<"strategies"> =>
        strategy !== null &&
        strategy.ownerId !== userId &&
        strategy.folderId === undefined,
    );
  } else {
    candidates = await ctx.db
      .query("strategies")
      .withIndex("by_ownerId", (q) => q.eq("ownerId", userId))
      .collect();
    candidates = candidates.filter(
      (strategy) => strategy.folderId === undefined,
    );

    if (scope === "all") {
      const memberships = await ctx.db
        .query("strategyCollaborators")
        .withIndex("by_userId", (q) => q.eq("userId", userId))
        .collect();
      const shared = await Promise.all(
        memberships.map((membership) => ctx.db.get(membership.strategyId)),
      );
      candidates.push(
        ...shared.filter(
          (strategy): strategy is Doc<"strategies"> =>
            strategy !== null &&
            strategy.ownerId !== userId &&
            strategy.folderId === undefined,
        ),
      );
    }
  }

  const dedup = new Map<Id<"strategies">, Doc<"strategies">>();
  for (const strategy of candidates) {
    if (
      matchesScope(strategy.ownerId, userId, scope) &&
      (await getEffectiveStrategyRoleForUser(ctx, strategy, userId)) !== null
    ) {
      dedup.set(strategy._id, strategy);
    }
  }
  return Array.from(dedup.values());
}

async function resolveOwnedFolderId(
  ctx: MutationCtx,
  folderPublicId: string | undefined,
  userId: Id<"users">,
) {
  if (folderPublicId === undefined) {
    return undefined;
  }
  const folder = await getFolderByPublicId(ctx, folderPublicId);
  if (folder.ownerId !== userId) {
    throw new Error("Forbidden");
  }
  return folder._id;
}

async function assertInitialPagePublicIdAvailable(
  ctx: MutationCtx,
  pagePublicId: string,
  allowedStrategyId?: Id<"strategies">,
) {
  const existingPage = await ctx.db
    .query("pages")
    .withIndex("by_publicId", (q) => q.eq("publicId", pagePublicId))
    .first();
  if (
    existingPage !== null &&
    (allowedStrategyId === undefined ||
      existingPage.strategyId !== allowedStrategyId)
  ) {
    throw new Error(`Page publicId already exists: ${pagePublicId}`);
  }
}

async function insertInitialPage(
  ctx: MutationCtx,
  args: {
    strategyId: Id<"strategies">;
    initialPage: InitialPageInput;
    now: number;
  },
) {
  await ctx.db.insert("pages", {
    publicId: args.initialPage.publicId,
    strategyId: args.strategyId,
    name: args.initialPage.name,
    sortIndex: 0,
    isAttack: args.initialPage.isAttack,
    settings: args.initialPage.settings,
    revision: 1,
    createdAt: args.now,
    updatedAt: args.now,
  });
}

async function createStrategyWithInitialPageRecord(
  ctx: MutationCtx,
  args: StrategyCreateInput,
  userId: Id<"users">,
  initialPage: InitialPageInput,
) {
  const now = Date.now();
  const folderId = await resolveOwnedFolderId(ctx, args.folderPublicId, userId);

  const existing = await ctx.db
    .query("strategies")
    .withIndex("by_publicId", (q) => q.eq("publicId", args.publicId))
    .collect();
  const existingOwned = existing.find((item) => item.ownerId === userId);
  if (existingOwned !== undefined) {
    const pages = await ctx.db
      .query("pages")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", existingOwned._id))
      .collect();
    if (pages.length === 0) {
      await assertInitialPagePublicIdAvailable(
        ctx,
        initialPage.publicId,
        existingOwned._id,
      );
      await insertInitialPage(ctx, {
        strategyId: existingOwned._id,
        initialPage,
        now,
      });
    }
    return { ok: true, reused: true };
  }
  if (existing.length > 0) {
    throw new Error(`Strategy publicId already exists: ${args.publicId}`);
  }

  await assertInitialPagePublicIdAvailable(ctx, initialPage.publicId);

  const strategyId = await ctx.db.insert("strategies", {
    publicId: args.publicId,
    ownerId: userId,
    folderId,
    name: args.name,
    mapData: args.mapData,
    sequence: 0,
    themeProfileId: args.themeProfileId,
    themeOverridePalette: args.themeOverridePalette,
    createdAt: now,
    updatedAt: now,
  });

  await insertInitialPage(ctx, {
    strategyId,
    initialPage,
    now,
  });

  return { ok: true };
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

    const strategies = await listStrategiesInFolder(
      ctx,
      folderId,
      user._id,
      scope,
    );
    return await summarizeStrategies(ctx, strategies, user._id);
  },
});

export const listSharedWithMe = query({
  args: {},
  handler: async (ctx) => {
    const user = await requireCurrentUser(ctx);
    const memberships = await ctx.db
      .query("strategyCollaborators")
      .withIndex("by_userId", (q) => q.eq("userId", user._id))
      .collect();
    const shared = await Promise.all(
      memberships.map((membership) => ctx.db.get(membership.strategyId)),
    );
    const strategies = shared.filter(
      (strategy): strategy is Doc<"strategies"> =>
        strategy !== null &&
        strategy.ownerId !== user._id &&
        strategy.folderId === undefined,
    );
    return await summarizeStrategies(ctx, strategies, user._id);
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
    themeOverridePalette: v.optional(mapThemePaletteValidator),
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    return await createStrategyWithInitialPageRecord(ctx, args, user._id, {
      publicId: createPublicId(),
      name: "Page 1",
      isAttack: true,
    });
  },
});

export const createWithInitialPage = mutation({
  args: {
    publicId: v.string(),
    name: v.string(),
    mapData: v.string(),
    initialPagePublicId: v.string(),
    initialPageName: v.string(),
    initialPageIsAttack: v.boolean(),
    initialPageSettings: v.optional(strategySettingsValidator),
    folderPublicId: v.optional(v.string()),
    themeProfileId: v.optional(v.string()),
    themeOverridePalette: v.optional(mapThemePaletteValidator),
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    return await createStrategyWithInitialPageRecord(ctx, args, user._id, {
      publicId: args.initialPagePublicId,
      name: args.initialPageName,
      isAttack: args.initialPageIsAttack,
      settings: args.initialPageSettings,
    });
  },
});

export const update = mutation({
  args: {
    strategyPublicId: v.string(),
    name: v.optional(v.string()),
    mapData: v.optional(v.string()),
    themeProfileId: v.optional(v.string()),
    clearThemeProfileId: v.optional(v.boolean()),
    themeOverridePalette: v.optional(mapThemePaletteValidator),
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
