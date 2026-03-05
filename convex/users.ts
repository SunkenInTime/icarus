import { mutation } from "./_generated/server";

export const ensureCurrentUser = mutation({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (identity === null) {
      // Convex auth can lag briefly behind Supabase session changes.
      // Treat unauthenticated calls as a no-op and let the next attempt sync.
      return null;
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
      });
      return existingUser._id;
    }

    return await ctx.db.insert("users", {
      externalId,
      displayName,
      avatarUrl,
      createdAt: Date.now(),
    });
  },
});
