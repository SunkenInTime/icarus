import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import {
  deleteStrategyAgentSummary,
  refreshStrategyAgentSummary,
} from "./lib/strategyAgentSummary";
import {
  collectAssetIdFromElementPayload,
  collectAssetIdsFromLineupPayload,
  copyActiveAssetToStrategy,
} from "./lib/imageAssets";
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
import { markDeletedStrategyImageAssetsRef } from "./images";
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

type LineupData = Doc<"lineups">["payload"]["data"];

function isJsonObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/// A lineup group's data under a new group id. The group's agent and its
/// items' abilities name the group they belong to, so they move with it.
function lineupGroupDataWithId(data: LineupData, id: string): LineupData {
  const { agent, items } = data;
  return {
    ...data,
    id,
    ...(isJsonObject(agent) ? { agent: { ...agent, lineUpID: id } } : {}),
    ...(Array.isArray(items)
      ? {
          items: items.map((item) =>
            isJsonObject(item) && isJsonObject(item.ability)
              ? { ...item, ability: { ...item.ability, lineUpID: id } }
              : item,
          ),
        }
      : {}),
  } as LineupData;
}

type LineupPayload = Doc<"lineups">["payload"];

/// New entity ids for a copied strategy's lineups, one map per kind (ids
/// repeat across kinds), shared by every row so a link follows its origin
/// and landing to their new ids whatever order the rows are copied in.
function lineupIdMap() {
  const byKind = new Map<string, Map<string, string>>();
  return (kind: string, id: string): string => {
    let ids = byKind.get(kind);
    if (ids === undefined) byKind.set(kind, (ids = new Map()));
    let next = ids.get(id);
    if (next === undefined) ids.set(id, (next = createPublicId()));
    return next;
  };
}

/// A lineup row as the copy stores it: its key and payload under new ids.
/// Graph rows keep the `<kind>:<entity id>` key; a legacy group gets a new
/// group id, which its agent and abilities follow.
function copiedLineupRow(
  payload: LineupPayload,
  newId: (kind: string, id: string) => string,
): { publicId: string; payload: LineupPayload } {
  const data = payload.data;
  const idOf = (value: unknown) => (typeof value === "string" ? value : "");
  switch (payload.kind) {
    case "lineupGroup": {
      const id = createPublicId();
      return {
        publicId: id,
        payload: { ...payload, data: lineupGroupDataWithId(data, id) },
      };
    }
    case "lineupOrigin": {
      const id = newId("lineupOrigin", idOf(data.id));
      const agent = data.agent;
      return {
        publicId: `lineupOrigin:${id}`,
        payload: {
          ...payload,
          data: {
            ...data,
            id,
            ...(isJsonObject(agent) ? { agent: { ...agent, lineUpID: id } } : {}),
          } as LineupData,
        },
      };
    }
    case "lineupLanding": {
      const id = newId("lineupLanding", idOf(data.id));
      const ability = data.ability;
      return {
        publicId: `lineupLanding:${id}`,
        payload: {
          ...payload,
          data: {
            ...data,
            id,
            ...(isJsonObject(ability)
              ? { ability: { ...ability, lineUpID: id } }
              : {}),
          } as LineupData,
        },
      };
    }
    case "lineupLink": {
      const id = newId("lineupLink", idOf(data.id));
      return {
        publicId: `lineupLink:${id}`,
        payload: {
          ...payload,
          data: {
            ...data,
            id,
            originId: newId("lineupOrigin", idOf(data.originId)),
            landingId: newId("lineupLanding", idOf(data.landingId)),
          } as LineupData,
        },
      };
    }
  }
}

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
    const source = await getStrategyByPublicId(
      ctx,
      args.sourceStrategyPublicId,
    );
    const { user } = await assertStrategyRole(ctx, source, "editor");

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

    const pageIdMap = new Map<Id<"pages">, Id<"pages">>();
    const sourcePages = await ctx.db
      .query("pages")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", source._id))
      .collect();
    for (const page of sourcePages) {
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
      pageIdMap.set(page._id, pageId);
      const content = await ctx.db
        .query("pageContents")
        .withIndex("by_pageId", (q) => q.eq("pageId", page._id))
        .first();
      await ctx.db.insert("pageContents", {
        pageId,
        settings: content?.settings,
        revision: 1,
        createdAt: now,
        updatedAt: now,
      });
    }

    // Each image the copy shows, keyed by its asset id in the copy, mapped to
    // its asset id in the source. A placed image's asset id is its element id,
    // which the copy renames; lineup images keep their ids, since asset ids
    // are scoped to a strategy.
    const sourceAssetIdByCopyId = new Map<string, string>();

    const sourceElements = await ctx.db
      .query("elements")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", source._id))
      .collect();
    for (const element of sourceElements) {
      const pageId = pageIdMap.get(element.pageId);
      if (element.deleted || pageId === undefined) continue;
      const publicId = createPublicId();
      const sourceAssetId =
        element.elementType === "image"
          ? collectAssetIdFromElementPayload(element.payload)
          : null;
      if (sourceAssetId !== null) {
        sourceAssetIdByCopyId.set(publicId, sourceAssetId);
      }
      await ctx.db.insert("elements", {
        publicId,
        strategyId,
        pageId,
        elementType: element.elementType,
        payloadKind: element.payloadKind,
        payloadVersion: element.payloadVersion,
        payload: {
          ...element.payload,
          data: { ...element.payload.data, id: publicId },
        },
        sortIndex: element.sortIndex,
        revision: 1,
        deleted: false,
        createdAt: now,
        updatedAt: now,
      });
    }

    const sourceLineups = await ctx.db
      .query("lineups")
      .withIndex("by_strategyId", (q) => q.eq("strategyId", source._id))
      .collect();
    const newLineupId = lineupIdMap();
    for (const lineup of sourceLineups) {
      const pageId = pageIdMap.get(lineup.pageId);
      if (lineup.deleted || pageId === undefined) continue;
      for (const assetId of collectAssetIdsFromLineupPayload(lineup.payload)) {
        sourceAssetIdByCopyId.set(assetId, assetId);
      }
      const copy = copiedLineupRow(lineup.payload, newLineupId);
      await ctx.db.insert("lineups", {
        publicId: copy.publicId,
        strategyId,
        pageId,
        payloadKind: lineup.payloadKind,
        payloadVersion: lineup.payloadVersion,
        payload: copy.payload,
        sortIndex: lineup.sortIndex,
        revision: 1,
        deleted: false,
        createdAt: now,
        updatedAt: now,
      });
    }

    for (const [targetAssetPublicId, sourceAssetPublicId] of
      sourceAssetIdByCopyId) {
      const copied = await copyActiveAssetToStrategy(ctx, {
        sourceStrategyId: source._id,
        sourceAssetPublicId,
        targetStrategyId: strategyId,
        targetAssetPublicId,
        userId: user._id,
        now,
      });
      if (copied === "uploading") {
        // Throwing discards the whole copy. A retry once the upload lands
        // copies the image instead of leaving the copy without it for good.
        throw conflictError(
          "An image in this strategy is still uploading. Try again once it finishes.",
        );
      }
    }

    await refreshStrategyAgentSummary(ctx, strategyId);
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
    return { ok: true } as const;
  },
});

export { deleteStrategy as delete };
