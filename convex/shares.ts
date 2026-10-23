import type { QueryCtx, MutationCtx } from "./_generated/server";
import { query } from "./_generated/server";
import { internalMutation, mutation } from "./lib/functions";
import { makeFunctionReference } from "convex/server";
import { v } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import {
  assertFolderRole,
  assertStrategyRole,
  getEffectiveFolderRoleForUser,
  getEffectiveStrategyRoleForUser,
  higherCollaboratorRole,
  requireCurrentUser,
  type CollaboratorRole,
} from "./lib/auth";
import {
  assertMoveFinished,
  getFolderByPublicId,
  getStrategyByPublicId,
} from "./lib/entities";
import {
  assertSupportedCloudProtocol,
  cloudProtocolArgs,
} from "./lib/cloudProtocol";
import {
  notFoundError,
  errorWithCode,
  conflictError,
  invalidOpError,
} from "./lib/errors";
import { discordAvatarUrl, UNKNOWN_DISPLAY_NAME } from "./lib/profile";
import {
  accessRoleValidator,
  okResultValidator,
} from "./lib/publicValidators";

const targetTypeValidator = v.union(v.literal("strategy"), v.literal("folder"));
const collaboratorRoleValidator = v.union(v.literal("viewer"), v.literal("editor"));
type AnyCtx = QueryCtx | MutationCtx;

async function resolveTarget(
  ctx: AnyCtx,
  targetType: "strategy" | "folder",
  targetPublicId: string,
) {
  if (targetType === "strategy") {
    const strategy = await getStrategyByPublicId(ctx, targetPublicId);
    return { targetType, strategy, folder: null };
  }

  const folder = await getFolderByPublicId(ctx, targetPublicId);
  return { targetType, strategy: null, folder };
}

export const list = query({
  args: {
    targetType: targetTypeValidator,
    targetPublicId: v.string(),
  },
  returns: v.array(
    v.object({
      token: v.string(),
      role: collaboratorRoleValidator,
      createdAt: v.number(),
      revokedAt: v.union(v.number(), v.null()),
    }),
  ),
  handler: async (ctx, args) => {
    const resolved = await resolveTarget(ctx, args.targetType, args.targetPublicId);

    if (resolved.strategy !== null) {
      await assertStrategyRole(ctx, resolved.strategy, "owner");
    } else if (resolved.folder !== null) {
      await assertFolderRole(ctx, resolved.folder, "owner");
    }

    const links =
      resolved.strategy !== null
        ? await ctx.db
            .query("shareLinks")
            .withIndex("by_strategyId", (q) => q.eq("strategyId", resolved.strategy!._id))
            .collect()
        : await ctx.db
            .query("shareLinks")
            .withIndex("by_folderId", (q) => q.eq("folderId", resolved.folder!._id))
            .collect();

    return links
      .sort((a, b) => b.createdAt - a.createdAt)
      .map((link) => ({
        token: link.token,
        role: link.role,
        createdAt: link.createdAt,
        revokedAt: link.revokedAt ?? null,
      }));
  },
});

export const create = mutation({
  args: {
    ...cloudProtocolArgs,
    targetType: targetTypeValidator,
    targetPublicId: v.string(),
    token: v.string(),
    role: collaboratorRoleValidator,
  },
  returns: okResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const user = await requireCurrentUser(ctx);
    const resolved = await resolveTarget(ctx, args.targetType, args.targetPublicId);

    if (resolved.strategy !== null) {
      await assertStrategyRole(ctx, resolved.strategy, "owner");
    } else if (resolved.folder !== null) {
      await assertFolderRole(ctx, resolved.folder, "owner");
    }
    if (resolved.strategy !== null) assertMoveFinished(resolved.strategy);

    const existingLink = await ctx.db
      .query("shareLinks")
      .withIndex("by_token", (q) => q.eq("token", args.token))
      .first();
    if (existingLink !== null) {
      throw conflictError(`Share token already exists: ${args.token}`);
    }

    await ctx.db.insert("shareLinks", {
      token: args.token,
      targetType: args.targetType,
      strategyId: resolved.strategy?._id,
      folderId: resolved.folder?._id,
      role: args.role,
      createdByUserId: user._id,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    });

    return { ok: true } as const;
  },
});

