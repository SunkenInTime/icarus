import type { QueryCtx, MutationCtx } from "./_generated/server";
import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import {
  assertFolderRole,
  assertStrategyRole,
  requireCurrentUser,
} from "./lib/auth";
import { getFolderByPublicId, getStrategyByPublicId } from "./lib/entities";

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
  handler: async (ctx, args) => {
    const resolved = await resolveTarget(ctx, args.targetType, args.targetPublicId);

    if (resolved.strategy !== null) {
      const { role } = await assertStrategyRole(ctx, resolved.strategy, "owner");
      if (role !== "owner") {
        throw new Error("Forbidden");
      }
    } else if (resolved.folder !== null) {
      const { role } = await assertFolderRole(ctx, resolved.folder, "owner");
      if (role !== "owner") {
        throw new Error("Forbidden");
      }
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
    targetType: targetTypeValidator,
    targetPublicId: v.string(),
    token: v.string(),
    role: collaboratorRoleValidator,
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    const resolved = await resolveTarget(ctx, args.targetType, args.targetPublicId);

    if (resolved.strategy !== null) {
      const { role } = await assertStrategyRole(ctx, resolved.strategy, "owner");
      if (role !== "owner") {
        throw new Error("Forbidden");
      }
    } else if (resolved.folder !== null) {
      const { role } = await assertFolderRole(ctx, resolved.folder, "owner");
      if (role !== "owner") {
        throw new Error("Forbidden");
      }
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

    return { ok: true };
  },
});

export const revoke = mutation({
  args: {
    targetType: targetTypeValidator,
    targetPublicId: v.string(),
    token: v.string(),
  },
  handler: async (ctx, args) => {
    const resolved = await resolveTarget(ctx, args.targetType, args.targetPublicId);

    if (resolved.strategy !== null) {
      const { role } = await assertStrategyRole(ctx, resolved.strategy, "owner");
      if (role !== "owner") {
        throw new Error("Forbidden");
      }
    } else if (resolved.folder !== null) {
      const { role } = await assertFolderRole(ctx, resolved.folder, "owner");
      if (role !== "owner") {
        throw new Error("Forbidden");
      }
    }

    const link = await ctx.db
      .query("shareLinks")
      .withIndex("by_token", (q) => q.eq("token", args.token))
      .first();

    if (link === null) {
      throw new Error("Share link not found");
    }

    if (
      (resolved.strategy !== null && link.strategyId !== resolved.strategy._id) ||
      (resolved.folder !== null && link.folderId !== resolved.folder._id)
    ) {
      throw new Error("Share link not found");
    }

    await ctx.db.patch(link._id, {
      revokedAt: Date.now(),
      updatedAt: Date.now(),
    });

    return { ok: true };
  },
});

export const redeem = mutation({
  args: {
    token: v.string(),
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    const link = await ctx.db
      .query("shareLinks")
      .withIndex("by_token", (q) => q.eq("token", args.token))
      .first();

    if (link === null) {
      throw new Error("Share link not found");
    }

    if (link.revokedAt !== undefined) {
      throw new Error("Share link revoked");
    }

    if (link.targetType === "strategy") {
      const strategy = link.strategyId === undefined ? null : await ctx.db.get(link.strategyId);
      if (strategy === null) {
        throw new Error("Strategy not found");
      }

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
            createdAt: Date.now(),
            updatedAt: Date.now(),
          });
        } else {
          await ctx.db.patch(existingMembership._id, {
            role: link.role,
            updatedAt: Date.now(),
          });
        }
      }

      const folder =
        strategy.folderId === undefined ? null : await ctx.db.get(strategy.folderId);

      return {
        ok: true,
        targetType: "strategy",
        strategyPublicId: strategy.publicId,
        folderPublicId: folder?.publicId ?? null,
        role: strategy.ownerId === user._id ? "owner" : link.role,
      };
    }

    const folder = link.folderId === undefined ? null : await ctx.db.get(link.folderId);
    if (folder === null) {
      throw new Error("Folder not found");
    }

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
          createdAt: Date.now(),
          updatedAt: Date.now(),
        });
      } else {
        await ctx.db.patch(existingMembership._id, {
          role: link.role,
          updatedAt: Date.now(),
        });
      }
    }

    return {
      ok: true,
      targetType: "folder",
      folderPublicId: folder.publicId,
      role: folder.ownerId === user._id ? "owner" : link.role,
    };
  },
});
