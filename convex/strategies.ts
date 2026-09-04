import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import type { MutationCtx, QueryCtx } from "./_generated/server";
import {
  assertFolderRole,
  assertStrategyRole,
  getEffectiveFolderRoleForUser,
  getEffectiveStrategyRoleForUser,
  higherRole,
  requireCurrentUser,
} from "./lib/auth";
import type { StrategyRole } from "./lib/auth";
import { getFolderByPublicId, getStrategyByPublicId } from "./lib/entities";
import {
  assertSupportedCloudProtocol,
  cloudProtocolArgs,
} from "./lib/cloudProtocol";
import {
  mapThemePaletteValidator,
  strategySettingsValidator,
} from "./lib/payloadValidators";
import {
  conflictError,
  forbiddenError,
} from "./lib/errors";
import { purgeDeletedPageOrphansRef } from "./maintenance";
import {
  createResultValidator,
  okResultValidator,
  revisionResultValidator,
  strategyHeaderValidator,
  strategySummaryValidator,
} from "./lib/publicValidators";

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
  isAutoNamed?: boolean;
  isAttack: boolean;
  settings?: Doc<"pageContents">["settings"];
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
  const strategyRoleById = new Map<Id<"strategies">, "viewer" | "editor">();
  for (const membership of memberships) {
    strategyRoleById.set(membership.strategyId, membership.role);
  }

  const folderById = new Map<Id<"folders">, Promise<Doc<"folders"> | null>>();
  const folderRoleById = new Map<
    Id<"folders">,
    Promise<StrategyRole | null>
  >();

  const getFolder = (folderId: Id<"folders">): Promise<Doc<"folders"> | null> => {
    const cached = folderById.get(folderId);
    if (cached !== undefined) {
      return cached;
    }

    const promise = ctx.db.get(folderId);
    folderById.set(folderId, promise);
    return promise;
  };

  const getFolderRole = (
    folderId: Id<"folders">,
  ): Promise<StrategyRole | null> => {
    const cached = folderRoleById.get(folderId);
    if (cached !== undefined) {
      return cached;
    }

    const promise = (async () => {
      const folder = await getFolder(folderId);
      if (folder === null) {
        return null;
      }
      return await getEffectiveFolderRoleForUser(ctx, folder, userId);
    })();
    folderRoleById.set(folderId, promise);
    return promise;
  };

  const orderedStrategies = [...strategies].sort((a, b) => b.updatedAt - a.updatedAt);

  return await Promise.all(orderedStrategies.map(async (strategy): Promise<{
    publicId: string;
    name: string;
    mapData: string;
    revision: number;
    createdAt: number;
    updatedAt: number;
    role: StrategyRole;
    attackLabel: "Unknown" | "Mixed" | "Attack" | "Defend";
    folderPublicId: string | null;
    themeProfileId: string | null;
    themeOverridePalette:
      | NonNullable<Doc<"strategies">["themeOverridePalette"]>
      | null;
  }> => {
    const pagesPromise = ctx.db
      .query("pages")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
      .take(100);
    const folderPromise =
      strategy.folderId === undefined
        ? Promise.resolve(null)
        : getFolder(strategy.folderId);
    const folderRolePromise =
      strategy.folderId === undefined || strategy.ownerId === userId
        ? Promise.resolve(null)
        : getFolderRole(strategy.folderId);
    const [pages, folder, folderRole] = await Promise.all([
      pagesPromise,
      folderPromise,
      folderRolePromise,
    ]);
    let attackLabel: "Unknown" | "Mixed" | "Attack" | "Defend" = "Unknown";
    if (pages.length > 0) {
      const first = pages[0]!.isAttack;
      const mixed = pages.some((page) => page.isAttack !== first);
      attackLabel = mixed ? "Mixed" : first ? "Attack" : "Defend";
    }

    let role: StrategyRole;
    if (strategy.ownerId === userId) {
      role = "owner";
    } else {
      const directRole = strategyRoleById.get(strategy._id);
      role = higherRole(directRole ?? null, folderRole) ?? "viewer";
    }

    return {
      publicId: strategy.publicId,
      name: strategy.name,
      mapData: strategy.mapData,
      revision: strategy.revision,
      createdAt: strategy.createdAt,
      updatedAt: strategy.updatedAt,
      role,
      attackLabel,
      folderPublicId:
        strategy.folderId === undefined ? null : (folder?.publicId ?? null),
      themeProfileId: strategy.themeProfileId ?? null,
      themeOverridePalette: strategy.themeOverridePalette ?? null,
    };
  }));
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
    throw forbiddenError();
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
    throw conflictError(`Page publicId already exists: ${pagePublicId}`);
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
  const pageId = await ctx.db.insert("pages", {
    publicId: args.initialPage.publicId,
    strategyId: args.strategyId,
    name: args.initialPage.name,
    ...(args.initialPage.isAutoNamed === undefined
      ? {}
      : { isAutoNamed: args.initialPage.isAutoNamed }),
    sortIndex: 0,
    isAttack: args.initialPage.isAttack,
    revision: 1,
    createdAt: args.now,
    updatedAt: args.now,
  });
  await ctx.db.insert("pageContents", {
    pageId,
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
    return { ok: true, reused: true } as const;
  }
  if (existing.length > 0) {
    throw conflictError(`Strategy publicId already exists: ${args.publicId}`);
  }

  await assertInitialPagePublicIdAvailable(ctx, initialPage.publicId);

  const strategyId = await ctx.db.insert("strategies", {
    publicId: args.publicId,
    ownerId: userId,
    folderId,
    name: args.name,
    mapData: args.mapData,
    revision: 0,
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

  return { ok: true } as const;
}

export const listForFolder = query({
  args: {
    folderPublicId: v.optional(v.string()),
    scope: strategyScopeValidator,
  },
  returns: v.array(strategySummaryValidator),
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
  returns: v.array(strategySummaryValidator),
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
  returns: strategyHeaderValidator,
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    const { role } = await assertStrategyRole(ctx, strategy, "viewer");

    return {
      publicId: strategy.publicId,
      name: strategy.name,
      mapData: strategy.mapData,
      revision: strategy.revision,
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
    ...cloudProtocolArgs,
    publicId: v.string(),
    name: v.string(),
    mapData: v.string(),
    folderPublicId: v.optional(v.string()),
    themeProfileId: v.optional(v.string()),
    themeOverridePalette: v.optional(mapThemePaletteValidator),
  },
  returns: createResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const user = await requireCurrentUser(ctx);
    return await createStrategyWithInitialPageRecord(ctx, args, user._id, {
      publicId: createPublicId(),
      name: "Page 1",
      isAutoNamed: true,
      isAttack: true,
    });
  },
});

export const createWithInitialPage = mutation({
  args: {
    ...cloudProtocolArgs,
    publicId: v.string(),
    name: v.string(),
    mapData: v.string(),
    initialPagePublicId: v.string(),
    initialPageName: v.string(),
    initialPageIsAutoNamed: v.optional(v.boolean()),
    initialPageIsAttack: v.boolean(),
    initialPageSettings: v.optional(strategySettingsValidator),
    folderPublicId: v.optional(v.string()),
    themeProfileId: v.optional(v.string()),
    themeOverridePalette: v.optional(mapThemePaletteValidator),
  },
  returns: createResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const user = await requireCurrentUser(ctx);
    return await createStrategyWithInitialPageRecord(ctx, args, user._id, {
      publicId: args.initialPagePublicId,
      name: args.initialPageName,
      isAutoNamed: args.initialPageIsAutoNamed,
      isAttack: args.initialPageIsAttack,
      settings: args.initialPageSettings,
    });
  },
});

