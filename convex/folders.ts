import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import { requireCurrentUser } from "./lib/auth";
import { getFolderByPublicId } from "./lib/entities";

export const listForParent = query({
  args: {
    parentFolderPublicId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);

    let parentFolderId;
    if (args.parentFolderPublicId !== undefined) {
      const parent = await getFolderByPublicId(ctx, args.parentFolderPublicId);
      if (parent.ownerId !== user._id) {
        throw new Error("Forbidden");
      }
      parentFolderId = parent._id;
    }

    const folders = await ctx.db
      .query("folders")
      .withIndex("by_ownerId", (q) => q.eq("ownerId", user._id))
      .collect();

    return folders
      .filter((f) => f.parentFolderId === parentFolderId)
      .sort((a, b) => a.createdAt - b.createdAt)
      .map((f) => ({
        publicId: f.publicId,
        name: f.name,
        parentFolderPublicId:
          f.parentFolderId === undefined
            ? null
            : folders.find((p) => p._id === f.parentFolderId)?.publicId ?? null,
        createdAt: f.createdAt,
        updatedAt: f.updatedAt,
      }));
  },
});

export const create = mutation({
  args: {
    publicId: v.string(),
    name: v.string(),
    parentFolderPublicId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    const now = Date.now();

    let parentFolderId;
    if (args.parentFolderPublicId !== undefined) {
      const parent = await getFolderByPublicId(ctx, args.parentFolderPublicId);
      if (parent.ownerId !== user._id) {
        throw new Error("Forbidden");
      }
      parentFolderId = parent._id;
    }

    await ctx.db.insert("folders", {
      publicId: args.publicId,
      ownerId: user._id,
      name: args.name,
      parentFolderId,
      createdAt: now,
      updatedAt: now,
    });

    return { ok: true };
  },
});

export const update = mutation({
  args: {
    folderPublicId: v.string(),
    name: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    const folder = await getFolderByPublicId(ctx, args.folderPublicId);

    if (folder.ownerId !== user._id) {
      throw new Error("Forbidden");
    }

    const patch: { name?: string; updatedAt: number } = {
      updatedAt: Date.now(),
    };

    if (args.name !== undefined) {
      patch.name = args.name;
    }

    await ctx.db.patch(folder._id, patch);
    return { ok: true };
  },
});

export const move = mutation({
  args: {
    folderPublicId: v.string(),
    parentFolderPublicId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    const folder = await getFolderByPublicId(ctx, args.folderPublicId);

    if (folder.ownerId !== user._id) {
      throw new Error("Forbidden");
    }

    let parentFolderId;
    if (args.parentFolderPublicId !== undefined) {
      const parent = await getFolderByPublicId(ctx, args.parentFolderPublicId);
      if (parent.ownerId !== user._id) {
        throw new Error("Forbidden");
      }
      parentFolderId = parent._id;
    }

    await ctx.db.patch(folder._id, {
      parentFolderId,
      updatedAt: Date.now(),
    });

    return { ok: true };
  },
});

export const deleteFolder = mutation({
  args: {
    folderPublicId: v.string(),
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    const folder = await getFolderByPublicId(ctx, args.folderPublicId);

    if (folder.ownerId !== user._id) {
      throw new Error("Forbidden");
    }

    const children = await ctx.db
      .query("folders")
      .withIndex("by_parentFolderId", (q) => q.eq("parentFolderId", folder._id))
      .collect();
    if (children.length > 0) {
      throw new Error("Folder has children");
    }

    const strategies = await ctx.db
      .query("strategies")
      .withIndex("by_folderId", (q) => q.eq("folderId", folder._id))
      .collect();
    if (strategies.length > 0) {
      throw new Error("Folder has strategies");
    }

    await ctx.db.delete(folder._id);
    return { ok: true };
  },
});

export { deleteFolder as delete };
