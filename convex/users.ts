import { mutation, query } from "./_generated/server";
import {
  findUserByIdentity,
  getCanonicalExternalId,
} from "./lib/auth";
import { unauthenticatedError } from "./lib/errors";

export const ensureCurrentUser = mutation({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (identity === null) {
      throw unauthenticatedError();
    }

    const externalId = getCanonicalExternalId(identity);
    const displayName = identity.name ?? identity.nickname ?? "Discord user";
    const avatarUrl = identity.pictureUrl ?? undefined;

    const existingUser = await findUserByIdentity(ctx, identity);

    if (existingUser !== null) {
      await ctx.db.patch(existingUser._id, {
        externalId,
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

    const user = await findUserByIdentity(ctx, identity);

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