export const update = mutation({
  args: {
    ...cloudProtocolArgs,
    strategyPublicId: v.string(),
    expectedRevision: v.number(),
    name: v.optional(v.string()),
    mapData: v.optional(v.string()),
    themeProfileId: v.optional(v.string()),
    clearThemeProfileId: v.optional(v.boolean()),
    themeOverridePalette: v.optional(mapThemePaletteValidator),
    clearThemeOverridePalette: v.optional(v.boolean()),
  },
  returns: revisionResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");

    const patch: Record<string, unknown> = {};

    if (args.name !== undefined && args.name !== strategy.name) {
      patch.name = args.name;
    }
    if (args.mapData !== undefined && args.mapData !== strategy.mapData) {
      patch.mapData = args.mapData;
    }

    if (args.clearThemeProfileId === true) {
      if (strategy.themeProfileId !== undefined) {
        patch.themeProfileId = undefined;
      }
    } else if (
      args.themeProfileId !== undefined &&
      args.themeProfileId !== strategy.themeProfileId
    ) {
      patch.themeProfileId = args.themeProfileId;
    }

    if (args.clearThemeOverridePalette === true) {
      if (strategy.themeOverridePalette !== undefined) {
        patch.themeOverridePalette = undefined;
      }
    } else if (args.themeOverridePalette !== undefined) {
      patch.themeOverridePalette = args.themeOverridePalette;
    }

    if (Object.keys(patch).length === 0) {
      return { ok: true, reused: true, revision: strategy.revision } as const;
    }
    if (args.expectedRevision !== strategy.revision) {
      throw conflictError("Strategy revision mismatch");
    }

    const revision = strategy.revision + 1;
    await ctx.db.patch(strategy._id, {
      ...patch,
      revision,
      updatedAt: Date.now(),
    });
    return { ok: true, revision } as const;
  },
});

export const move = mutation({
  args: {
    ...cloudProtocolArgs,
    strategyPublicId: v.string(),
    expectedRevision: v.number(),
    folderPublicId: v.optional(v.string()),
  },
  returns: revisionResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "editor");

    if (args.expectedRevision !== strategy.revision) {
      throw conflictError("Strategy revision mismatch");
    }

    let folderId;
    if (args.folderPublicId !== undefined) {
      const folder = await getFolderByPublicId(ctx, args.folderPublicId);
      if (folder.ownerId !== strategy.ownerId) {
        throw forbiddenError();
      }
      folderId = folder._id;
    }

    const revision = strategy.revision + 1;
    await ctx.db.patch(strategy._id, {
      folderId,
      revision,
      updatedAt: Date.now(),
    });

    return { ok: true, revision } as const;
  },
});

const deleteStrategy = mutation({
  args: {
    ...cloudProtocolArgs,
    strategyPublicId: v.string(),
    expectedRevision: v.number(),
  },
  returns: okResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "owner");
    if (args.expectedRevision !== strategy.revision) {
      throw conflictError("Strategy revision mismatch");
    }

    const pages = await ctx.db
      .query("pages")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
      .collect();

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

    await ctx.db.delete(strategy._id);
    return { ok: true } as const;
  },
});

export { deleteStrategy as delete };
