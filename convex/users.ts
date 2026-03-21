import { mutation, query } from "./_generated/server";
import { unauthenticatedError } from "./lib/errors";

export const ensureCurrentUser = mutation({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (identity === null) {
      throw unauthenticatedError();
    }

    const externalId = identity.subject ?? identity.tokenIdentifier;
    const displayName = identity.name ?? identity.nickname ?? "Discord user";
    const avatarUrl = identity.pictureUrl ?? undefined;

    const existingUser = await ctx.db
      .query("users")
      .withIndex("by_externalId", (query) => query.eq("externalId", externalId))
      .first();

    if (existingUser !== null) {
      await ctx.db.patch(existingUser._id, {
        displayName,
        avatarUrl,
        updatedAt: Date.now(),
      });
      return existingUser._id;
    }

    return await ctx.db.insert("users", {
      externalId,
      displayName,
      avatarUrl,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    });
  },
});

export const me = query({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (identity === null) {
      return null;
    }

    const externalId = identity.subject ?? identity.tokenIdentifier;
    const user = await ctx.db
      .query("users")
      .withIndex("by_externalId", (query) => query.eq("externalId", externalId))
      .first();

    if (user === null) {
      return null;
    }

    return {
      id: user._id,
      externalId: user.externalId,
      displayName: user.displayName,
      avatarUrl: user.avatarUrl ?? null,
      createdAt: user.createdAt,
      updatedAt: user.updatedAt,
    };
  },
});