export const revoke = mutation({
  args: {
    ...cloudProtocolArgs,
    targetType: targetTypeValidator,
    targetPublicId: v.string(),
    token: v.string(),
    // Also remove everyone whose access came from this link. Older clients
    // leave it unset and keep the old behavior: people who joined stay.
    removeMembers: v.optional(v.boolean()),
  },
  returns: okResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const resolved = await resolveTarget(ctx, args.targetType, args.targetPublicId);

    if (resolved.strategy !== null) {
      await assertStrategyRole(ctx, resolved.strategy, "owner");
    } else if (resolved.folder !== null) {
      await assertFolderRole(ctx, resolved.folder, "owner");
    }

    const link = await ctx.db
      .query("shareLinks")
      .withIndex("by_token", (q) => q.eq("token", args.token))
      .first();

    if (link === null) {
      throw notFoundError("Share link", args.token);
    }

    if (
      (resolved.strategy !== null && link.strategyId !== resolved.strategy._id) ||
      (resolved.folder !== null && link.folderId !== resolved.folder._id)
    ) {
      throw notFoundError("Share link", args.token);
    }

    if (link.revokedAt === undefined) {
      await ctx.db.patch(link._id, {
        revokedAt: Date.now(),
        updatedAt: Date.now(),
      });
    }

    if (args.removeMembers === true) {
      await removeLinkMembers(ctx, link);
    }

    return { ok: true } as const;
  },
});

/**
 * How many memberships one transaction removes. A link shared widely can
 * have more joiners than one transaction may write (Convex allows 16,000),
 * so the rest go in batches that reschedule themselves.
 */
export const LINK_MEMBER_REMOVAL_BATCH = 500;

const removeLinkMembersBatchRef = makeFunctionReference<"mutation">(
  "shares:removeLinkMembersBatch",
);

/**
 * Removes up to one batch of the people [link] let in, and schedules the
 * next batch when there may be more. Each person loses access when their
 * membership goes, within seconds of the link being disabled.
 */
async function removeLinkMembers(ctx: MutationCtx, link: Doc<"shareLinks">) {
  const batch =
    link.targetType === "strategy"
      ? await ctx.db
          .query("strategyCollaborators")
          .withIndex("by_shareLinkId", (q) => q.eq("shareLinkId", link._id))
          .take(LINK_MEMBER_REMOVAL_BATCH)
      : await ctx.db
          .query("folderCollaborators")
          .withIndex("by_shareLinkId", (q) => q.eq("shareLinkId", link._id))
          .take(LINK_MEMBER_REMOVAL_BATCH);
  for (const membership of batch) {
    await ctx.db.delete(membership._id);
  }
  if (batch.length === LINK_MEMBER_REMOVAL_BATCH) {
    await ctx.scheduler.runAfter(0, removeLinkMembersBatchRef, {
      linkId: link._id,
    });
  }
}

export const removeLinkMembersBatch = internalMutation({
  args: { linkId: v.id("shareLinks") },
  returns: v.null(),
  handler: async (ctx, args) => {
    const link = await ctx.db.get(args.linkId);
    if (link !== null) {
      await removeLinkMembers(ctx, link);
    }
    return null;
  },
});

/**
 * What a share link opens, for someone who holds it but has not redeemed it
 * (usually because they are signed out). Needs no account: the token is the
 * credential, and a strategy link lets its holder view that strategy by
 * passing the token to the read queries. Folders still need an account.
 */
export const resolve = query({
  args: {
    token: v.string(),
  },
  returns: v.union(
    v.object({
      targetType: v.literal("strategy"),
      strategyPublicId: v.string(),
      role: collaboratorRoleValidator,
    }),
    v.object({
      targetType: v.literal("folder"),
      role: collaboratorRoleValidator,
    }),
  ),
  handler: async (ctx, args) => {
    const link = await ctx.db
      .query("shareLinks")
      .withIndex("by_token", (q) => q.eq("token", args.token))
      .first();
    if (link === null) {
      throw notFoundError("Share link", args.token);
    }
    if (link.revokedAt !== undefined) {
      throw errorWithCode("SHARE_LINK_REVOKED", "Share link revoked");
    }

    if (link.targetType === "folder") {
      return { targetType: "folder", role: link.role } as const;
    }
    const strategy =
      link.strategyId === undefined ? null : await ctx.db.get(link.strategyId);
    if (strategy === null) {
      throw notFoundError("Share link", args.token);
    }
    return {
      targetType: "strategy",
      strategyPublicId: strategy.publicId,
      role: link.role,
    } as const;
  },
});

