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
        iconCodePoint: f.iconCodePoint ?? null,
        iconFontFamily: f.iconFontFamily ?? null,
        iconFontPackage: f.iconFontPackage ?? null,
        color: f.color ?? null,
        customColorValue: f.customColorValue ?? null,
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
    iconCodePoint: v.optional(v.number()),
    iconFontFamily: v.optional(v.string()),
    iconFontPackage: v.optional(v.string()),
    color: v.optional(v.string()),
    customColorValue: v.optional(v.number()),
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

    const existing = await ctx.db
      .query("folders")
      .withIndex("by_publicId", (q) => q.eq("publicId", args.publicId))
      .collect();
    const existingOwned = existing.find((item) => item.ownerId === user._id);
    if (existingOwned !== undefined) {
      return { ok: true, reused: true };
    }
    if (existing.length > 0) {
      throw new Error(`Folder publicId already exists: ${args.publicId}`);
    }

    await ctx.db.insert("folders", {
      publicId: args.publicId,
      ownerId: user._id,
      name: args.name,
      parentFolderId,
      iconCodePoint: args.iconCodePoint,
      iconFontFamily: args.iconFontFamily,
      iconFontPackage: args.iconFontPackage,
      color: args.color,
      customColorValue: args.customColorValue,
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
    iconCodePoint: v.optional(v.number()),
    iconFontFamily: v.optional(v.string()),
    iconFontPackage: v.optional(v.string()),
    clearIconFontFamily: v.optional(v.boolean()),
    clearIconFontPackage: v.optional(v.boolean()),
    color: v.optional(v.string()),
    customColorValue: v.optional(v.number()),
    clearCustomColorValue: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const user = await requireCurrentUser(ctx);
    const folder = await getFolderByPublicId(ctx, args.folderPublicId);

    if (folder.ownerId !== user._id) {
      throw new Error("Forbidden");
    }

    const patch: {
      name?: string;
      iconCodePoint?: number;
      iconFontFamily?: string;
      iconFontPackage?: string;
      color?: string;
      customColorValue?: number;
      updatedAt: number;
    } = {
      updatedAt: Date.now(),
    };

    if (args.name !== undefined) {
      patch.name = args.name;
    }
    if (args.iconCodePoint !== undefined) {
      patch.iconCodePoint = args.iconCodePoint;
    }
    if (args.clearIconFontFamily === true) {
      patch.iconFontFamily = undefined;
    } else if (args.iconFontFamily !== undefined) {
      patch.iconFontFamily = args.iconFontFamily;
    }
    if (args.clearIconFontPackage === true) {
      patch.iconFontPackage = undefined;
    } else if (args.iconFontPackage !== undefined) {
      patch.iconFontPackage = args.iconFontPackage;
    }
    if (args.color !== undefined) {
      patch.color = args.color;
    }
    if (args.clearCustomColorValue === true) {
      patch.customColorValue = undefined;
    } else if (args.customColorValue !== undefined) {
      patch.customColorValue = args.customColorValue;
    }

    await ctx.db.patch(folder._id, patch);
    return { ok: true };
  },
});

export const listAll = query({
  args: {},
  handler: async (ctx) => {
    const user = await requireCurrentUser(ctx);
    const folders = await ctx.db
      .query("folders")
      .withIndex("by_ownerId", (q) => q.eq("ownerId", user._id))
      .collect();

    return folders
      .sort((a, b) => a.createdAt - b.createdAt)
      .map((f) => ({
        publicId: f.publicId,
        name: f.name,
        iconCodePoint: f.iconCodePoint ?? null,
        iconFontFamily: f.iconFontFamily ?? null,
        iconFontPackage: f.iconFontPackage ?? null,
        color: f.color ?? null,
        customColorValue: f.customColorValue ?? null,
        parentFolderPublicId:
          f.parentFolderId === undefined
            ? null
            : folders.find((p) => p._id === f.parentFolderId)?.publicId ?? null,
        createdAt: f.createdAt,
        updatedAt: f.updatedAt,
      }));
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
