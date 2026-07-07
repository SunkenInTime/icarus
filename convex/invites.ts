import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import {
  assertStrategyRole,
  getStrategyRoleForUser,
  higherCollaboratorRole,
  requireCurrentUser,
  type CollaboratorRole,
} from "./lib/auth";
import { getStrategyByPublicId } from "./lib/entities";
import {
  forbiddenError,
  invalidOpError,
  notFoundError,
  errorWithCode,
} from "./lib/errors";

export const get = query({
  args: {
    token: v.optional(v.string()),
    strategyPublicId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);

    if (args.token !== undefined) {
      const invite = await ctx.db
        .query("inviteTokens")
        .withIndex("by_token", (q) => q.eq("token", args.token!))
        .first();
      if (invite === null) {
        return null;
      }

      const strategy = await ctx.db.get(invite.strategyId);
      if (strategy === null) {
        return null;
      }

      const role = await getStrategyRoleForUser(ctx, strategy, user._id);
      return {
        token: invite.token,
        strategyPublicId: strategy.publicId,
        inviteRole: invite.role,
        hasAccessAlready: role !== null,
        revoked: invite.revokedAt !== undefined,
        expiresAt: invite.expiresAt ?? null,
        createdAt: invite.createdAt,
      };
    }

    if (args.strategyPublicId !== undefined) {
      const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
      await assertStrategyRole(ctx, strategy, "owner");

      const invites = await ctx.db
        .query("inviteTokens")
        .withIndex("by_strategyId", (q) => q.eq("strategyId", strategy._id))
        .collect();

      return invites
        .sort((a, b) => b.createdAt - a.createdAt)
        .map((invite) => ({
          token: invite.token,
          role: invite.role,
          createdAt: invite.createdAt,
          expiresAt: invite.expiresAt ?? null,
          revokedAt: invite.revokedAt ?? null,
          redeemedByUserId: invite.redeemedByUserId ?? null,
        }));
    }

    throw invalidOpError("Either token or strategyPublicId is required");
  },
});

export const create = mutation({
  args: {
    strategyPublicId: v.string(),
    token: v.string(),
    role: v.union(v.literal("editor"), v.literal("viewer")),
    expiresAt: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    const { user, role } = await assertStrategyRole(ctx, strategy, "owner");
    if (role !== "owner") {
      throw forbiddenError();
    }

    const now = Date.now();
    await ctx.db.insert("inviteTokens", {
      token: args.token,
      strategyId: strategy._id,
      role: args.role,
      createdByUserId: user._id,
      expiresAt: args.expiresAt,
      createdAt: now,
      updatedAt: now,
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
    const invite = await ctx.db
      .query("inviteTokens")
      .withIndex("by_token", (q) => q.eq("token", args.token))
      .first();

    if (invite === null) {
      throw notFoundError("Invite", args.token);
    }

    if (invite.revokedAt !== undefined) {
      throw errorWithCode("INVITE_REVOKED", "Invite revoked");
    }

    if (invite.expiresAt !== undefined && invite.expiresAt < Date.now()) {
      throw errorWithCode("INVITE_EXPIRED", "Invite expired");
    }

    const strategy = await ctx.db.get(invite.strategyId);
    if (strategy === null) {
      throw notFoundError("Strategy", invite.strategyId);
    }

    let redeemedRole: CollaboratorRole = invite.role;
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
          role: invite.role,
          invitedByUserId: invite.createdByUserId,
          createdAt: Date.now(),
          updatedAt: Date.now(),
        });
      } else {
        redeemedRole = higherCollaboratorRole(
          existingMembership.role,
          invite.role,
        );
        if (redeemedRole !== existingMembership.role) {
          await ctx.db.patch(existingMembership._id, {
            role: redeemedRole,
            updatedAt: Date.now(),
          });
        }
      }
    }

    await ctx.db.patch(invite._id, {
      redeemedByUserId: user._id,
      updatedAt: Date.now(),
    });

    return {
      ok: true,
      strategyPublicId: strategy.publicId,
      role: strategy.ownerId === user._id ? "owner" : redeemedRole,
    };
  },
});

export const revoke = mutation({
  args: {
    strategyPublicId: v.string(),
    token: v.string(),
  },
  handler: async (ctx, args) => {
    const strategy = await getStrategyByPublicId(ctx, args.strategyPublicId);
    const { role } = await assertStrategyRole(ctx, strategy, "owner");
    if (role !== "owner") {
      throw forbiddenError();
    }

    const invite = await ctx.db
      .query("inviteTokens")
      .withIndex("by_token", (q) => q.eq("token", args.token))
      .first();

    if (invite === null || invite.strategyId !== strategy._id) {
      throw notFoundError("Invite", args.token);
    }

    await ctx.db.patch(invite._id, {
      revokedAt: Date.now(),
      updatedAt: Date.now(),
    });

    return { ok: true };
  },
});