export const redeem = mutation({
  args: {
    ...cloudProtocolArgs,
    token: v.string(),
  },
  returns: v.union(
    v.object({
      ok: v.literal(true),
      targetType: v.literal("strategy"),
      strategyPublicId: v.string(),
      folderPublicId: v.union(v.string(), v.null()),
      role: accessRoleValidator,
      // True when the caller could already open the target (they own it, or
      // already held this role or a higher one), so the link granted nothing.
      // Always sent. Optional only so a client built against this contract
      // still decodes a deployment that predates the field (web deploys on
      // merge; the Convex deployment is updated separately).
      alreadyHadAccess: v.optional(v.boolean()),
    }),
    v.object({
      ok: v.literal(true),
      targetType: v.literal("folder"),
      folderPublicId: v.string(),
      role: accessRoleValidator,
      alreadyHadAccess: v.optional(v.boolean()),
    }),
  ),
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const user = await requireCurrentUser(ctx);
    const link = await ctx.db
      .query("shareLinks")
      .withIndex("by_token", (q) => q.eq("token", args.token))
      .first();

    if (link === null) {
      throw notFoundError("Share link", args.token);
    }

    if (link.revokedAt !== undefined) {
      throw errorWithCode("SHARE_LINK_REVOKED", "Share link revoked");
    }

    if (link.targetType === "strategy") {
      const strategy = link.strategyId === undefined ? null : await ctx.db.get(link.strategyId);
      if (strategy === null) {
        throw notFoundError(
          "Strategy",
          link.strategyId === undefined ? "unknown" : link.strategyId,
        );
      }

      let redeemedRole: CollaboratorRole = link.role;
      let alreadyHadAccess = strategy.ownerId === user._id;
      if (strategy.ownerId !== user._id) {
        const existingMembership = await ctx.db
          .query("strategyCollaborators")
          .withIndex("by_strategyId_userId", (q) =>
            q.eq("strategyId", strategy._id).eq("userId", user._id),
          )
          .first();

        if (existingMembership === null) {
          await ctx.db.insert("strategyCollaborators", {
            strategyId: strategy._id,
            userId: user._id,
            role: link.role,
            invitedByUserId: link.createdByUserId,
            shareLinkId: link._id,
            createdAt: Date.now(),
            updatedAt: Date.now(),
          });
        } else {
          redeemedRole = higherCollaboratorRole(
            existingMembership.role,
            link.role,
          );
          alreadyHadAccess = redeemedRole === existingMembership.role;
          if (!alreadyHadAccess) {
            await ctx.db.patch(existingMembership._id, {
              role: redeemedRole,
              shareLinkId: link._id,
              updatedAt: Date.now(),
            });
          }
        }
      }

      const folder =
        strategy.folderId === undefined ? null : await ctx.db.get(strategy.folderId);

      return {
        ok: true,
        targetType: "strategy",
        strategyPublicId: strategy.publicId,
        folderPublicId: folder?.publicId ?? null,
        role: strategy.ownerId === user._id ? "owner" : redeemedRole,
        alreadyHadAccess,
      } as const;
    }

    const folder = link.folderId === undefined ? null : await ctx.db.get(link.folderId);
    if (folder === null) {
      throw notFoundError("Folder", args.token);
    }

    let redeemedRole: CollaboratorRole = link.role;
    let alreadyHadAccess = folder.ownerId === user._id;
    if (folder.ownerId !== user._id) {
      const existingMembership = await ctx.db
        .query("folderCollaborators")
        .withIndex("by_folderId_userId", (q) =>
          q.eq("folderId", folder._id).eq("userId", user._id),
        )
        .first();

      if (existingMembership === null) {
        await ctx.db.insert("folderCollaborators", {
          folderId: folder._id,
          userId: user._id,
          role: link.role,
          invitedByUserId: link.createdByUserId,
          shareLinkId: link._id,
          createdAt: Date.now(),
          updatedAt: Date.now(),
        });
      } else {
        redeemedRole = higherCollaboratorRole(
          existingMembership.role,
          link.role,
        );
        alreadyHadAccess = redeemedRole === existingMembership.role;
        if (!alreadyHadAccess) {
          await ctx.db.patch(existingMembership._id, {
            role: redeemedRole,
            shareLinkId: link._id,
            updatedAt: Date.now(),
          });
        }
      }
    }

    return {
      ok: true,
      targetType: "folder",
      folderPublicId: folder.publicId,
      role: folder.ownerId === user._id ? "owner" : redeemedRole,
      alreadyHadAccess,
    } as const;
  },
});

