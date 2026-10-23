import { query } from "./_generated/server";
import { mutation } from "./lib/functions";
import { getConvexSize, v } from "convex/values";
import {
  agentTypesOf,
  deleteStrategyAgentSummary,
  readStrategyAgentTypes,
  refreshStrategyAgentSummary,
  storeStrategyAgentSummary,
} from "./lib/strategyAgentSummary";
import {
  ContentCopy,
  CopyBudget,
  createPublicId,
} from "./lib/contentCopy";
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
import {
  assertMoveFinished,
  assertWithinFolder,
  getFolderByPublicId,
  getStrategyByPublicId,
  livePagesQuery,
  isListed,
  listedStrategiesInFolder,
} from "./lib/entities";
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
  errorWithCode,
  forbiddenError,
} from "./lib/errors";
import { purgeDeletedPageOrphansRef } from "./maintenance";
import { markDeletedStrategyImageAssetsRef } from "./images";
import { assertSafeFileNameId } from "./lib/fileNameIds";
import { assertKnownMapChange } from "./lib/maps";
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
  unfinishedMove?: boolean;
};

type InitialPageInput = {
  publicId: string;
  name: string;
  isAutoNamed?: boolean;
  isAttack: boolean;
  settings?: Doc<"pageContents">["settings"];
};

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
  includeAgentTypes: boolean,
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
    agentTypes?: string[];
  }> => {
    const pagesPromise = livePagesQuery(ctx, strategy._id).take(100);
    const folderPromise =
      strategy.folderId === undefined
        ? Promise.resolve(null)
        : getFolder(strategy.folderId);
    const folderRolePromise =
      strategy.folderId === undefined || strategy.ownerId === userId
        ? Promise.resolve(null)
        : getFolderRole(strategy.folderId);
    const agentTypesPromise = includeAgentTypes
      ? readStrategyAgentTypes(ctx, strategy._id)
      : Promise.resolve(undefined);
    const [pages, folder, folderRole, agentTypes] = await Promise.all([
      pagesPromise,
      folderPromise,
      folderRolePromise,
      agentTypesPromise,
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
      ...(agentTypes === undefined ? {} : { agentTypes }),
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
    candidates = await listedStrategiesInFolder(ctx, folderId);
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
      .withIndex("by_ownerId_and_folderId_and_unfinishedMove", (q) =>
        q
          .eq("ownerId", userId)
          .eq("folderId", undefined)
          .eq("unfinishedMove", undefined),
      )
      .collect();

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
      isListed(strategy) &&
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
  assertSafeFileNameId("Strategy id", args.publicId);
  assertKnownMapChange(args.mapData, undefined);
  const now = Date.now();
  const folderId = await resolveOwnedFolderId(ctx, args.folderPublicId, userId);

  const existing = await ctx.db
    .query("strategies")
    .withIndex("by_publicId", (q) => q.eq("publicId", args.publicId))
    .collect();
  const existingOwned = existing.find((item) => item.ownerId === userId);
  if (existingOwned !== undefined) {
    // A retry carries the same move state. Reusing a listed strategy for a
    // move, or a moving one for an ordinary create, would show a partial
    // strategy or hide a finished one.
    if (
      (existingOwned.unfinishedMove === true) !==
      (args.unfinishedMove === true)
    ) {
      throw conflictError(`Strategy publicId already exists: ${args.publicId}`);
    }
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
    ...(args.unfinishedMove === true ? { unfinishedMove: true } : {}),
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
    includeAgentTypes: v.optional(v.boolean()),
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
    return await summarizeStrategies(
      ctx,
      strategies,
      user._id,
      args.includeAgentTypes === true,
    );
  },
});

/// Where every folder and strategy of the caller's own library sits, read
/// in one transaction: a backup checks against it that it holds all of
/// them, which listing folder by folder can't prove while another device
/// moves things. Strategies a move hasn't finished are left out, as in
/// every library list.
export const listInventory = query({
  args: {},
  returns: v.object({
    folders: v.array(
      v.object({
        publicId: v.string(),
        parentFolderPublicId: v.union(v.string(), v.null()),
      }),
    ),
    strategies: v.array(
      v.object({
        publicId: v.string(),
        folderPublicId: v.union(v.string(), v.null()),
      }),
    ),
  }),
  handler: async (ctx) => {
    const user = await requireCurrentUser(ctx);
    const folders = await ctx.db
      .query("folders")
      .withIndex("by_ownerId", (q) => q.eq("ownerId", user._id))
      .collect();
    const folderPublicIds = new Map(
      folders.map((folder) => [folder._id, folder.publicId]),
    );
    // Every strategy of the owner, half-moved ones too (filtered below):
    // this is read once, not watched, so their writes cost nothing here.
    const strategies = await ctx.db
      .query("strategies")
      .withIndex("by_ownerId_and_folderId_and_unfinishedMove", (q) =>
        q.eq("ownerId", user._id),
      )
      .collect();
    return {
      folders: folders.map((folder) => ({
        publicId: folder.publicId,
        parentFolderPublicId:
          folder.parentFolderId === undefined
            ? null
            : (folderPublicIds.get(folder.parentFolderId) ?? null),
      })),
      strategies: strategies.filter(isListed).map((strategy) => ({
        publicId: strategy.publicId,
        folderPublicId:
          strategy.folderId === undefined
            ? null
            : (folderPublicIds.get(strategy.folderId) ?? null),
      })),
    };
  },
});

export const listSharedWithMe = query({
  args: { includeAgentTypes: v.optional(v.boolean()) },
  returns: v.array(strategySummaryValidator),
  handler: async (ctx, args) => {
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
        isListed(strategy) &&
        strategy.ownerId !== user._id &&
        strategy.folderId === undefined,
    );
    return await summarizeStrategies(
      ctx,
      strategies,
      user._id,
      args.includeAgentTypes === true,
    );
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
    // Sent by a device moving a strategy in from its local library: the
    // strategy stays out of library lists until finishMove. Older clients
    // never send it.
    unfinishedMove: v.optional(v.boolean()),
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

/// Copies a strategy into the caller's library in one transaction: pages,
/// page settings, live elements and lineups under fresh publicIds, and an
/// image asset row per image the copy shows. The rows share the source's
/// stored bytes, so deleting either strategy leaves the other's images alone.
export const duplicate = mutation({
  args: {
    ...cloudProtocolArgs,
    sourceStrategyPublicId: v.string(),
    publicId: v.string(),
    name: v.string(),
    folderPublicId: v.optional(v.string()),
  },
  returns: createResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    assertSafeFileNameId("Strategy id", args.publicId);
    const source = await getStrategyByPublicId(
      ctx,
      args.sourceStrategyPublicId,
    );
    const { user } = await assertStrategyRole(ctx, source, "editor");
    assertMoveFinished(source);

    const existing = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", args.publicId))
      .first();
    if (existing !== null) {
      if (existing.ownerId === user._id) {
        // A retry of a duplicate that already committed.
        return { ok: true, reused: true } as const;
      }
      throw conflictError(`Strategy publicId already exists: ${args.publicId}`);
    }

    // A source written before maps were checked must not spread.
    assertKnownMapChange(source.mapData, undefined);

    // The copy lands in the folder the caller is browsing when it is theirs.
    // Browsing a folder someone shared with them, the copy goes to the root
    // of their own library: it is theirs, not the folder owner's.
    const folder =
      args.folderPublicId === undefined
        ? null
        : await ctx.db
            .query("folders")
            .withIndex("by_publicId", (q) =>
              q.eq("publicId", args.folderPublicId!),
            )
            .first();
    const folderId = folder?.ownerId === user._id ? folder._id : undefined;
    const now = Date.now();
    const strategyId = await ctx.db.insert("strategies", {
      publicId: args.publicId,
      ownerId: user._id,
      folderId,
      name: args.name,
      mapData: source.mapData,
      revision: 0,
      themeProfileId: source.themeProfileId,
      themeOverridePalette: source.themeOverridePalette,
      createdAt: now,
      updatedAt: now,
    });

    // One transaction copies everything. Past the budget the whole
    // duplicate is refused with a clear error: the transaction rolls back,
    // so no part of a copy is ever left behind.
    const budget = new CopyBudget(() =>
      errorWithCode(
        "STRATEGY_TOO_LARGE_TO_DUPLICATE",
        "This strategy is too large to duplicate.",
      ),
    );
    const copy = new ContentCopy(ctx, {
      sourceStrategyId: source._id,
      targetStrategyId: strategyId,
      userId: user._id,
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
    await storeStrategyAgentSummary(
      ctx,
      strategyId,
      agentTypesOf(copy.elements, copy.lineupAgents),
    );
    return { ok: true } as const;
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
      assertKnownMapChange(args.mapData, strategy.mapData);
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
    await assertStrategyRole(ctx, strategy, "owner");

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

/// Shows a strategy a move made with unfinishedMove, once the moving device
/// has confirmed every part of it landed. Calling it again changes nothing.
/// Refused (CONFLICT) when the strategy is no longer in [folderPublicId],
/// the folder the move put it in (absent for the top level): someone deleted
/// that folder meanwhile, and the device keeps its original rather than
/// publish the strategy somewhere it did not ask for.
export const finishMove = mutation({
  args: {
    ...cloudProtocolArgs,
    strategyPublicId: v.string(),
    folderPublicId: v.optional(v.string()),
  },
  returns: okResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "owner");
    const folderPublicId = args.folderPublicId;
    const folder =
      folderPublicId === undefined
        ? null
        : await ctx.db
            .query("folders")
            .withIndex("by_publicId", (q) => q.eq("publicId", folderPublicId))
            .first();
    const expectedFolderId =
      folderPublicId === undefined ? undefined : folder?._id;
    if (
      (folderPublicId !== undefined && folder === null) ||
      strategy.folderId !== expectedFolderId
    ) {
      throw conflictError("The strategy is no longer where the move put it");
    }
    if (strategy.unfinishedMove === true) {
      await ctx.db.patch(strategy._id, { unfinishedMove: undefined });
    }
    return { ok: true } as const;
  },
});

const deleteStrategy = mutation({
  args: {
    ...cloudProtocolArgs,
    strategyPublicId: v.string(),
    expectedRevision: v.number(),
    // See assertWithinFolder.
    withinFolderPublicId: v.optional(v.string()),
  },
  returns: okResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    await assertStrategyRole(ctx, strategy, "owner");
    if (args.expectedRevision !== strategy.revision) {
      throw conflictError("Strategy revision mismatch");
    }
    await assertWithinFolder(
      ctx,
      strategy.folderId,
      args.withinFolderPublicId,
    );
    await deleteStrategyRecord(ctx, strategy);
    return { ok: true } as const;
  },
});

export { deleteStrategy as delete };

/// Deletes a strategy a move left unfinished, and only such a strategy:
/// one whose move failed, or that the moving app quit in the middle of. A
/// strategy whose move finished belongs in the library and stays. Says
/// which it found, so a device that lost finishMove's answer can tell its
/// move did finish.
export const abandonMove = mutation({
  args: {
    ...cloudProtocolArgs,
    strategyPublicId: v.string(),
  },
  returns: v.object({
    ok: v.literal(true),
    outcome: v.union(
      v.literal("deleted"),
      v.literal("finished"),
      v.literal("missing"),
    ),
  }),
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const strategy = await ctx.db
      .query("strategies")
      .withIndex("by_publicId", (q) => q.eq("publicId", args.strategyPublicId))
      .first();
    if (strategy === null) return { ok: true, outcome: "missing" } as const;
    await assertStrategyRole(ctx, strategy, "owner");
    if (strategy.unfinishedMove !== true) {
      return { ok: true, outcome: "finished" } as const;
    }
    await deleteStrategyRecord(ctx, strategy);
    return { ok: true, outcome: "deleted" } as const;
  },
});

/// Deletes [strategy] with everything that belongs to it.
async function deleteStrategyRecord(
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