async function assertOwnsTarget(
  ctx: AnyCtx,
  resolved: Awaited<ReturnType<typeof resolveTarget>>,
) {
  if (resolved.strategy !== null) {
    await assertStrategyRole(ctx, resolved.strategy, "owner");
  } else if (resolved.folder !== null) {
    await assertFolderRole(ctx, resolved.folder, "owner");
  }
}

/**
 * The membership row [memberId] names, when it gives someone direct access
 * to the resolved target. Rows on anything else, including the folders a
 * strategy sits in, read as not found: they are managed where they live.
 */
async function getDirectMembership(
  ctx: AnyCtx,
  resolved: Awaited<ReturnType<typeof resolveTarget>>,
  memberId: string,
) {
  if (resolved.strategy !== null) {
    const id = ctx.db.normalizeId("strategyCollaborators", memberId);
    const row = id === null ? null : await ctx.db.get(id);
    if (row === null || row.strategyId !== resolved.strategy._id) {
      throw notFoundError("Member", memberId);
    }
    return row;
  }
  const id = ctx.db.normalizeId("folderCollaborators", memberId);
  const row = id === null ? null : await ctx.db.get(id);
  if (row === null || row.folderId !== resolved.folder!._id) {
    throw notFoundError("Member", memberId);
  }
  return row;
}

const memberValidator = v.object({
  // Names this membership for setMemberRole and removeMember.
  memberId: v.string(),
  // Null when the account has never carried a name.
  displayName: v.union(v.string(), v.null()),
  avatarUrl: v.union(v.string(), v.null()),
  role: collaboratorRoleValidator,
  joinedAt: v.number(),
  // The link they joined through, when it is known.
  shareLinkToken: v.union(v.string(), v.null()),
});

/** How many people [listMembers] returns at a time. */
export const MEMBER_PAGE_SIZE = 50;

async function describeMember(
  ctx: AnyCtx,
  row: {
    _id: string;
    userId: Id<"users">;
    role: CollaboratorRole;
    createdAt: number;
    shareLinkId?: Id<"shareLinks">;
  },
) {
  const user = await ctx.db.get(row.userId);
  const link =
    row.shareLinkId === undefined ? null : await ctx.db.get(row.shareLinkId);
  return {
    memberId: row._id,
    displayName: memberName(user),
    // Rows written before avatars were checked can hold any address.
    avatarUrl: discordAvatarUrl(user?.avatarUrl),
    role: row.role,
    joinedAt: row.createdAt,
    shareLinkToken: link?.token ?? null,
  };
}

function memberName(user: Doc<"users"> | null): string | null {
  return user === null || user.displayName === UNKNOWN_DISPLAY_NAME
    ? null
    : user.displayName;
}

/**
 * The people a strategy or folder was shared with directly, oldest first,
 * [MEMBER_PAGE_SIZE] at a time: pass the previous page's [nextCursor] as
 * [cursor] for the next. Only the owner can read them. People who reach it
 * through a folder it sits in are listed with that folder (see
 * [listFolderAccess]).
 */
export const listMembers = query({
  args: {
    targetType: targetTypeValidator,
    targetPublicId: v.string(),
    cursor: v.optional(v.string()),
  },
  returns: v.object({
    members: v.array(memberValidator),
    nextCursor: v.union(v.string(), v.null()),
  }),
  handler: async (ctx, args) => {
    const resolved = await resolveTarget(ctx, args.targetType, args.targetPublicId);
    await assertOwnsTarget(ctx, resolved);
    const pageOpts = { numItems: MEMBER_PAGE_SIZE, cursor: args.cursor ?? null };

    const result =
      resolved.strategy !== null
        ? await ctx.db
            .query("strategyCollaborators")
            .withIndex("by_strategyId", (q) => q.eq("strategyId", resolved.strategy!._id))
            .paginate(pageOpts)
        : await ctx.db
            .query("folderCollaborators")
            .withIndex("by_folderId", (q) => q.eq("folderId", resolved.folder!._id))
            .paginate(pageOpts);
    const members = [];
    for (const row of result.page) {
      members.push(await describeMember(ctx, row));
    }
    return {
      members,
      nextCursor: result.isDone ? null : result.continueCursor,
    };
  },
});

/**
 * The folders a strategy or folder sits in that are shared with someone,
 * nearest first: their people can open it too, and are managed there.
 * Only the owner can read them.
 */
export const listFolderAccess = query({
  args: {
    targetType: targetTypeValidator,
    targetPublicId: v.string(),
  },
  returns: v.array(v.object({ publicId: v.string(), name: v.string() })),
  handler: async (ctx, args) => {
    const resolved = await resolveTarget(ctx, args.targetType, args.targetPublicId);
    await assertOwnsTarget(ctx, resolved);
    const shared = [];
    let parentFolderId =
      resolved.strategy !== null
        ? resolved.strategy.folderId
        : resolved.folder!.parentFolderId;
    while (parentFolderId !== undefined) {
      const folder: Doc<"folders"> | null = await ctx.db.get(parentFolderId);
      if (folder === null) break;
      const anyone = await ctx.db
        .query("folderCollaborators")
        .withIndex("by_folderId", (q) => q.eq("folderId", folder._id))
        .first();
      if (anyone !== null) {
        shared.push({ publicId: folder.publicId, name: folder.name });
      }
      parentFolderId = folder.parentFolderId;
    }
    return shared;
  },
});

/** Past this many, a link's joiners are counted as "more". */
export const LINK_JOIN_COUNT_CAP = 100;

/** How many joiners' names a link's count carries. */
const LINK_JOIN_NAMES = 5;

/**
 * For each link of a strategy or folder, how many people it let in (up to
 * [LINK_JOIN_COUNT_CAP], with [more] past it) and the first few names, so
 * disabling it can say who would be removed. Only the owner can read them.
 */
export const listLinkJoins = query({
  args: {
    targetType: targetTypeValidator,
    targetPublicId: v.string(),
  },
  returns: v.array(
    v.object({
      token: v.string(),
      joined: v.number(),
      more: v.boolean(),
      names: v.array(v.string()),
    }),
  ),
  handler: async (ctx, args) => {
    const resolved = await resolveTarget(ctx, args.targetType, args.targetPublicId);
    await assertOwnsTarget(ctx, resolved);
    const links =
      resolved.strategy !== null
        ? await ctx.db
            .query("shareLinks")
            .withIndex("by_strategyId", (q) => q.eq("strategyId", resolved.strategy!._id))
            .collect()
        : await ctx.db
            .query("shareLinks")
            .withIndex("by_folderId", (q) => q.eq("folderId", resolved.folder!._id))
            .collect();
    const joins = [];
    for (const link of links) {
      const rows =
        link.targetType === "strategy"
          ? await ctx.db
              .query("strategyCollaborators")
              .withIndex("by_shareLinkId", (q) => q.eq("shareLinkId", link._id))
              .take(LINK_JOIN_COUNT_CAP + 1)
          : await ctx.db
              .query("folderCollaborators")
              .withIndex("by_shareLinkId", (q) => q.eq("shareLinkId", link._id))
              .take(LINK_JOIN_COUNT_CAP + 1);
      const names = [];
      for (const row of rows.slice(0, LINK_JOIN_NAMES)) {
        names.push(memberName(await ctx.db.get(row.userId)) ?? "Teammate");
      }
      joins.push({
        token: link.token,
        joined: Math.min(rows.length, LINK_JOIN_COUNT_CAP),
        more: rows.length > LINK_JOIN_COUNT_CAP,
        names,
      });
    }
    return joins;
  },
});

/** Changes what someone the target was shared with directly may do. */
export const setMemberRole = mutation({
  args: {
    ...cloudProtocolArgs,
    targetType: targetTypeValidator,
    targetPublicId: v.string(),
    memberId: v.string(),
    role: collaboratorRoleValidator,
  },
  returns: okResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const resolved = await resolveTarget(ctx, args.targetType, args.targetPublicId);
    await assertOwnsTarget(ctx, resolved);
    const membership = await getDirectMembership(ctx, resolved, args.memberId);
    if (membership.role !== args.role) {
      await ctx.db.patch(membership._id, {
        role: args.role,
        updatedAt: Date.now(),
      });
    }
    return { ok: true } as const;
  },
});

/**
 * Takes away someone's direct access. It ends at their next read or write,
 * since every protected function checks the role again. A share link they
 * still hold lets them join again until it is disabled.
 */
export const removeMember = mutation({
  args: {
    ...cloudProtocolArgs,
    targetType: targetTypeValidator,
    targetPublicId: v.string(),
    memberId: v.string(),
  },
  returns: okResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const resolved = await resolveTarget(ctx, args.targetType, args.targetPublicId);
    await assertOwnsTarget(ctx, resolved);
    const membership = await getDirectMembership(ctx, resolved, args.memberId);
    await ctx.db.delete(membership._id);
    return { ok: true } as const;
  },
});

/**
 * Ends the caller's own direct access to something shared with them.
 * Access through a folder it sits in stays; leaving that folder ends it.
 */
export const leave = mutation({
  args: {
    ...cloudProtocolArgs,
    targetType: targetTypeValidator,
    targetPublicId: v.string(),
  },
  returns: okResultValidator,
  handler: async (ctx, args) => {
    assertSupportedCloudProtocol(args.clientProtocolVersion);
    const user = await requireCurrentUser(ctx);
    const resolved = await resolveTarget(ctx, args.targetType, args.targetPublicId);
    const ownerId = resolved.strategy?.ownerId ?? resolved.folder!.ownerId;
    if (ownerId === user._id) {
      throw invalidOpError("An owner cannot leave what they own");
    }
    const membership =
      resolved.strategy !== null
        ? await ctx.db
            .query("strategyCollaborators")
            .withIndex("by_strategyId_userId", (q) =>
              q.eq("strategyId", resolved.strategy!._id).eq("userId", user._id),
            )
            .first()
        : await ctx.db
            .query("folderCollaborators")
            .withIndex("by_folderId_userId", (q) =>
              q.eq("folderId", resolved.folder!._id).eq("userId", user._id),
            )
            .first();
    if (membership !== null) {
      await ctx.db.delete(membership._id);
    }
    return { ok: true } as const;
  },
});

/**
 * What a share link opens, for a signed-in person deciding whether to add
 * it: the name, the access the link gives, and the access they already
 * have. Reading it joins nothing; shares:redeem does.
 */
export const preview = query({
  args: {
    token: v.string(),
  },
  returns: v.union(
    v.object({
      targetType: v.literal("strategy"),
      publicId: v.string(),
      name: v.string(),
      linkRole: collaboratorRoleValidator,
      myRole: v.union(accessRoleValidator, v.null()),
    }),
    v.object({
      targetType: v.literal("folder"),
      publicId: v.string(),
      name: v.string(),
      linkRole: collaboratorRoleValidator,
      myRole: v.union(accessRoleValidator, v.null()),
    }),
  ),
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    const link = await ctx.db
      .query("shareLinks")
      .withIndex("by_token", (q) => q.eq("token", args.token))
      .first();
    if (link === null) {
      throw notFoundError("Share link", args.token);
    }
    if (link.revokedAt !== undefined) {
      throw errorWithCode("SHARE_LINK_REVOKED", "Share link revoked");
    }

    if (link.targetType === "strategy") {
      const strategy =
        link.strategyId === undefined ? null : await ctx.db.get(link.strategyId);
      if (strategy === null) {
        throw notFoundError("Share link", args.token);
      }
      return {
        targetType: "strategy",
        publicId: strategy.publicId,
        name: strategy.name,
        linkRole: link.role,
        myRole: await getEffectiveStrategyRoleForUser(ctx, strategy, user._id),
      } as const;
    }

    const folder =
      link.folderId === undefined ? null : await ctx.db.get(link.folderId);
    if (folder === null) {
      throw notFoundError("Share link", args.token);
    }
    return {
      targetType: "folder",
      publicId: folder.publicId,
      name: folder.name,
      linkRole: link.role,
      myRole: await getEffectiveFolderRoleForUser(ctx, folder, user._id),
    } as const;
  },
});
